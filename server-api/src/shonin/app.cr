module Shonin
  # Builds the Spectre application with every route mounted under /api/v1.
  def self.build_app : Spectre::App
    app = Spectre::App.new
    app.max_body = 1_048_576

    app.error { |ex, req, res| Api.error_response(ex, req, res) }
    app.not_found do |req, res|
      Api.json(res, 404) do |b|
        b.object do
          b.field "error", "not_found"
          b.field "message", "No such route: #{req.method} #{req.path}"
        end
      end
    end

    app.use Spectre::Middleware.logger if Config.log_requests
    app.use Spectre::Middleware.cors(origin: Config.cors_origin, headers: "Content-Type, Authorization")
    app.use Spectre.layer { |req, res, nxt| res.header("X-Content-Type-Options", "nosniff"); nxt.call }

    api = Spectre::Router.new
    Routes::AuthRoutes.register(api)
    Routes::AdminRoutes.register(api)
    Routes::StoreRoutes.register(api)
    Routes::ProductRoutes.register(api)
    Routes::OrderRoutes.register(api)
    Routes::ChatRoutes.register(api)
    Routes::BackupRoutes.register(api)
    app.mount "/api/v1", api
    app.static "/images", Config.images_dir, max_age: 86_400

    app.get "/health" do |req, res|
      Shonin.db.scalar("select 1")
      Api.json(res) { |b| b.object { b.field "status", "ok" } }
    end

    app
  end

  def self.run : Nil
    Log.setup_from_env(default_level: Log::Severity::Info)
    pool = connect!
    Schema.migrate!(pool)
    Schema.seed_admin!(pool)
    Dir.mkdir_p(Config.images_dir)

    app = build_app
    puts "[shonin] listening on #{Config.host}:#{Config.port}  (links in emails use #{Config.base_url})"
    app.listen(Config.port, Config.host)
    pool.close
  end
end
