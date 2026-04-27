import { defineConfig } from "@rsbuild/core"
import { pluginReact } from "@rsbuild/plugin-react"
import tailwindcss from "@tailwindcss/postcss"
import toml from "@iarna/toml"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const webuiRoot = resolve(projectRoot, "webui/src")

function tomlPlugin() {
  return {
    name: "bullx-toml",
    setup(api: { transform: (...args: unknown[]) => void }) {
      api.transform({ test: /\.toml$/ }, ({ code }: { code: string }) => ({
        code: `export default ${JSON.stringify(toml.parse(code))}`,
        map: null,
      }))
    },
  }
}

export default defineConfig({
  resolve: {
    alias: {
      "@": webuiRoot,
      "@locales": resolve(projectRoot, "priv/locales/client"),
    },
  },
  tools: {
    postcss(_options, { addPlugins }) {
      addPlugins(tailwindcss())
    },
  },
  plugins: [
    pluginReact({
      swcReactOptions: { runtime: "automatic" },
    }),
    tomlPlugin(),
  ],
})
