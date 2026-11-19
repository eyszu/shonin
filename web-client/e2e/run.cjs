const { chromium } = require("playwright");
const fs = require("fs");
const BASE = "http://localhost:4173";
const tag = Math.random().toString(36).slice(2, 7);
let fails = 0;
const ok = (n, c, x = "") => { console.log((c ? "PASS " : "FAIL ") + n + (c ? "" : "  " + x)); if (!c) fails++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const lastLink = () => { const m = [...fs.readFileSync("/tmp/shonin.log", "utf8").matchAll(/(http\S+\/auth\/verify\?token=\S+)/g)]; return m.at(-1)[1]; };

(async () => {
  const browser = await chromium.launch();
  const mk = async () => {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2, serviceWorkers: "allow" });
    const page = await ctx.newPage();
    page.on("pageerror", (e) => { console.log("PAGEERROR", e.message); fails++; });
    page.on("dialog", (d) => d.accept("Out of stock"));
    return { ctx, page };
  };

  // category through the API as admin
  const adminTok = (await (await fetch(BASE + "/api/v1/auth/login", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "admin@shonin.test", password: "adminpass123" }) })).json()).token;
  await fetch(BASE + "/api/v1/admin/categories", { method: "POST", headers: { "content-type": "application/json", authorization: "Bearer " + adminTok }, body: JSON.stringify({ name: "Gadgets" }) });

  async function signup(page, email, pw) {
    await page.goto(BASE + "/register");
    await page.fill('input[type=email]', email); await page.fill('input[type=password]', pw);
    await page.click("button:has-text('Create account')");
    await page.waitForSelector("text=Check your email");
    await sleep(300);
    const v = await page.context().newPage(); await v.goto(lastLink());
    const okv = await v.locator("text=Email verified").count(); await v.close();
    await page.click("text=Go to sign in");
    await page.fill('input[type=email]', email); await page.fill('input[type=password]', pw);
    await page.click("button:has-text('Sign in')");
    await page.waitForSelector(".bottomnav");
    return okv;
  }

  // ---------- seller
  const S = await mk(); const sp = S.page; global.SP = sp; sp.on("response", (r) => r.url().includes("/api/") && r.status() >= 400 && console.log("HTTP", r.status(), r.url()));
  ok("seller verified via emailed link in browser", await signup(sp, `seller${tag}@t.test`, "password123") === 1);
  await sp.goto(BASE + "/seller");
  await sp.fill("input[minlength='2']", `Tech Hut ${tag}`);
  await sp.click("button:has-text('Create store')");
  await sp.waitForSelector("text=Active products");
  ok("store created, seller center shown", true);
  await sp.goto(BASE + "/seller/products");
  await sp.click("button:has-text('Add your first product')");
  await sp.fill("input[minlength='2']", "Mechanical Keyboard");
  await sp.fill("input[type=number][step='0.01']", "1299.50");
  await sp.fill("input[type=number][step='1']", "10");
  await sp.selectOption("select", { label: "Gadgets" });
  await sp.fill("textarea", "Clicky blue switches.");
  await sp.click("button:has-text('Create and add photos')");
  await sp.waitForSelector("text=/Photos \\(/");
  await sp.setInputFiles("input[type=file]", ["e2e/photo1.jpg", "e2e/photo2.jpg"]);
  await sp.waitForFunction(() => { const i = [...document.querySelectorAll(".thumbs img")]; return i.length === 2 && i.every((x) => x.complete && x.naturalWidth > 0); }, null, { timeout: 15000 });
  ok("two photos uploaded (browser re-encodes, server resizes to 192x192)", true);
  const dims = await sp.evaluate(() => [...document.querySelectorAll(".thumbs img")].map((i) => [i.naturalWidth, i.naturalHeight]));
  ok("stored images are 192x192", dims.every(([w, h]) => w === 192 && h === 192), JSON.stringify(dims));
  await sp.screenshot({ path: "/tmp/shot_product_edit.png" });

  // ---------- buyer
  const B = await mk(); const bp = B.page;
  await bp.goto(BASE + "/");
  await bp.waitForSelector(".product");
  ok("home lists the product", (await bp.locator(".product").count()) === 1);
  await bp.screenshot({ path: "/tmp/shot_home.png" });
  await bp.fill("input[type=search]", "keyb"); await bp.press("input[type=search]", "Enter");
  await bp.waitForSelector(".product");
  ok("prefix search works", (await bp.locator(".product").count()) === 1);
  await bp.click(".product");
  await bp.waitForSelector(".pdp-price");
  await bp.click("button:has-text('Add to cart')");
  await bp.waitForURL(/\/login/);
  ok("adding to cart while signed out redirects to login", true);
  await bp.goto(BASE + "/register"); // sign up in same context
  const bemail = `buyer${tag}@t.test`;
  await bp.fill('input[type=email]', bemail); await bp.fill('input[type=password]', "password123");
  await bp.click("button:has-text('Create account')"); await bp.waitForSelector("text=Check your email"); await sleep(300);
  const v = await B.ctx.newPage(); await v.goto(lastLink()); await v.close();
  await bp.goto(BASE + "/login"); await bp.fill('input[type=email]', bemail); await bp.fill('input[type=password]', "password123");
  await bp.click("button:has-text('Sign in')"); await bp.waitForSelector(".bottomnav");
  await bp.goto(BASE + "/"); await bp.click(".product"); await bp.waitForSelector(".pdp-price");
  await bp.screenshot({ path: "/tmp/shot_pdp.png" });
  await bp.click("button:has-text('Add to cart')");
  await bp.waitForSelector(".badge");
  ok("cart badge updates", (await bp.locator(".topbar .badge").first().innerText()) === "1");
  await bp.goto(BASE + "/cart"); await bp.waitForSelector("text=Checkout");
  await bp.screenshot({ path: "/tmp/shot_cart.png" });
  await bp.click("a:has-text('Checkout')");
  await bp.fill("input[autocomplete=name]", "Juan Dela Cruz"); await bp.fill("input[type=tel]", "09171234567"); await bp.fill("textarea", "123 Rizal St, Manila");
  await bp.click("button:has-text('Place order')");
  await bp.waitForURL(/\/orders$/); await bp.waitForSelector("text=pending");
  ok("order placed (cash on delivery)", true);

  // ---------- seller handles the order
  await sp.goto(BASE + "/seller/orders"); await sp.waitForSelector("text=Juan Dela Cruz");
  await sp.click("text=Juan Dela Cruz"); await sp.click("button.btn.primary:has-text('Confirm')");
  await sp.waitForSelector("text=No orders here");
  await sp.click(".chip:has-text('confirmed')");
  await sp.waitForSelector("text=Juan Dela Cruz");
  ok("seller confirmed the order", true);

  // ---------- chat: buyer writes, seller answers, buyer receives via long poll
  await bp.goto(BASE + "/"); await bp.click(".product"); await bp.waitForSelector(".pdp-price");
  await bp.click("button[aria-label='Chat with seller']");
  await bp.fill(".sheet textarea", "Is it hot-swappable?"); await bp.click(".sheet button:has-text('Send')");
  await bp.waitForSelector(".bubble.mine");
  await sp.goto(BASE + "/chats?as=seller"); await sp.waitForSelector("text=Is it hot-swappable?");
  ok("seller inbox shows message with masked buyer", (await sp.locator(".list-item").first().innerText()).includes("***"));
  await sp.click(".list-item"); await sp.waitForSelector(".bubble");
  await sp.fill(".composer input", "Yes, it is!"); await sp.click(".composer button");
  await bp.waitForSelector("text=Yes, it is!", { timeout: 8000 });
  ok("buyer receives seller reply in real time (long-poll)", true);
  await bp.screenshot({ path: "/tmp/shot_chat.png" });

  // ---------- admin
  const A = await mk(); const ap = A.page;
  await ap.goto(BASE + "/login"); await ap.fill('input[type=email]', "admin@shonin.test"); await ap.fill('input[type=password]', "adminpass123");
  await ap.click("button:has-text('Sign in')"); await ap.waitForSelector(".bottomnav");
  await ap.goto(BASE + "/admin"); await ap.waitForSelector(`text=${bemail}`);
  await ap.click(`text=${bemail}`);
  await ap.fill(".sheet input[maxlength='500']", "spamming links");
  await ap.click(".sheet button:has-text('Suspend')");
  await ap.waitForSelector(".sheet .tag.warn:has-text('suspended')");
  ok("admin suspends buyer from the UI", true);
  await bp.goto(BASE + "/account"); await bp.waitForSelector(".banner.warn");
  ok("buyer sees suspension banner", (await bp.locator(".banner.warn").innerText()).includes("spamming links"));
  await bp.goto(BASE + "/chats"); // reading still allowed
  await ap.screenshot({ path: "/tmp/shot_admin.png" });

  // backups through the UI
  await ap.click("button[aria-label='Close']"); await ap.click(".tabs button:has-text('Backups')");
  const [d1] = await Promise.all([ap.waitForEvent("download"), ap.click("button:has-text('Download database')")]);
  const [d2] = await Promise.all([ap.waitForEvent("download"), ap.click("button:has-text('Download images ZIP')")]);
  ok("DB backup downloads from admin UI", /\.sql\.gz$/.test(d1.suggestedFilename()), d1.suggestedFilename());
  ok("images ZIP downloads from admin UI", /\.zip$/.test(d2.suggestedFilename()), d2.suggestedFilename());

  // ---------- PWA
  const man = await (await fetch(BASE + "/manifest.webmanifest")).json();
  ok("manifest valid (standalone, icons incl. maskable)", man.display === "standalone" && man.icons.some((i) => i.purpose === "maskable") && man.icons.length >= 3);
  await bp.goto(BASE + "/"); await bp.waitForSelector(".product");
  const sw = await bp.evaluate(async () => { const r = await navigator.serviceWorker.ready; return !!r.active; });
  ok("service worker active", sw);
  await sleep(1500);
  await B.ctx.setOffline(true);
  await bp.reload(); await bp.waitForSelector(".banner.offline, .product", { timeout: 8000 });
  ok("app shell loads offline", (await bp.locator(".shell").count()) === 1);
  ok("offline banner shown", (await bp.locator(".banner.offline").count()) === 1);
  await bp.screenshot({ path: "/tmp/shot_offline.png" });
  await B.ctx.setOffline(false);

  await browser.close();
  console.log(fails ? `${fails} FAILED` : "ALL PASSED");
  process.exit(fails ? 1 : 0);
})().catch(async (e) => { (global.SP && await global.SP.screenshot({ path: "/tmp/crash.png" }).catch(() => {})); console.error("E2E CRASH", e.message.split("\n").slice(0, 6).join("\n")); process.exit(2); });
