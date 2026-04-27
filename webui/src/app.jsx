import React from "react"
import axios from "axios"
import { createInertiaApp } from "@inertiajs/react"
import { createRoot } from "react-dom/client"
import { BullXI18nextProvider } from "./i18n/provider"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const inertiaElement = document.getElementById("app")
const inertiaPage = initialInertiaPage(inertiaElement)
const pages = import.meta.webpackContext("./spas", {
  recursive: true,
  regExp: /\.jsx$/,
  mode: "lazy",
})

axios.defaults.xsrfHeaderName = "x-csrf-token"

if (csrfToken) {
  axios.defaults.headers.common["x-csrf-token"] = csrfToken
}

if (inertiaPage) {
  createInertiaApp({
    page: inertiaPage,
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
