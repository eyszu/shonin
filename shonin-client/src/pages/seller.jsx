import { createEffect, createSignal, For, Show } from "solid-js";
import { A, useNavigate, useParams } from "@solidjs/router";
import { createLoader } from "../lib/load.js";
import { api } from "../lib/api.js";
import app, { money, when } from "../lib/store.js";
import { prepareImage } from "../lib/image.js";
import { createPager } from "../lib/pager.js";
import { Empty, Gate, Header, Icon, Img, Sentinel, Sheet, Spinner, errText } from "../lib/ui.jsx";
import { STATUS_TAG } from "./orders.jsx";

// null when the user has no store yet.
const loadStore = () => api.get("/stores/me").catch((e) => { if (e.code === "no_store") return null; throw e; });

function CreateStore() {
  const [f, setF] = createSignal({ name: "", description: "" });
  const [err, setErr] = createSignal(null);
  const [busy, setBusy] = createSignal(false);
  async function submit(e) {
    e.preventDefault(); setBusy(true); setErr(null);
    try { await api.post("/stores", { name: f().name.trim(), description: f().description.trim() }); await app.loadMe(); location.reload(); }
    catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  }
  return (
    <form class="form" onSubmit={submit}>
      <div class="panel"><h2>Open your store</h2><p class="muted" style="margin:0">Pick a name shoppers will recognise. You can change it later.</p></div>
      <label class="field"><span>Store name</span><input required minlength="2" maxlength="60" value={f().name} onInput={(e) => setF({ ...f(), name: e.target.value })} /></label>
      <label class="field"><span>About your store</span><textarea maxlength="2000" value={f().description} onInput={(e) => setF({ ...f(), description: e.target.value })} /></label>
      <Show when={err()}><div class="err" role="alert">{err()}</div></Show>
      <button class="btn primary block" disabled={busy()}>Create store</button>
    </form>
  );
}

export function SellerHome() {
  const [store] = createLoader(() => (app.user() ? true : null), loadStore);
  const [stats] = createLoader(() => (store() ? true : null), () => api.get("/stores/me/stats"));
  const orders = () => stats()?.orders || {};
  return (
    <>
      <Header title="Seller center" />
      <div class="page">
        <Gate>
          <Show when={store.loading}><Spinner /></Show>
          <Show when={store.state === "ready" && store() === null}><CreateStore /></Show>
          <Show when={store()}>
            {(s) => (
              <>
                <div class="panel">
                  <div class="row"><Img class="thumb" src={s().logo} alt={s().name} /><div class="grow"><h2>{s().name}</h2><span class={`tag ${s().status === "open" ? "good" : "warn"}`}>{s().status}</span></div></div>
                </div>
                <Show when={stats()}>
                  <div class="stats">
                    <div class="stat"><b>{stats().products_active}</b><span class="muted">Active products</span></div>
                    <div class="stat"><b>{stats().units_in_stock}</b><span class="muted">Units in stock</span></div>
                    <div class="stat"><b>{orders().pending?.count || 0}</b><span class="muted">Orders to confirm</span></div>
                    <div class="stat"><b>{money(orders().completed?.total_cents || 0)}</b><span class="muted">Completed sales</span></div>
                  </div>
                </Show>
                <div class="list">
                  <A class="list-item" href="/seller/products"><Icon name="box" /><span class="grow">Products</span></A>
                  <A class="list-item" href="/seller/orders"><Icon name="cart" /><span class="grow">Orders</span></A>
                  <A class="list-item" href="/chats?as=seller"><Icon name="chat" /><span class="grow">Customer messages</span></A>
                  <A class="list-item" href="/seller/store"><Icon name="store" /><span class="grow">Store settings</span></A>
                  <A class="list-item" href={`/store/${s().id}`}><Icon name="search" /><span class="grow">View public page</span></A>
                </div>
              </>
            )}
          </Show>
        </Gate>
      </div>
    </>
  );
}

