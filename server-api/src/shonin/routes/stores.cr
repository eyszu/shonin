module Shonin
  module Routes
    # Store management for sellers: create, edit, open/close, logo, own product
    # list, order handling and sales stats. Public store pages are here too.
    module StoreRoutes
      alias StoreRow = {Int64, Int64, String, String, String?, String, Time}

      SELECT_STORE = "select id, owner_id, name, description, logo, status, created_at from stores"

      def self.write_store(b : JSON::Builder, row : StoreRow, *, private_view : Bool = false) : Nil
        id, owner_id, name, description, logo, status, created_at = row
        b.object do
          b.field "id", id
          b.field "name", name
          b.field "description", description
          b.field "logo", Images.url(logo)
          b.field "status", status
          b.field "created_at", created_at
          b.field "owner_id", owner_id if private_view
        end
      end

      # The caller's own store, or 404.
      def self.own_store!(req : Spectre::Request) : StoreRow
        row = Shonin.db.query_one?("#{SELECT_STORE} where owner_id = $1", req.auth!.id, as: StoreRow)
        row || fail!(404, "no_store", "You have not created a store yet. POST /api/v1/stores first.")
      end

      def self.register(r : Spectre::Router) : Nil
        # POST /stores {"name", "description"?}
        r.post "/stores", Guards::USER do |req, res|
          body = Body.parse(req)
          name = body.string!("name", 2, 60)
          description = body.string("description", 0, 2000) || ""
          row = begin
            Shonin.db.query_one(
              "insert into stores (owner_id, name, description) values ($1, $2, $3) returning id, owner_id, name, description, logo, status, created_at",
              req.auth!.id, name, description, as: StoreRow)
          rescue ex : Mjollnir::PGError
            raise ex unless ex.code == "23505"
            if ex.message.to_s.includes?("stores_name_key")
              fail!(409, "store_name_taken", "That store name is already in use")
            else
              fail!(409, "store_exists", "You already have a store")
            end
          end
          Api.json(res, 201) { |b| write_store(b, row, private_view: true) }
        end

        # GET /stores/me
        r.get "/stores/me", Guards::SESSION do |req, res|
          row = own_store!(req)
          Api.json(res) { |b| write_store(b, row, private_view: true) }
        end

        # PATCH /stores/me {"name"?, "description"?, "status"?: open|closed}
        r.patch "/stores/me", Guards::USER do |req, res|
          store = own_store!(req)
          body = Body.parse(req)
          name = body.string("name", 2, 60)
          description = body.string("description", 0, 2000)
          status = body.string("status", 1, 10)
          fail!(422, "invalid_status", "status must be open or closed") if status && !{"open", "closed"}.includes?(status)
          row = begin
            Shonin.db.query_one(<<-SQL, store[0], name, description, status, as: StoreRow)
              update stores set name = coalesce($2, name), description = coalesce($3, description),
                     status = coalesce($4, status), updated_at = now()
              where id = $1
              returning id, owner_id, name, description, logo, status, created_at
              SQL
          rescue ex : Mjollnir::PGError
            raise ex unless ex.code == "23505"
            fail!(409, "store_name_taken", "That store name is already in use")
          end
          Api.json(res) { |b| write_store(b, row, private_view: true) }
        end

        # PUT /stores/me/logo  (image as request body or multipart "image")
        r.put "/stores/me/logo", Guards::USER do |req, res|
          store = own_store!(req)
          file = Images.store(Images.read_upload(req))
          old = Shonin.db.query_one("select logo from stores where id = $1", store[0], as: String?)
          Shonin.db.exec "update stores set logo = $2, updated_at = now() where id = $1", store[0], file
          Images.remove(old)
          Api.json(res) { |b| b.object { b.field "logo", Images.url(file) } }
        end

        # DELETE /stores/me/logo
        r.delete "/stores/me/logo", Guards::USER do |req, res|
          store = own_store!(req)
          old = Shonin.db.query_one("select logo from stores where id = $1", store[0], as: String?)
          Shonin.db.exec "update stores set logo = null, updated_at = now() where id = $1", store[0]
          Images.remove(old)
          res.send_status(204)
        end

        # GET /stores/me/stats
        r.get "/stores/me/stats", Guards::SESSION do |req, res|
          store = own_store!(req)
          products = Shonin.db.query_one(
            "select count(*)::bigint, count(*) filter (where status = 'active')::bigint, coalesce(sum(stock), 0)::bigint from products where store_id = $1",
            store[0], as: {Int64, Int64, Int64})
          orders = Shonin.db.query_all(
            "select status, count(*)::bigint, coalesce(sum(total_cents), 0)::bigint from orders where store_id = $1 group by status",
            store[0], as: {String, Int64, Int64})
          Api.json(res) do |b|
            b.object do
              b.field "products_total", products[0]
              b.field "products_active", products[1]
              b.field "units_in_stock", products[2]
              b.field "orders" do
                b.object do
                  orders.each do |status, count, total|
                    b.field status do
                      b.object do
                        b.field "count", count
                        b.field "total_cents", total
                      end
                    end
                  end
                end
              end
            end
          end
        end

        # GET /stores/me/products?cursor=&limit=   (includes hidden products)
        r.get "/stores/me/products", Guards::SESSION do |req, res|
          store = own_store!(req)
          limit = Api.limit(req)
          Products.write_list(res, limit, Products.fetch_store_products(store[0], Api.int_query(req, "cursor"), limit, include_hidden: true))
        end

        # GET /stores/me/orders?status=&cursor=&limit=
        r.get "/stores/me/orders", Guards::SESSION do |req, res|
          store = own_store!(req)
          status = Api.string_query(req, "status", 20)
          Orders.list(req, res, store[0], status, seller: true)
        end

        # POST /stores/me/orders/:id/(confirm|ship|cancel)
        {"confirm" => {"pending", "confirmed"}, "ship" => {"confirmed", "shipped"}}.each do |action, (from, to)|
          r.post "/stores/me/orders/:id/#{action}", Guards::USER do |req, res|
            store = own_store!(req)
            id = req.params.int("id")
            found = Shonin.db.query_one?(
              "update orders set status = $3, updated_at = now() where id = $1 and store_id = $2 and status = $4 returning id",
              id, store[0], to, from, as: Int64)
            unless found
              exists = Shonin.db.query_one?("select status from orders where id = $1 and store_id = $2", id, store[0], as: String)
              fail!(404, "not_found", "Order not found") unless exists
              fail!(409, "invalid_transition", "Order is #{exists}; cannot #{action}")
            end
            Api.message(res, 200, "Order #{to}")
          end
        end

        r.post "/stores/me/orders/:id/cancel", Guards::USER do |req, res|
          store = own_store!(req)
          reason = Body.parse_optional(req).string("reason", 0, 500)
          Orders.cancel!(req.params.int("id"), store[0], true, reason || "Cancelled by seller")
          Api.message(res, 200, "Order cancelled and stock restored")
        end

        # GET /stores/me/orders/:id
        r.get "/stores/me/orders/:id", Guards::SESSION do |req, res|
          Orders.detail(res, own_store!(req)[0], req.params.int("id"), seller: true)
        end

        # GET /stores/:id (public)
        r.get "/stores/:id" do |req, res|
          id = req.params.int("id")
          row = Shonin.db.query_one?("#{SELECT_STORE} where id = $1", id, as: StoreRow)
          fail!(404, "not_found", "Store not found") unless row
          count = Shonin.db.query_one("select count(*)::bigint from products where store_id = $1 and status = 'active'", id, as: Int64)
          Api.json(res) do |b|
            b.object do
              id_, _owner, name, description, logo, status, created_at = row
              b.field "id", id_
              b.field "name", name
              b.field "description", description
              b.field "logo", Images.url(logo)
              b.field "status", status
              b.field "created_at", created_at
              b.field "product_count", count
            end
          end
        end
      end
    end
  end
end
