import { useCallback, useEffect, useRef, useState } from "react"
import {
  api,
  explain,
  fatal,
  panelApi,
  setBillingBase,
  type Bot,
  type Files,
  type Job,
  type Me,
  type Payment,
  type Plan,
  type SiteFile,
  type Skill,
  type Text,
} from "./api"
import { backButton, initData, openExternal, webApp } from "./telegram"
import { count, date, days, plural, rub, size, when } from "./format"
import { render } from "./markdown"

// The bot panel: what a bot's owner sees inside Telegram (druzhok spec
// docs/superpowers/specs/2026-10-24-bot-panel-design.md). Three tabs: the
// bot's state and settings and its files, both read only and served by
// druzhok, and the account, plans and payments, served by ruoc-gateway as
// before the cabinet moved here. A payment takes two taps: one to open it at
// the bank, one to go there, because Telegram opens an outside link only from
// a tap and the bank can take seconds to answer.

type Tab = "bot" | "files" | "billing"
type BillingScreen = "account" | "plans" | "receipt"

const timeFmt = new Intl.DateTimeFormat("ru-RU", { hour: "2-digit", minute: "2-digit" })
// A reset within a day reads as a time, a later one as a date.
const resetAt = (iso: string) => {
  const at = new Date(iso)
  return at.getTime() - Date.now() < 24 * 3600 * 1000 ? `в ${timeFmt.format(at)}` : date(iso)
}

function startTab(): Tab {
  const t = new URLSearchParams(window.location.search).get("tab")
  return t === "billing" || t === "files" ? t : "bot"
}

