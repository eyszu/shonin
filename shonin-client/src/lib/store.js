import { createSignal, createRoot } from "solid-js";
import { api, auth } from "./api.js";

export const money = (cents) =>
  new Intl.NumberFormat(undefined, { style: "currency", currency: import.meta.env.VITE_CURRENCY || "PHP" }).format(
    (cents || 0) / 100,
  );

export const when = (iso) => {
  const d = new Date(iso);
  const sec = (Date.now() - d) / 1000;
  if (sec < 60) return "now";
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  if (sec < 604800) return `${Math.floor(sec / 86400)}d`;
  return d.toLocaleDateString();
};

export default createRoot(() => {
  const [user, setUser] = createSignal(null); // {id,email,role,store_id,suspended,...}
  const [ready, setReady] = createSignal(!auth.token);
  const [cartCount, setCartCount] = createSignal(0);
  const [toasts, setToasts] = createSignal([]);
  const [online, setOnline] = createSignal(navigator.onLine);
  const [installEvent, setInstallEvent] = createSignal(null);

  addEventListener("online", () => setOnline(true));
  addEventListener("offline", () => setOnline(false));
  addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); setInstallEvent(e); });
  addEventListener("appinstalled", () => setInstallEvent(null));

  let n = 0;
  function toast(text, kind = "info") {
    const id = ++n;
    setToasts((t) => [...t, { id, text, kind }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), kind === "error" ? 5000 : 2600);
  }

  async function refreshCart() {
    if (!auth.token) return setCartCount(0);
    try {
      const c = await api.get("/cart");
      setCartCount(c.items.reduce((s, i) => s + i.qty, 0));
    } catch {}
  }

  async function loadMe() {
    if (!auth.token) { setUser(null); setReady(true); return; }
    try {
      setUser(await api.get("/me"));
      refreshCart();
    } catch (e) {
      if (e.status === 401 || e.status === 403) setUser(null);
    } finally {
      setReady(true);
    }
  }

  auth.onLost(() => { setUser(null); setCartCount(0); });

  async function login(email, password) {
    const r = await api.post("/auth/login", { email, password });
    auth.set(r.token);
    await loadMe();
  }

  async function logout(everywhere = false) {
    try { await api.post(everywhere ? "/auth/logout-all" : "/auth/logout"); } catch {}
    auth.set(null);
    setUser(null);
    setCartCount(0);
  }

  loadMe();
  return { user, ready, cartCount, setCartCount, refreshCart, toasts, toast, online, installEvent, setInstallEvent, loadMe, login, logout };
});
