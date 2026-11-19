#!/usr/bin/env python3
"""End-to-end smoke test against a running Shonin. Usage: smoke.py [base_url] [server_log]
Reads the verification link from the server's console log, exactly as a human would."""
import io, json, re, struct, sys, time, urllib.request, urllib.error, zipfile, gzip, uuid, zlib, threading

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:3000"
LOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/shonin.log"
ADMIN = ("admin@shonin.test", "adminpass123")
API = BASE + "/api/v1"
fails = 0

def call(method, path, body=None, token=None, raw=None, ctype=None, base=API):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(base + path, data=data, method=method)
    if data is not None: req.add_header("Content-Type", ctype or "application/json")
    if token: req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            b = r.read(); return r.status, (json.loads(b) if b and r.headers.get("Content-Type","").startswith("application/json") else b), r.headers
    except urllib.error.HTTPError as e:
        b = e.read()
        try: return e.code, json.loads(b), e.headers
        except Exception: return e.code, b, e.headers

def check(name, cond, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"   {extra}"))
    if not cond: fails += 1

def png(w, h, color):
    raw = b"".join(b"\x00" + bytes(color) * w for _ in range(h))
    def chunk(t, d): c = struct.pack(">I", len(d)) + t + d; return c + struct.pack(">I", zlib.crc32(t + d))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")

def link_for(email):
    time.sleep(0.3)
    text = open(LOG).read()
    found = re.findall(r"(http\S+/auth/verify\?token=\S+)", text)
    assert found, "no verification link in server log"
    return found[-1]

def register_verify_login(email, pw="correct horse 1"):
    s, b, _ = call("POST", "/auth/register", {"email": email, "password": pw}); assert s == 201, (s, b)
    s, b, _ = call("POST", "/auth/login", {"email": email, "password": pw})
    check(f"{email}: login blocked before verification", s == 403 and b["error"] == "email_not_verified", (s, b))
    url = link_for(email)
    req = urllib.request.Request(url, headers={"Accept": "text/html"})
    html = urllib.request.urlopen(req).read().decode()
    check(f"{email}: verify link works in a browser", "Email verified" in html)
    s, b, _ = call("POST", "/auth/login", {"email": email, "password": pw}); assert s == 200, (s, b)
    return b["token"], b["user"]["id"]

tag = uuid.uuid4().hex[:6]
s, b, _ = call("POST", "/auth/register", {"email": f"x{tag}@t.test", "password": "short"}); check("short password rejected", s == 422, (s, b))
s, b, _ = call("POST", "/auth/register", {"email": "not-an-email", "password": "longenough1"}); check("bad email rejected", s == 422, (s, b))

seller_tok, seller_id = register_verify_login(f"seller{tag}@t.test")
buyer_tok, buyer_id = register_verify_login(f"buyer{tag}@t.test")
s, b, _ = call("POST", "/auth/register", {"email": f"seller{tag}@t.test", "password": "correct horse 1"}); check("duplicate email -> 409", s == 409, (s, b))
s, b, _ = call("POST", "/auth/login", {"email": ADMIN[0], "password": ADMIN[1]}); admin_tok = b["token"]

# Store management
s, b, _ = call("POST", "/stores", {"name": f"Seller Shop {tag}", "description": "Good stuff"}, seller_tok); check("create store", s == 201, (s, b)); store_id = b["id"]
s, b, _ = call("POST", "/stores", {"name": f"Second {tag}"}, seller_tok); check("one store per user", s == 409, (s, b))
s, b, _ = call("PATCH", "/stores/me", {"description": "Updated"}, seller_tok); check("edit store", s == 200 and b["description"] == "Updated", (s, b))
s, b, _ = call("POST", "/admin/categories", {"name": f"Gadgets {tag}"}, admin_tok); check("admin creates category", s == 201, (s, b)); cat = b["id"]
s, b, _ = call("POST", "/admin/categories", {"name": "x"}, seller_tok); check("non-admin cannot create category", s == 403, (s, b))

# Images: 400x200 landscape -> must come out 192x192 without distortion
def jpeg_bytes():
    import subprocess
    return subprocess.run(["convert", "-size", "400x200", "gradient:red-blue", "jpg:-"], capture_output=True).stdout