export default function App() {
  const [bot, setBot] = useState<Bot | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [tab, setTab] = useState<Tab>(startTab)

  useEffect(() => {
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

  if (failure) return <Notice text={failure} />
  if (!bot) return <Notice text="Загрузка…" quiet />

  return (
    <>
      <main className="app app--tabs">
        {tab === "bot" && <BotTab bot={bot} />}
        {tab === "files" && <FilesTab />}
        {tab === "billing" && <Billing />}
      </main>
      <nav className="tabs">
        {(
          [
            ["bot", "Бот"],
            ["files", "Файлы"],
            ["billing", "Счёт"],
          ] as const
        ).map(([id, label]) => (
          <button key={id} className={tab === id ? "tab tab--on" : "tab"} onClick={() => setTab(id)}>
            {label}
          </button>
        ))}
      </nav>
    </>
  )
}

function Notice({ text, quiet }: { text: string; quiet?: boolean }) {
  return (
    <main className="app">
      <p className={quiet ? "notice notice--quiet" : "notice"}>{text}</p>
    </main>
  )
}

// --- Бот ---------------------------------------------------------------------

const stateText: Record<Bot["state"], string> = {
  awake: "не спит",
  asleep: "спит",
  starting: "запускается",
  stopped: "остановлен",
  error: "ошибка запуска",
}

const yes = (b: boolean) => (b ? "вкл" : "выкл")

function BotTab({ bot }: { bot: Bot }) {
  const s = bot.settings
  const rows: [string, string][] = [
    ["Модель", s.model],
    ["Язык", s.language === "ru" ? "русский" : s.language === "en" ? "английский" : s.language],
    ["Часовой пояс", s.timezone],
    ["В группах", s.mention_only ? `только по имени${s.trigger_name ? ` «${s.trigger_name}»` : ""}` : "отвечает всем"],
    ["Сон", s.sleep_enabled ? `через ${s.sleep_idle_minutes} мин без дел` : "выкл"],
    ["Картинки", s.image_gen_enabled ? `вкл${s.image_gen_model ? ` · ${s.image_gen_model}` : ""}` : "выкл"],
    ["Сайт", yes(s.website_hosting_enabled)],
    ["Память", s.memory_provider === "mnemosyne" ? "долгая (Mnemosyne)" : "обычная"],
    ["Общая память группы", yes(s.group_shared_memory)],
  ]
  const a = bot.access
  return (
    <>
      <section className="card">
        <div className="plan__head">
          <h1>{bot.username ? `@${bot.username}` : bot.name}</h1>
          <span className={`badge badge--${bot.state}`}>{stateText[bot.state]}</span>
        </div>
        <p className="hint">Последний запуск: {when(bot.started_at)}</p>
        {bot.start_error && <p className="error">{bot.start_error}</p>}
      </section>

      <section className="card">
        <p className="label">Настройки</p>
        <dl className="rows">
          {rows.map(([k, v]) => (
            <div key={k} className="row">
              <dt>{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>
      </section>

      <section className="card">
        <p className="label">Доступ</p>
        <dl className="rows">
          <div className="row">
            <dt>Писать боту лично</dt>
            <dd>{a.allow_all_users ? "все" : `${a.allowed_users} ${plural(a.allowed_users, "человек", "человека", "человек")}`}</dd>
          </div>
          <div className="row">
            <dt>Чаты без упоминания</dt>
            <dd>{a.free_response_chats}</dd>
          </div>
        </dl>
        <p className="hint">Изменить настройки пока можно только через поддержку.</p>
      </section>
    </>
  )
}

// --- Файлы -------------------------------------------------------------------

type FileScreen =
  | { kind: "list" }
  | { kind: "text"; title: string; load: () => Promise<Text>; back?: FileScreen }
  | { kind: "jobs" }
  | { kind: "skills" }
  | { kind: "site" }

function FilesTab() {
  const [files, setFiles] = useState<Files | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [screen, setScreen] = useState<FileScreen>({ kind: "list" })

  useEffect(() => {
    panelApi.files().then(setFiles, (err) => setError(explain(err)))
  }, [])

  useEffect(
    () =>
      backButton(
        screen.kind === "list"
          ? null
          : () => setScreen(screen.kind === "text" && screen.back ? screen.back : { kind: "list" }),
      ),
    [screen],
  )

  if (screen.kind === "text") return <TextView title={screen.title} load={screen.load} />
  if (screen.kind === "jobs") return <JobsView />
  if (screen.kind === "skills")
    return <SkillsView open={(title, load) => setScreen({ kind: "text", title, load, back: { kind: "skills" } })} />
  if (screen.kind === "site") return <SiteView />

  if (!files) return <p className="notice notice--quiet">{error ?? "Загрузка…"}</p>

  const meta = (m: Files["soul"]) => (m ? `${size(m.size)} · ${when(m.modified_at)}` : "пусто")
  const items: { title: string; sub: string; go: (() => void) | null }[] = [
    {
      title: "Характер",
      sub: meta(files.soul),
      go: files.soul ? () => setScreen({ kind: "text", title: "Характер", load: () => panelApi.file("soul") }) : null,
    },
    {
      title: "Память",
      sub: meta(files.memory),
      go: files.memory ? () => setScreen({ kind: "text", title: "Память", load: () => panelApi.file("memory") }) : null,
    },
    {
      title: "О вас",
      sub: meta(files.user),
      go: files.user ? () => setScreen({ kind: "text", title: "О вас", load: () => panelApi.file("user") }) : null,
    },
    {
      title: "Задачи по расписанию",
      sub: files.jobs.count ? `${files.jobs.count}` : "нет",
      go: files.jobs.count ? () => setScreen({ kind: "jobs" }) : null,
    },
    {
      title: "Навыки",
      sub: `свои: ${files.skills.own} · встроенные: ${files.skills.bundled}`,
      go: files.skills.own ? () => setScreen({ kind: "skills" }) : null,
    },
    {
      title: "Сайт",
      sub: files.site ? `${files.site.files} ${plural(files.site.files, "файл", "файла", "файлов")}` : "нет",
      go: files.site && files.site.files ? () => setScreen({ kind: "site" }) : null,
    },
  ]

  return (
    <>
      <h1 className="screen-title">Файлы</h1>
      {items.map((it) => (
        <button key={it.title} className="item" disabled={!it.go} onClick={() => it.go?.()}>
          <span>{it.title}</span>
          <span className="hint">{it.sub}</span>
        </button>
      ))}
    </>
  )
}

function TextView({ title, load }: { title: string; load: () => Promise<Text> }) {
  const [text, setText] = useState<Text | null>(null)
  const [error, setError] = useState<string | null>(null)
  const box = useRef<HTMLDivElement>(null)

  useEffect(() => {
    load().then(setText, (err) => setError(explain(err)))
  }, [load])

  // Links the bot wrote open outside Telegram, never inside the panel.
  useEffect(() => {
    const el = box.current
    if (!el) return
    const onClick = (e: MouseEvent) => {
      const a = (e.target as Element).closest("a")
      if (!a) return
      e.preventDefault()
      const href = a.getAttribute("href")
      if (href) openExternal(href)
    }
    el.addEventListener("click", onClick)
    return () => el.removeEventListener("click", onClick)
  }, [text])

  return (
    <>
      <h1 className="screen-title">{title}</h1>
      {error && <p className="error">{error}</p>}
      {!text && !error && <p className="notice notice--quiet">Загрузка…</p>}
      {text && (
        <>
          <p className="hint">Изменён {when(text.modified_at)}</p>
          <div ref={box} className="card markdown" dangerouslySetInnerHTML={{ __html: render(text.text) }} />
          {text.truncated && <p className="hint">Файл длинный, показано начало.</p>}
        </>
      )}
    </>
  )
}

const jobState: Record<string, string> = {
  scheduled: "по расписанию",
  paused: "на паузе",
  completed: "выполнена",
  error: "ошибка",
}

function JobsView() {
  const [jobs, setJobs] = useState<Job[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    panelApi.jobs().then(
      (r) => {
        setJobs(r.jobs)
        if (r.error) setError("Файл задач не читается.")
      },
      (err) => setError(explain(err)),
    )
  }, [])

  return (
    <>
      <h1 className="screen-title">Задачи по расписанию</h1>
      {error && <p className="error">{error}</p>}
      {!jobs && !error && <p className="notice notice--quiet">Загрузка…</p>}
      {jobs?.map((j, i) => (
        <section key={i} className="card">
          <div className="plan__head">
            <h2>{j.name}</h2>
            <span className="badge">{jobState[j.state] ?? j.state}</span>
          </div>
          <p className="hint">{j.schedule}</p>
          {j.prompt && j.prompt !== j.name && <p className="prompt">{j.prompt}</p>}
          <p className="hint">
            Следующий запуск: {when(j.next_run_at)} · прошлый: {when(j.last_run_at)}
            {j.last_status ? ` (${j.last_status})` : ""}
          </p>
        </section>
      ))}
    </>
  )
}

function SkillsView({ open }: { open: (title: string, load: () => Promise<Text>) => void }) {
  const [skills, setSkills] = useState<Skill[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    panelApi.skills().then((r) => setSkills(r.skills), (err) => setError(explain(err)))
  }, [])

  return (
    <>
      <h1 className="screen-title">Навыки</h1>
      <p className="hint">Навыки, которые бот создал сам.</p>
      {error && <p className="error">{error}</p>}
      {!skills && !error && <p className="notice notice--quiet">Загрузка…</p>}
      {skills?.map((s) => (
        <button key={s.path.join("/")} className="item" onClick={() => open(s.name, () => panelApi.skill(s))}>
          <span>
            {s.name}
            {s.category ? <span className="hint"> · {s.category}</span> : null}
          </span>
          {s.description && <span className="hint">{s.description}</span>}
        </button>
      ))}
    </>
  )
}

function SiteView() {
  const [files, setFiles] = useState<SiteFile[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    panelApi.site().then((r) => setFiles(r.files ?? []), (err) => setError(explain(err)))
  }, [])

  const sites = files ? Array.from(new Set(files.map((f) => f.site))) : []
  return (
    <>
      <h1 className="screen-title">Сайт</h1>
      {error && <p className="error">{error}</p>}
      {!files && !error && <p className="notice notice--quiet">Загрузка…</p>}
      {sites.map((site) => (
        <section key={site} className="card">
          <h2>{site}</h2>
          <ul className="tree">
            {files!
              .filter((f) => f.site === site && f.type === "file")
              .map((f) => (
                <li key={f.path}>
                  <span>{f.path.slice(site.length + 1)}</span>
                  <span className="hint">{size(f.size)}</span>
                </li>
              ))}
          </ul>
        </section>
      ))}
    </>
  )
}

// --- Счёт (ruoc-gateway's bot cabinet) ---------------------------------------

function Billing() {
  const [me, setMe] = useState<Me | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [screen, setScreen] = useState<BillingScreen>("account")
  const [watching, setWatching] = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      const next = await api.me()
      setMe(next)
      if (next.pending_payment?.state === "pending") setWatching(next.pending_payment.id)
    } catch (err) {
      setFailure(explain(err))
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => backButton(screen === "account" ? null : () => setScreen("account")), [screen])

  if (failure) return <p className="notice">{failure}</p>
  if (!me) return <p className="notice notice--quiet">Загрузка…</p>

  return (
    <>
      {watching && (
        <PaymentWatch
          key={watching}
          id={watching}
          onDone={() => {
            setWatching(null)
            load()
          }}
        />
      )}
      {screen === "account" && <Account me={me} go={setScreen} />}
      {screen === "plans" && (
        <Plans me={me} needReceipt={() => setScreen("receipt")} onOpened={(id) => setWatching(id)} />
      )}
      {screen === "receipt" && <Receipt me={me} onChanged={load} done={() => setScreen("account")} />}
    </>
  )
}

function Account({ me, go }: { me: Me; go: (s: BillingScreen) => void }) {
  const sub = me.subscription
  const until = sub?.paid_through ?? sub?.current_period_end
  return (
    <>
      <section className="card">
        <p className="label">Тариф</p>
        <h1>{sub ? sub.plan_name : "Нет тарифа"}</h1>
        {sub && until && <p className="hint">{sub.paid_through ? "Оплачен до" : "Продлится"} {date(until)}</p>}
        {sub?.next_plan_name && <p className="hint">Потом: {sub.next_plan_name}</p>}
      </section>

      <section className="card">
        <p className="label">Баланс</p>
        <p className="figure">{rub(me.balance_nanorub)}</p>
        {me.limits && (
          <>
            <Meter label="Сессия" used={me.limits.session.used_percent} resets={me.limits.session.resets_at} />
            <Meter label="Неделя" used={me.limits.weekly.used_percent} resets={me.limits.weekly.resets_at} />
          </>
        )}
        <p className="hint">
          За 30 дней: {count(me.usage_30d.requests)}{" "}
          {plural(me.usage_30d.requests, "запрос", "запроса", "запросов")}, {rub(me.usage_30d.charged_nanorub)}
        </p>
      </section>

      <button className="primary" onClick={() => go("plans")}>
        Тарифы и оплата
      </button>
      <button className="secondary" onClick={() => go("receipt")}>
        Почта для чеков{me.receipt.verified ? `: ${me.receipt.email}` : ""}
      </button>
    </>
  )
}

function Meter({ label, used, resets }: { label: string; used: number; resets: string | null }) {
  const pct = Math.max(0, Math.min(100, used))
  return (
    <div className="meter">
      <div className="meter__row">
        <span>{label}</span>
        <span className="hint">
          {pct}%{resets ? ` · сброс ${resetAt(resets)}` : ""}
        </span>
      </div>
      <div className="meter__bar" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
        <div style={{ width: `${pct}%` }} />
      </div>
    </div>
  )
}

function Plans({
  me,
  needReceipt,
  onOpened,
}: {
  me: Me
  needReceipt: () => void
  onOpened: (paymentID: string) => void
}) {
  const [plans, setPlans] = useState<Plan[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [opened, setOpened] = useState<{ plan: string; id: string; url: string; fallback: boolean } | null>(null)

  useEffect(() => {
    api.plans().then(setPlans, (err) => setError(explain(err)))
  }, [])

  // First tap: ask the bank for a payment. Telegram would not open the link
  // after the bank's wait, so the button turns into a second tap that does.
  const buy = async (plan: Plan) => {
    if (!me.receipt.verified) {
      needReceipt()
      return
    }
    setError(null)
    setBusy(plan.id)
    try {
      const p = await api.checkout(plan.id, plan.amount_nanorub)
      setOpened({ plan: plan.id, id: p.payment_id, url: p.payment_url, fallback: false })
    } catch (err) {
      setError(explain(err))
    } finally {
      setBusy(null)
    }
  }

  const go = () => {
    if (!opened) return
    const ok = openExternal(opened.url)
    setOpened({ ...opened, fallback: !ok })
    onOpened(opened.id)
  }

  if (!plans) return <p className="notice notice--quiet">{error ?? "Загрузка…"}</p>
  return (
    <>
      <h1 className="screen-title">Тарифы</h1>
      {me.receipt.verified ? (
        <p className="hint">Чек придёт на {me.receipt.email}.</p>
      ) : (
        <p className="hint">Перед оплатой нужно подтвердить почту — на неё придёт чек.</p>
      )}
      {error && <p className="error">{error}</p>}
      {plans.length === 0 && <p className="hint">Тарифов пока нет.</p>}
      {plans.map((plan) => (
        <section key={plan.id} className={plan.current ? "card card--current" : "card"}>
          <div className="plan__head">
            <h2>{plan.name}</h2>
            {plan.current && <span className="badge">ваш тариф</span>}
          </div>
          <p className="figure">
            {rub(plan.price_nanorub)} <span className="hint">за {days(plan.period_days)}</span>
          </p>
          {plan.description && <p className="hint">{plan.description}</p>}
          {plan.amount_nanorub !== undefined && plan.amount_nanorub !== plan.price_nanorub && (
            <p className="hint">
              К оплате сейчас: {rub(plan.amount_nanorub)}
              {plan.discount_percent ? ` (скидка ${plan.discount_percent}%)` : ""}
            </p>
          )}
          {plan.starts_at && plan.change === "renew" && <p className="hint">Начнётся {date(plan.starts_at)}</p>}
          {plan.blocked ? (
            <p className="hint">
              {plan.blocked === "plan_change_scheduled"
                ? "Другой тариф уже куплен на следующий период."
                : "Эту смену тарифа можно сделать через поддержку."}
            </p>
          ) : plan.amount_nanorub === undefined ? null : opened?.plan === plan.id ? (
            <>
              <button className="primary" onClick={go}>
                Перейти к оплате
              </button>
              {opened.fallback && (
                <p className="hint">
                  Если страница банка не открылась, нажмите:{" "}
                  <a href={opened.url} target="_blank" rel="noreferrer">
                    оплатить на сайте банка
                  </a>
                </p>
              )}
            </>
          ) : (
            <button className="primary" disabled={busy !== null} onClick={() => buy(plan)}>
              {busy === plan.id ? "Готовим оплату…" : plan.current ? "Продлить" : "Оплатить"}
            </button>
          )}
        </section>
      ))}
    </>
  )
}

// PaymentWatch asks about a payment while the owner is at the bank: every 3 s
// for two minutes, and whenever the cabinet comes back into view.
// If the window passes with no answer, or a refusal makes asking pointless,
// the banner says so and offers to ask again or to hide it.
function PaymentWatch({ id, onDone }: { id: string; onDone: () => void }) {
  const [payment, setPayment] = useState<Payment | null>(null)
  const [gaveUp, setGaveUp] = useState<string | null>(null)
  const [round, setRound] = useState(0)
  const doneRef = useRef(onDone)
  doneRef.current = onDone

  useEffect(() => {
    const started = Date.now()
    let stopped = false
    setGaveUp(null)
    const check = async () => {
      if (stopped) return
      try {
        const p = await api.payment(id)
        if (stopped) return
        setPayment(p)
        if (p.state !== "pending") stopped = true
      } catch (err) {
        if (fatal(err)) {
          stopped = true
          setGaveUp(explain(err))
        }
      }
    }
    check()
    const timer = window.setInterval(() => {
      if (stopped) {
        window.clearInterval(timer)
        return
      }
      if (Date.now() - started > 120_000) {
        window.clearInterval(timer)
        stopped = true
        setGaveUp("Банк пока не ответил. Если вы оплатили, тариф обновится сам.")
        return
      }
      check()
    }, 3000)
    const onVisible = () => {
      if (document.visibilityState === "visible") check()
    }
    document.addEventListener("visibilitychange", onVisible)
    return () => {
      stopped = true
      window.clearInterval(timer)
      document.removeEventListener("visibilitychange", onVisible)
    }
  }, [id, round])

  if (!payment || payment.state === "pending") {
    if (gaveUp) {
      return (
        <div className="banner">
          <p>{gaveUp}</p>
          <button className="link" onClick={() => setRound((n) => n + 1)}>
            Проверить ещё раз
          </button>{" "}
          <button className="link" onClick={() => doneRef.current()}>
            Скрыть
          </button>
        </div>
      )
    }
    return <p className="banner">Ждём ответ банка об оплате…</p>
  }
  const ok = payment.state === "paid"
  return (
    <div className={ok ? "banner banner--ok" : "banner banner--bad"}>
      <p>{ok ? `Оплата прошла: ${payment.plan_name}.` : "Оплата не прошла, деньги не списаны."}</p>
      <button className="link" onClick={() => doneRef.current()}>
        Хорошо
      </button>
    </div>
  )
}

function Receipt({ me, onChanged, done }: { me: Me; onChanged: () => Promise<void> | void; done: () => void }) {
  const [email, setEmail] = useState("")
  const [code, setCode] = useState("")
  // At stage "current" the code went to the confirmed address; the pending
  // address is the new one being asked for.
  const [sentTo, setSentTo] = useState<string | null>(
    me.receipt.pending ? (me.receipt.pending.stage === "current" ? me.receipt.email : me.receipt.pending.email) : null,
  )
  const [stage, setStage] = useState<"new" | "current" | null>(me.receipt.pending?.stage ?? null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const send = async () => {
    setError(null)
    setBusy(true)
    try {
      const r = await api.receiptEmail(email.trim())
      setSentTo(r.sent_to)
      setStage(r.stage)
      setCode("")
      // So the code in flight survives leaving this screen and coming back.
      void onChanged()
    } catch (err) {
      setError(explain(err))
    } finally {
      setBusy(false)
    }
  }

  const confirm = async () => {
    setError(null)
    setBusy(true)
    try {
      const r = await api.confirmReceipt(code.trim())
      setCode("")
      if (r.done) {
        await onChanged()
        done()
        return
      }
      setSentTo(r.sent_to ?? null)
      setStage("new")
      void onChanged()
    } catch (err) {
      setError(explain(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="screen-title">Почта для чеков</h1>
      <p className="hint">
        {me.receipt.verified
          ? `Сейчас чеки приходят на ${me.receipt.email}.`
          : "На эту почту придут чеки об оплате. Её нужно подтвердить кодом из письма."}
      </p>
      {error && <p className="error">{error}</p>}
      {stage === null ? (
        <section className="card">
          <label className="field">
            <span>{me.receipt.verified ? "Новый адрес" : "Адрес почты"}</span>
            <input
              type="email"
              inputMode="email"
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="name@example.com"
            />
          </label>
          <button className="primary" disabled={busy || !email.trim()} onClick={send}>
            Получить код
          </button>
        </section>
      ) : (
        <section className="card">
          <p className="hint">
            {stage === "current"
              ? `Чтобы сменить адрес, введите код из письма на прежнюю почту ${sentTo ?? ""}.`
              : `Код отправлен на ${sentTo ?? "новую почту"}.`}
          </p>
          <label className="field">
            <span>Код из письма</span>
            <input
              inputMode="numeric"
              autoComplete="one-time-code"
              maxLength={6}
              value={code}
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
            />
          </label>
          <button className="primary" disabled={busy || code.length !== 6} onClick={confirm}>
            Подтвердить
          </button>
          <button
            className="link"
            onClick={() => {
              setStage(null)
              setError(null)
            }}
          >
            Указать другой адрес
          </button>
        </section>
      )}
    </>
  )
}
