require "compress/gzip"
require "compress/zip"

module Shonin
  module Routes
    # Admin-only backups, both streamed so memory stays flat however big the data is.
    #
    #   GET /admin/backup/db      gzip-compressed SQL; restore: gunzip -c f.sql.gz | psql shonin
    #   GET /admin/backup/images  zip of every stored product image and logo
    module BackupRoutes
      # Parent tables first. Sessions and email tokens are deliberately left out.
      TABLES = {
        {"users", "id"}, {"categories", "id"}, {"stores", "id"}, {"products", "id"},
        {"product_images", "id"}, {"cart_items", "user_id, product_id"}, {"orders", "id"},
        {"order_items", "id"}, {"conversations", "id"}, {"messages", "id"}, {"moderation_log", "id"},
      }
      CHUNK = 500

      private def self.stamp : String
        Time.utc.to_s("%Y%m%d-%H%M%S")
      end

      def self.dump_sql(io : IO) : Nil
        tag = "$bk#{Random::Secure.hex(8)}$"
        Compress::Gzip::Writer.open(io, level: Compress::Gzip::DEFAULT_COMPRESSION) do |gz|
          gz << "-- Shonin database backup #{Time.utc.to_rfc3339}\n"
          gz << "-- Restore into a database that Shonin has already migrated:\n"
          gz << "--   gunzip -c backup.sql.gz | psql \"$DATABASE_URL\"\n"
          gz << "-- Contains password hashes. Store it like a secret.\n"
          gz << "begin;\n"
          gz << "truncate table " << TABLES.join(", ") { |t| t[0] } << " restart identity cascade;\n"

          Shonin.db.with_connection do |conn|
            conn.exec "begin isolation level repeatable read read only"
            begin
              TABLES.each do |table, order|
                count = 0
                chunk = IO::Memory.new
                flush = -> {
                  if count > 0
                    gz << "insert into " << table << " select * from json_populate_recordset(null::" << table << ", " << tag << "["
                    gz.write chunk.to_slice
                    gz << "]" << tag << "::json);\n"
                    chunk.clear
                    count = 0
                  end
                }
                conn.query("select row_to_json(t)::text from #{table} t order by #{order}") do |rs|
                  rs.each do
                    chunk << ',' if count > 0
                    chunk << rs.read(String)
                    count += 1
                    flush.call if count >= CHUNK
                  end
                end
                flush.call
                if order == "id"
                  gz << "select setval(pg_get_serial_sequence('" << table << "', 'id'), coalesce((select max(id) from " << table << "), 1), (select count(*) > 0 from " << table << "));\n"
                end
              end
            ensure
              conn.exec "rollback"
            end
          end
          gz << "commit;\n"
        end
      end

      def self.zip_images(io : IO) : Int32
        files = Dir.glob(File.join(Config.images_dir, "*.jpg")).sort
        written = 0
        Compress::Zip::Writer.open(io) do |zip|
          files.each do |path|
            bytes = begin
              File.read(path).to_slice
            rescue File::NotFoundError
              next # deleted while we were zipping
            end
            zip.add("images/#{File.basename(path)}", bytes)
            written += 1
          end
          zip.add("README.txt", "Shonin image backup, #{written} files, generated #{Time.utc.to_rfc3339}.\nCopy the images/ folder contents back into the data/images directory.\n")
        end
        written
      end

      def self.register(r : Spectre::Router) : Nil
        r.get "/admin/backup/db", Guards::ADMIN do |req, res|
          Log.info { "db backup requested by admin #{req.auth!.id}" }
          sink = res.raw
          sink.status_code = 200
          sink.headers["Content-Type"] = "application/gzip"
          sink.headers["Content-Disposition"] = %(attachment; filename="shonin-db-#{stamp}.sql.gz")
          sink.headers["Cache-Control"] = "no-store"
          dump_sql(sink)
        end

        r.get "/admin/backup/images", Guards::ADMIN do |req, res|
          Log.info { "image backup requested by admin #{req.auth!.id}" }
          sink = res.raw
          sink.status_code = 200
          sink.headers["Content-Type"] = "application/zip"
          sink.headers["Content-Disposition"] = %(attachment; filename="shonin-images-#{stamp}.zip")
          sink.headers["Cache-Control"] = "no-store"
          zip_images(sink)
        end
      end
    end
  end
end
