import "vite/modulepreload-polyfill"

// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"

import React from "react"
import axios from "axios"
import { createInertiaApp } from "@inertiajs/react"
import { createRoot } from "react-dom/client"
import { BullXI18nextProvider } from "./i18n/provider"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const pages = import.meta.glob("./spas/**/*.jsx")
const liveViewSelector = "[data-phx-main], [data-phx-session]"

axios.defaults.xsrfHeaderName = "x-csrf-token"

if (csrfToken) {
  axios.defaults.headers.common["x-csrf-token"] = csrfToken
}

createInertiaApp({
  title: title => title ? `${title} · BullX` : "BullX",
  resolve: async name => {
    const page = pages[`./spas/${name}.jsx`]

    if (!page) {
      throw new Error(`Unknown Inertia page: ${name}`)
    }

    return await page()
  },
  setup({ App, el, props }) {
    createRoot(el).render(
      <BullXI18nextProvider>
        <App {...props} />
      </BullXI18nextProvider>,
    )
  },
})

if (document.querySelector(liveViewSelector)) {
  setupLiveView()
}

async function setupLiveView() {
  const [{ Socket }, { LiveSocket }, colocated, { default: topbar }] = await Promise.all([
    import("phoenix"),
    import("phoenix_live_view"),
    import("phoenix-colocated/bullx"),
    import("../vendor/topbar"),
  ])

  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: csrfToken },
    hooks: { ...(colocated.hooks || {}) },
  })

  topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })
  window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
  window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

  liveSocket.connect()
  window.liveSocket = liveSocket

  if (import.meta.env.DEV) {
    setupLiveReloader()
  }
}

function setupLiveReloader() {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if (keyDown === "c") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if (keyDown === "d") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
