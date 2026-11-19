# Tiny keep-alive HTTP load generator.
#   crystal build --release bench/load.cr -o bin/load
#   bin/load http://localhost:3000/api/v1/products 64 10 [bearer-token]
require "http/client"

url = URI.parse(ARGV[0])
conc = (ARGV[1]? || "32").to_i
secs = (ARGV[2]? || "10").to_i
token = ARGV[3]?
headers = HTTP::Headers.new
headers["Authorization"] = "Bearer #{token}" if token
target = url.request_target

lat = Array(Array(Int32)).new(conc) { [] of Int32 }
errors = Atomic(Int32).new(0)
stop = Time.monotonic + secs.seconds
done = Channel(Nil).new

conc.times do |i|
  spawn do
    client = HTTP::Client.new(url)
    while Time.monotonic < stop
      t0 = Time.monotonic
      begin
        r = client.get(target, headers)
        errors.add(1) unless r.status_code == 200
      rescue
        errors.add(1)
        client = HTTP::Client.new(url)
      end
      lat[i] << (Time.monotonic - t0).total_microseconds.to_i32
    end
    done.send(nil)
  end
end
conc.times { done.receive }

all = lat.flatten.sort!
n = all.size
pct = ->(p : Float64) { all[(n * p).to_i.clamp(0, n - 1)] / 1000.0 }
puts "requests=#{n} errors=#{errors.get} rps=#{(n / secs).round(0)} p50=#{pct.call(0.5).round(2)}ms p99=#{pct.call(0.99).round(2)}ms max=#{(all.last / 1000.0).round(1)}ms"
