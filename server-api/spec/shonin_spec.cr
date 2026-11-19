ENV["SHONIN_NO_AUTORUN"] = "1"
ENV["SHONIN_DATABASE_URL"] ||= "mjollnir://shonin:shonin@127.0.0.1/shonin_test?max_pool_size=4"
ENV["SHONIN_DATA_DIR"] = "/tmp/shonin_spec_data"
ENV["SHONIN_BCRYPT_COST"] = "4"
require "spec"
require "../src/shonin"

pool = Shonin.connect!
Shonin::Schema.migrate!(pool)
Dir.mkdir_p(Shonin::Config.images_dir)
APP = Shonin.build_app
JSON_H = HTTP::Headers{"Content-Type" => "application/json"}

describe "Shonin API" do
  it "answers health" do
    APP.request("GET", "/health").status_code.should eq 200
  end

  it "requires a token" do
    r = APP.request("GET", "/api/v1/me")
    r.status_code.should eq 401
    JSON.parse(r.body)["error"].should eq "unauthorized"
  end

  it "returns JSON 404 for unknown routes" do
    r = APP.request("GET", "/api/v1/nope")
    r.status_code.should eq 404
    JSON.parse(r.body)["error"].should eq "not_found"
  end

  it "registers, refuses login until verified, and rejects duplicates" do
    email = "spec#{Random::Secure.hex(4)}@t.test"
    body = {email: email, password: "a long password"}.to_json
    APP.request("POST", "/api/v1/auth/register", body, JSON_H).status_code.should eq 201
    APP.request("POST", "/api/v1/auth/register", body, JSON_H).status_code.should eq 409
    r = APP.request("POST", "/api/v1/auth/login", body, JSON_H)
    r.status_code.should eq 403
    JSON.parse(r.body)["error"].should eq "email_not_verified"
  end

  it "validates input" do
    r = APP.request("POST", "/api/v1/auth/register", {email: "bad", password: "x"}.to_json, JSON_H)
    r.status_code.should eq 422
  end

  it "rejects non-admins on admin routes" do
    APP.request("GET", "/api/v1/admin/users").status_code.should eq 401
  end

  it "keeps product listing public and paginated" do
    r = APP.request("GET", "/api/v1/products?limit=2")
    r.status_code.should eq 200
    JSON.parse(r.body)["items"].as_a.size.should be <= 2
  end

  it "resizes any aspect ratio to exactly 192x192" do
    [{400, 200}, {100, 300}, {192, 192}, {1, 1}, {37, 501}].each do |(w, h)|
      img = Immagini::Image.new(w, h, Immagini::Color.new(200_u8, 30_u8, 30_u8, 255_u8))
      jpg = Shonin::Images.process(img.encode(Immagini::Format::PNG))
      Immagini::Codecs::JPEG.dimensions(jpg).should eq({192, 192})
    end
  end

  it "rejects non-images" do
    expect_raises(Shonin::ApiError) { Shonin::Images.process("hello".to_slice) }
  end
end
