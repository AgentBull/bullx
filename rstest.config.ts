import { withRsbuildConfig } from "@rstest/adapter-rsbuild"
import { defineConfig } from "@rstest/core"

export default defineConfig({
  extends: withRsbuildConfig(),
  include: ["webui/src/**/*.test.{ts,tsx,js,jsx}"],
  testEnvironment: "happy-dom",
})