img = jpeg_bytes() or png(400, 200, (200, 30, 30))
s, b, _ = call("PUT", "/stores/me/logo", raw=img, ctype="application/octet-stream", token=seller_tok); check("logo upload", s == 200, (s, b))
s, b, _ = call("POST", "/stores/me/products", {"name": f"Phone {tag}", "description": "A shiny phone", "price_cents": 49900, "stock": 5, "category_id": cat}, seller_tok); check("create product", s == 201, (s, b)); pid = b["id"]
s, b, _ = call("POST", f"/stores/me/products/{pid}/images", raw=img, ctype="application/octet-stream", token=seller_tok); check("product image upload", s == 201 and b["width"] == 192, (s, b)); url1 = b["url"]
bound = "XBOUNDARYX"
mp = (f"--{bound}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n").encode() + png(100, 300, (10, 200, 10)) + f"\r\n--{bound}--\r\n".encode()
s, b, _ = call("POST", f"/stores/me/products/{pid}/images", raw=mp, ctype=f"multipart/form-data; boundary={bound}", token=seller_tok); check("multipart PNG upload", s == 201, (s, b)); url2 = b["url"]
s, b, _ = call("POST", f"/stores/me/products/{pid}/images", raw=b"not an image at all", ctype="application/octet-stream", token=seller_tok); check("non-image rejected 415", s == 415, (s, b))
for u in (url1, url2):
    s, data, h = call("GET", u, base=BASE)
    dims = None
    if data[:2] == b"\xff\xd8":
        i = 2
        while i < len(data):
            if data[i] != 0xFF: i += 1; continue
            m = data[i+1]
            if m in (0xC0, 0xC1, 0xC2): dims = struct.unpack(">HH", data[i+5:i+9])[::-1]; break
            i += 2 + struct.unpack(">H", data[i+2:i+4])[0]
    check(f"served image {u} is a 192x192 JPEG", s == 200 and dims == (192, 192), (s, dims))

# Catalogue
s, b, _ = call("GET", "/products?q=shin"); check("prefix search finds product", any(i["id"] == pid for i in b["items"]), b)
s, b, _ = call("GET", f"/products?category_id={cat}&sort=price_asc"); check("category + sort", s == 200 and len(b["items"]) == 1, (s, b))
s, b, _ = call("GET", f"/products/{pid}"); check("product detail has 2 images", len(b["images"]) == 2, b)

# Cart + order
s, b, _ = call("PUT", "/cart/items", {"product_id": pid, "qty": 1}, seller_tok); check("cannot buy own product", s == 422, (s, b))
s, b, _ = call("PUT", "/cart/items", {"product_id": pid, "qty": 9}, buyer_tok); check("cart accepts qty", s == 200, (s, b))
s, b, _ = call("POST", "/orders", {"ship_name": "Bob", "ship_phone": "0917000000", "ship_address": "1 Main St"}, buyer_tok); check("order beyond stock -> 409", s == 409, (s, b))
s, b, _ = call("PUT", "/cart/items", {"product_id": pid, "qty": 2}, buyer_tok)
s, b, _ = call("POST", "/orders", {"ship_name": "Bob", "ship_phone": "0917000000", "ship_address": "1 Main St"}, buyer_tok); check("place order", s == 201, (s, b)); oid = b["order_ids"][0]
s, b, _ = call("GET", f"/products/{pid}"); check("stock decremented to 3", b["stock"] == 3 and b["sold"] == 2, b)
s, b, _ = call("POST", f"/stores/me/orders/{oid}/confirm", None, seller_tok); check("seller confirms", s == 200, (s, b))
s, b, _ = call("POST", f"/stores/me/orders/{oid}/ship", None, seller_tok); check("seller ships", s == 200, (s, b))
s, b, _ = call("POST", f"/orders/{oid}/complete", None, buyer_tok); check("buyer completes", s == 200, (s, b))
s, b, _ = call("GET", "/stores/me/stats", token=seller_tok); check("stats", s == 200 and b["orders"]["completed"]["total_cents"] == 99800, (s, b))
# cancel restores stock
call("PUT", "/cart/items", {"product_id": pid, "qty": 1}, buyer_tok)
s, b, _ = call("POST", "/orders", {"ship_name": "Bob", "ship_phone": "0917000000", "ship_address": "1 Main St"}, buyer_tok); oid2 = b["order_ids"][0]
s, b, _ = call("POST", f"/orders/{oid2}/cancel", None, buyer_tok); check("buyer cancels pending", s == 200, (s, b))
s, b, _ = call("GET", f"/products/{pid}"); check("stock restored after cancel", b["stock"] == 3, b)

