import { createEffect, createSignal, For, Show } from "solid-js";
import { createLoader } from "../lib/load.js";
import { api, saveBlob } from "../lib/api.js";
import app, { when } from "../lib/store.js";
import { createPager } from "../lib/pager.js";
import { Empty, Header, Icon, Sentinel, Sheet, Spinner, errText } from "../lib/ui.jsx";

const STATE_TAG = { active: "good", suspended: "warn", banned: "bad" };

function UserSheet(props) {
  const [d, { refetch }] = createLoader(() => props.id, (id) => api.get(`/admin/users/${id}`));
  const [reason, setReason] = createSignal("");
  const [hours, setHours] = createSignal("24");
  const [busy, setBusy] = createSignal(false);

  async function run(fn, ok) {
    setBusy(true);
    try { await fn(); app.toast(ok, "ok"); setReason(""); await refetch(); props.onChange(); }
    catch (e) { app.toast(errText(e), "error"); } finally { setBusy(false); }
  }
  const u = () => d()?.user;
  const needReason = () => reason().trim().length < 3;
  return (
    <Sheet title={u()?.email || "User"} onClose={props.onClose}>
      <Show when={d.loading}><Spinner /></Show>
      <Show when={u()}>
        <div class="row wrap"><span class="tag">{u().role}</span><span class={`tag ${STATE_TAG[u().state]}`}>{u().state}</span>
          <Show when={!u().email_verified}><span class="tag warn">unverified</span></Show></div>
        <Show when={u().suspended_until && u().state === "suspended"}><div class="muted">Suspended until {new Date(u().suspended_until).toLocaleString()}</div></Show>
        <Show when={u().ban_reason}><div class="muted">Ban reason: {u().ban_reason}</div></Show>
        <Show when={u().role !== "admin"}>
          <label class="field"><span>Reason (shown to the user)</span><input value={reason()} onInput={(e) => setReason(e.target.value)} maxlength="500" /></label>
          <Show when={u().state !== "banned"}>
            <div class="row">
              <label class="field" style="width:110px"><span>Hours</span><input type="number" min="1" max="8760" value={hours()} onInput={(e) => setHours(e.target.value)} /></label>
              <button class="btn grow" style="align-self:end" disabled={busy() || needReason()} onClick={() => run(() => api.post(`/admin/users/${props.id}/suspend`, { duration_hours: parseInt(hours(), 10), reason: reason().trim() }), "User suspended")}>Suspend</button>
            </div>
            <button class="btn danger block" disabled={busy() || needReason()} onClick={() => confirm("Ban this user? They are signed out everywhere.") && run(() => api.post(`/admin/users/${props.id}/ban`, { reason: reason().trim() }), "User banned")}>Ban permanently</button>
          </Show>
          <Show when={u().state === "suspended"}><button class="btn block" disabled={busy()} onClick={() => run(() => api.del(`/admin/users/${props.id}/suspend`), "Suspension lifted")}>Lift suspension</button></Show>
          <Show when={u().state === "banned"}><button class="btn block" disabled={busy()} onClick={() => run(() => api.del(`/admin/users/${props.id}/ban`), "Ban lifted")}>Lift ban</button></Show>
        </Show>
        <Show when={d().history.length}>
          <b>History</b>
          <div class="list"><For each={d().history}>{(h) => <div class="list-item"><div class="grow"><b>{h.action}</b><div class="muted">{h.reason}</div></div><span class="muted">{when(h.at)}</span></div>}</For></div>
        </Show>
      </Show>
    </Sheet>
  );
}

