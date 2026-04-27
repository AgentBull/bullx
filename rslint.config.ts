import { defineConfig, ts } from "@rslint/core"

export default defineConfig([
  {
    ignores: [
      "**/_build/**",
      "**/deps/**",
      "**/node_modules/**",
      "**/priv/static/**",
      "**/tmp/**",
    ],
  },
  ts.configs.recommended,
])
