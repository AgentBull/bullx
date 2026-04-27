import type { StorybookConfig } from "storybook-react-rsbuild"

const config: StorybookConfig = {
  framework: {
    name: "storybook-react-rsbuild",
    options: {
      builder: {
        rsbuildConfigPath: ".storybook/rsbuild.config.ts",
      },
    },
  },
  stories: ["../webui/src/uikit/stories/**/*.stories.@(ts|tsx)"],
  addons: ["@storybook/addon-docs", "@storybook/addon-themes"],
  typescript: {
    reactDocgen: "react-docgen",
  },
}

export default config
