import { useEffect, useLayoutEffect, useRef, useState } from "react"
import { api, cached, panelApi, type Bot, type Files, type Me } from "./api"
import { backButton, closePanel, openTelegram } from "./telegram"
import { initials, plural } from "./format"
import { Row, useLoad } from "./ui"
import { planLine } from "./billing"
import { MemoryList, MemoryView, type MemoryScreen } from "./memory"
import Invites from "./invites"
import type { Go } from "./nav"

// Бот: who the bot is and whether it is up, what is left of its plan in one
// line into Счёт, what is left to set up, what it knows and can do, what to try,
// invites and support. Each part loads on its own, so ruoc being slow does not
// hide the bot, and a bot whose files cannot be read still shows its plan.

const stateText: Record<Bot["state"], [string, string]> = {
  awake: ["работает", "Отвечает сразу."],
  asleep: ["спит", "Проснётся от первого сообщения, это занимает несколько секунд."],
  starting: ["запускается", "Будет готов через несколько секунд."],
  stopped: ["остановлен", "Бот сейчас не отвечает. Напишите в поддержку."],
  error: ["не запустился", "Бот сейчас не отвечает. Мы уже знаем об этом."],
}

export function botTitle(bot: Bot): string {
  return bot.title ?? (bot.username ? `@${bot.username}` : bot.name)
}

interface Step {
  id: string
  title: string
  done: boolean
  hint: string
  action: { label: string; run: () => void }
}

function steps(bot: Bot, files: Files | null, me: Me | null, go: Go): Step[] {
  const chat = { label: "Написать боту", run: closePanel }
  const list: Step[] = [
    {
      id: "receipt",
      title: "Почта для чеков",
      done: !!me?.receipt.verified,
      hint: "На неё придут чеки, когда будете оплачивать тариф.",
      action: { label: "Указать почту", run: () => go("billing", "receipt") },
    },
    {
      id: "user",
      title: "Расскажите о себе",
      done: !!files?.user,
      hint: "Напишите боту, чем занимаетесь и что вам интересно, — он запомнит и будет отвечать точнее.",
      action: chat,
    },
    {
      id: "job",
      title: "Первое напоминание",
      done: !!files && files.jobs.count > 0,
      hint: "Попросите: «Каждое утро в 9 присылай мне погоду и планы на день».",
      action: chat,
    },
  ]
  if (bot.settings.website_hosting_enabled)
    list.push({
      id: "site",
      title: "Свой сайт",
      done: !!files?.site?.files,
      hint: "Попросите: «Сделай мне сайт-визитку».",
      action: chat,
    })
  return list
}

/** What to try: one line, naming only what this bot has switched on. */
function tryLine(bot: Bot): string {
  const s = bot.settings
  const asks = [
    "отправить голосовое",
    s.image_gen_enabled ? "попросить «нарисуй кота-космонавта»" : null,
    s.website_hosting_enabled ? "попросить сделать страницу, бот её опубликует" : null,
  ].filter((a): a is string => a !== null)
  const last = asks.pop()!
  return `Можно ${asks.length ? `${asks.join(", ")} или ${last}` : last}.`
}

type Screen = { kind: "main" } | { kind: "invites" } | MemoryScreen

export default function Home({ bot, go }: { bot: Bot; go: Go }) {
  const files = useLoad(() => cached("files", panelApi.files))
  const me = useLoad(() => cached("me", api.me))
  const [screen, setScreen] = useState<Screen>({ kind: "main" })

  // Coming back from a detail returns to the same place in the list, so the
  // next row is one tap away. Before paint, so the page does not jump.
  const mainY = useRef(0)
  const open = (next: Screen) => {
    if (screen.kind === "main") mainY.current = window.scrollY
    setScreen(next)
  }
  useLayoutEffect(() => {
    window.scrollTo(0, screen.kind === "main" ? mainY.current : 0)
  }, [screen])

  useEffect(() => {
    return backButton(
      screen.kind === "main"
        ? null
        : () => setScreen(screen.kind === "text" && screen.back ? screen.back : { kind: "main" }),
    )
  }, [screen])

  if (screen.kind === "invites") return <Invites />
  if (screen.kind !== "main") return <MemoryView screen={screen} open={open} />

  const list = steps(bot, files.data, me.data, go)
  const left = list.filter((s) => !s.done)
  const known = files.data !== null && me.data !== null
  const [state, stateHint] = stateText[bot.state]
  const title = botTitle(bot)
  const plan = me.data ? planLine(me.data) : null

  return (
    <>
      <header className="bot-head">
        <span className="avatar" aria-hidden="true">
          {initials(title)}
        </span>
        <div className="bot-head__text">
          <h1 className="hero__name">{title}</h1>
          {bot.username && bot.title ? <p className="hero__handle">@{bot.username}</p> : null}
        </div>
        <span className={`chip chip--${bot.state}`}>{state}</span>
      </header>
      <p className="hint">{stateHint}</p>

      <div className="group">
        {plan ? (
          <Row icon="card" tone="blue" title={plan.title} sub={plan.sub} onClick={() => go("billing")} />
        ) : me.error ? (
          <Row icon="card" tone="grey" title="Тариф сейчас не загрузился" onClick={() => go("billing")} />
        ) : (
          <div className="skeleton__line" aria-busy="true" />
        )}
      </div>

      {known && left.length > 0 ? (
        <>
          <span className="label">
            Настройка · {left.length === 1 ? "остался 1 шаг" : `осталось ${left.length} ${plural(left.length, "шаг", "шага", "шагов")}`}
          </span>
          {left.map((s) => (
            <section key={s.id} className="step">
              <div className="step__body">
                <p className="step__title">{s.title}</p>
                <p className="hint">{s.hint}</p>
                <button className="secondary secondary--small" onClick={s.action.run}>
                  {s.action.label}
                </button>
              </div>
            </section>
          ))}
        </>
      ) : null}

      <MemoryList files={files.data} error={files.error} reload={files.reload} open={open} />
      <p className="hint">{tryLine(bot)}</p>

      <div className="group">
        <Row icon="gift" tone="pink" title="Пригласить друга" sub="Друг сможет создать своего бота" onClick={() => open({ kind: "invites" })} />
        {bot.support_url ? (
          <Row icon="chat" tone="blue" title="Поддержка" sub="Ответим в Telegram" onClick={() => openTelegram(bot.support_url!)} />
        ) : null}
      </div>
    </>
  )
}
