module Shonin
  # The authenticated caller, attached to the request by a guard.
  struct Auth
    getter id : Int64
    getter email : String
    getter role : String
    getter suspended : Bool
    getter suspended_until : Time?
    getter suspend_reason : String?

    def initialize(@id, @email, @role, @suspended, @suspended_until, @suspend_reason)
    end

    def admin? : Bool
      @role == "admin"
    end

    def suspended? : Bool
      @suspended
    end

    def suspension_message : String
      text = "Your account is suspended"
      if until_time = @suspended_until
        text += " until #{until_time.to_rfc3339}"
      end
      if reason = @suspend_reason
        text += ": #{reason}"
      end
      text
    end
  end

  module Sessions
    # Resolves the bearer token to a user with one indexed query. Moderation
    # state is read from the database on every request, so a ban or
    # suspension takes effect immediately, not when a token expires.
    def self.authenticate(req : Spectre::Request) : Auth
      header = req.header("Authorization")
      fail!(401, "unauthorized", "Send an Authorization: Bearer <token> header") unless header
      unless header.size > 7 && header.starts_with?("Bearer ")
        fail!(401, "unauthorized", "Send an Authorization: Bearer <token> header")
      end
      token = header.byte_slice(7).strip

      row = Shonin.db.query_one?(<<-SQL, Security.digest(token), as: {Int64, String, String, String, Bool, Time?, String?})
        select u.id, u.email, u.role, u.status,
               coalesce(u.suspended_until > now(), false),
               u.suspended_until, u.suspend_reason
        from sessions s
        join users u on u.id = s.user_id
        where s.token_hash = $1 and s.expires_at > now()
        SQL
      fail!(401, "invalid_token", "The token is invalid or has expired") unless row

      id, email, role, status, suspended, until_time, reason = row
      fail!(403, "account_banned", "This account has been banned") if status == "banned"
      Auth.new(id, email, role, suspended, until_time, reason)
    end

    # Creates a session and returns the raw token (shown to the client once).
    def self.create(user_id : Int64) : {String, Time}
      token = Security.new_token
      expires = Time.utc + Config::SESSION_TTL
      Shonin.db.exec "insert into sessions (token_hash, user_id, expires_at) values ($1, $2, $3)",
        Security.digest(token), user_id, expires
      {token, expires}
    end
  end

  # Route guards. Attach them per route: `app.get "/me", Guards::USER do ... end`.
  module Guards
    # Any signed-in user who is not suspended.
    USER = Spectre.layer do |req, res, nxt|
      auth = Sessions.authenticate(req)
      fail!(403, "account_suspended", auth.suspension_message) if auth.suspended?
      req.auth = auth
      nxt.call
    end

    # A signed-in user even if suspended (for /me and logout, so they can see why).
    SESSION = Spectre.layer do |req, res, nxt|
      req.auth = Sessions.authenticate(req)
      nxt.call
    end

    ADMIN = Spectre.layer do |req, res, nxt|
      auth = Sessions.authenticate(req)
      fail!(403, "forbidden", "Administrator access required") unless auth.admin?
      fail!(403, "account_suspended", auth.suspension_message) if auth.suspended?
      req.auth = auth
      nxt.call
    end
  end
end

class Spectre::Request
  property auth : Shonin::Auth?

  # The caller set by a guard. Only valid on routes that have one.
  def auth! : Shonin::Auth
    @auth || raise "route is missing an auth guard"
  end
end
