// The panel's four tabs, and how a screen sends the owner to another tab or
// to one of its sub-screens.

export type Tab = "home" | "billing" | "support" | "settings"

export type Go = (tab: Tab, screen?: string) => void
