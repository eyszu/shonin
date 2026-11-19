// Thin fetch wrapper for the Shonin API. Same-origin (Vite proxies /api), so no CORS.
const BASE = "/api/v1";
const KEY = "shonin.token";

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message || code || `HTTP ${status}`);
    this.status = status;
    this.code = code;
  }
}

let token = null;
try { token = localStorage.getItem(KEY); } catch {}
let onAuthLost = () => {};

export const auth = {
  get token() { return token; },
  set(t) {
    token = t;
    try { t ? localStorage.setItem(KEY, t) : localStorage.removeItem(KEY); } catch {}
  },
  onLost(fn) { onAuthLost = fn; },
};

async function request(method, path, { body, raw, signal, blob } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  let payload;
  if (raw) {
    payload = raw; // a File/Blob, sent as-is
    headers["Content-Type"] = "application/octet-stream";
  } else if (body !== undefined) {
    payload = JSON.stringify(body);
    headers["Content-Type"] = "application/json";
  }
  let res;
  try {
    res = await fetch(BASE + path, { method, headers, body: payload, signal });
  } catch (e) {
    if (e.name === "AbortError") throw e;
    throw new ApiError(0, "offline", "You appear to be offline");
  }
  if (blob) {
    if (!res.ok) throw await toError(res);
    return { blob: await res.blob(), name: /filename="([^"]+)"/.exec(res.headers.get("Content-Disposition") || "")?.[1] };
  }
  if (res.status === 204) return null;
  if (!res.ok) throw await toError(res);
  const type = res.headers.get("Content-Type") || "";
  return type.includes("json") ? res.json() : res.text();
}

async function toError(res) {
  let data = {};
  try { data = await res.json(); } catch {}
  if (res.status === 401 && token) { auth.set(null); onAuthLost(); }
  return new ApiError(res.status, data.error, data.message);
}

export const api = {
  get: (p, o) => request("GET", p, o),
  post: (p, body, o) => request("POST", p, { body, ...o }),
  put: (p, body, o) => request("PUT", p, { body, ...o }),
  patch: (p, body, o) => request("PATCH", p, { body, ...o }),
  del: (p, o) => request("DELETE", p, o),
  upload: (method, p, file) => request(method, p, { raw: file }),
  download: (p) => request("GET", p, { blob: true }),
};

export function saveBlob({ blob, name }, fallback) {
  const url = URL.createObjectURL(blob);
  const a = Object.assign(document.createElement("a"), { href: url, download: name || fallback });
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}
