import { createSignal, Show } from "solid-js";
import { A, useNavigate, useSearchParams } from "@solidjs/router";
import { api } from "../lib/api.js";
import app from "../lib/store.js";
import { Gate, Header, Icon, errText } from "../lib/ui.jsx";

export function Login() {
  const nav = useNavigate();
  const [sp] = useSearchParams();
  const [email, setEmail] = createSignal("");
  const [password, setPassword] = createSignal("");
  const [err, setErr] = createSignal(null);
  const [busy, setBusy] = createSignal(false);
  const [unverified, setUnverified] = createSignal(false);

  async function submit(e) {
    e.preventDefault();
    setBusy(true); setErr(null); setUnverified(false);
    try {
      await app.login(email().trim(), password());
      nav(sp.next && sp.next.startsWith("/") ? sp.next : "/", { replace: true });
    } catch (e) {
      setUnverified(e.code === "email_not_verified");
      setErr(errText(e));
    } finally { setBusy(false); }
  }

  async function resend() {
    try { await api.post("/auth/resend", { email: email().trim() }); app.toast("If the account needs it, a new link was sent. Check the server console.", "ok"); }
    catch (e) { app.toast(errText(e), "error"); }
  }

  return (
    <>
      <Header title="Sign in" />
      <form class="page form" onSubmit={submit}>
        <label class="field"><span>Email</span>
          <input type="email" required autocomplete="email" inputmode="email" value={email()} onInput={(e) => setEmail(e.target.value)} />
        </label>
        <label class="field"><span>Password</span>
          <input type="password" required autocomplete="current-password" value={password()} onInput={(e) => setPassword(e.target.value)} />
        </label>
        <Show when={err()}><div class="err" role="alert">{err()}</div></Show>
        <Show when={unverified()}><button type="button" class="btn" onClick={resend}>Resend verification link</button></Show>
        <button class="btn primary block" disabled={busy()}>{busy() ? "Signing in…" : "Sign in"}</button>
        <p class="muted" style="text-align:center">New here? <A href="/register" style="color:var(--brand);font-weight:600">Create an account</A></p>
      </form>
    </>
  );
}

export function Register() {
  const [email, setEmail] = createSignal("");
  const [password, setPassword] = createSignal("");
  const [err, setErr] = createSignal(null);
  const [busy, setBusy] = createSignal(false);
  const [sent, setSent] = createSignal(false);

  async function submit(e) {
    e.preventDefault();
    setBusy(true); setErr(null);
    try {
      await api.post("/auth/register", { email: email().trim(), password: password() });
      setSent(true);
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  }

  return (
    <>
      <Header title="Create account" />
      <Show
        when={!sent()}
        fallback={
          <div class="page">
            <div class="panel" style="text-align:center">
              <h2>Check your email</h2>
              <p style="margin:0">We sent a verification link to <b>{email()}</b>. Open it to activate your account, then sign in.</p>
              <p class="muted" style="margin:0">Development server: the link is printed in the Shonin server console.</p>
              <A class="btn primary" href="/login">Go to sign in</A>
            </div>
          </div>
        }
      >
        <form class="page form" onSubmit={submit}>
          <label class="field"><span>Email</span>
            <input type="email" required autocomplete="email" inputmode="email" value={email()} onInput={(e) => setEmail(e.target.value)} />
          </label>
          <label class="field"><span>Password (at least 8 characters)</span>
            <input type="password" required minlength="8" maxlength="128" autocomplete="new-password" value={password()} onInput={(e) => setPassword(e.target.value)} />
          </label>
          <Show when={err()}><div class="err" role="alert">{err()}</div></Show>
          <button class="btn primary block" disabled={busy()}>{busy() ? "Creating…" : "Create account"}</button>
          <p class="muted" style="text-align:center">Already registered? <A href="/login" style="color:var(--brand);font-weight:600">Sign in</A></p>
        </form>
      </Show>
    </>
  );
}

export function Account() {
  const nav = useNavigate();
  const u = () => app.user();
  return (
    <>
      <Header title="Me" />
      <div class="page">
        <Gate>
          <div class="panel">
            <b class="ellipsis">{u()?.email}</b>
            <div class="row wrap">
              <span class="tag">{u()?.role}</span>
              <Show when={u()?.suspended}><span class="tag warn">Suspended</span></Show>
            </div>
          </div>
          <div class="list">
            <A class="list-item" href="/orders"><Icon name="box" /><span class="grow">My orders</span></A>
            <A class="list-item" href="/chats"><Icon name="chat" /><span class="grow">Messages</span></A>
            <A class="list-item" href="/seller"><Icon name="store" /><span class="grow">{u()?.store_id ? "Seller center" : "Start selling"}</span></A>
            <Show when={u()?.role === "admin"}>
              <A class="list-item" href="/admin"><Icon name="shield" /><span class="grow">Admin</span></A>
            </Show>
          </div>
          <Show when={app.installEvent()}>
            <button class="btn" onClick={async () => { const e = app.installEvent(); e.prompt(); await e.userChoice; app.setInstallEvent(null); }}>
              <Icon name="download" size={18} /> Install app
            </button>
          </Show>
          <button class="btn block" onClick={async () => { await app.logout(); nav("/"); }}>Sign out</button>
          <button class="btn small danger" onClick={async () => { await app.logout(true); nav("/"); }}>Sign out of all devices</button>
        </Gate>
      </div>
    </>
  );
}
