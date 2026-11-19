# Shonin

A Shopee-style marketplace **REST API** written in Crystal.

| Piece | Used for |
|---|---|
| [Spectre](https://github.com/eyszu/spectre) | HTTP microframework (routing, middleware, static files) |
| [Mjollnir](vendor/mjollnir) | PostgreSQL driver (standalone, vendored in `vendor/mjollnir`) |
| [Immagini](https://github.com/eyszu/immagini) | Resizing every uploaded image to 192x192 |

Features: email + password registration with an email-verification link (printed to the server console), sessions, banning and timed suspension, stores and store management, products with images, search, cart, cash-on-delivery orders, seller-to-customer chat (long-poll), admin database backup download and an images ZIP download.

## Run it

```sh
# 1. PostgreSQL 14+ with an empty database
createuser shonin --pwprompt && createdb shonin -O shonin

# 2. build and start (migrations run automatically)
shards install --ignore-crystal-version
crystal build --release src/shonin.cr -o bin/shonin   # you may need to create bin folder
SHONIN_ADMIN_EMAIL=asyong@gmail.com SHONIN_ADMIN_PASSWORD='asyong' ./bin/shonin
```

Register an account and look at the terminal where the server runs. You will see:

```
========================================================
To:      you@example.com
Subject: Verify your Shonin account
...
http://localhost:3000/api/v1/auth/verify?token=...
```

Open that link in a browser; you get an "Email verified" page and can log in.

| Variable | Default | Meaning |
|---|---|---|
| `SHONIN_PORT` / `PORT` | 3000 | listen port |
| `SHONIN_HOST` | 0.0.0.0 | bind address |
| `SHONIN_DATABASE_URL` | `mjollnir://shonin:shonin@127.0.0.1/shonin?max_pool_size=16` | database |
| `SHONIN_BASE_URL` | `http://localhost:<port>` | host used in the emailed link |
| `SHONIN_DATA_DIR` | `./data` | image storage (`data/images`) |
| `SHONIN_ADMIN_EMAIL`, `SHONIN_ADMIN_PASSWORD` | none | creates the first administrator at startup |
| `SHONIN_BCRYPT_COST` | 10 | password hashing cost |
| `SHONIN_CORS_ORIGIN` | `*` | CORS origin |
| `SHONIN_LOG_REQUESTS` | off | access log |

## API

Base path `/api/v1`. JSON in and out. Authenticated routes need `Authorization: Bearer <token>`. Errors look like `{"error": "code", "message": "..."}`. Lists return `{"items": [...], "next_cursor": "..."}`; pass `cursor` back for the next page (keyset pagination, so deep pages stay fast).

**Auth**
- `POST /auth/register` `{email, password}` (password 8-128 chars) → 201, link printed to console
- `GET /auth/verify?token=` the link in the email (HTML page for browsers, JSON otherwise)
- `POST /auth/resend` `{email}` · `POST /auth/login` `{email, password}` → `{token, expires_at, user}`
- `POST /auth/logout` · `POST /auth/logout-all` · `GET /me`

**Moderation (admin)**
- `GET /admin/users?q=&state=active|suspended|banned` · `GET /admin/users/:id` (with history)
- `POST /admin/users/:id/ban` `{reason}` · `DELETE /admin/users/:id/ban`
- `POST /admin/users/:id/suspend` `{duration_hours, reason}` · `DELETE /admin/users/:id/suspend`
- `POST /admin/categories` `{name}` · `DELETE /admin/categories/:id`

Banned users lose every session at once and cannot log in. Suspended users can sign in and read but every write is refused with `account_suspended` until the suspension ends; their store disappears from listings meanwhile. State is checked in the database on every request, so it takes effect immediately. Administrators cannot be banned or suspended.

**Stores (seller)**
- `POST /stores` `{name, description?}` (one per user) · `GET/PATCH /stores/me` (`name`, `description`, `status: open|closed`)
- `PUT /stores/me/logo` · `DELETE /stores/me/logo`
- `GET /stores/me/stats` · `GET /stores/me/products` · `GET /stores/me/orders?status=` · `GET /stores/me/orders/:id`
- `POST /stores/me/orders/:id/confirm | ship | cancel` (cancel restores stock)
- `GET /stores/:id` public page

**Products**
- Public: `GET /products?q=&category_id=&store_id=&sort=new|popular|price_asc|price_desc` (prefix full-text search), `GET /products/:id`, `GET /categories`
- Seller: `POST /stores/me/products`, `GET|PATCH|DELETE /stores/me/products/:id`, `POST /stores/me/products/:id/images`, `DELETE /stores/me/products/:id/images/:image_id` (max 5 images)

**Images.** Upload the image as the raw request body (`Content-Type: application/octet-stream`) or as a multipart field named `image`. JPEG (baseline) and PNG, up to 5 MiB and 12 megapixels. Whatever the input size or aspect ratio, the stored file is a **192x192 JPEG** served from `/images/<name>.jpg`. Resizing uses Immagini's `fill`: a single scale factor is applied to both axes (resulting sizes rounded to whole pixels), then the overflow is cropped from the centre, so nothing is ever stretched or squashed. EXIF orientation is honoured.

**Cart and orders (cash on delivery)**
- `GET /cart` · `PUT /cart/items` `{product_id, qty}` · `DELETE /cart/items/:product_id` · `DELETE /cart`
- `POST /orders` `{ship_name, ship_phone, ship_address, note?}` checks out the cart, one order per store; stock is taken with an atomic `UPDATE ... WHERE stock >= qty`, so concurrent buyers cannot oversell
- `GET /orders` · `GET /orders/:id` · `POST /orders/:id/cancel` (pending only) · `POST /orders/:id/complete` (after shipping)

**Chat**
- `POST /conversations` `{store_id, message}` customer starts or continues a chat with a store
- `POST /stores/me/conversations` `{customer_id, message}` seller writes to someone who has ordered from them
- `GET /conversations?as=customer|seller` inbox with unread counts (customers appear to sellers as `j***@example.com`)
- `GET /conversations/:id/messages?after=<id>&wait=<seconds, max 25>` long-poll for new messages; `?before=<id>` pages history
- `POST /conversations/:id/messages` `{body}`

Only the two participants can read a conversation (not even admins). Suspended users can read but not send; messages to banned users are refused.

**Backups (admin)**
- `GET /admin/backup/db` streams `shonin-db-<time>.sql.gz`: a consistent snapshot (repeatable-read), data only. Sessions and email tokens are excluded. **It contains password hashes; treat it as a secret.**
- `GET /admin/backup/images` streams `shonin-images-<time>.zip` with every stored image.

```sh
curl -H "Authorization: Bearer $TOKEN" -OJ http://localhost:3000/api/v1/admin/backup/db
curl -H "Authorization: Bearer $TOKEN" -OJ http://localhost:3000/api/v1/admin/backup/images

# Restore: start Shonin once against the empty database (it creates the schema), then
gunzip -c shonin-db-*.sql.gz | psql "postgresql://shonin:...@host/shonin"
unzip shonin-images-*.zip -d data/      # restores data/images/*.jpg
```

## Why it is fast

- Spectre's compiled route table and Mjollnir's binary-protocol prepared statements with a statement cache; the catalogue query text is memoised per filter combination so each is prepared once.
- Responses are written straight with `JSON::Builder`, no intermediate trees.
- Keyset pagination, partial indexes per sort order and a GIN index for search; a login/auth check is one indexed query.
- Stock changes, counters and moderation checks happen inside PostgreSQL (no read-modify-write races).
- Images are resized once at upload time; afterwards they are static 3-8 KB files with cache headers.
- Backups stream (gzip/zip written as they are produced), memory stays flat.

Measured on this sandbox (shared 4-core VM, server, PostgreSQL and the load generator all on one machine, 64 keep-alive connections, `--release`, 2,000 products): `/health` 34k req/s, `/me` with auth 18k req/s, static image 30k req/s, `GET /products` 4.9k req/s (p50 8.7 ms), search `?q=` 4.1k req/s. Run `bench/load.cr` yourself for your hardware.

## Tests

```sh
createdb shonin_test -O shonin && crystal spec            # unit/API specs
./bin/shonin & python3 script/smoke.py                    # 45 end-to-end checks incl. console link, backups, 192x192
```

## Limitations (deliberate for v0.1)

No payment gateway (cash on delivery only), no reviews, no password reset, no real email sending (`Mailer.deliver` in `src/shonin/security.cr` is the one place to plug SMTP in). Immagini decodes baseline JPEG and PNG only: progressive JPEGs are rejected with a clear error. Crystal runs on one thread here, so image resizing (a few ms) and bcrypt briefly occupy the event loop; the rate limiter, chat wake-up hub and caches live in process memory, so run one process per database or move those to a shared store before scaling out.
