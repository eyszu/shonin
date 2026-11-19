module Shonin
  # An error with a stable machine-readable `code`, turned into
  # `{"error": code, "message": ...}` by the app's error handler.
  class ApiError < Spectre::HTTPError
    getter code : String
    getter retry_after : Int32?

    def initialize(status : Int32, @code : String, message : String, @retry_after : Int32? = nil)
      super(status, message)
    end
  end
end

# Raises an `ApiError`. Global on purpose, so handlers can write `fail!(404, ...)`.
def fail!(status : Int32, code : String, message : String) : NoReturn
  raise Shonin::ApiError.new(status, code, message)
end

module Shonin
  module Api
    JSON_TYPE = "application/json; charset=utf-8"

    # Builds a JSON document straight into a buffer (no intermediate structs)
    # and sends it. The block must write one complete value.
    def self.json(res : Spectre::Response, status : Int32 = 200, & : JSON::Builder ->) : Nil
      io = IO::Memory.new(1024)
      JSON.build(io) { |builder| yield builder }
      res.status(status).send(io.to_slice, JSON_TYPE)
    end

    def self.message(res : Spectre::Response, status : Int32, text : String) : Nil
      json(res, status) { |b| b.object { b.field "message", text } }
    end

    # --- errors -------------------------------------------------------------------

    def self.error_response(ex : Exception, req : Spectre::Request, res : Spectre::Response) : Nil
      status = 500
      code = "internal_error"
      message = "Internal Server Error"
      retry_after = nil

      case ex
      when ApiError
        status, code, message, retry_after = ex.status, ex.code, ex.message.to_s, ex.retry_after
      when Spectre::HTTPError
        status = ex.status
        code = HTTP::Status.new(status).description.to_s.downcase.tr(" ", "_")
        message = ex.message.to_s
      when Mjollnir::PGError
        case ex.code
        when "23505"
          status, code, message = 409, "conflict", "That already exists"
        when "23503"
          status, code, message = 409, "conflict", "A related record is missing or still in use"
        when "23514", "22P02", "22003", "22001", "22007"
          status, code, message = 422, "invalid_value", "A value is out of range or malformed"
        else
          log_exception(ex, req)
        end
      when Mjollnir::PoolTimeout, Mjollnir::ConnectionLost, Mjollnir::ConnectionRefused
        status, code, message, retry_after = 503, "unavailable", "The database is busy, try again shortly", 1
        log_exception(ex, req)
      else
        log_exception(ex, req)
      end

      res.header("Retry-After", retry_after.to_s) if retry_after
      json(res, status) do |b|
        b.object do
          b.field "error", code
          b.field "message", message
        end
      end
    end

    private def self.log_exception(ex : Exception, req : Spectre::Request) : Nil
      Log.for("shonin").error(exception: ex) { "#{req.method} #{req.path}" }
    end

    # --- request helpers ------------------------------------------------------------

    # `?limit=` clamped to 1..max.
    def self.limit(req : Spectre::Request, default : Int32 = 20, max : Int32 = 50) : Int32
      raw = req.query["limit"]?
      return default unless raw
      (raw.to_i? || fail!(400, "invalid_limit", "limit must be an integer")).clamp(1, max)
    end

    # An optional integer query parameter.
    def self.int_query(req : Spectre::Request, name : String) : Int64?
      raw = req.query[name]?
      return nil if raw.nil? || raw.empty?
      raw.to_i64? || fail!(400, "invalid_#{name}", "#{name} must be an integer")
    end

    def self.string_query(req : Spectre::Request, name : String, max : Int32 = 100) : String?
      raw = req.query[name]?.try(&.strip)
      return nil if raw.nil? || raw.empty?
      fail!(400, "invalid_#{name}", "#{name} is too long") if raw.size > max
      raw
    end

    # Writes a `{"items": [...], "next_cursor": ...}` page.
    def self.page(res : Spectre::Response, next_cursor : String?, & : JSON::Builder ->) : Nil
      json(res) do |b|
        b.object do
          b.field "items" do
            b.array { yield b }
          end
          b.field "next_cursor", next_cursor
        end
      end
    end
  end

  # Strict, field-by-field access to a JSON object body, with clear 422 messages.
  struct Body
    def initialize(@h : Hash(String, JSON::Any))
    end

    def self.parse(req : Spectre::Request) : Body
      any = req.json
      Body.new(any.as_h? || fail!(422, "invalid_body", "The body must be a JSON object"))
    end

    # The same, but an empty body counts as `{}`.
    def self.parse_optional(req : Spectre::Request) : Body
      return Body.new({} of String => JSON::Any) if req.body.strip.empty?
      parse(req)
    end

    def has?(key : String) : Bool
      @h.has_key?(key)
    end

    # A string, or nil when absent or null.
    def string(key : String, min : Int32 = 1, max : Int32 = 255, strip : Bool = true) : String?
      value = @h[key]?
      return nil if value.nil? || value.raw.nil?
      text = value.as_s? || fail!(422, "invalid_field", "#{key} must be a string")
      text = text.strip if strip
      unless text.size >= min && text.size <= max
        fail!(422, "invalid_field", "#{key} must be #{min} to #{max} characters")
      end
      text
    end

    def string!(key : String, min : Int32 = 1, max : Int32 = 255, strip : Bool = true) : String
      string(key, min, max, strip) || fail!(422, "missing_field", "#{key} is required")
    end

    # An integer, or nil when absent or null.
    def integer(key : String, min : Int64, max : Int64) : Int64?
      value = @h[key]?
      return nil if value.nil? || value.raw.nil?
      number = value.as_i64? || fail!(422, "invalid_field", "#{key} must be an integer")
      unless number >= min && number <= max
        fail!(422, "invalid_field", "#{key} must be between #{min} and #{max}")
      end
      number
    end

    def integer!(key : String, min : Int64, max : Int64) : Int64
      integer(key, min, max) || fail!(422, "missing_field", "#{key} is required")
    end

    def null?(key : String) : Bool
      value = @h[key]?
      !value.nil? && value.raw.nil?
    end
  end

  # Input rules shared by several endpoints.
  module Validate
    EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

    def self.email(raw : String) : String
      email = raw.strip.downcase
      unless email.size <= 254 && EMAIL_RE.matches?(email)
        fail!(422, "invalid_email", "Enter a valid email address")
      end
      email
    end

    def self.password(raw : String) : String
      unless raw.size >= 8 && raw.size <= 128
        fail!(422, "invalid_password", "Password must be 8 to 128 characters")
      end
      raw
    end

    def self.id(value : String, what : String) : Int64
      value.to_i64? || fail!(400, "invalid_id", "#{what} id must be an integer")
    end
  end

  # A fixed-window, in-memory limiter. It protects the expensive endpoints
  # (password hashing, email) from being hammered; with several server
  # processes each one counts separately.
  module RateLimit
    @@buckets = {} of String => {Int32, Time::Span}

    def self.check!(key : String, limit : Int32, window : Time::Span) : Nil
      now = Time.monotonic
      bucket = @@buckets[key]?
      if bucket && bucket[1] > now
        count = bucket[0] + 1
        @@buckets[key] = {count, bucket[1]}
        if count > limit
          wait = (bucket[1] - now).total_seconds.ceil.to_i
          raise ApiError.new(429, "rate_limited", "Too many attempts, try again later", wait)
        end
      else
        sweep(now) if @@buckets.size > 10_000
        @@buckets[key] = {1, now + window}
      end
    end

    def self.reset! : Nil
      @@buckets.clear
    end

    private def self.sweep(now : Time::Span) : Nil
      @@buckets.reject! { |_, bucket| bucket[1] <= now }
    end
  end
end
