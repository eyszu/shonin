import { createSignal, For, Show } from "solid-js";
import { A, useNavigate, useParams } from "@solidjs/router";
import { createLoader } from "../lib/load.js";
import { api } from "../lib/api.js";
import app, { money, when } from "../lib/store.js";
import { createPager } from "../lib/pager.js";
import { Empty, Gate, Header, Icon, Img, Sentinel, Spinner, errText } from "../lib/ui.jsx";

export const STATUS_TAG = { pending: "warn", confirmed: "", shipped: "", completed: "good", cancelled: "bad" };

export function CartPage() {
  const [cart, { refetch, mutate }] = createLoader(() => (app.user() ? true : null), () => api.get("/cart"));
  const [busy, setBusy] = createSignal(false);

  async function setQty(item, qty) {
    setBusy(true);
    try {
      if (qty < 1) await api.del(`/cart/items/${item.product_id}`);
      else await api.put("/cart/items", { product_id: item.product_id, qty: Math.min(99, qty) });
      await refetch(); app.refreshCart();
    } catch (e) { app.toast(errText(e), "error"); } finally { setBusy(false); }
  }
  const ok = () => cart()?.items.filter((i) => i.available) || [];
  const total = () => cart()?.total_cents || 0;

  return (
    <>
      <Header title="Cart" />
      <div class="page" style="padding-bottom:90px">
        <Gate>
          <Show when={cart.loading && !cart()}><Spinner /></Show>
          <Show when={cart()}>
            <Show when={cart().items.length > 0} fallback={<Empty title="Your cart is empty"><A class="btn primary" href="/">Start shopping</A></Empty>}>
              <div class="list">
                <For each={cart().items}>
                  {(i) => (
                    <div class="list-item" style="align-items:flex-start">
                      <div class="grow">
                        <A href={`/p/${i.product_id}`} class="ellipsis" style="display:block;font-weight:600">{i.name}</A>
                        <div class="price">{money(i.price_cents)}</div>
                        <Show when={!i.available}><span class="tag bad">Unavailable or not enough stock</span></Show>
                      </div>
                      <div class="qty">
                        <button disabled={busy()} onClick={() => setQty(i, i.qty - 1)} aria-label="Less"><Icon name={i.qty === 1 ? "trash" : "minus"} size={16} /></button>
                        <span>{i.qty}</span>
                        <button disabled={busy()} onClick={() => setQty(i, i.qty + 1)} aria-label="More"><Icon name="plus" size={16} /></button>
                      </div>
                    </div>
                  )}
                </For>
              </div>
              <div class="actionbar">
                <div class="grow"><div class="muted">Total</div><b class="price" style="font-size:1.2rem">{money(total())}</b></div>
                <A class={`btn primary ${ok().length !== cart().items.length ? "" : ""}`} href="/checkout" style="flex:none">Checkout ({ok().length})</A>
              </div>
            </Show>
          </Show>
        </Gate>
      </div>
    </>
  );
}

const SAVED = "shonin.ship";
const loadShip = () => { try { return JSON.parse(localStorage.getItem(SAVED)) || {}; } catch { return {}; } };