export function StoreEdit() {
  const [store, { refetch }] = createLoader(() => (app.user() ? true : null), loadStore);
  const [f, setF] = createSignal(null);
  const [busy, setBusy] = createSignal(false);
  createEffect(() => { if (store() && !f()) setF({ name: store().name, description: store().description, status: store().status }); });

  async function save(e) {
    e.preventDefault(); setBusy(true);
    try { await api.patch("/stores/me", { ...f(), name: f().name.trim() }); await refetch(); app.toast("Saved", "ok"); }
    catch (e) { app.toast(errText(e), "error"); } finally { setBusy(false); }
  }
  async function logo(e) {
    const file = e.target.files[0]; e.target.value = "";
    if (!file) return;
    setBusy(true);
    try { await api.upload("PUT", "/stores/me/logo", await prepareImage(file)); await refetch(); app.toast("Logo updated", "ok"); }
    catch (e) { app.toast(errText(e), "error"); } finally { setBusy(false); }
  }
  async function removeLogo() {
    try { await api.del("/stores/me/logo"); await refetch(); } catch (e) { app.toast(errText(e), "error"); }
  }
  return (
    <>
      <Header title="Store settings" />
      <div class="page">
        <Gate>
          <Show when={store() && f()}>
            <div class="panel row">
              <Img class="thumb" src={store().logo} alt={store().name} />
              <label class="btn small">Change logo<input type="file" accept="image/*" hidden onChange={logo} /></label>
              <Show when={store().logo}><button class="btn small" onClick={removeLogo}>Remove</button></Show>
            </div>
            <form class="form" onSubmit={save}>
              <label class="field"><span>Store name</span><input required minlength="2" maxlength="60" value={f().name} onInput={(e) => setF({ ...f(), name: e.target.value })} /></label>
              <label class="field"><span>About</span><textarea maxlength="2000" value={f().description} onInput={(e) => setF({ ...f(), description: e.target.value })} /></label>
              <label class="field"><span>Status</span>
                <select value={f().status} onChange={(e) => setF({ ...f(), status: e.target.value })}>
                  <option value="open">Open: visible to shoppers</option>
                  <option value="closed">Closed: hidden, no new orders</option>
                </select>
              </label>
              <button class="btn primary block" disabled={busy()}>Save changes</button>
            </form>
          </Show>
          <Show when={store.state === "ready" && store() === null}><Empty title="No store yet"><A class="btn primary" href="/seller">Create one</A></Empty></Show>
        </Gate>
      </div>
    </>
  );
}

export function SellerProducts() {
  const nav = useNavigate();
  const pager = createPager(() => "/stores/me/products?limit=30");
  const [adding, setAdding] = createSignal(false);
  const [cats] = createLoader(() => api.get("/categories").catch(() => []));
  const [f, setF] = createSignal({ name: "", price: "", stock: "1", category_id: "", description: "" });
  const [busy, setBusy] = createSignal(false);
  createEffect(() => { if (app.user()) pager.reset(); });

  async function create(e) {
    e.preventDefault(); setBusy(true);
    try {
      const v = f();
      const r = await api.post("/stores/me/products", {
        name: v.name.trim(), description: v.description.trim(),
        price_cents: Math.round(parseFloat(v.price) * 100), stock: parseInt(v.stock, 10),
        ...(v.category_id ? { category_id: Number(v.category_id) } : {}),
      });
      nav(`/seller/products/${r.id}`);
    } catch (e) { app.toast(e.status === 404 ? "Create your store first" : errText(e), "error"); } finally { setBusy(false); }
  }
  return (
    <>
      <Header title="My products"><button class="icon-btn" onClick={() => setAdding(true)} aria-label="Add product"><Icon name="plus" /></button></Header>
      <div class="page">
        <Gate>
          <div class="list">
            <For each={pager.items()}>
              {(p) => (
                <A class="list-item" href={`/seller/products/${p.id}`}>
                  <Img class="thumb" src={p.cover} alt={p.name} />
                  <div class="grow"><div class="ellipsis">{p.name}</div><div class="price">{money(p.price_cents)}</div><div class="muted">Stock {p.stock} · {p.sold} sold</div></div>
                  <Show when={p.status === "hidden"}><span class="tag warn">Hidden</span></Show>
                </A>
              )}
            </For>
          </div>
          <Show when={pager.loading()}><Spinner /></Show>
          <Show when={pager.done() && !pager.items().length}>
            <Empty title="No products yet"><button class="btn primary" onClick={() => setAdding(true)}>Add your first product</button></Empty>
          </Show>
          <Show when={!pager.done()}><Sentinel onVisible={pager.more} /></Show>
          <Show when={adding()}>
            <Sheet title="New product" onClose={() => setAdding(false)}>
              <form class="form" onSubmit={create}>
                <label class="field"><span>Name</span><input required minlength="2" maxlength="150" value={f().name} onInput={(e) => setF({ ...f(), name: e.target.value })} /></label>
                <div class="row">
                  <label class="field grow"><span>Price</span><input required type="number" min="0" step="0.01" inputmode="decimal" value={f().price} onInput={(e) => setF({ ...f(), price: e.target.value })} /></label>
                  <label class="field grow"><span>Stock</span><input required type="number" min="0" step="1" inputmode="numeric" value={f().stock} onInput={(e) => setF({ ...f(), stock: e.target.value })} /></label>
                </div>
                <label class="field"><span>Category</span>
                  <select value={f().category_id} onChange={(e) => setF({ ...f(), category_id: e.target.value })}>
                    <option value="">None</option><For each={cats()}>{(c) => <option value={c.id}>{c.name}</option>}</For>
                  </select>
                </label>
                <label class="field"><span>Description</span><textarea maxlength="5000" value={f().description} onInput={(e) => setF({ ...f(), description: e.target.value })} /></label>
                <button class="btn primary block" disabled={busy()}>Create and add photos</button>
              </form>
            </Sheet>
          </Show>
        </Gate>
      </div>
    </>
  );
}