function Users() {
  const [q, setQ] = createSignal("");
  const [state, setState] = createSignal("");
  const [open, setOpen] = createSignal(null);
  const pager = createPager(() => `/admin/users?limit=30${q() ? `&q=${encodeURIComponent(q())}` : ""}${state() ? `&state=${state()}` : ""}`);
  createEffect(() => { q(); state(); pager.reset(); });
  let t;
  return (
    <>
      <label class="field"><span>Search by email</span><input type="search" onInput={(e) => { clearTimeout(t); const v = e.target.value; t = setTimeout(() => setQ(v.trim()), 300); }} /></label>
      <div class="chips"><For each={["", "active", "suspended", "banned"]}>{(s) => <button class={`chip ${state() === s ? "on" : ""}`} onClick={() => setState(s)}>{s || "All"}</button>}</For></div>
      <div class="list">
        <For each={pager.items()}>
          {(u) => (
            <button class="list-item" style="width:100%;border:0;background:none;text-align:left;cursor:pointer" onClick={() => setOpen(u.id)}>
              <div class="grow"><div class="ellipsis"><b>{u.email}</b></div><div class="muted">#{u.id} · {u.role}</div></div>
              <span class={`tag ${STATE_TAG[u.state]}`}>{u.state}</span>
            </button>
          )}
        </For>
      </div>
      <Show when={pager.loading()}><Spinner /></Show>
      <Show when={pager.done() && !pager.items().length}><Empty title="No users match" /></Show>
      <Show when={!pager.done()}><Sentinel onVisible={pager.more} /></Show>
      <Show when={open()}><UserSheet id={open()} onClose={() => setOpen(null)} onChange={pager.reset} /></Show>
    </>
  );
}

function Categories() {
  const [cats, { refetch }] = createLoader(() => api.get("/categories"));
  const [name, setName] = createSignal("");
  async function add(e) {
    e.preventDefault();
    try { await api.post("/admin/categories", { name: name().trim() }); setName(""); refetch(); } catch (e) { app.toast(errText(e), "error"); }
  }
  async function del(c) {
    if (!confirm(`Delete "${c.name}"? Its products become uncategorised.`)) return;
    try { await api.del(`/admin/categories/${c.id}`); refetch(); } catch (e) { app.toast(errText(e), "error"); }
  }
  return (
    <>
      <form class="row" onSubmit={add}>
        <input class="grow" style="height:44px;padding:0 12px;border-radius:12px;border:1px solid var(--line);background:var(--surface)" placeholder="New category" required minlength="2" maxlength="60" value={name()} onInput={(e) => setName(e.target.value)} />
        <button class="btn primary">Add</button>
      </form>
      <div class="list"><For each={cats()}>{(c) => <div class="list-item"><span class="grow">{c.name}</span><button class="icon-btn" style="color:var(--bad)" onClick={() => del(c)} aria-label={`Delete ${c.name}`}><Icon name="trash" /></button></div>}</For></div>
    </>
  );
}

function Backups() {
  const [busy, setBusy] = createSignal("");
  async function get(kind, path, fallback) {
    setBusy(kind);
    try { saveBlob(await api.download(path), fallback); app.toast("Download ready", "ok"); }
    catch (e) { app.toast(errText(e), "error"); } finally { setBusy(""); }
  }
  return (
    <>
      <div class="panel">
        <b>Database backup</b>
        <p class="muted" style="margin:0">Compressed SQL snapshot of all data. Contains password hashes, so keep it private. Restore with <code>gunzip -c file | psql</code>.</p>
        <button class="btn primary" disabled={!!busy()} onClick={() => get("db", "/admin/backup/db", "shonin-db.sql.gz")}><Icon name="download" size={18} /> {busy() === "db" ? "Preparing…" : "Download database"}</button>
      </div>
      <div class="panel">
        <b>Images backup</b>
        <p class="muted" style="margin:0">ZIP of every product photo and store logo.</p>
        <button class="btn primary" disabled={!!busy()} onClick={() => get("img", "/admin/backup/images", "shonin-images.zip")}><Icon name="download" size={18} /> {busy() === "img" ? "Preparing…" : "Download images ZIP"}</button>
      </div>
    </>
  );
}

export function Admin() {
  const [tab, setTab] = createSignal("users");
  return (
    <>
      <Header title="Admin" />
      <Show when={app.ready()} fallback={<Spinner />}>
        <Show when={app.user()?.role === "admin"} fallback={<Empty title="Admins only" />}>
          <div class="tabs"><For each={[["users", "Users"], ["cats", "Categories"], ["backup", "Backups"]]}>{([k, l]) => <button class={tab() === k ? "on" : ""} onClick={() => setTab(k)}>{l}</button>}</For></div>
          <div class="page">
            <Show when={tab() === "users"}><Users /></Show>
            <Show when={tab() === "cats"}><Categories /></Show>
            <Show when={tab() === "backup"}><Backups /></Show>
          </div>
        </Show>
      </Show>
    </>
  );
}
