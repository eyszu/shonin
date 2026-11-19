module Shonin
  # Product queries shared by the public catalogue and the seller's own list.
  module Products
    alias Row = {Int64, Int64, String, Int64?, String, String, Int64, Int32, Int32, String, Time, String?}

    COLUMNS = <<-SQL.strip
      p.id, p.store_id, s.name, p.category_id, p.name, p.description, p.price_cents,
      p.stock, p.sold, p.status, p.created_at,
      (select pi.filename from product_images pi where pi.product_id = p.id order by pi.position, pi.id limit 1)
      SQL

    # Listings hide products whose store is closed or whose owner is banned/suspended.
    VISIBLE = "p.status = 'active' and s.status = 'open' and u.status = 'active' and (u.suspended_until is null or u.suspended_until <= now())"

    SORTS = {"new", "popular", "price_asc", "price_desc"}

    @@sql_cache = {} of String => String

    def self.write_row(b : JSON::Builder, row : Row) : Nil
      id, store_id, store_name, category_id, name, description, price, stock, sold, status, created_at, cover = row
      b.object do
        b.field "id", id
        b.field "store_id", store_id
        b.field "store_name", store_name
        b.field "category_id", category_id
        b.field "name", name
        b.field "description", description
        b.field "price_cents", price
        b.field "stock", stock
        b.field "sold", sold
        b.field "status", status
        b.field "cover", Images.url(cover)
        b.field "created_at", created_at
      end
    end

    def self.cursor_for(row : Row, sort : String) : String
      case sort
      when "popular"                  then "#{row[8]}:#{row[0]}"
      when "price_asc", "price_desc"  then "#{row[6]}:#{row[0]}"
      else                                 row[0].to_s
      end
    end

    def self.write_list(res : Spectre::Response, limit : Int32, rows : Array(Row), sort : String = "new") : Nil
      more = rows.size > limit
      rows = rows.first(limit) if more
      Api.page(res, more ? cursor_for(rows.last, sort) : nil) { |b| rows.each { |row| write_row(b, row) } }
    end

    # Seller-side list (newest first, keyset on id).
    def self.fetch_store_products(store_id : Int64, cursor : Int64?, limit : Int32, include_hidden : Bool) : Array(Row)
      Shonin.db.query_all(<<-SQL, store_id, cursor, limit + 1, as: Row)
        select #{COLUMNS}
        from products p join stores s on s.id = p.store_id
        where p.store_id = $1 and ($2::bigint is null or p.id < $2)
        order by p.id desc limit $3
        SQL
    end

    # Public catalogue. SQL text is built per filter combination and memoised, so
    # each combination is one prepared statement.
    def self.search(q : String?, category : Int64?, store : Int64?, sort : String, cursor : String?, limit : Int32) : Array(Row)
      words = q ? q.scan(/[[:alnum:]]+/).first(8).map { |m| "#{m[0]}:*" } : [] of String
      tsq = words.empty? ? nil : words.join(" & ")

      cur_a = cur_b = nil
      if cursor
        parts = cursor.split(':')
        cur_a = parts[0]?.try(&.to_i64?)
        cur_b = parts[1]?.try(&.to_i64?)
        valid = sort == "new" ? !cur_a.nil? : (!cur_a.nil? && !cur_b.nil?)
        fail!(400, "invalid_cursor", "cursor is not valid") unless valid
      end

      key = "#{tsq ? 1 : 0}#{category ? 1 : 0}#{store ? 1 : 0}#{sort}#{cursor ? 1 : 0}"
      args = [] of Int64 | String
      sql = @@sql_cache[key] ||= build_sql(!tsq.nil?, !category.nil?, !store.nil?, sort, !cursor.nil?)
      args << tsq if tsq
      args << category if category
      args << store if store
      if cursor
        if sort == "new"
          args << cur_a.not_nil!
        else
          args << cur_a.not_nil!
          args << cur_b.not_nil!
        end
      end
      args << (limit + 1).to_i64
      Shonin.db.query_all(sql, args: args, as: Row)
    end

    private def self.build_sql(has_q : Bool, has_cat : Bool, has_store : Bool, sort : String, has_cursor : Bool) : String
      n = 0
      String.build do |s|
        s << "select " << COLUMNS << " from products p join stores s on s.id = p.store_id join users u on u.id = s.owner_id where " << VISIBLE
        s << " and to_tsvector('simple', p.name || ' ' || p.description) @@ to_tsquery('simple', $" << (n += 1) << ")" if has_q
        s << " and p.category_id = $" << (n += 1) if has_cat
        s << " and p.store_id = $" << (n += 1) if has_store
        if has_cursor
          case sort
          when "new"
            s << " and p.id < $" << (n += 1)
          when "popular"
            s << " and (p.sold, p.id) < ($" << (n += 1) << ", $" << (n += 1) << ")"
          when "price_asc"
            s << " and (p.price_cents, p.id) > ($" << (n += 1) << ", $" << (n += 1) << ")"
          else
            s << " and (p.price_cents, p.id) < ($" << (n += 1) << ", $" << (n += 1) << ")"
          end
        end
        s << (case sort
        when "popular"    then " order by p.sold desc, p.id desc"
        when "price_asc"  then " order by p.price_cents asc, p.id asc"
        when "price_desc" then " order by p.price_cents desc, p.id desc"
        else                   " order by p.id desc"
        end)
        s << " limit $" << (n += 1)
      end
    end
  end
end
