import { Show, Suspense } from "solid-js";
import { useLocation } from "@solidjs/router";
import app from "./lib/store.js";
import { BottomNav, Toasts, Spinner } from "./lib/ui.jsx";

// Screens that bring their own fixed bottom bar (buy bar, composer) hide the tab bar.
const NO_NAV = /^\/(p\/|chats\/|checkout|login|register|seller\/products\/)/;

export default function Layout(props) {
  const loc = useLocation();
  const hideNav = () => NO_NAV.test(loc.pathname);
  const u = () => app.user();
  return (
    <div class={`shell ${hideNav() ? "no-nav" : ""}`}>
      <Show when={!app.online()}><div class="banner offline">You are offline. Showing saved pages where possible.</div></Show>
      <Show when={u()?.suspended}>
        <div class="banner warn">
          Your account is suspended{u().suspended_until ? ` until ${new Date(u().suspended_until).toLocaleString()}` : ""}
          {u().suspend_reason ? `: ${u().suspend_reason}` : ""}. You can browse but not buy, sell or chat.
        </div>
      </Show>
      <Suspense fallback={<Spinner />}>{props.children}</Suspense>
      <Show when={!hideNav()}><BottomNav /></Show>
      <Toasts />
    </div>
  );
}
