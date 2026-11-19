module Shonin
  module Routes
    # Shopping cart and buyer-side orders (cash on delivery; no payments).
    module OrderRoutes
      record Line, product_id : Int64, qty : Int32, store_id : Int64, name : String, price : Int64, stock : Int32, available : Bool

      private def self.cart_lines(user_id : Int64) : Array(Line)
        rows = Shonin.db.query_all(<<-SQL, user_id, as: {Int64, Int32, Int64, String, Int64, Int32, Bool})
          select c.product_id, c.qty, p.store_id, p.name, p.price_cents, p.stock,
                 (#{Products::VISIBLE} and s.owner_id <> c.user_id)
          from cart_items c
          join products p on p.id = c.product_id
          join stores s on s.id = p.store_id
          join users u on u.id = s.owner_id
          where c.user_id = $1
          order by c.product_id
          SQL
        rows.map { |r| Line.new(r[0], r[1], r[2], r[3], r[4], r[5], r[6] && r[5] >= r[1]) }
      end

      def self.register(r : Spectre::Router) : Nil
        # GET /cart
        r.get "/cart", Guards::SESSION do |req, res|
          lines = cart_lines(req.auth!.id)
          total = lines.sum { |l| l.available ? l.price * l.qty : 0_i64 }
          Api.json(res) do |b|
            b.object do
              b.field "items" do
                b.array do
                  lines.each do |l|
                    b.object do
                      b.field "product_id", l.product_id
                      b.field "store_id", l.store_id
                      b.field "name", l.name
                      b.field "price_cents", l.price
                      b.field "qty", l.qty
                      b.field "available", l.available
                    end
                  end
                end
              end
              b.field "total_cents", total
            end
          end
        end

        # PUT /cart/items {"product_id", "qty": 1..99}  (sets the quantity)
        r.put "/cart/items", Guards::USER do |req, res|
          body = Body.parse(req)
          product_id = body.integer!("product_id", 1_i64, Int64::MAX)
          qty = body.integer!("qty", 1_i64, 99_i64)
          user_id = req.auth!.id

          ok = Shonin.db.query_one?(<<-SQL, product_id, as: {Int64, Int64})
            select s.owner_id, p.id from products p
            join stores s on s.id = p.store_id join users u on u.id = s.owner_id
            where p.id = $1 and #{Products::VISIBLE}
            SQL
          fail!(404, "not_found", "Product not found") unless ok
          fail!(422, "own_product", "You cannot buy from your own store") if ok[0] == user_id

          added = Shonin.db.query_one?(<<-SQL, user_id, product_id, qty, Config::MAX_CART_LINES, as: Int32)
            insert into cart_items (user_id, product_id, qty)
            select $1, $2, $3
            where exists (select 1 from cart_items where user_id = $1 and product_id = $2)
               or (select count(*) from cart_items where user_id = $1) < $4
            on conflict (user_id, product_id) do update set qty = excluded.qty
            returning qty
            SQL
          fail!(409, "cart_full", "A cart holds at most #{Config::MAX_CART_LINES} different products") unless added
          Api.message(res, 200, "Cart updated")
        end

        # DELETE /cart/items/:product_id
        r.delete "/cart/items/:product_id", Guards::USER do |req, res|
          Shonin.db.exec "delete from cart_items where user_id = $1 and product_id = $2", req.auth!.id, req.params.int("product_id")
          res.send_status(204)
        end

        # DELETE /cart
        r.delete "/cart", Guards::USER do |req, res|
          Shonin.db.exec "delete from cart_items where user_id = $1", req.auth!.id
          res.send_status(204)
        end

        # POST /orders {"ship_name", "ship_phone", "ship_address", "note"?}
        # Checks out the whole cart. One order per store. Stock is taken with an
        # atomic UPDATE ... WHERE stock >= qty, so concurrent buyers cannot oversell.
        r.post "/orders", Guards::USER do |req, res|
          body = Body.parse(req)
          ship_name = body.string!("ship_name", 2, 100)
          ship_phone = body.string!("ship_phone", 5, 30)
          ship_address = body.string!("ship_address", 5, 500)
          note = body.string("note", 0, 500) || ""
          user_id = req.auth!.id

          lines = cart_lines(user_id)
          fail!(422, "empty_cart", "Your cart is empty") if lines.empty?
          bad = lines.reject(&.available)
          fail!(409, "unavailable_items", "Not available in the requested quantity: #{bad.map(&.name).join(", ")}") unless bad.empty?

          order_ids = [] of Int64
          Shonin.db.transaction do |tx|
            by_store = Hash(Int64, Array({Line, Int64, String?})).new { |h, k| h[k] = [] of {Line, Int64, String?} }
            lines.each do |l| # ordered by product id: consistent lock order, no deadlocks
              got = tx.query_one?(<<-SQL, l.product_id, l.qty, as: {Int64, String?})
                update products p set stock = stock - $2, sold = sold + $2
                where p.id = $1 and p.stock >= $2 and p.status = 'active'
                returning p.price_cents,
                  (select pi.filename from product_images pi where pi.product_id = p.id order by pi.position, pi.id limit 1)
                SQL
              fail!(409, "out_of_stock", "Not enough stock for #{l.name}") unless got
              by_store[l.store_id] << {l, got[0], got[1]}
            end

            by_store.each do |store_id, items|
              total = items.sum { |(l, price, _)| price * l.qty }
              oid = tx.query_one(<<-SQL, user_id, store_id, total, ship_name, ship_phone, ship_address, note, as: Int64)
                insert into orders (buyer_id, store_id, total_cents, ship_name, ship_phone, ship_address, note)
                values ($1, $2, $3, $4, $5, $6, $7) returning id
                SQL
              items.each do |(l, price, image)|
                tx.exec "insert into order_items (order_id, product_id, name, price_cents, qty, image) values ($1, $2, $3, $4, $5, $6)",
                  oid, l.product_id, l.name, price, l.qty, image
              end
              order_ids << oid
            end
            tx.exec "delete from cart_items where user_id = $1", user_id
          end

          Api.json(res, 201) do |b|
            b.object do
              b.field "message", "Order placed (cash on delivery)"
              b.field "order_ids" do
                b.array { order_ids.each { |id| b.number id } }
              end
            end
          end
        end

        # GET /orders?status=&cursor=&limit=
        r.get "/orders", Guards::SESSION do |req, res|
          Orders.list(req, res, req.auth!.id, Api.string_query(req, "status", 20), seller: false)
        end

        # GET /orders/:id
        r.get "/orders/:id", Guards::SESSION do |req, res|
          Orders.detail(res, req.auth!.id, req.params.int("id"), seller: false)
        end

        # POST /orders/:id/cancel (buyer, only while pending)
        r.post "/orders/:id/cancel", Guards::USER do |req, res|
          Orders.cancel!(req.params.int("id"), req.auth!.id, false, "Cancelled by buyer")
          Api.message(res, 200, "Order cancelled and stock restored")
        end

        # POST /orders/:id/complete (buyer confirms receipt of a shipped order)
        r.post "/orders/:id/complete", Guards::USER do |req, res|
          id = req.params.int("id")
          found = Shonin.db.query_one?(
            "update orders set status = 'completed', updated_at = now() where id = $1 and buyer_id = $2 and status = 'shipped' returning id",
            id, req.auth!.id, as: Int64)
          unless found
            fail!(404, "not_found", "Order not found") unless Shonin.db.query_one?("select 1 from orders where id = $1 and buyer_id = $2", id, req.auth!.id, as: Int32)
            fail!(409, "invalid_transition", "Only shipped orders can be marked completed")
          end
          Api.message(res, 200, "Order completed")
        end
      end
    end
  end
end
