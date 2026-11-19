require "crypto/bcrypt/password"
require "digest/sha256"
require "base64"

module Shonin
  module Security
    # bcrypt only uses the first 72 bytes of its input. Hashing the password
    # with SHA-256 first lets any length work and keeps the full password
    # significant.
    private def self.prehash(password : String) : String
      Base64.strict_encode(Digest::SHA256.digest(password))
    end

    def self.hash_password(password : String) : String
      Crypto::Bcrypt::Password.create(prehash(password), cost: Config.bcrypt_cost).to_s
    end

    def self.verify_password(password : String, hash : String) : Bool
      Crypto::Bcrypt::Password.new(hash).verify(prehash(password))
    rescue Crypto::Bcrypt::Error
      false
    end

    @@dummy_hash : String?

    # Verifies against a throwaway hash so a login for an unknown email takes
    # as long as one for a real account (no account enumeration by timing).
    def self.burn_time(password : String) : Nil
      hash = @@dummy_hash ||= hash_password("shonin-timing-equaliser")
      verify_password(password, hash)
    end

    # A random URL-safe secret (256 bits).
    def self.new_token : String
      Random::Secure.urlsafe_base64(32)
    end

    # Tokens are stored only as their SHA-256, so a leaked database does not
    # leak usable sessions or verification links.
    def self.digest(token : String) : String
      Digest::SHA256.hexdigest(token)
    end
  end

  module Mailer
    # Prints the email to the console instead of sending it, so the
    # verification link can be opened from the log. Swap this method for SMTP
    # or an API client in production.
    def self.deliver(to : String, subject : String, body : String) : Nil
      STDOUT.puts "\n================ EMAIL (console mailer) ================"
      STDOUT.puts "To:      #{to}"
      STDOUT.puts "Subject: #{subject}"
      STDOUT.puts
      STDOUT.puts body
      STDOUT.puts "========================================================\n"
      STDOUT.flush
    end

    def self.verification(email : String, token : String) : Nil
      link = "#{Config.base_url}/api/v1/auth/verify?token=#{token}"
      deliver(email, "Verify your Shonin account", <<-TEXT)
        Welcome to Shonin!

        Open this link to verify your email address (valid for 24 hours):

        #{link}

        If you did not create this account, ignore this email.
        TEXT
    end
  end
end
