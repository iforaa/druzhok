import { useEffect, useState } from "react"
import { api, cached, panelApi, type Bot, type Files, type Me } from "./api"
import { backButton, closePanel, openTelegram } from "./telegram"
import { initials, plural } from "./format"
import { Icon, Meter, Money, Ring, useLoad } from "./ui"
import { periodNote } from "./billing"
import type { Go } from "./nav"

// Главная: who the bot is and whether it is up, the balance as the one big
// figure, what is left to set up, four shortcuts, tips, and the limits at a
// glance. Each part loads on its own, so ruoc being slow does not hide the
// bot, and a bot whose files cannot be read still shows its balance.

const stateText: Record<Bot["state"], [string, string]> = {
  awake: ["работает", "Отвечает сразу."],
  asleep: ["спит", "Проснётся от первого сообщения, это занимает несколько секунд."],
  starting: ["запускается", "Будет готов через несколько секунд."],
  stopped: ["остановлен", "Бот сейчас не отвечает. Напишите в поддержку."],
  error: ["не запустился", "Бот сейчас не отвечает. Мы уже знаем об этом."],
}

// "Оплачен до…" reads "оплачен до…" after the plan's name; a plan name inside stays as written.
const lowerFirst = (s: string) => s.charAt(0).toLowerCase() + s.slice(1)

export function botTitle(bot: Bot): string {
  return bot.title ?? (bot.username ? `@${bot.username}` : bot.name)
}

