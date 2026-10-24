// The part of Telegram's WebApp object the cabinet uses. telegram-web-app.js
// puts it on window before the app loads; outside Telegram it is there but
// empty, and initData is "".

interface BackButton {
  show(): void
  hide(): void
  onClick(cb: () => void): void
  offClick(cb: () => void): void
}

interface WebApp {
  initData: string
  colorScheme?: "light" | "dark"
  ready(): void
  expand(): void
  close?(): void
  openLink(url: string): void
  openTelegramLink?(url: string): void
  setHeaderColor?(color: string): void
  setBackgroundColor?(color: string): void
  setBottomBarColor?(color: string): void
  onEvent?(event: string, cb: () => void): void
  BackButton: BackButton
}

declare global {
  interface Window {
    Telegram?: { WebApp?: WebApp }
  }
}

export function webApp(): WebApp | undefined {
  return window.Telegram?.WebApp
}

/** The signed init data, or "" outside Telegram. */
export function initData(): string {
  return webApp()?.initData ?? ""
}

/** The bot the cabinet was opened from, from ?bot= in its address. */
export function botID(): string {
  const id = new URLSearchParams(window.location.search).get("bot") ?? ""
  return /^\d{1,20}$/.test(id) ? id : ""
}

/**
 * Opens the bank's page in the system browser. Telegram honours this only
 * during a tap, so it is called from a button's own click. False when it
 * could not: the page then shows the link to tap or copy.
 */
export function openExternal(url: string): boolean {
  const app = webApp()
  if (!app?.openLink) return false
  try {
    app.openLink(url)
    return true
  } catch {
    return false
  }
}

/** Shows Telegram's back button while a sub-screen is open. */
export function backButton(onBack: (() => void) | null): () => void {
  const button = webApp()?.BackButton
  if (!button) return () => {}
  if (!onBack) {
    button.hide()
    return () => {}
  }
  button.show()
  button.onClick(onBack)
  // Hidden on the way out too: switching tabs unmounts a sub-screen, and a
  // Back button left showing would do nothing.
  return () => {
    button.offClick(onBack)
    button.hide()
  }
}

/**
 * The panel wears its own colours, light or dark as the owner's Telegram is,
 * and asks Telegram to paint its header and background to match so the page
 * does not sit in a frame of another colour.
 */
export function applyTheme() {
  const app = webApp()
  const paint = () => {
    const scheme = app?.colorScheme === "light" ? "light" : "dark"
    document.documentElement.dataset.theme = scheme
    const bg = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim()
    if (!bg) return
    try {
      app?.setHeaderColor?.(bg)
      app?.setBackgroundColor?.(bg)
      app?.setBottomBarColor?.(bg)
    } catch {
      // An old client without these: the frame keeps Telegram's colour.
    }
  }
  paint()
  app?.onEvent?.("themeChanged", paint)
}

/** Opens a t.me link inside Telegram (a share sheet, a chat), else outside. */
export function openTelegram(url: string): boolean {
  const app = webApp()
  try {
    if (app?.openTelegramLink && url.startsWith("https://t.me/")) {
      app.openTelegramLink(url)
      return true
    }
  } catch {
    // fall through to an ordinary link
  }
  return openExternal(url)
}

/** Closes the panel, back to the chat with the bot. */
export function closePanel() {
  webApp()?.close?.()
}
