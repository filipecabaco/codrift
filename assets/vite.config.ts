import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import tailwindcss from "@tailwindcss/vite";

// The Elixir/Francis server (REST, SSE, WebSocket, MCP) listens on 7437.
// In dev, Vite serves the SPA with HMR and proxies all backend traffic there.
// In prod, `vite build` emits into ../priv/static and Francis serves it.
const target = "http://localhost:7437";

export default defineConfig({
  plugins: [tailwindcss(), svelte()],
  resolve: {
    alias: {
      $lib: fileURLToPath(new URL("./src/lib", import.meta.url)),
    },
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": { target },
      "/events": { target }, // SSE stream
      "/oauth": { target },
      "/mcp": { target },
      "/ws": { target, ws: true }, // agent input WebSocket
    },
  },
  build: {
    outDir: "../priv/static",
    emptyOutDir: false, // keep diff.html / term.html prototypes alongside
    target: "es2022",
  },
});
