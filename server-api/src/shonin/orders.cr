module Shonin
  # Shared order queries for the buyer and seller sides.
  module Orders
    STATUSES = {"pending", "confirmed", "shipped", "completed", "cancelled"}

    alias Row = {Int64, Int64, Int64, String, String, Int64, String, String, String, String, String?, Time}

    COLUMNS = "o.id, o.buyer_id, o.store_id, st.name, o.status, o.total_cents, o.ship_name, o.ship_phone, o.ship_address, o.note, o.cancel_reason, o.created_at"

    def self.write_row(b : JSON::Builder, row : Row, items : Array({Int64?, String, Int64, Int32, String?})? = nil) : Nil
      id, buyer_id, store_id, store_name, status, total, ship_name, ship_phone, ship_address, note, cancel_reason, created_at = row
      b.object do
        b.field "id", id
        b.field "buyer_id", buyer_id
        b.field "store_id", store_id
        b.field "store_name", store_name
        b.field "status", status
        b.field "total_cents", total
        b.field "ship_name", ship_name
        b.field "ship_phone", ship_phone
        b.field "ship_address", ship_address
        b.field "note", note
        b.field "cancel_reason", cancel_reason
        b.field "created_at", created_at
        if items
          b.field "items" do
            b.array do
              items.each do |product_id, name, price, qty, image|
                b.object do
                  b.field "product_id", product_id
                  b.field "name", name
                  b.field "price_cents", price
                  b.field "qty", qty
                  b.field "image", Images.url(image)
                end
              end
            end
          end
        end
      end
    end

    def self.items_for(order_id : Int64)
      Shonin.db.query_all(
        "select product_id, name, price_cents, qty, image from order_items where order_id = $1 order by id",
        order_id, as: {Int64?, String, Int64, Int32, String?})
    end

    def self.list(req : Spectre::Request, res : Spectre::Response, owner_id : Int64, status : String?, seller : Bool) : Nil
      limit = Api.limit(req)
      cursor = Api.int_query(req, "cursor")
      fail!(400, "invalid_status", "status must be one of #{STATUSES.join(", ")}") if status && !STATUSES.includes?(status)
      rows = if seller
               Shonin.db.query_all(<<-SQL, owner_id, status, cursor, limit + 1, as: Row)
                 select #{COLUMNS} from orders o join stores st on st.id = o.store_id
                 where o.store_id = $1 and ($2::text is null or o.status = $2) and ($3::bigint is null or o.id < $3)
                 order by o.id desc limit $4
                 SQL
             else
               Shonin.db.query_all(<<-SQL, owner_id, status, cursor, limit + 1, as: Row)
                 select #{COLUMNS} from orders o join stores st on st.id = o.store_id
                 where o.buyer_id = $1 and ($2::text is null or o.status = $2) and ($3::bigint is null or o.id < $3)
                 order by o.id desc limit $4
                 SQL
             end
      more = rows.size > limit
      rows = rows.first(limit) if more
      Api.page(res, more ? rows.last[0].to_s : nil) { |b| rows.each { |row| write_row(b, row) } }
    end

    def self.detail(res : Spectre::Response, owner_id : Int64, id : Int64, seller : Bool) : Nil
      row = if seller
              Shonin.db.query_one?("select #{COLUMNS} from orders o join stores st on st.id = o.store_id where o.id = $1 and o.store_id = $2", id, owner_id, as: Row)
            else
              Shonin.db.query_one?("select #{COLUMNS} from orders o join stores st on st.id = o.store_id where o.id = $1 and o.buyer_id = $2", id, owner_id, as: Row)
            end
      fail!(404, "not_found", "Order not found") unless row
      items = items_for(id)
      Api.json(res) { |b| write_row(b, row, items) }
    end

    # Cancels an order that has not shipped and puts its stock back, atomically.
    # `seller` picks whether `owner_id` is a store id or a buyer id.
    def self.cancel!(id : Int64, owner_id : Int64, seller : Bool, reason : String, buyer_pending_only : Bool = false) : Nil
      Shonin.db.transaction do |tx|
        found = if seller
                  tx.query_one?(<<-SQL, id, owner_id, reason, as: Int64)
                    update orders set status = 'cancelled', cancel_reason = $3, updated_at = now()
                    where id = $1 and store_id = $2 and status in ('pending', 'confirmed') returning id
                    SQL
                else
                  tx.query_one?(<<-SQL, id, owner_id, reason, as: Int64)
                    update orders set status = 'cancelled', cancel_reason = $3, updated_at = now()
                    where id = $1 and buyer_id = $2 and status = 'pending' returning id
                    SQL
                end
        unless found
          fail!(404, "not_found", "Order not found") unless tx.query_one?(
            seller ? "select 1 from orders where id = $1 and store_id = $2" : "select 1 from orders where id = $1 and buyer_id = $2",
            id, owner_id, as: Int32)
          fail!(409, "invalid_transition", seller ? "Only pending or confirmed orders can be cancelled" : "Only pending orders can be cancelled by the buyer")
        end
        tx.exec(<<-SQL, id)
          update products p set stock = p.stock + i.qty, sold = greatest(p.sold - i.qty, 0)
          from order_items i where i.order_id = $1 and i.product_id = p.id
          SQL
      end
    end
  end
end
