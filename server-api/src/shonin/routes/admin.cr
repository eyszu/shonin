module Shonin
  module Routes
    # Moderation (ban, suspend) and category management. Every route here
    # requires an administrator.
    module AdminRoutes
      STATE_SQL = <<-SQL.strip
        (case when u.status = 'banned' then 'banned'
              when u.suspended_until > now() then 'suspended'
              else 'active' end)
        SQL

      # Loads the target of a moderation action. Administrators (including the
      # caller) cannot be banned or suspended.
      private def self.moderatable!(id : Int64) : Nil
        row = Shonin.db.query_one?("select role from users where id = $1", id, as: String)
        fail!(404, "not_found", "User not found") unless row
        fail!(403, "cannot_moderate_admin", "Administrator accounts cannot be banned or suspended") if row == "admin"
      end

      private def self.write_user(b : JSON::Builder, row) : Nil
        id, email, role, state, verified, suspended_until, ban_reason, created_at = row
        b.object do
          b.field "id", id
          b.field "email", email
          b.field "role", role
          b.field "state", state
          b.field "email_verified", verified
          b.field "suspended_until", suspended_until
          b.field "ban_reason", ban_reason
          b.field "created_at", created_at
        end
      end

      def self.register(r : Spectre::Router) : Nil
        # GET /admin/users?q=&state=active|suspended|banned&cursor=&limit=
        r.get "/admin/users", Guards::ADMIN do |req, res|
          limit = Api.limit(req)
          q = Api.string_query(req, "q")
          state = Api.string_query(req, "state", 20)
          fail!(400, "invalid_state", "state must be active, suspended or banned") if state && !%w(active suspended banned).includes?(state)
          cursor = Api.int_query(req, "cursor")

          rows = Shonin.db.query_all(<<-SQL, q, state, cursor, limit + 1, as: {Int64, String, String, String, Bool, Time?, String?, Time})
            select u.id, u.email, u.role, #{STATE_SQL}, u.email_verified_at is not null,
                   u.suspended_until, u.ban_reason, u.created_at
            from users u
            where ($1::text is null or strpos(u.email, lower($1)) > 0)
              and ($2::text is null or #{STATE_SQL} = $2)
              and ($3::bigint is null or u.id < $3)
            order by u.id desc
            limit $4
            SQL
          more = rows.size > limit
          rows = rows.first(limit) if more
          Api.page(res, more ? rows.last[0].to_s : nil) { |b| rows.each { |row| write_user(b, row) } }
        end

        # GET /admin/users/:id  (with moderation history)
        r.get "/admin/users/:id", Guards::ADMIN do |req, res|
          id = req.params.int("id")
          row = Shonin.db.query_one?(<<-SQL, id, as: {Int64, String, String, String, Bool, Time?, String?, Time})
            select u.id, u.email, u.role, #{STATE_SQL}, u.email_verified_at is not null,
                   u.suspended_until, u.ban_reason, u.created_at
            from users u where u.id = $1
            SQL
          fail!(404, "not_found", "User not found") unless row
          history = Shonin.db.query_all(<<-SQL, id, as: {Int64, Int64, String, String?, Time?, Time})
            select id, admin_id, action, reason, until_at, created_at
            from moderation_log where user_id = $1 order by id desc limit 50
            SQL
          Api.json(res) do |b|
            b.object do
              b.field "user" { write_user(b, row) }
              b.field "history" do
                b.array do
                  history.each do |hid, admin_id, action, reason, until_at, at|
                    b.object do
                      b.field "id", hid
                      b.field "admin_id", admin_id
                      b.field "action", action
                      b.field "reason", reason
                      b.field "until", until_at
                      b.field "at", at
                    end
                  end
                end
              end
            end
          end
        end

        # POST /admin/users/:id/ban {"reason"}: permanent; signs the user out everywhere.
        r.post "/admin/users/:id/ban", Guards::ADMIN do |req, res|
          id = req.params.int("id")
          reason = Body.parse(req).string!("reason", 3, 500)
          moderatable!(id)
          Shonin.db.transaction do |tx|
            tx.exec "update users set status = 'banned', ban_reason = $2, banned_at = now() where id = $1", id, reason
            tx.exec "delete from sessions where user_id = $1", id
            tx.exec "insert into moderation_log (admin_id, user_id, action, reason) values ($1, $2, 'ban', $3)",
              req.auth!.id, id, reason
          end
          Api.message(res, 200, "User banned")
        end

        # DELETE /admin/users/:id/ban
        r.delete "/admin/users/:id/ban", Guards::ADMIN do |req, res|
          id = req.params.int("id")
          lifted = Shonin.db.transaction do |tx|
            found = tx.query_one?(
              "update users set status = 'active', ban_reason = null, banned_at = null where id = $1 and status = 'banned' returning id",
              id, as: Int64)
            tx.exec "insert into moderation_log (admin_id, user_id, action) values ($1, $2, 'unban')", req.auth!.id, id if found
            found
          end
          fail!(409, "not_banned", "That user is not banned") unless lifted
          Api.message(res, 200, "Ban lifted")
        end

        # POST /admin/users/:id/suspend {"duration_hours": 1..8760, "reason"}
        r.post "/admin/users/:id/suspend", Guards::ADMIN do |req, res|
          id = req.params.int("id")
          body = Body.parse(req)
          hours = body.integer!("duration_hours", 1_i64, 8760_i64)
          reason = body.string!("reason", 3, 500)
          moderatable!(id)
          until_at = Shonin.db.transaction do |tx|
            time = tx.query_one(
              "update users set suspended_until = now() + make_interval(hours => $2), suspend_reason = $3 where id = $1 returning suspended_until",
              id, hours, reason, as: Time)
            tx.exec "insert into moderation_log (admin_id, user_id, action, reason, until_at) values ($1, $2, 'suspend', $3, $4)",
              req.auth!.id, id, reason, time
            time
          end
          Api.json(res) do |b|
            b.object do
              b.field "message", "User suspended"
              b.field "suspended_until", until_at
            end
          end
        end

        # DELETE /admin/users/:id/suspend
        r.delete "/admin/users/:id/suspend", Guards::ADMIN do |req, res|
          id = req.params.int("id")
          lifted = Shonin.db.transaction do |tx|
            found = tx.query_one?(
              "update users set suspended_until = null, suspend_reason = null where id = $1 and suspended_until > now() returning id",
              id, as: Int64)
            tx.exec "insert into moderation_log (admin_id, user_id, action) values ($1, $2, 'unsuspend')", req.auth!.id, id if found
            found
          end
          fail!(409, "not_suspended", "That user is not suspended") unless lifted
          Api.message(res, 200, "Suspension lifted")
        end

        # POST /admin/categories {"name"}
        r.post "/admin/categories", Guards::ADMIN do |req, res|
          name = Body.parse(req).string!("name", 2, 60)
          id = Shonin.db.query_one("insert into categories (name) values ($1) returning id", name, as: Int64)
          Api.json(res, 201) do |b|
            b.object do
              b.field "id", id
              b.field "name", name
            end
          end
        end

        # DELETE /admin/categories/:id (products in it become uncategorised)
        r.delete "/admin/categories/:id", Guards::ADMIN do |req, res|
          id = req.params.int("id")
          removed = Shonin.db.exec("delete from categories where id = $1", id).rows_affected
          fail!(404, "not_found", "Category not found") if removed == 0
          res.send_status(204)
        end
      end
    end
  end
end