interface Step {
  id: string
  title: string
  done: boolean
  hint: string
  action?: { label: string; run: () => void }
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

interface Tip {
  id: string
  title: string
  text: string
}

function tips(bot: Bot): Tip[] {
  const s = bot.settings
  const all: (Tip | null)[] = [
    s.image_gen_enabled
      ? { id: "draw", title: "Бот умеет рисовать", text: "Попросите: «нарисуй кота-космонавта»." }
      : null,
    { id: "voice", title: "Можно голосом", text: "Отправьте голосовое — бот его поймёт." },
    s.memory_provider === "mnemosyne"
      ? { id: "memory", title: "Бот помнит важное", text: "Что он знает о вас — во вкладке «Память»." }
      : null,
    s.website_hosting_enabled
      ? { id: "site", title: "Сайт за минуту", text: "Попросите бота сделать страницу — он её опубликует." }
      : null,
  ]
  return all.filter((t): t is Tip => t !== null)
}

const TIPS_KEY = "panel.tips.hidden"

function tipsHidden(): boolean {
  try {
    return window.localStorage.getItem(TIPS_KEY) === "1"
  } catch {
    return false
  }
}

export default function Home({ bot, go }: { bot: Bot; go: Go }) {
  const files = useLoad(() => cached("files", panelApi.files))
  const me = useLoad(() => cached("me", api.me))
  const [screen, setScreen] = useState<"main" | "setup">("main")

  useEffect(() => backButton(screen === "main" ? null : () => setScreen("main")), [screen])

  const list = steps(bot, files.data, me.data, go)
  const done = list.filter((s) => s.done).length
  const known = files.data !== null && me.data !== null

  if (screen === "setup") return <Setup list={list} />

  const [state, stateHint] = stateText[bot.state]
  const title = botTitle(bot)

  return (
    <>
      <header className="topbar">
        <span className="avatar" aria-hidden="true">
          {initials(title)}
        </span>
        <button className="round-button" aria-label="Пригласить друга" onClick={() => go("more", "invites")}>
          <Icon name="gift" />
        </button>
      </header>

      <section className="hero">
        <h1 className="hero__name">{title}</h1>
        {bot.username && bot.title ? <p className="hero__handle">@{bot.username}</p> : null}
        <span className={`chip chip--${bot.state}`}>{state}</span>
        <p className="hero__hint">{stateHint}</p>

        <p className="hero__label">Баланс</p>
        {me.data ? (
          <>
            <Money nanorub={me.data.balance_nanorub} />
            {me.data.subscription ? (
              <p className="hero__sub">
                {me.data.subscription.plan_name} · {lowerFirst(periodNote(me.data.subscription))}
              </p>
            ) : (
              <p className="hero__sub">Тариф не выбран</p>
            )}
          </>
        ) : me.error ? (
          <p className="hero__sub">Счёт сейчас не загрузился</p>
        ) : (
          <div className="skeleton__money" />
        )}
      </section>

      {known && done < list.length ? (
        <button className="setup" onClick={() => setScreen("setup")}>
          <Ring done={done} total={list.length} />
          <span className="setup__text">
            <span className="setup__title">Настройка бота</span>
            <span className="setup__sub">
              {list.length - done === 1
                ? "остался 1 шаг"
                : `осталось ${list.length - done} ${plural(list.length - done, "шаг", "шага", "шагов")}`}
            </span>
          </span>
          <Icon name="chevron" size={20} />
        </button>
      ) : null}

      <div className="actions">
        <Action icon="plus" label="Пополнить" onClick={() => go("billing", "plans")} />
        <Action icon="spark" label="Память" onClick={() => go("memory")} />
        <Action icon="gift" label="Пригласить" onClick={() => go("more", "invites")} />
        {bot.support_url ? (
          <Action icon="chat" label="Поддержка" onClick={() => openTelegram(bot.support_url!)} />
        ) : (
          <Action icon="puzzle" label="Навыки" onClick={() => go("memory", "skills")} />
        )}
      </div>

      <Tips list={tips(bot)} />

      {me.data?.limits ? (
        <button className="card card--button" onClick={() => go("billing")}>
          <span className="card__head">
            <span className="label">Лимиты тарифа</span>
            <Icon name="chevron" size={18} />
          </span>
          <Meter title="За 5 часов" used={me.data.limits.session.used_percent} resets={me.data.limits.session.resets_at} idle="Начнётся с первого сообщения" />
          <Meter title="За неделю" used={me.data.limits.weekly.used_percent} resets={me.data.limits.weekly.resets_at} idle="Начнётся с первого сообщения" />
        </button>
      ) : null}
    </>
  )
}

function Action({ icon, label, onClick }: { icon: string; label: string; onClick: () => void }) {
  return (
    <button className="action" onClick={onClick}>
      <span className="action__icon">
        <Icon name={icon} size={20} />
      </span>
      <span>{label}</span>
    </button>
  )
}

function Tips({ list }: { list: Tip[] }) {
  const [hidden, setHidden] = useState(tipsHidden)
  const [index, setIndex] = useState(0)
  if (hidden || list.length === 0) return null

  const hide = () => {
    setHidden(true)
    try {
      window.localStorage.setItem(TIPS_KEY, "1")
    } catch {
      // Private mode: hidden until the panel is reopened.
    }
  }

  return (
    <section className="tips" aria-label="Подсказки">
      <div
        className="tips__track"
        onScroll={(e) => {
          const el = e.currentTarget
          setIndex(Math.round(el.scrollLeft / Math.max(1, el.clientWidth)))
        }}
      >
        {list.map((t) => (
          <article key={t.id} className="tip">
            <p className="tip__title">{t.title}</p>
            <p className="tip__text">{t.text}</p>
          </article>
        ))}
      </div>
      <button className="tips__close" aria-label="Скрыть подсказки" onClick={hide}>
        <Icon name="close" size={16} />
      </button>
      {list.length > 1 ? (
        <div className="tips__dots" aria-hidden="true">
          {list.map((t, i) => (
            <span key={t.id} className={i === index ? "dot dot--on" : "dot"} />
          ))}
        </div>
      ) : null}
    </section>
  )
}

function Setup({ list }: { list: Step[] }) {
  const done = list.filter((s) => s.done).length
  return (
    <>
      <h1 className="screen-title">Настройка бота</h1>
      <p className="hint">
        Готово {done} из {list.length}. Каждый шаг делает бота полезнее.
      </p>
      {list.map((s) => (
        <section key={s.id} className={s.done ? "step step--done" : "step"}>
          <span className="step__mark">{s.done ? <Icon name="check" size={16} /> : null}</span>
          <div className="step__body">
            <p className="step__title">{s.title}</p>
            {!s.done ? (
              <>
                <p className="hint">{s.hint}</p>
                {s.action ? (
                  <button className="secondary secondary--small" onClick={s.action.run}>
                    {s.action.label}
                  </button>
                ) : null}
              </>
            ) : null}
          </div>
        </section>
      ))}
    </>
  )
}
