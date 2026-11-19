import { createEffect, createSignal, For, on, Show } from "solid-js";
import { A, useNavigate, useParams, useSearchParams } from "@solidjs/router";
import { createLoader } from "../lib/load.js";
import { api } from "../lib/api.js";
import app, { money } from "../lib/store.js";
import { createPager } from "../lib/pager.js";
import { Empty, Header, Icon, Img, ProductCard, Sentinel, Sheet, Spinner, errText } from "../lib/ui.jsx";

const SORTS = [["new", "Latest"], ["popular", "Top sales"], ["price_asc", "Price: low"], ["price_desc", "Price: high"]];

function Grid(props) {
  const pager = createPager(props.source);
  createEffect(on(props.source, () => pager.reset()));
  return (
    <>
      <div class="grid">
        <For each={pager.items()}>{(it) => <ProductCard item={it} />}</For>
      </div>
      <Show when={pager.loading()}><Spinner /></Show>
      <Show when={pager.error()}><p class="err">{pager.error()}</p></Show>
      <Show when={!pager.loading() && pager.done() && pager.items().length === 0 && !pager.error()}>
        <Empty title="Nothing here yet">{props.empty || "Try a different search."}</Empty>
      </Show>
      <Show when={!pager.done()}><Sentinel onVisible={pager.more} /></Show>
    </>
  );
}

export function Home() {
  const [sp, setSp] = useSearchParams();
  const [cats] = createLoader(() => api.get("/categories").catch(() => []));
  const [text, setText] = createSignal(sp.q || "");
  const source = () => {
    const p = new URLSearchParams({ limit: "20" });
    if (sp.q) p.set("q", sp.q);
    if (sp.cat) p.set("category_id", sp.cat);
    if (sp.sort) p.set("sort", sp.sort);
    return `/products?${p}`;
  };
  return (
    <>
      <div class="searchbar">
        <form onSubmit={(e) => { e.preventDefault(); setSp({ q: text().trim() || undefined }); }} role="search">
          <Icon name="search" size={18} />
          <input type="search" placeholder="Search Shonin" value={text()} onInput={(e) => setText(e.target.value)} enterkeyhint="search" />
        </form>
      </div>
      <div class="page">
        <div class="chips">
          <button class={`chip ${!sp.cat ? "on" : ""}`} onClick={() => setSp({ cat: undefined })}>All</button>
          <For each={cats()}>{(c) => <button class={`chip ${sp.cat === String(c.id) ? "on" : ""}`} onClick={() => setSp({ cat: c.id })}>{c.name}</button>}</For>
        </div>
        <div class="chips">
          <For each={SORTS}>{([k, label]) => <button class={`chip ${(sp.sort || "new") === k ? "on" : ""}`} onClick={() => setSp({ sort: k === "new" ? undefined : k })}>{label}</button>}</For>
        </div>
        <Grid source={source} />
      </div>
    </>
  );
}

export function StorePage() {
  const params = useParams();
  const [store] = createLoader(() => params.id, (id) => api.get(`/stores/${id}`));
  return (
    <>
      <Header title={store()?.name || "Store"} />
      <div class="page">
        <Show when={store.error}><Empty title="Store not found" /></Show>
        <Show when={store()}>
          {(s) => (
            <div class="panel">
              <div class="row">
                <Img class="thumb" src={s().logo} alt={s().name} />
                <div class="grow">
                  <h2>{s().name}</h2>
                  <div class="muted">{s().product_count} products</div>
                </div>
              </div>
              <Show when={s().description}><p style="margin:0;white-space:pre-wrap">{s().description}</p></Show>
              <Show when={s().status === "closed"}><span class="tag warn">Temporarily closed</span></Show>
            </div>
          )}
        </Show>
        <Grid source={() => `/products?store_id=${params.id}&limit=20`} empty="This store has no products." />
      </div>
    </>
  );
}

