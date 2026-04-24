import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const assetsRoot = dirname(fileURLToPath(import.meta.url))
const appRoot = resolve(assetsRoot, "..")
const mixEnv = process.env.MIX_ENV || "dev"
const mixBuildPath = process.env.MIX_BUILD_PATH || resolve(appRoot, "_build", mixEnv)
const vitePort = parsePort(process.env.VITE_PORT || "5173")

function parsePort(raw) {
  const port = Number.parseInt(raw, 10)

  if (Number.isNaN(port) || String(port) !== raw || port < 1 || port > 65535) {
    throw new Error(`Invalid VITE_PORT: ${raw}`)
  }

  return port
}

function phoenixPlugin({ pattern } = {}) {
  return {
    name: "bullx-phoenix-vite",
    handleHotUpdate({ file, modules }) {
      if (!pattern || !file.match(pattern)) return

      return [...modules].flatMap(module => {
        if (module.file === file) return [...module.importers]
        return [module]
      })
    },
    configureServer() {
      process.stdin.resume()
    },
  }
}

export default defineConfig({
  root: assetsRoot,
  cacheDir: resolve(appRoot, "node_modules/.vite"),
  server: {
    host: "127.0.0.1",
    port: vitePort,
    strictPort: true,
    cors: {
      origin: ["http://localhost:4000", "http://127.0.0.1:4000"],
    },
    fs: {
      allow: [appRoot, mixBuildPath],
    },
  },
  optimizeDeps: {
    include: ["phoenix", "phoenix_html", "phoenix_live_view"],
  },
  build: {
    manifest: true,
    outDir: "../priv/static/assets",
    emptyOutDir: true,
    rollupOptions: {
      input: [resolve(assetsRoot, "js/app.jsx"), resolve(assetsRoot, "css/app.css")],
      output: {
        entryFileNames: "js/[name]-[hash].js",
        chunkFileNames: "js/[name]-[hash].js",
        assetFileNames: assetInfo => {
          if (assetInfo.name?.endsWith(".css")) return "css/[name]-[hash][extname]"
          return "assets/[name]-[hash][extname]"
        },
      },
    },
  },
  resolve: {
    alias: {
      "@": resolve(assetsRoot, "js"),
      phoenix: resolve(appRoot, "deps/phoenix/priv/static/phoenix.mjs"),
      phoenix_html: resolve(appRoot, "deps/phoenix_html/priv/static/phoenix_html.js"),
      phoenix_live_view: resolve(
        appRoot,
        "deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js",
      ),
      "phoenix-colocated": resolve(mixBuildPath, "phoenix-colocated"),
    },
  },
  plugins: [
    react(),
    tailwindcss(),
    phoenixPlugin({
      pattern: /\.(ex|heex)$/,
    }),
  ],
})
