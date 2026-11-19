import { onCleanup, onMount, Show, For } from "solid-js";
import { A, useNavigate, useLocation } from "@solidjs/router";
import app, { money } from "./store.js";

export const Icon = (p) => {
  const paths = {
    home: "M3 11l9-8 9 8M5 10v10h5v-6h4v6h5V10",
    cart: "M3 4h2l2.4 11h10.2L20 7H6M9 20h.01M17 20h.01",
    chat: "M4 5h16v11H9l-5 4z",
    user: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c0-4 4-6 8-6s8 2 8 6",
    search: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM21 21l-5-5",
    back: "M15 5l-7 7 7 7",
    plus: "M12 5v14M5 12h14",
    minus: "M5 12h14",
    trash: "M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13",
    store: "M4 9l1-5h14l1 5M4 9c0 2 3 2 4 0 1 2 3 2 4 0 1 2 3 2 4 0 1 2 4 2 4 0M5 11v9h14v-9",
    box: "M3 7l9-4 9 4v10l-9 4-9-4zM3 7l9 4 9-4M12 11v10",
    send: "M4 12l16-8-6 16-3-7z",
    shield: "M12 3l8 3v6c0 5-4 8-8 9-4-1-8-4-8-9V6z",
    camera: "M4 8h3l2-3h6l2 3h3v11H4zM12 17a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z",
    x: "M6 6l12 12M18 6L6 18",
    download: "M12 4v11M7 11l5 5 5-5M5 20h14",
  };
  return (
    <svg class="icon" width={p.size || 22} height={p.size || 22} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d={paths[p.name]} />
    </svg>
  );
};

export const Img = (p) => (
  <div class={`img ${p.class || ""}`}>
    <Show when={p.src} fallback={<span class="img-ph">{(p.alt || "?").slice(0, 1).toUpperCase()}</span>}>
      <img src={p.src} alt={p.alt || ""} loading="lazy" decoding="async" width="192" height="192" />
    </Show>
  </div>
);

export const Spinner = () => <div class="spinner" role="status" aria-label="Loading" />;

export const Empty = (p) => (
  <div class="empty">
    <div class="empty-title">{p.title}</div>
    <Show when={p.children}><div class="muted">{p.children}</div></Show>
  </div>
);

export const Sentinel = (p) => {
  let el;
  onMount(() => {
    const io = new IntersectionObserver((e) => e[0].isIntersecting && p.onVisible(), { rootMargin: "400px" });
    io.observe(el);
    onCleanup(() => io.disconnect());
  });
  return <div ref={el} class="sentinel" />;
};

export const ProductCard = (p) => (
  <A class="card product" href={`/p/${p.item.id}`}>
    <Img src={p.item.cover} alt={p.item.name} />
    <div class="card-body">
      <div class="name">{p.item.name}</div>
      <div class="price">{money(p.item.price_cents)}</div>
      <div class="meta">
        <span>{p.item.sold} sold</span>
        <Show when={p.item.stock === 0}><span class="tag bad">Sold out</span></Show>
      </div>
    </div>
  </A>
);

// Page header with a back button.
export const Header = (p) => {
  const nav = useNavigate();
  return (
    <header class="topbar">
      <button class="icon-btn" onClick={() => (history.length > 1 ? history.back() : nav("/"))} aria-label="Back">
        <Icon name="back" />
      </button>
      <h1>{p.title}</h1>
      <div class="topbar-end">{p.children}</div>
    </header>
  );
};

// Requires sign-in; otherwise shows a prompt that returns here after login.
export const Gate = (p) => {
  const loc = useLocation();
  return (
    <Show when={app.ready()} fallback={<Spinner />}>
      <Show
        when={app.user()}
        fallback={
          <div class="gate">
            <h2>Sign in to continue</h2>
            <p class="muted">You need an account for this.</p>
            <A class="btn primary" href={`/login?next=${encodeURIComponent(loc.pathname + loc.search)}`}>Sign in</A>
            <A class="btn" href="/register">Create account</A>
          </div>
        }
      >
        {p.children}
      </Show>
    </Show>
  );
};

export const Toasts = () => (
  <div class="toasts" aria-live="polite">
    <For each={app.toasts()}>{(t) => <div class={`toast ${t.kind}`}>{t.text}</div>}</For>
  </div>
);

export const BottomNav = () => {
  const loc = useLocation();
  const on = (p) => (p === "/" ? loc.pathname === "/" : loc.pathname.startsWith(p));
  const Tab = (q) => (
    <A href={q.href} class={`tab ${on(q.href) ? "on" : ""}`}>
      <span class="tab-icon">
        <Icon name={q.icon} />
        <Show when={q.badge > 0}><b class="badge">{q.badge > 99 ? "99+" : q.badge}</b></Show>
      </span>
      <span>{q.label}</span>
    </A>
  );
  return (
    <nav class="bottomnav" aria-label="Main">
      <Tab href="/" icon="home" label="Shop" />
      <Tab href="/chats" icon="chat" label="Chat" />
      <Tab href="/cart" icon="cart" label="Cart" badge={app.cartCount()} />
      <Tab href="/account" icon="user" label="Me" />
    </nav>
  );
};

export function errText(e) {
  return e?.message || "Something went wrong";
}

export const Sheet = (p) => (
  <div class="sheet-back" onClick={(e) => e.target === e.currentTarget && p.onClose()}>
    <div class="sheet" role="dialog" aria-modal="true" aria-label={p.title}>
      <div class="row between">
        <h2>{p.title}</h2>
        <button class="icon-btn" style="color:var(--text)" onClick={p.onClose} aria-label="Close"><Icon name="x" /></button>
      </div>
      {p.children}
    </div>
  </div>
);
