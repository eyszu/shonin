import { defineConfig, loadEnv } from "vite";
import solid from "vite-plugin-solid";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  // Where the Shonin API runs. Dev and `preview` proxy to it, so the browser
  // sees a single origin and no CORS setup is needed.
  const target = env.SHONIN_API || "http://localhost:3000";
  const proxy = {
    "/api": { target, changeOrigin: true },
    "/images": { target, changeOrigin: true },
  };

  return {
    plugins: [
      solid(),
      VitePWA({
        registerType: "autoUpdate",
        includeAssets: ["icon.svg", "apple-touch-icon.png"],
        manifest: {
          name: "Shonin",
          short_name: "Shonin",
          description: "Buy and sell, mobile first.",
          theme_color: "#d9480f",
          background_color: "#fff8f3",
          display: "standalone",
          orientation: "portrait",
          start_url: "/",
          scope: "/",
          icons: [
            { src: "/pwa-192.png", sizes: "192x192", type: "image/png" },
            { src: "/pwa-512.png", sizes: "512x512", type: "image/png" },
            { src: "/pwa-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
          ],
        },
        workbox: {
          navigateFallback: "/index.html",
          navigateFallbackDenylist: [/^\/api\//, /^\/images\//],
          globPatterns: ["**/*.{js,css,html,svg,png,ico,webmanifest}"],
          runtimeCaching: [
            {
              // Product photos never change once stored (random filenames).
              urlPattern: ({ url }) => url.pathname.startsWith("/images/"),
              handler: "CacheFirst",
              options: { cacheName: "shonin-images", expiration: { maxEntries: 300, maxAgeSeconds: 60 * 60 * 24 * 30 } },
            },
            {
              // Browsing data: show cached copy when offline, refresh when online.
              urlPattern: ({ url, request }) =>
                request.method === "GET" &&
                (url.pathname === "/api/v1/categories" || url.pathname.startsWith("/api/v1/products") || url.pathname.startsWith("/api/v1/stores/")) &&
                !url.pathname.startsWith("/api/v1/stores/me"),
              handler: "NetworkFirst",
              options: { cacheName: "shonin-browse", networkTimeoutSeconds: 4, expiration: { maxEntries: 80, maxAgeSeconds: 60 * 60 * 24 } },
            },
          ],
        },
      }),
    ],
    server: { host: true, port: 5173, proxy },
    preview: { host: true, port: 4173, proxy },
    build: { target: "es2020" },
  };
});