# Chat
s, b, _ = call("POST", "/conversations", {"store_id": store_id, "message": "Is it unlocked?"}, buyer_tok); check("customer starts chat", s == 201, (s, b)); cid = b["conversation_id"]
s, b, _ = call("GET", "/conversations?as=seller", token=seller_tok); check("seller inbox shows unread + masked email", b["items"][0]["unread"] == 1 and "***" in b["items"][0]["with"], b)
result = {}
def poller():
    result["r"] = call("GET", f"/conversations/{cid}/messages?after=999999999&wait=10", token=buyer_tok)
s, b, _ = call("GET", f"/conversations/{cid}/messages", token=seller_tok); last = b["items"][-1]["id"]
t = threading.Thread(target=lambda: result.update(r=call("GET", f"/conversations/{cid}/messages?after={last}&wait=10", token=buyer_tok))); t0 = time.time(); t.start()
time.sleep(0.5)
s, b, _ = call("POST", f"/conversations/{cid}/messages", {"body": "Yes, unlocked!"}, seller_tok); check("seller replies", s == 201, (s, b))
t.join(); el = time.time() - t0
check("long-poll delivered reply instantly", result["r"][0] == 200 and result["r"][1]["items"][0]["body"] == "Yes, unlocked!" and el < 3, (result["r"], el))
s, b, _ = call("POST", f"/stores/me/conversations", {"customer_id": buyer_id, "message": "Thanks for ordering"}, seller_tok); check("seller can message a past customer", s == 201, (s, b))
s, b, _ = call("GET", f"/conversations/{cid}/messages", token=admin_tok); check("outsiders (even admin) cannot read chats", s == 404, (s, b))

# Moderation
s, b, _ = call("POST", f"/admin/users/{buyer_id}/suspend", {"duration_hours": 2, "reason": "spamming"}, admin_tok); check("suspend user", s == 200, (s, b))
s, b, _ = call("POST", f"/conversations/{cid}/messages", {"body": "hi"}, buyer_tok); check("suspended user cannot send", s == 403 and b["error"] == "account_suspended", (s, b))
s, b, _ = call("GET", "/orders", token=buyer_tok); check("suspended user can still read", s == 200, (s, b))
s, b, _ = call("DELETE", f"/admin/users/{buyer_id}/suspend", None, admin_tok); check("unsuspend", s == 200, (s, b))
s, b, _ = call("POST", f"/admin/users/{buyer_id}/ban", {"reason": "fraud"}, admin_tok); check("ban user", s == 200, (s, b))
s, b, _ = call("GET", "/me", token=buyer_tok); check("banned user's token dies immediately", s in (401, 403), (s, b))
s, b, _ = call("POST", "/auth/login", {"email": f"buyer{tag}@t.test", "password": "correct horse 1"}); check("banned login -> account_banned", s == 403 and b["error"] == "account_banned", (s, b))
s, b, _ = call("POST", f"/admin/users/{seller_id}/ban", {"reason": "test"}, buyer_tok); check("non-admin cannot ban", s in (401, 403), (s, b))
s, b, _ = call("POST", f"/admin/users/1/ban", {"reason": "nope"}, admin_tok); check("admins cannot be banned", s == 403, (s, b))
s, b, _ = call("DELETE", f"/admin/users/{buyer_id}/ban", None, admin_tok); check("unban", s == 200, (s, b))
s, b, _ = call("GET", f"/admin/users/{buyer_id}", token=admin_tok); check("moderation history recorded", [h["action"] for h in b["history"]][:4] == ["unban", "ban", "unsuspend", "suspend"], b)

# Backups
s, data, h = call("GET", "/admin/backup/db", token=admin_tok)
sql = gzip.decompress(data).decode() if s == 200 else ""
check("db backup is valid gzip SQL with data", s == 200 and "insert into products" in sql and f"Phone {tag}" in sql and sql.rstrip().endswith("commit;"), (s, sql[:200]))
s, b, _ = call("GET", "/admin/backup/db", token=seller_tok); check("db backup forbidden to users", s == 403, (s, b))
s, data, h = call("GET", "/admin/backup/images", token=admin_tok)
z = zipfile.ZipFile(io.BytesIO(data)) if s == 200 else None
names = [n for n in z.namelist() if n.endswith(".jpg")] if z else []
check("images zip valid and has images", z is not None and z.testzip() is None and len(names) >= 3, (s, names))

print(f"\n{'ALL PASSED' if not fails else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
