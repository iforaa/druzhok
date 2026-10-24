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
  openLink(url: string): void
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
  return () => button.offClick(onBack)
}
