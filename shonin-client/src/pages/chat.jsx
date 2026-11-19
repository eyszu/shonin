import { createEffect, createSignal, For, onCleanup, onMount, Show } from "solid-js";
import { A, useNavigate, useParams, useSearchParams } from "@solidjs/router";
import { createLoader } from "../lib/load.js";
import { api } from "../lib/api.js";
import app, { when } from "../lib/store.js";
import { createPager } from "../lib/pager.js";
import { Empty, Gate, Header, Icon, Sentinel, Spinner, errText } from "../lib/ui.jsx";

export function Chats() {
  const [sp, setSp] = useSearchParams();
  const role = () => (sp.as === "seller" && app.user()?.store_id ? "seller" : "customer");
  const pager = createPager(() => `/conversations?as=${role()}&limit=30`);
  createEffect(() => { if (app.user()) { role(); pager.reset(); } });
  return (
    <>
      <Header title="Messages" />
      <Gate>
        <Show when={app.user()?.store_id}>
          <div class="tabs">
            <button class={role() === "customer" ? "on" : ""} onClick={() => setSp({ as: undefined })}>Buying</button>
            <button class={role() === "seller" ? "on" : ""} onClick={() => setSp({ as: "seller" })}>Selling</button>
          </div>
        </Show>
        <div class="page">
          <div class="list">
            <For each={pager.items()}>
              {(c) => (
                <A class="list-item" href={`/chats/${c.id}?as=${role()}`}>
                  <div class="grow">
                    <div class="row between"><b class="ellipsis">{c.with}</b><span class="muted nowrap">{c.last_message_at ? when(c.last_message_at) : ""}</span></div>
                    <div class="muted ellipsis">{c.last_message}</div>
                  </div>
                  <Show when={c.unread > 0}><b class="badge" style="position:static">{c.unread}</b></Show>
                </A>
              )}
            </For>
          </div>
          <Show when={pager.loading()}><Spinner /></Show>
          <Show when={pager.done() && pager.items().length === 0}>
            <Empty title="No conversations yet">Open a product and tap the chat button to message a seller.</Empty>
          </Show>
          <Show when={!pager.done()}><Sentinel onVisible={pager.more} /></Show>
        </div>
      </Gate>
    </>
  );
}

export function Thread() {
  const params = useParams();
  const [text, setText] = createSignal("");
  const [msgs, setMsgs] = createSignal([]);
  const [loading, setLoading] = createSignal(true);
  const [error, setError] = createSignal(null);
  const [sending, setSending] = createSignal(false);
  const [more, setMore] = createSignal(null);
  let bottom;
  let alive = true;
  const ctl = new AbortController();

  const add = (list) => {
    if (!list.length) return;
    const have = new Set(msgs().map((m) => m.id));
    const fresh = list.filter((m) => !have.has(m.id));
    if (fresh.length) {
      setMsgs((a) => a.concat(fresh).sort((x, y) => x.id - y.id));
      queueMicrotask(() => bottom?.scrollIntoView({ block: "end" }));
    }
  };

  async function loadFirst() {
    try {
      const r = await api.get(`/conversations/${params.id}/messages?limit=50`);
      setMsgs(r.items); setMore(r.next_cursor);
      queueMicrotask(() => bottom?.scrollIntoView({ block: "end" }));
      poll();
    } catch (e) { setError(e.status === 404 ? "Conversation not found." : errText(e)); } finally { setLoading(false); }
  }

  async function older() {
    const r = await api.get(`/conversations/${params.id}/messages?limit=50&before=${more()}`);
    setMsgs((a) => r.items.concat(a)); setMore(r.next_cursor);
  }

  // Long-poll: the server holds the request open until a message arrives.
  async function poll() {
    while (alive) {
      const last = msgs().at(-1)?.id ?? 0;
      try {
        const r = await api.get(`/conversations/${params.id}/messages?after=${last}&wait=20`, { signal: ctl.signal });
        add(r.items);
      } catch (e) {
        if (!alive || e.name === "AbortError") return;
        await new Promise((res) => setTimeout(res, e.status === 0 ? 3000 : 5000));
      }
    }
  }

  async function send(e) {
    e.preventDefault();
    const body = text().trim();
    if (!body) return;
    setSending(true);
    try {
      const r = await api.post(`/conversations/${params.id}/messages`, { body });
      setText("");
      add([{ id: r.id, mine: true, body, created_at: r.created_at }]);
    } catch (e) { app.toast(e.code === "account_suspended" ? "You are suspended and can't send messages" : errText(e), "error"); } finally { setSending(false); }
  }

  onMount(() => { if (app.user()) loadFirst(); else setLoading(false); });
  onCleanup(() => { alive = false; ctl.abort(); });

  return (
    <>
      <Header title="Chat" />
      <Gate>
        <Show when={loading()}><Spinner /></Show>
        <Show when={error()}><Empty title={error()} /></Show>
        <div class="thread">
          <Show when={more()}><button class="btn small" style="justify-self:center" onClick={older}>Load earlier messages</button></Show>
          <For each={msgs()}>
            {(m) => (
              <div class={`bubble ${m.mine ? "mine" : ""}`}>
                {m.body}
                <time>{new Date(m.created_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
              </div>
            )}
          </For>
          <div ref={bottom} />
        </div>
        <form class="composer" onSubmit={send}>
          <input value={text()} onInput={(e) => setText(e.target.value)} maxlength="2000" placeholder="Type a message" enterkeyhint="send" aria-label="Message" />
          <button disabled={sending() || !text().trim()} aria-label="Send"><Icon name="send" size={20} /></button>
        </form>
      </Gate>
    </>
  );
}
