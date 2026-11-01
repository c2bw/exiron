import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/exiron"
import topbar from "../vendor/topbar"
import RequestActivityScroll from "./hooks/request_activity_scroll"
import ComposerSession from "./hooks/composer_session"

const startThemeControls = () => {
  try {
    const prefersDark = matchMedia("(prefers-color-scheme: dark)")
    const systemTheme = () => prefersDark.matches ? "dark" : "light"

    const storedTheme = () => {
      try {
        return localStorage.getItem("phx:theme")
      } catch (_error) {
        return null
      }
    }

    const setStoredTheme = (theme) => {
      try {
        if (theme === "system") {
          localStorage.removeItem("phx:theme")
        } else {
          localStorage.setItem("phx:theme", theme)
        }
      } catch (_error) {
        // Browser privacy settings can disable storage; the DOM theme still updates.
      }
    }

    const setTheme = (theme) => {
      if (theme === "system") {
        setStoredTheme("system")
        document.documentElement.setAttribute("data-theme", systemTheme())
        document.documentElement.setAttribute("data-theme-source", "system")
      } else {
        setStoredTheme(theme)
        document.documentElement.setAttribute("data-theme", theme)
        document.documentElement.setAttribute("data-theme-source", "user")
      }
    }

    if (!document.documentElement.hasAttribute("data-theme")) {
      setTheme(storedTheme() || "system")
    }

    window.addEventListener("storage", e => e.key === "phx:theme" && setTheme(e.newValue || "system"))
    window.addEventListener("phx:set-theme", e => setTheme(e.target.dataset.phxTheme))

    prefersDark.addEventListener("change", _e => {
      if (document.documentElement.getAttribute("data-theme-source") === "system") {
        document.documentElement.setAttribute("data-theme", systemTheme())
      }
    })
  } catch (_error) {
    document.documentElement.setAttribute("data-theme", "light")
    document.documentElement.setAttribute("data-theme-source", "system")
  }
}

startThemeControls()

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, RequestActivityScroll, ComposerSession},
})

topbar.config({barColors: {0: "#4ade80"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
