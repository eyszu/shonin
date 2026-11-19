# Shonin client

Mobile-first PWA for the [Shonin](../shonin) marketplace API. **SolidJS + Vite, plain JavaScript (no TypeScript).**
Production bundle: about 27 KB gzipped for the shell; seller and admin screens load on demand.

## Run

```sh
npm install
cp .env.example .env.local        # optional: API address, currency
npm run dev                       # http://localhost:5173 (also on your LAN, for phone testing)
```

Start the API in another terminal. Because the client proxies `/api` and `/images` to it, the browser sees one origin (no CORS setup). To make the verification link printed in the server console open the *client*, start the API with its base URL pointing here:

```sh
SHONIN_BASE_URL=http://localhost:5173 ./bin/shonin     # dev
SHONIN_BASE_URL=http://localhost:4173 ./bin/shonin     # npm run preview
```

Build and serve the PWA:

```sh
npm run build && npm run preview     # http://localhost:4173
```

In production, serve `dist/` from any static host or reverse proxy and route `/api/*` and `/images/*` to the Shonin server (same origin). PWA install and the service worker need HTTPS (or localhost).

## What is in it

| Area | Screens |
|---|---|
| Shop | home with search, category chips, sorting, infinite scroll; product page with swipe gallery; store page |
| Buying | cart, checkout (address remembered on the device), orders, cancel, "I received it" |
| Account | register, sign in, resend verification, sign out (this device or all), install button |
| Chat | inbox (buying and selling tabs, unread badges), thread with real-time delivery by long-poll |
| Seller | store creation and settings (open/closed, logo), stats, products CRUD with up to 5 photos, order handling, message a buyer |
| Admin | users with search and state filter, suspend / ban / lift with reasons and history, categories, **database backup** and **images ZIP** downloads |

Photos are re-encoded in the browser to a baseline JPEG (max 1600 px, EXIF rotation applied) before upload. That keeps phone photos small and avoids formats the server cannot read (WebP, HEIC, progressive JPEG); the server then makes the final 192×192 image.

## PWA

- Web app manifest (standalone, portrait, original icon set including a maskable icon), `viewport-fit=cover` with safe-area insets for notched phones.
- Workbox service worker (auto-updating): app shell precached; product photos cache-first; catalogue/category/store reads network-first with a cached fallback, so browsing keeps working offline. An offline banner is shown. Account, cart, orders and chat always need the network.
- Light and dark themes follow the system setting.

## Layout

```
src/lib/api.js     fetch wrapper, bearer token, errors, file download
src/lib/store.js   session, cart count, toasts, online state, install prompt
src/lib/load.js    small Suspense-free data loader
src/lib/pager.js   cursor pagination for the API lists
src/lib/ui.jsx     icons, bottom nav, sheet, header, auth gate
src/pages/*.jsx    screens (shop, auth, orders, chat, seller, admin)
```

## Notes

- Prices are formatted with `VITE_CURRENCY` (default `PHP`); the API stores integer cents.
- Sessions are opaque bearer tokens kept in `localStorage`. A ban or suspension takes effect on the next request; the client shows the suspension banner and disables writes.
- Chat uses long-polling (`?after=<id>&wait=20`), the same endpoint works from any HTTP client.

## End-to-end test

`e2e/run.cjs` drives the real UI in a phone-sized Chromium (register, verify via the console link, create store and product with photos, buy, chat in real time, suspend a user as admin, download both backups, offline mode). It needs Playwright (`npm i -D playwright`), the API on :3000 started with `SHONIN_BASE_URL=http://localhost:4173`, a fresh database with admin `admin@shonin.test` / `adminpass123`, the API log at `/tmp/shonin.log`, and `npm run preview` running.
