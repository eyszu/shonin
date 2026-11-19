module Shonin
  module Routes
    # Public catalogue plus the seller's product CRUD and image management.
    module ProductRoutes
      MAX_PRICE = 100_000_000_00_i64 # 100 million, in cents
      MAX_STOCK = 1_000_000_i64

      private def self.owned_product!(store_id : Int64, id : Int64) : Nil
        ok = Shonin.db.query_one?("select 1 from products where id = $1 and store_id = $2", id, store_id, as: Int32)
        fail!(404, "not_found", "Product not found in your store") unless ok
      end

      private def self.check_category!(id : Int64?) : Nil
        return unless id
        ok = Shonin.db.query_one?("select 1 from categories where id = $1", id, as: Int32)
        fail!(422, "invalid_category", "Unknown category_id") unless ok
      end

      private def self.write_detail(res : Spectre::Response, id : Int64, row : Products::Row) : Nil
        images = Shonin.db.query_all(
          "select id, filename from product_images where product_id = $1 order by position, id", id, as: {Int64, String})
        Api.json(res) do |b|
          id_, store_id, store_name, category_id, name, description, price, stock, sold, status, created_at, _cover = row
          b.object do
            b.field "id", id_
            b.field "store_id", store_id
            b.field "store_name", store_name
            b.field "category_id", category_id
            b.field "name", name
            b.field "description", description
            b.field "price_cents", price
            b.field "stock", stock
            b.field "sold", sold
            b.field "status", status
            b.field "created_at", created_at
            b.field "images" do
              b.array do
                images.each do |iid, file|
                  b.object do
                    b.field "id", iid
                    b.field "url", Images.url(file)
                  end
                end
              end
            end
          end
        end
      end

      def self.register(r : Spectre::Router) : Nil
        # GET /categories
        r.get "/categories" do |req, res|
          rows = Shonin.db.query_all("select id, name from categories order by lower(name)", as: {Int64, String})
          Api.json(res) do |b|
            b.array do
              rows.each do |id, name|
                b.object do
                  b.field "id", id
                  b.field "name", name
                end
              end
            end
          end
        end

        # GET /products?q=&category_id=&store_id=&sort=new|popular|price_asc|price_desc&cursor=&limit=
        r.get "/products" do |req, res|
          limit = Api.limit(req)
          sort = Api.string_query(req, "sort", 20) || "new"
          fail!(400, "invalid_sort", "sort must be one of #{Products::SORTS.join(", ")}") unless Products::SORTS.includes?(sort)
          rows = Products.search(Api.string_query(req, "q", 100), Api.int_query(req, "category_id"),
            Api.int_query(req, "store_id"), sort, Api.string_query(req, "cursor", 40), limit)
          Products.write_list(res, limit, rows, sort)
        end

        # GET /products/:id
        r.get "/products/:id" do |req, res|
          id = req.params.int("id")
          row = Shonin.db.query_one?(<<-SQL, id, as: Products::Row)
            select #{Products::COLUMNS}
            from products p join stores s on s.id = p.store_id join users u on u.id = s.owner_id
            where p.id = $1 and #{Products::VISIBLE}
            SQL
          fail!(404, "not_found", "Product not found") unless row
          write_detail(res, id, row)
        end

        # POST /stores/me/products {"name", "description"?, "price_cents", "stock", "category_id"?, "status"?}
        r.post "/stores/me/products", Guards::USER do |req, res|
          store = StoreRoutes.own_store!(req)
          body = Body.parse(req)
          name = body.string!("name", 2, 150)
          description = body.string("description", 0, 5000) || ""
          price = body.integer!("price_cents", 0_i64, MAX_PRICE)
          stock = body.integer!("stock", 0_i64, MAX_STOCK)
          category = body.integer("category_id", 1_i64, Int64::MAX)
          status = body.string("status", 1, 10) || "active"
          fail!(422, "invalid_status", "status must be active or hidden") unless {"active", "hidden"}.includes?(status)
          check_category!(category)
          id = Shonin.db.query_one(
            "insert into products (store_id, category_id, name, description, price_cents, stock, status) values ($1, $2, $3, $4, $5, $6, $7) returning id",
            store[0], category, name, description, price, stock, status, as: Int64)
          Api.json(res, 201) { |b| b.object { b.field "id", id } }
        end

        # GET /stores/me/products/:id
        r.get "/stores/me/products/:id", Guards::SESSION do |req, res|
          store = StoreRoutes.own_store!(req)
          id = req.params.int("id")
          row = Shonin.db.query_one?(<<-SQL, id, store[0], as: Products::Row)
            select #{Products::COLUMNS}
            from products p join stores s on s.id = p.store_id
            where p.id = $1 and p.store_id = $2
            SQL
          fail!(404, "not_found", "Product not found in your store") unless row
          write_detail(res, id, row)
        end

        # PATCH /stores/me/products/:id  (any subset of fields)
        r.patch "/stores/me/products/:id", Guards::USER do |req, res|
          store = StoreRoutes.own_store!(req)
          id = req.params.int("id")
          body = Body.parse(req)
          name = body.string("name", 2, 150)
          description = body.string("description", 0, 5000)
          price = body.integer("price_cents", 0_i64, MAX_PRICE)
          stock = body.integer("stock", 0_i64, MAX_STOCK)
          status = body.string("status", 1, 10)
          fail!(422, "invalid_status", "status must be active or hidden") if status && !{"active", "hidden"}.includes?(status)
          set_category = body.has?("category_id")
          category = body.null?("category_id") ? nil : body.integer("category_id", 1_i64, Int64::MAX)
          check_category!(category)
          updated = Shonin.db.query_one?(<<-SQL, id, store[0], name, description, price, stock, status, set_category, category, as: Int64)
            update products set
              name = coalesce($3, name), description = coalesce($4, description),
              price_cents = coalesce($5, price_cents), stock = coalesce($6, stock),
              status = coalesce($7, status),
              category_id = case when $8::boolean then $9 else category_id end,
              updated_at = now()
            where id = $1 and store_id = $2
            returning id
            SQL
          fail!(404, "not_found", "Product not found in your store") unless updated
          Api.message(res, 200, "Product updated")
        end

        # DELETE /stores/me/products/:id
        r.delete "/stores/me/products/:id", Guards::USER do |req, res|
          store = StoreRoutes.own_store!(req)
          id = req.params.int("id")
          files = Shonin.db.query_all("select filename from product_images where product_id = $1", id, as: String)
          removed = Shonin.db.exec("delete from products where id = $1 and store_id = $2", id, store[0]).rows_affected
          fail!(404, "not_found", "Product not found in your store") if removed == 0
          files.each { |f| Images.remove(f) }
          res.send_status(204)
        end

        # POST /stores/me/products/:id/images  (image as raw body, or multipart "image"; max 5 per product)
        r.post "/stores/me/products/:id/images", Guards::USER do |req, res|
          store = StoreRoutes.own_store!(req)
          id = req.params.int("id")
          owned_product!(store[0], id)
          file = Images.store(Images.read_upload(req))
          image_id = Shonin.db.query_one?(<<-SQL, id, file, Config::MAX_PRODUCT_IMAGES, as: Int64)
            insert into product_images (product_id, filename, position)
            select $1, $2, count(*) from product_images where product_id = $1
            having count(*) < $3
            returning id
            SQL
          unless image_id
            Images.remove(file)
            fail!(409, "too_many_images", "A product can have at most #{Config::MAX_PRODUCT_IMAGES} images")
          end
          Api.json(res, 201) do |b|
            b.object do
              b.field "id", image_id
              b.field "url", Images.url(file)
              b.field "width", Config::IMAGE_SIZE
              b.field "height", Config::IMAGE_SIZE
            end
          end
        end

        # DELETE /stores/me/products/:id/images/:image_id
        r.delete "/stores/me/products/:id/images/:image_id", Guards::USER do |req, res|
          store = StoreRoutes.own_store!(req)
          id = req.params.int("id")
          owned_product!(store[0], id)
          file = Shonin.db.query_one?(
            "delete from product_images where id = $1 and product_id = $2 returning filename",
            req.params.int("image_id"), id, as: String)
          fail!(404, "not_found", "Image not found") unless file
          Images.remove(file)
          res.send_status(204)
        end
      end
    end
  end
end
