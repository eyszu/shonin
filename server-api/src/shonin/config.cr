module Shonin
  # Runtime configuration, read once from the environment.
  module Config
    class_getter port : Int32 = (ENV["SHONIN_PORT"]? || ENV["PORT"]? || "3000").to_i
    class_getter host : String = ENV["SHONIN_HOST"]? || "0.0.0.0"

    # Mjollnir URL. The default matches the README's quick-start database.
    class_getter database_url : String = ENV["SHONIN_DATABASE_URL"]? ||
                                         "postgres://asyong:asyong@127.0.0.1/shonin?max_pool_size=16&application_name=shonin"

    # Used to build the links in emails.
    class_getter base_url : String = (ENV["SHONIN_BASE_URL"]? || "http://localhost:#{port}").rstrip('/')

    class_getter data_dir : String = ENV["SHONIN_DATA_DIR"]? || "./data"
    class_getter images_dir : String = File.join(data_dir, "images")

    # Optional first administrator, created (verified) at startup if missing.
    class_getter admin_email : String? = ENV["SHONIN_ADMIN_EMAIL"]?.try(&.strip.downcase.presence)
    class_getter admin_password : String? = ENV["SHONIN_ADMIN_PASSWORD"]?.presence

    class_getter bcrypt_cost : Int32 = (ENV["SHONIN_BCRYPT_COST"]? || "10").to_i
    class_getter cors_origin : String = ENV["SHONIN_CORS_ORIGIN"]? || "*"
    class_getter log_requests : Bool = %w(1 true yes on).includes?((ENV["SHONIN_LOG_REQUESTS"]? || "").downcase)

    # Hard limits.
    SESSION_TTL        = 30.days
    VERIFY_TTL         = 24.hours
    MAX_UPLOAD_BYTES   = 5 * 1024 * 1024
    MAX_IMAGE_PIXELS   = 12_000_000
    IMAGE_SIZE         = 192
    MAX_PRODUCT_IMAGES = 5
    MAX_CART_LINES     = 100
    MAX_MESSAGE_CHARS  = 2000
  end
end
