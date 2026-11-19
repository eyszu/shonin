module Shonin
  module Routes
    module AuthRoutes
      VERIFIED_PAGE = <<-HTML
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Shonin</title><style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;text-align:center}
        h1{margin-bottom:.25rem}.ok{color:#0a7d33}.bad{color:#b3261e}</style></head>
        <body><h1 class="%CLASS%">%TITLE%</h1><p>%TEXT%</p></body></html>
        HTML

      private def self.page(res : Spectre::Response, status : Int32, ok : Bool, title : String, text : String) : Nil
        html = VERIFIED_PAGE.sub("%CLASS%", ok ? "ok" : "bad").sub("%TITLE%", title).sub("%TEXT%", text)
        res.status(status).html(html)
      end

      # Creates and "sends" a verification token. Old tokens for the user are replaced.
      def self.send_verification(user_id : Int64, email : String) : Nil
        token = Security.new_token
        Shonin.db.transaction do |tx|
          tx.exec "delete from email_tokens where user_id = $1 or expires_at < now()", user_id
          tx.exec "insert into email_tokens (token_hash, user_id, expires_at) values ($1, $2, $3)",
            Security.digest(token), user_id, Time.utc + Config::VERIFY_TTL
        end
        Mailer.verification(email, token)
      end

      def self.register(r : Spectre::Router) : Nil
        # POST /auth/register {"email", "password"}
        r.post "/auth/register" do |req, res|
          RateLimit.check!("register:#{req.ip}", 20, 1.hour)
          body = Body.parse(req)
          email = Validate.email(body.string!("email", 3, 254))
          password = Validate.password(body.string!("password", 8, 128, strip: false))

          id = begin
            Shonin.db.query_one(
              "insert into users (email, password_hash) values ($1, $2) returning id",
              email, Security.hash_password(password), as: Int64)
          rescue ex : Mjollnir::PGError
            raise ex unless ex.code == "23505"
            fail!(409, "email_taken", "An account with that email already exists")
          end

          send_verification(id, email)
          Api.json(res, 201) do |b|
            b.object do
              b.field "message", "Account created. Open the verification link we emailed to activate it."
              b.field "user_id", id
            end
          end
        end

        # GET /auth/verify?token=...  (the link in the email; opens fine in a browser)
        r.get "/auth/verify" do |req, res|
          wants_html = req.header("Accept").to_s.includes?("text/html")
          token = req.query["token"]?.to_s
          user_id = token.empty? ? nil : Shonin.db.query_one?(
            "select user_id from email_tokens where token_hash = $1 and expires_at > now()",
            Security.digest(token), as: Int64)

          if user_id
            Shonin.db.exec "update users set email_verified_at = coalesce(email_verified_at, now()) where id = $1", user_id
            if wants_html
              page(res, 200, true, "Email verified", "Your account is active. You can now sign in.")
            else
              Api.message(res, 200, "Email verified. You can now sign in.")
            end
          elsif wants_html
            page(res, 400, false, "Link not valid", "This verification link is invalid or has expired. Request a new one from the app.")
          else
            fail!(400, "invalid_token", "This verification link is invalid or has expired")
          end
        end

        # POST /auth/resend {"email"}  (always answers 202, so it cannot be used to find accounts)
        r.post "/auth/resend" do |req, res|
          RateLimit.check!("resend-ip:#{req.ip}", 10, 1.hour)
          body = Body.parse(req)
          email = Validate.email(body.string!("email", 3, 254))
          RateLimit.check!("resend:#{email}", 3, 1.hour)

          row = Shonin.db.query_one?(
            "select id from users where email = $1 and email_verified_at is null and status = 'active'",
            email, as: Int64)
          send_verification(row, email) if row
          Api.message(res, 202, "If that account exists and is not verified yet, a new link has been sent.")
        end

        # POST /auth/login {"email", "password"} -> {"token", ...}
        r.post "/auth/login" do |req, res|
          ip = req.ip
          RateLimit.check!("login-ip:#{ip}", 100, 15.minutes)
          body = Body.parse(req)
          email = Validate.email(body.string!("email", 3, 254))
          password = body.string!("password", 1, 128, strip: false)
          RateLimit.check!("login:#{ip}:#{email}", 10, 15.minutes)

          row = Shonin.db.query_one?(<<-SQL, email, as: {Int64, String, String, Bool, String, String?})
            select id, password_hash, role, email_verified_at is not null, status, ban_reason
            from users where email = $1
            SQL
          unless row
            Security.burn_time(password)
            fail!(401, "invalid_credentials", "Incorrect email or password")
          end
          id, hash, role, verified, status, ban_reason = row
          unless Security.verify_password(password, hash)
            fail!(401, "invalid_credentials", "Incorrect email or password")
          end

          # Only someone with the right password learns about account state.
          fail!(403, "account_banned", ban_reason ? "This account has been banned: #{ban_reason}" : "This account has been banned") if status == "banned"
          fail!(403, "email_not_verified", "Verify your email first. Use /auth/resend to get a new link.") unless verified

          token, expires = Sessions.create(id)
          Api.json(res) do |b|
            b.object do
              b.field "token", token
              b.field "expires_at", expires
              b.field "user" do
                b.object do
                  b.field "id", id
                  b.field "email", email
                  b.field "role", role
                end
              end
            end
          end
        end

        # POST /auth/logout: ends the current session.
        r.post "/auth/logout", Guards::SESSION do |req, res|
          token = req.header("Authorization").to_s.byte_slice(7).strip
          Shonin.db.exec "delete from sessions where token_hash = $1", Security.digest(token)
          res.send_status(204)
        end

        # POST /auth/logout-all: ends every session of the caller.
        r.post "/auth/logout-all", Guards::SESSION do |req, res|
          Shonin.db.exec "delete from sessions where user_id = $1", req.auth!.id
          res.send_status(204)
        end

        # GET /me
        r.get "/me", Guards::SESSION do |req, res|
          auth = req.auth!
          store_id = Shonin.db.query_one?("select id from stores where owner_id = $1", auth.id, as: Int64)
          Api.json(res) do |b|
            b.object do
              b.field "id", auth.id
              b.field "email", auth.email
              b.field "role", auth.role
              b.field "store_id", store_id
              b.field "suspended", auth.suspended?
              b.field "suspended_until", auth.suspended_until if auth.suspended?
              b.field "suspend_reason", auth.suspend_reason if auth.suspended?
            end
          end
        end
      end
    end
  end
end