export function Product() {
  const params = useParams();
  const nav = useNavigate();
  const [p] = createLoader(() => params.id, (id) => api.get(`/products/${id}`));
  const [qty, setQty] = createSignal(1);
  const [busy, setBusy] = createSignal(false);
  const [slide, setSlide] = createSignal(0);
  const [chat, setChat] = createSignal(false);
  const [msg, setMsg] = createSignal("");

  const needLogin = () => {
    if (app.user()) return false;
    nav(`/login?next=${encodeURIComponent(location.pathname)}`);
    return true;
  };

  async function addToCart(thenGo) {
    if (needLogin()) return;
    setBusy(true);
    try {
      const cart = await api.get("/cart");
      const have = cart.items.find((i) => i.product_id === p().id)?.qty || 0;
      await api.put("/cart/items", { product_id: p().id, qty: Math.min(99, have + qty()) });
      await app.refreshCart();
      if (thenGo) nav("/cart"); else app.toast("Added to cart", "ok");
    } catch (e) {
      app.toast(e.code === "own_product" ? "You can't buy from your own store" : errText(e), "error");
    } finally { setBusy(false); }
  }

  async function startChat(e) {
    e.preventDefault();
    setBusy(true);
    try {
      const r = await api.post("/conversations", { store_id: p().store_id, message: msg().trim() });
      nav(`/chats/${r.conversation_id}`);
    } catch (e) {
      app.toast(e.code === "own_store" ? "This is your own store" : errText(e), "error");
    } finally { setBusy(false); }
  }

  return (
    <>
      <Header title="Product">
        <A class="icon-btn" href="/cart" aria-label="Cart"><Icon name="cart" /><Show when={app.cartCount() > 0}><b class="badge" style="background:#fff;color:var(--brand)">{app.cartCount()}</b></Show></A>
      </Header>
      <Show when={p.loading}><Spinner /></Show>
      <Show when={p.error}><Empty title="Product not available">It may have been removed or hidden.</Empty></Show>
      <Show when={p()}>
        {(it) => (
          <div class="page" style="padding-bottom:90px">
            <div class="gallery" onScroll={(e) => setSlide(Math.round(e.target.scrollLeft / e.target.clientWidth))}>
              <For each={it().images} fallback={<Img src={null} alt={it().name} />}>{(im) => <Img src={im.url} alt={it().name} />}</For>
            </div>
            <Show when={it().images.length > 1}>
              <div class="dots"><For each={it().images}>{(_, i) => <i class={`dot ${slide() === i() ? "on" : ""}`} />}</For></div>
            </Show>
            <div class="pdp-price">{money(it().price_cents)}</div>
            <h2>{it().name}</h2>
            <div class="row wrap muted">
              <span>{it().sold} sold</span><span>·</span>
              <span>{it().stock > 0 ? `${it().stock} in stock` : "Sold out"}</span>
            </div>
            <A class="list-item panel" href={`/store/${it().store_id}`}>
              <Icon name="store" /><span class="grow"><b>{it().store_name}</b><br /><span class="muted">Visit store</span></span>
            </A>
            <Show when={it().description}>
              <div class="panel"><h3>Description</h3><p style="margin:0;white-space:pre-wrap">{it().description}</p></div>
            </Show>
            <Show when={it().stock > 0}>
              <div class="row between">
                <span>Quantity</span>
                <div class="qty">
                  <button onClick={() => setQty((q) => Math.max(1, q - 1))} aria-label="Less"><Icon name="minus" size={16} /></button>
                  <span>{qty()}</span>
                  <button onClick={() => setQty((q) => Math.min(it().stock, 99, q + 1))} aria-label="More"><Icon name="plus" size={16} /></button>
                </div>
              </div>
            </Show>
            <div class="actionbar">
              <button class="btn" onClick={() => !needLogin() && setChat(true)} aria-label="Chat with seller"><Icon name="chat" size={20} /></button>
              <button class="btn" disabled={busy() || it().stock === 0} onClick={() => addToCart(false)}>Add to cart</button>
              <button class="btn primary" disabled={busy() || it().stock === 0} onClick={() => addToCart(true)}>Buy now</button>
            </div>
            <Show when={chat()}>
              <Sheet title={`Message ${it().store_name}`} onClose={() => setChat(false)}>
                <form class="form" onSubmit={startChat}>
                  <label class="field"><span>Your message</span>
                    <textarea required maxlength="2000" value={msg()} onInput={(e) => setMsg(e.target.value)} placeholder="Is this still available?" />
                  </label>
                  <button class="btn primary block" disabled={busy() || !msg().trim()}>Send</button>
                </form>
              </Sheet>
            </Show>
          </div>
        )}
      </Show>
    </>
  );
}
