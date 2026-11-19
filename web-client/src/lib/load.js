import { createEffect, createSignal, on, untrack } from "solid-js";

// A Suspense-free data loader with the same shape as createResource:
//   const [data, { refetch, mutate }] = createLoader(source, fetcher);
//   data()  data.loading  data.error  data.state ("unresolved" | "pending" | "ready" | "errored")
// A falsy source means "do not fetch yet" (e.g. waiting for sign-in). With one
// argument it is a fetcher that runs once. Stale responses are discarded.
export function createLoader(a, b) {
  const source = b ? a : () => true;
  const fetcher = b || a;
  const [data, setData] = createSignal(undefined);
  const [error, setError] = createSignal(undefined);
  const [loading, setLoading] = createSignal(false);
  const [state, setState] = createSignal("unresolved");
  let gen = 0;

  async function run(key) {
    const g = ++gen;
    if (!key) { setLoading(false); setState("unresolved"); return; }
    setLoading(true); setState("pending"); setError(undefined);
    try {
      const v = await fetcher(key);
      if (g !== gen) return;
      setData(() => v); setState("ready");
    } catch (e) {
      if (g !== gen) return;
      setError(() => e); setState("errored");
    } finally {
      if (g === gen) setLoading(false);
    }
  }

  createEffect(on(source, (key) => { run(key); }));

  const read = () => data();
  Object.defineProperties(read, {
    loading: { get: loading },
    error: { get: error },
    state: { get: state },
  });
  return [read, { refetch: () => run(untrack(source)), mutate: (v) => setData(() => v) }];
}
