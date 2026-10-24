import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

// The bot panel, a Telegram Mini App druzhok serves under /app/
// (DruzhokWebWeb.PanelPageController). The build lands in
// apps/druzhok_web/priv/static/app and is committed; ops/build-app.sh runs it.
export default defineConfig({
  base: "/app/",
  plugins: [react()],
  build: {
    outDir: "../../priv/static/app",
    emptyOutDir: true,
    assetsInlineLimit: 0,
  },
  server: {
    port: 5276,
    proxy: {
      // Dev: druzhok on :4000 wants Caddy's edge header (Plugs.Edge).
      "^/app/api/": {
        target: "http://127.0.0.1:4000",
        headers: { "x-druzhok-edge": process.env.DRUZHOK_EDGE_SECRET ?? "" },
      },
    },
  },
})
