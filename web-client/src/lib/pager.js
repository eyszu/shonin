import { createSignal, untrack } from "solid-js";
import { api } from "./api.js";

// Cursor pagination for {items, next_cursor} lists. `source()` returns the path;
// call reset() whenever it changes, more() to load the next page.
export function createPager(source) {
  const [items, setItems] = createSignal([]);
  const [loading, setLoading] = createSignal(false);
  const [done, setDone] = createSignal(false);
  const [error, setError] = createSignal(null);
  let cursor = null;
  let gen = 0;

  async function more() {
    if (untrack(loading) || untrack(done)) return;
    const g = gen;
    setLoading(true);
    try {
      const base = source(); // tracked on purpose: effects calling reset() re-run when the query changes
      const url = cursor ? `${base}${base.includes("?") ? "&" : "?"}cursor=${encodeURIComponent(cursor)}` : base;
      const r = await api.get(url);
      if (g !== gen) return;
      setItems((a) => a.concat(r.items));
      cursor = r.next_cursor;
      if (!cursor) setDone(true);
    } catch (e) {
      if (g === gen) { setError(e.message); setDone(true); }
    } finally {
      if (g === gen) setLoading(false);
    }
  }

  function reset() {
    gen++;
    cursor = null;
    setItems([]); setDone(false); setError(null); setLoading(false);
    return more();
  }

  return { items, setItems, loading, done, error, more, reset };
}
