// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      let text = this.el.dataset.text
      let ta = document.createElement("textarea")
      ta.value = text
      ta.style.position = "fixed"
      ta.style.opacity = "0"
      document.body.appendChild(ta)
      ta.select()
      document.execCommand("copy")
      document.body.removeChild(ta)
      let orig = this.el.innerText
      this.el.innerText = "Copied!"
      setTimeout(() => { this.el.innerText = orig }, 1500)
    })
  }
}

Hooks.CmdK = {
  mounted() {
    this._onKey = (e) => {
      const mod = e.metaKey || e.ctrlKey
      if (mod && (e.key === "k" || e.key === "K")) {
        e.preventDefault()
        this.pushEvent("toggle_palette", {})
      } else if (e.key === "Escape") {
        this.pushEvent("close_palette", {})
      }
    }
    window.addEventListener("keydown", this._onKey)
  },
  destroyed() {
    window.removeEventListener("keydown", this._onKey)
  }
}

Hooks.PaletteInput = {
  mounted() {
    // Focus the palette input and handle arrow/enter navigation locally
    setTimeout(() => this.el.focus(), 20)
    this._onKey = (e) => {
      if (e.key === "ArrowDown") {
        e.preventDefault()
        this.pushEvent("palette_move", {dir: 1})
      } else if (e.key === "ArrowUp") {
        e.preventDefault()
        this.pushEvent("palette_move", {dir: -1})
      } else if (e.key === "Enter") {
        e.preventDefault()
        this.pushEvent("palette_select", {})
      }
    }
    this.el.addEventListener("keydown", this._onKey)
  },
  destroyed() {
    this.el.removeEventListener("keydown", this._onKey)
  }
}

Hooks.FileEditor = {
  mounted() {
    const target = this.el.dataset.target
    const push = (event, payload) =>
      target ? this.pushEventTo(target, event, payload) : this.pushEvent(event, payload)

    this.handleEvent("request_file_content", () => {
      push("do_save_file", {content: this.el.value})
    })
    this.el.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "s") {
        e.preventDefault()
        push("do_save_file", {content: this.el.value})
      }
      if (e.key === "Tab") {
        e.preventDefault()
        let start = this.el.selectionStart
        let end = this.el.selectionEnd
        this.el.value = this.el.value.substring(0, start) + "  " + this.el.value.substring(end)
        this.el.selectionStart = this.el.selectionEnd = start + 2
      }
    })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#FD4F00"}, shadowColor: "rgba(253, 79, 0, .35)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

