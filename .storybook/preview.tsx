import type { Preview } from "@storybook/react"
import { withThemeByDataAttribute } from "@storybook/addon-themes"

import "@fontsource-variable/geist/index.css"
import "@/globals.css"

import { Toaster } from "@/uikit/components/sonner"
import { TooltipProvider } from "@/uikit/components/tooltip"

const preview: Preview = {
  parameters: {
    layout: "centered",
    controls: {
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/i,
      },
    },
    backgrounds: {
      options: {
        light: { name: "Light", value: "var(--color-white)" },
        dark: { name: "Dark", value: "var(--color-black)" },
      },
    },
    options: {
      storySort: {
        order: ["Foundations", ["Colors"], "Components", "*"],
      },
    },
  },
  decorators: [
    withThemeByDataAttribute({
      themes: { light: "light", dark: "dark" },
      defaultTheme: "light",
      attributeName: "data-theme",
    }),
    (Story) => (
      <TooltipProvider>
        <div className="bg-background text-foreground p-6 font-sans">
          <Story />
        </div>
        <Toaster />
      </TooltipProvider>
    ),
  ],
}

export default preview
