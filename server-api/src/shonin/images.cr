module Shonin
  # Upload handling: size caps, format sniffing, resize with Immagini, atomic write.
  #
  # Every stored image is exactly 192x192 JPEG. `fill` applies ONE uniform
  # scale factor to both axes (new dimensions are rounded to whole pixels),
  # then crops the overflow from the centre, so the picture is never stretched.
  module Images
    SIZE = Config::IMAGE_SIZE

    # Reads the raw request body (an image sent as-is, or one multipart "image"
    # part) with a hard byte cap. Never buffers more than the cap + 1.
    def self.read_upload(req : Spectre::Request) : Bytes
      raw = req.raw
      if len = raw.headers["Content-Length"]?.try(&.to_i64?)
        fail!(413, "image_too_large", "Images may be at most #{Config::MAX_UPLOAD_BYTES // 1_048_576} MiB") if len > Config::MAX_UPLOAD_BYTES + 4096
      end
      io = raw.body
      fail!(400, "no_image", "Send the image as the request body, or as a multipart field named \"image\"") unless io
      data = IO::Sized.new(io, Config::MAX_UPLOAD_BYTES.to_i64 + 4097).getb_to_end
      fail!(413, "image_too_large", "Images may be at most #{Config::MAX_UPLOAD_BYTES // 1_048_576} MiB") if data.size > Config::MAX_UPLOAD_BYTES + 4096

      ctype = raw.headers["Content-Type"]?.to_s
      if ctype.downcase.starts_with?("multipart/form-data")
        boundary = MIME::Multipart.parse_boundary(ctype) || fail!(400, "bad_multipart", "Missing multipart boundary")
        found : Bytes? = nil
        begin
          HTTP::FormData.parse(IO::Memory.new(data), boundary) do |part|
            if part.name == "image" && found.nil?
              buf = IO::Memory.new
              IO.copy(part.body, buf)
              found = buf.to_slice
            end
          end
        rescue HTTP::FormData::Error | MIME::Multipart::Error
          fail!(400, "bad_multipart", "Malformed multipart body")
        end
        return found || fail!(400, "no_image", "Multipart body needs a file field named \"image\"")
      end
      data
    end

    # Validates and converts to a 192x192 JPEG. Raises ApiError on bad input.
    def self.process(data : Bytes) : Bytes
      fail!(400, "no_image", "Empty upload") if data.empty?
      format = Immagini::Format.detect(data)
      fail!(415, "unsupported_image", "Upload a JPEG or PNG image") unless format && (format.jpeg? || format.png?)

      # Check dimensions from the header BEFORE decoding to avoid decompression bombs.
      begin
        w, h = format.jpeg? ? Immagini::Codecs::JPEG.dimensions(data) : Immagini::Codecs::PNG.dimensions(data)
        fail!(422, "image_too_large", "Image is too large (max #{Config::MAX_IMAGE_PIXELS // 1_000_000} megapixels)") if w.to_i64 * h > Config::MAX_IMAGE_PIXELS
        fail!(422, "image_too_small", "Image is too small") if w < 1 || h < 1

        img = Immagini::Image.decode(data, format, auto_orient: true)
        img.fill(SIZE, SIZE).encode(Immagini::Format::JPEG, quality: 85)
      rescue ex : Shonin::ApiError
        raise ex
      rescue ex
        fail!(422, "invalid_image", "The image could not be read (progressive JPEGs are not supported)")
      end
    end

    # Writes atomically (temp file + rename) and returns the stored filename.
    def self.store(data : Bytes) : String
      bytes = process(data)
      name = "#{Random::Secure.hex(16)}.jpg"
      path = File.join(Config.images_dir, name)
      tmp = "#{path}.tmp"
      File.write(tmp, bytes)
      File.rename(tmp, path)
      name
    end

    def self.remove(name : String?) : Nil
      return unless name
      return unless name =~ /\A[0-9a-f]{32}\.jpg\z/
      File.delete?(File.join(Config.images_dir, name))
    end

    def self.url(name : String?) : String?
      name ? "/images/#{name}" : nil
    end
  end
end
