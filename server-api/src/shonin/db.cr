module Shonin
  @@db : Mjollnir::Pool?

  # Opens the pool. Call once at startup (or from specs with a test URL).
  def self.connect!(url : String = Config.database_url) : Mjollnir::Pool
    @@db = Mjollnir.pool(url)
  end

  def self.db : Mjollnir::Pool
    @@db || raise "database not connected: call Shonin.connect! first"
  end

  module Schema
    LOCK_KEY = 7_770_001_i64

    # Applies pending migrations. An advisory lock makes this safe when
    # several instances start at once.
    def self.migrate!(db : Mjollnir::Pool) : Nil
      db.with_connection do |conn|
        conn.exec "select pg_advisory_lock($1)", LOCK_KEY
        begin
          conn.exec_all <<-SQL
            create table if not exists schema_migrations (
              version    integer     primary key,
              name       text        not null,
              applied_at timestamptz not null default now()
            )
          SQL
          applied = conn.query_all("select version from schema_migrations", as: Int32)
          Migrations::ALL.each do |m|
            next if applied.includes?(m.version)
            name = m.name.gsub("'", "''")
            conn.exec_all "#{m.sql}\n;\ninsert into schema_migrations (version, name) values (#{m.version}, '#{name}')"
            puts "[shonin] applied migration #{m.version}: #{m.name}"
          end
        ensure
          conn.exec "select pg_advisory_unlock($1)", LOCK_KEY
        end
      end
    end

    # Creates the administrator named in SHONIN_ADMIN_EMAIL / SHONIN_ADMIN_PASSWORD.
    def self.seed_admin!(db : Mjollnir::Pool) : Nil
      email = Config.admin_email
      password = Config.admin_password
      unless email && password
        puts "[shonin] no administrator configured (set SHONIN_ADMIN_EMAIL and SHONIN_ADMIN_PASSWORD)"
        return
      end

      if db.query_one?("select id from users where email = $1", email, as: Int64)
        db.exec "update users set role = 'admin', email_verified_at = coalesce(email_verified_at, now()) where email = $1", email
        puts "[shonin] administrator #{email} already exists"
      else
        db.exec "insert into users (email, password_hash, role, email_verified_at) values ($1, $2, 'admin', now())",
          email, Security.hash_password(password)
        puts "[shonin] created administrator #{email}"
      end
    end
  end
end