export function ProductEdit() {
  const params = useParams();
  const nav = useNavigate();
  const [p, { refetch }] = createLoader(() => (app.user() ? params.id : null), (id) => api.get(`/stores/me/products/${id}`));
  const [cats] = createLoader(() => api.get("/categories").catch(() => []));
  const [f, setF] = createSignal(null);
  const [busy, setBusy] = createSignal(false);
  createEffect(() => {
    const x = p();
    if (x && !f()) setF({ name: x.name, description: x.description, price: (x.price_cents / 100).toFixed(2), stock: String(x.stock), status: x.status, category_id: x.category_id ? String(x.category_id) : "" });
  });
  const set = (k) => (e) => setF({ ...f(), [k]: e.target.value });

  async function save(e) {
    e.preventDefault(); setBusy(true);
    try {
      const v = f();
      await api.patch(`/stores/me/products/${params.id}`, {
        name: v.name.trim(), description: v.description.trim(), price_cents: Math.round(parseFloat(v.price) * 100),
        stock: parseInt(v.stock, 10), status: v.status, category_id: v.category_id ? Number(v.category_id) : null,
      });
      app.toast("Saved", "ok");
    } catch (e) { app.toast(errText(e), "error"); } finally { setBusy(false); }
  }
  async function addImages(e) {
    const files = [...e.target.files]; e.target.value = "";
    setBusy(true);
    try {
      for (const file of files) await api.upload("POST", `/stores/me/products/${params.id}/images`, await prepareImage(file));
      await refetch();
    } catch (e) { app.toast(errText(e), "error"); await refetch(); } finally { setBusy(false); }
  }
  async function removeImage(id) {
    try { await api.del(`/stores/me/products/${params.id}/images/${id}`); await refetch(); } catch (e) { app.toast(errText(e), "error"); }
  }
  async function remove() {
    if (!confirm("Delete this product permanently? Past orders keep their details.")) return;
    try { await api.del(`/stores/me/products/${params.id}`); nav("/seller/products", { replace: true }); } catch (e) { app.toast(errText(e), "error"); }
  }

  return (
    <>
      <Header title="Edit product" />
      <div class="page">
        <Gate>
          <Show when={p.error}><Empty title="Product not found" /></Show>
          <Show when={p() && f()}>
            <div class="panel">
              <b>Photos <span class="muted">({p().images.length}/5, saved as 192×192)</span></b>
              <div class="thumbs">
                <For each={p().images}>{(im) => <div class="img"><img src={im.url} alt="" /><button class="x" onClick={() => removeImage(im.id)} aria-label="Remove photo"><Icon name="x" size={14} /></button></div>}</For>
                <Show when={p().images.length < 5}>
                  <label class="upload" aria-label="Add photos"><Icon name="camera" /><input type="file" accept="image/*" multiple onChange={addImages} /></label>
                </Show>
              </div>
            </div>
            <form class="form" onSubmit={save}>
              <label class="field"><span>Name</span><input required minlength="2" maxlength="150" value={f().name} onInput={set("name")} /></label>
              <div class="row">
                <label class="field grow"><span>Price</span><input required type="number" min="0" step="0.01" inputmode="decimal" value={f().price} onInput={set("price")} /></label>
                <label class="field grow"><span>Stock</span><input required type="number" min="0" step="1" inputmode="numeric" value={f().stock} onInput={set("stock")} /></label>
              </div>
              <label class="field"><span>Category</span>
                <select value={f().category_id} onChange={set("category_id")}>
                  <option value="">None</option><For each={cats()}>{(c) => <option value={c.id} selected={String(c.id) === f().category_id}>{c.name}</option>}</For>
                </select>
              </label>
              <label class="field"><span>Visibility</span>
                <select value={f().status} onChange={set("status")}><option value="active">Active: listed</option><option value="hidden">Hidden</option></select>
              </label>
              <label class="field"><span>Description</span><textarea maxlength="5000" value={f().description} onInput={set("description")} /></label>
              <button class="btn primary block" disabled={busy()}>Save changes</button>
              <button type="button" class="btn danger block" onClick={remove}>Delete product</button>
            </form>
          </Show>
        </Gate>
      </div>
    </>
  );
}

