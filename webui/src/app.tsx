import React from "react"
import { createInertiaApp } from "@inertiajs/react"
import { createRoot } from "react-dom/client"
import { BullXI18nextProvider } from "./i18n/provider"

const inertiaElement = document.getElementById("app")
const inertiaPage = initialInertiaPage(inertiaElement)
const pages = import.meta.webpackContext("./apps", {
  recursive: true,
  regExp: /\.jsx$/,
  mode: "lazy",
})

if (inertiaPage) {
  createInertiaApp({
    page: inertiaPage,
    http: { xsrfHeaderName: "x-csrf-token" },
    title: title => title ? `${title} · BullX` : "BullX",
    resolve: async name => {
      const path = `./${name}.jsx`

      if (!pages.keys().includes(path)) {
        throw new Error(`Unknown Inertia page: ${name}`)
      }

      return await pages(path)
    },
    setup({ App, el, props }) {
      createRoot(el).render(
        <BullXI18nextProvider>
          <App {...props} />
        </BullXI18nextProvider>,
      )
    },
  })
}

function initialInertiaPage(element) {
  const json = document.querySelector('script[data-page="app"][type="application/json"]')?.textContent
    || element?.dataset.page

  return json ? JSON.parse(json) : null
}
