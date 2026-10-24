import { useCallback, useEffect, useState } from "react"
import { explain, panelApi, setBillingBase, type Bot } from "./api"
import { applyTheme, initData, webApp } from "./telegram"
import { Icon, Skeleton } from "./ui"
import type { Tab } from "./nav"
import Home from "./home"
import Memory from "./memory"
import Billing from "./billing"
import More from "./more"

// The bot panel: what a bot's owner sees inside Telegram (druzhok spec
// docs/superpowers/specs/2026-10-24-bot-panel-design.md). Four tabs:
// Главная (the bot, what is left of its plan, setup and shortcuts), Память
// (what it knows and can do, read only), Счёт (the plan, its limits, plans
// and payments, served by ruoc-gateway) and Ещё (settings, access, invites,
// support).

const tabs: [Tab, string, string][] = [
  ["home", "Главная", "home"],
  ["memory", "Память", "spark"],
  ["billing", "Счёт", "wallet"],
  ["more", "Ещё", "more"],
]

// ?tab= opens a tab directly: the out-of-money notice sends tab=billing, and
// buttons made before the rename may still say tab=files.
function startTab(): Tab {
  const t = new URLSearchParams(window.location.search).get("tab")
  if (t === "billing" || t === "memory" || t === "more") return t
  if (t === "files") return "memory"
  return "home"
}

export default function App() {
  const [bot, setBot] = useState<Bot | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  // `n` remounts the tab, so going to a sub-screen from elsewhere starts it fresh.
  const [nav, setNav] = useState<{ tab: Tab; screen?: string; n: number }>({ tab: startTab(), n: 0 })

  useEffect(() => {
    applyTheme()
    webApp()?.ready()
    webApp()?.expand()
    if (!initData()) {
      setFailure("Откройте кабинет кнопкой «Кабинет» в чате с ботом.")
      return
    }
    panelApi.bot().then(
      (b) => {
        setBillingBase(b.billing_url)
        setBot(b)
      },
      (err) => setFailure(explain(err)),
    )
  }, [])

  const go = useCallback((tab: Tab, screen?: string) => {
    setNav((cur) => ({ tab, screen, n: cur.n + 1 }))
    window.scrollTo(0, 0)
  }, [])

  if (failure)
    return (
      <main className="app">
        <p className="notice">{failure}</p>
      </main>
    )

  return (
    <>
      <main className="app app--tabs">
        {!bot ? (
          <Skeleton hero rows={4} />
        ) : (
          <div key={nav.n} className="screen">
            {nav.tab === "home" && <Home bot={bot} go={go} />}
            {nav.tab === "memory" && <Memory start={nav.screen} />}
            {nav.tab === "billing" && <Billing start={nav.screen} />}
            {nav.tab === "more" && <More bot={bot} start={nav.screen} />}
          </div>
        )}
      </main>
      <nav className="tabbar" aria-label="Разделы">
        {tabs.map(([id, label, icon]) => (
          <button
            key={id}
            className={nav.tab === id ? "tabbar__tab tabbar__tab--on" : "tabbar__tab"}
            aria-current={nav.tab === id ? "page" : undefined}
            onClick={() => go(id)}
          >
            <Icon name={icon} size={24} />
            <span>{label}</span>
          </button>
        ))}
      </nav>
    </>
  )
}
