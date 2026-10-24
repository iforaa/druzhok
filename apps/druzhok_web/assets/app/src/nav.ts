// The panel's four tabs, and how a screen sends the owner to another tab or
// to one of its sub-screens (Главная's buttons do).

export type Tab = "home" | "memory" | "billing" | "more"

export type Go = (tab: Tab, screen?: string) => void