function SellerOrderRow(props) {
  const [open, setOpen] = createSignal(false);
  const [detail, setDetail] = createSignal(null);
  const [busy, setBusy] = createSignal(false);
  const [msg, setMsg] = createSignal(null);
  const nav = useNavigate();
  const o = () => props.order;

  async function toggle() {
    setOpen(!open());
    if (open() && !detail()) try { setDetail(await api.get(`/stores/me/orders/${o().id}`)); } catch (e) { app.toast(errText(e), "error"); }
  }
  async function act(action) {
    let reason;
    if (action === "cancel") { reason = prompt("Reason for cancelling (shown to the buyer)?", "Out of stock"); if (reason === null) return; }
    setBusy(true);
    try { await api.post(`/stores/me/orders/${o().id}/${action}`, action === "cancel" ? { reason } : undefined); props.onChange(); setDetail(null); setOpen(false); }
    catch (e) { app.toast(errText(e), "error"); } finally { setBusy(false); }
  }
  async function message(e) {
    e.preventDefault(); setBusy(true);
    try { const r = await api.post("/stores/me/conversations", { customer_id: o().buyer_id, message: msg().trim() }); nav(`/chats/${r.conversation_id}?as=seller`); }
    catch (e) { app.toast(errText(e), "error"); } finally { setBusy(false); }
  }
  return (
    <div>
      <button class="list-item" style="width:100%;border:0;background:none;text-align:left;cursor:pointer" onClick={toggle}>
        <div class="grow"><b>#{o().id} · {o().ship_name}</b><div class="muted">{when(o().created_at)} ago</div></div>
        <div style="text-align:right"><div class="price">{money(o().total_cents)}</div><span class={`tag ${STATUS_TAG[o().status]}`}>{o().status}</span></div>
      </button>
      <Show when={open()}>
        <div class="panel" style="border:0;border-radius:0;background:var(--bg)">
          <Show when={detail()} fallback={<Spinner />}>
            <For each={detail().items}>{(i) => <div class="row between"><span class="ellipsis">{i.qty} × {i.name}</span><b>{money(i.price_cents * i.qty)}</b></div>}</For>
            <div class="muted">Ship to</div>
            <div>{o().ship_name} · {o().ship_phone}<br />{o().ship_address}</div>
            <Show when={o().note}><div class="muted">Note: {o().note}</div></Show>
          </Show>
          <div class="row wrap">
            <Show when={o().status === "pending"}><button class="btn primary small" disabled={busy()} onClick={() => act("confirm")}>Confirm</button></Show>
            <Show when={o().status === "confirmed"}><button class="btn primary small" disabled={busy()} onClick={() => act("ship")}>Mark shipped</button></Show>
            <Show when={o().status === "pending" || o().status === "confirmed"}><button class="btn danger small" disabled={busy()} onClick={() => act("cancel")}>Cancel</button></Show>
            <button class="btn small" onClick={() => setMsg("")}><Icon name="chat" size={16} /> Message buyer</button>
          </div>
        </div>
      </Show>
      <Show when={msg() !== null}>
        <Sheet title="Message buyer" onClose={() => setMsg(null)}>
          <form class="form" onSubmit={message}>
            <label class="field"><span>Message</span><textarea required maxlength="2000" value={msg()} onInput={(e) => setMsg(e.target.value)} /></label>
            <button class="btn primary block" disabled={busy() || !msg().trim()}>Send</button>
          </form>
        </Sheet>
      </Show>
    </div>
  );
}

export function SellerOrders() {
  const [status, setStatus] = createSignal("pending");
  const pager = createPager(() => `/stores/me/orders?limit=20${status() ? `&status=${status()}` : ""}`);
  createEffect(() => { if (app.user()) { status(); pager.reset(); } });
  return (
    <>
      <Header title="Store orders" />
      <div class="page">
        <Gate>
          <div class="chips">
            <For each={["pending", "confirmed", "shipped", "completed", "cancelled", ""]}>
              {(s) => <button class={`chip ${status() === s ? "on" : ""}`} onClick={() => setStatus(s)}>{s || "All"}</button>}
            </For>
          </div>
          <div class="list"><For each={pager.items()}>{(o) => <SellerOrderRow order={o} onChange={pager.reset} />}</For></div>
          <Show when={pager.loading()}><Spinner /></Show>
          <Show when={pager.done() && !pager.items().length}><Empty title="No orders here" /></Show>
          <Show when={!pager.done()}><Sentinel onVisible={pager.more} /></Show>
        </Gate>
      </div>
    </>
  );
}