export function Checkout() {
  const nav = useNavigate();
  const saved = loadShip();
  const [f, setF] = createSignal({ ship_name: saved.ship_name || "", ship_phone: saved.ship_phone || "", ship_address: saved.ship_address || "", note: "" });
  const [cart] = createLoader(() => (app.user() ? true : null), () => api.get("/cart"));
  const [busy, setBusy] = createSignal(false);
  const [err, setErr] = createSignal(null);
  const set = (k) => (e) => setF({ ...f(), [k]: e.target.value });

  async function submit(e) {
    e.preventDefault();
    setBusy(true); setErr(null);
    try {
      await api.post("/orders", { ...f(), ship_name: f().ship_name.trim(), ship_phone: f().ship_phone.trim(), ship_address: f().ship_address.trim(), note: f().note.trim() });
      try { localStorage.setItem(SAVED, JSON.stringify({ ship_name: f().ship_name, ship_phone: f().ship_phone, ship_address: f().ship_address })); } catch {}
      await app.refreshCart();
      app.toast("Order placed!", "ok");
      nav("/orders", { replace: true });
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  }

  return (
    <>
      <Header title="Checkout" />
      <Gate>
        <form class="page form" onSubmit={submit}>
          <label class="field"><span>Full name</span><input required minlength="2" maxlength="100" autocomplete="name" value={f().ship_name} onInput={set("ship_name")} /></label>
          <label class="field"><span>Phone</span><input required type="tel" minlength="5" maxlength="30" autocomplete="tel" value={f().ship_phone} onInput={set("ship_phone")} /></label>
          <label class="field"><span>Delivery address</span><textarea required minlength="5" maxlength="500" autocomplete="street-address" value={f().ship_address} onInput={set("ship_address")} /></label>
          <label class="field"><span>Note to seller (optional)</span><input maxlength="500" value={f().note} onInput={set("note")} /></label>
          <div class="panel row between"><span>Payment</span><b>Cash on delivery</b></div>
          <Show when={cart()}><div class="panel row between"><span>Total</span><b class="price">{money(cart().total_cents)}</b></div></Show>
          <Show when={err()}><div class="err" role="alert">{err()}</div></Show>
          <button class="btn primary block" disabled={busy() || !cart()?.items.length}>{busy() ? "Placing order…" : "Place order"}</button>
        </form>
      </Gate>
    </>
  );
}

export function Orders() {
  const [status, setStatus] = createSignal("");
  const pager = createPager(() => `/orders?limit=20${status() ? `&status=${status()}` : ""}`);
  const pick = (s) => { setStatus(s); pager.reset(); };
  return (
    <>
      <Header title="My orders" />
      <div class="page">
        <Gate>
          <div class="chips">
            <For each={["", "pending", "confirmed", "shipped", "completed", "cancelled"]}>
              {(s) => <button class={`chip ${status() === s ? "on" : ""}`} onClick={() => pick(s)}>{s || "All"}</button>}
            </For>
          </div>
          <div class="list">
            <For each={pager.items()}>
              {(o) => (
                <A class="list-item" href={`/orders/${o.id}`}>
                  <div class="grow"><b>#{o.id} · {o.store_name}</b><div class="muted">{when(o.created_at)} ago</div></div>
                  <div style="text-align:right"><div class="price">{money(o.total_cents)}</div><span class={`tag ${STATUS_TAG[o.status]}`}>{o.status}</span></div>
                </A>
              )}
            </For>
          </div>
          <Show when={pager.loading()}><Spinner /></Show>
          <Show when={pager.done() && pager.items().length === 0}><Empty title="No orders yet" /></Show>
          <Show when={!pager.done()}><Sentinel onVisible={pager.more} /></Show>
        </Gate>
      </div>
    </>
  );
}

export function OrderDetail() {
  const params = useParams();
  const [o, { refetch }] = createLoader(() => (app.user() ? params.id : null), (id) => api.get(`/orders/${id}`));
  const [busy, setBusy] = createSignal(false);
  async function act(path, done) {
    setBusy(true);
    try { await api.post(`/orders/${params.id}/${path}`); app.toast(done, "ok"); await refetch(); } catch (e) { app.toast(errText(e), "error"); } finally { setBusy(false); }
  }
  return (
    <>
      <Header title={`Order #${params.id}`} />
      <div class="page">
        <Gate>
          <Show when={o.error}><Empty title="Order not found" /></Show>
          <Show when={o()}>
            {(x) => (
              <>
                <div class="panel row between"><A href={`/store/${x().store_id}`}><b>{x().store_name}</b></A><span class={`tag ${STATUS_TAG[x().status]}`}>{x().status}</span></div>
                <div class="list">
                  <For each={x().items}>
                    {(i) => (
                      <div class="list-item">
                        <Img class="thumb" src={i.image} alt={i.name} />
                        <div class="grow"><div class="ellipsis">{i.name}</div><div class="muted">{money(i.price_cents)} × {i.qty}</div></div>
                        <b>{money(i.price_cents * i.qty)}</b>
                      </div>
                    )}
                  </For>
                </div>
                <div class="panel">
                  <div class="row between"><span>Total (cash on delivery)</span><b class="price">{money(x().total_cents)}</b></div>
                  <div class="muted">Ship to</div>
                  <div>{x().ship_name} · {x().ship_phone}<br />{x().ship_address}</div>
                  <Show when={x().note}><div class="muted">Note: {x().note}</div></Show>
                  <Show when={x().cancel_reason}><div class="err">Cancelled: {x().cancel_reason}</div></Show>
                </div>
                <Show when={x().status === "pending"}><button class="btn danger block" disabled={busy()} onClick={() => confirm("Cancel this order?") && act("cancel", "Order cancelled")}>Cancel order</button></Show>
                <Show when={x().status === "shipped"}><button class="btn primary block" disabled={busy()} onClick={() => act("complete", "Thanks! Order completed")}>I received my order</button></Show>
              </>
            )}
          </Show>
        </Gate>
      </div>
    </>
  );
}
