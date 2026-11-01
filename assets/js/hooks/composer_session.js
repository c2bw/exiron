const storageKey = "exiron:composer:last-destination"
const warning = "Leave this page? Your unsent message will be lost."

// Install before LiveSocket binds history navigation. A hook registered later
// can otherwise run after LiveView has already replaced the composer.
let activeComposer = null
window.addEventListener("popstate", event => activeComposer?.onPopState(event), true)

export default {
  mounted() {
    activeComposer = this
    this.dirty = false
    this.hasAttachment = false
    this.leaving = false
    this.captureLocation = () => {
      if (window.location.pathname === "/compose") {
        this.composerURL = window.location.href
        this.composerState = window.history.state
      }
    }
    this.captureLocation()
    this.beforeUnload = event => {
      if (this.dirty && !this.leaving) {
        event.preventDefault()
        event.returnValue = ""
      }
    }
    this.allowLeave = () => {
      this.leaving = true
      clearTimeout(this.leaveTimer)
      this.leaveTimer = setTimeout(() => { this.leaving = false }, 1000)
    }
    this.setDirty = dirty => {
      this.dirty = dirty
      window.removeEventListener("beforeunload", this.beforeUnload)
      if (dirty) window.addEventListener("beforeunload", this.beforeUnload)
    }
    this.onInput = event => {
      if (event.target.id === "composer-text" || event.target.matches?.("[data-composer-upload]")) {
        if (event.target.matches?.("[data-composer-upload]")) this.hasAttachment = event.target.files.length > 0
        this.captureLocation()
        this.setDirty(Boolean(document.getElementById("composer-text")?.value) || this.hasAttachment)
      }
    }
    this.onClick = event => {
      const link = event.target.closest?.("a[href]")
      if (!this.dirty || this.leaving || !link || event.defaultPrevented || event.button !== 0 ||
          event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || link.hasAttribute("download") ||
          (link.target && link.target !== "_self")) return
      const target = new URL(link.href, window.location.href)
      if (target.origin === location.origin && target.pathname === location.pathname && target.search === location.search) return
      if (window.confirm(warning)) {
        this.allowLeave()
      } else {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    }
    this.onPopState = event => {
      if (!this.dirty || this.leaving) return
      if (window.confirm(warning)) {
        this.allowLeave()
      } else {
        event.stopImmediatePropagation()
        // Keep the composer mounted; the LiveView popstate handler must not run.
        window.history.pushState(this.composerState, "", this.composerURL)
      }
    }
    document.addEventListener("input", this.onInput, true)
    document.addEventListener("change", this.onInput, true)
    document.addEventListener("click", this.onClick, true)
    window.addEventListener("phx:navigate", this.captureLocation)
    this.handleEvent("composer_destination", ({target}) => {
      try {
        if (target) sessionStorage.setItem(storageKey, target)
        else sessionStorage.removeItem(storageKey)
      } catch (_error) { /* Storage may be disabled; selection still works. */ }
    })
    this.handleEvent("composer_attachment", ({present}) => {
      this.hasAttachment = present
      this.setDirty(Boolean(document.getElementById("composer-text")?.value) || present)
    })
    this.handleEvent("composer_sent", () => { this.hasAttachment = false; this.setDirty(false) })
    const text = document.getElementById("composer-text")
    this.setDirty(Boolean(text?.value))
    try {
      const target = sessionStorage.getItem(storageKey)
      if (target) this.pushEvent("restore_destination", {target})
    } catch (_error) { /* Session memory is optional. */ }
  },
  destroyed() {
    if (activeComposer === this) activeComposer = null
    clearTimeout(this.leaveTimer)
    window.removeEventListener("beforeunload", this.beforeUnload)
    window.removeEventListener("phx:navigate", this.captureLocation)
    document.removeEventListener("input", this.onInput, true)
    document.removeEventListener("change", this.onInput, true)
    document.removeEventListener("click", this.onClick, true)
  },
}
