import { useCallback, useEffect, useRef, useState } from "react"
import { api, APIError, cached, explain, fatal, invalidate, portalUrl, type Me, type Payment, type Plan } from "./api"
import { backButton, openExternal } from "./telegram"
import { count, date, days, moment, rub } from "./format"
import { ErrorNote, Figure, Icon, Meter, Row, Skeleton } from "./ui"

// Счёт: ruoc-gateway's bot cabinet (ruoc internal/httpapi/miniapp.go), called
// cross-origin: the plan and when its period ends, how much of it is left
// (its limits, with the day each comes back), and the plans and payments.
// There is no balance to show: a bot's plan is all it spends. A payment
// takes two taps: one to open it at the bank, one to go there, because
// Telegram opens an outside link only from a tap and the bank can take
// seconds to answer.
//
// A bot can spend from its owner's Cleo Code account instead of its own
// (ruoc's funding link): the owner proves the account with its password here,
// and from then on `me` describes that account, its plans are the portal's,
// and the receipt goes to its verified email. Only re-pointing to another
// account is offered, never unlinking.

type Screen = "account" | "receipt" | "link"

/**
 * What the period line says, as ruoc's own portal says it: a cancelled plan
 * still holds until its period runs out, and paid time bought ahead is named.
 */
export function periodNote(sub: NonNullable<Me["subscription"]>): string {
  const end = sub.current_period_end
  if (sub.status === "expired") return `Закончился ${date(end)}`
  if (sub.status === "active") {
    if (sub.next_plan_name) return `Оплачен до ${date(end)}, потом «${sub.next_plan_name}»`
    if (sub.paid_through && Date.parse(sub.paid_through) > Date.parse(end)) return `Оплачен до ${date(sub.paid_through)}`
    return sub.paid_through ? `Оплачен до ${date(end)}` : `Текущий период до ${date(end)}`
  }
  if (Date.parse(end) <= Date.now()) return "Отменён"
  return `Отменён, действует до ${date(end)}`
}

/**
 * The plan in one line, for Бот's row into Счёт: what is left of the week, or
 * that the 5-hour limit has run out, since the bot stops answering then
 * whatever the week says.
 */
export function planLine(me: Me): { title: string; sub: string } {
  const sub = me.subscription
  const line = sub ? `${sub.plan_name} · ${lowerFirst(periodNote(sub))}` : "Тариф не выбран"
  if (!me.limits) return sub ? { title: sub.plan_name, sub: lowerFirst(periodNote(sub)) } : { title: "Тариф не выбран", sub: "Посмотреть тарифы" }
  const session = me.limits.session
  if (session.used_percent >= 100)
    return {
      title: "Лимит на 5 часов исчерпан",
      sub: session.resets_at ? `Вернётся ${moment(session.resets_at)}` : line,
    }
  const left = 100 - Math.max(0, Math.min(100, Math.round(me.limits.weekly.used_percent)))
  return { title: `Осталось на неделю ${left}%`, sub: line }
}

/**
 * The plan at a glance, Счёт's big figure: what is left of the week, the
 * plan's name and its period. A plan without limits shows its name.
 */
export function PlanHero({ me }: { me: Me }) {
  const sub = me.subscription
  const line = sub ? `${sub.plan_name} · ${lowerFirst(periodNote(sub))}` : "Тариф не выбран"
  if (!me.limits)
    return (
      <>
        <p className="hero__label">Тариф</p>
        <Figure whole={sub ? sub.plan_name : "—"} small />
        {sub ? <p className="hero__sub">{lowerFirst(periodNote(sub))}</p> : null}
      </>
    )
  const left = 100 - Math.max(0, Math.min(100, Math.round(me.limits.weekly.used_percent)))
  return (
    <>
      <p className="hero__label">Осталось на неделю</p>
      <Figure whole={String(left)} rest="%" />
      <p className="hero__sub">{line}</p>
    </>
  )
}

// "Оплачен до…" reads "оплачен до…" after the plan's name; a plan name inside stays as written.
const lowerFirst = (s: string) => s.charAt(0).toLowerCase() + s.slice(1)

export default function Billing({ start }: { start?: string }) {
  const [me, setMe] = useState<Me | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [screen, setScreen] = useState<Screen>(start === "receipt" || start === "link" ? start : "account")
  const [watching, setWatching] = useState<string | null>(null)

  const load = useCallback(async (fresh = false) => {
    if (fresh) invalidate("me")
    try {
      const next = await cached("me", api.me)
      setFailure(null)
      setMe(next)
      if (next.pending_payment?.state === "pending") setWatching(next.pending_payment.id)
    } catch (err) {
      setFailure(explain(err))
    }
  }, [])

  // Fresh on every visit, as before the account was shared with Главная: a
  // payment opened earlier, or finished at the bank meanwhile, shows here.
  useEffect(() => {
    load(true)
  }, [load])

  // After a link or re-point the account is another one, whose payments the
  // old account's watcher could not ask about: it goes, and `me` says whether
  // the new account has one to watch.
  const reloadAccount = useCallback(async () => {
    setWatching(null)
    await load(true)
  }, [load])

  useEffect(() => {
    window.scrollTo(0, 0)
    return backButton(screen === "account" ? null : () => setScreen("account"))
  }, [screen])

  if (failure) return <ErrorNote error={failure} retry={() => load(true)} />
  if (!me) return <Skeleton hero rows={4} />
  // A linked bot has no receipt email of its own to set: ruoc refuses the
  // routes (409 linked), the account's verified email takes the receipts.
  const shown: Screen = screen === "receipt" && me.linked ? "account" : screen

  return (
    <>
      {watching ? (
        <PaymentWatch
          key={watching}
          id={watching}
          onDone={() => {
            setWatching(null)
            load(true)
          }}
        />
      ) : null}
      {shown === "account" ? (
        <Account
          me={me}
          go={setScreen}
          onOpened={(id) => {
            invalidate("me")
            setWatching(id)
          }}
          onLinkChanged={reloadAccount}
        />
      ) : null}
      {shown === "receipt" ? <Receipt me={me} onChanged={() => load(true)} done={() => setScreen("account")} /> : null}
      {shown === "link" ? (
        <Link
          me={me}
          done={async () => {
            await reloadAccount()
            setScreen("account")
          }}
        />
      ) : null}
    </>
  )
}

function Account({
  me,
  go,
  onOpened,
  onLinkChanged,
}: {
  me: Me
  go: (s: Screen) => void
  onOpened: (paymentID: string) => void
  onLinkChanged: () => void
}) {
  return (
    <>
      <section className="hero hero--plain">
        <PlanHero me={me} />
      </section>

      {me.limits ? (
        <section className="card">
          <div className="card__head">
            <span className="label">Лимиты тарифа</span>
          </div>
          <Meter
            title="За 5 часов"
            used={me.limits.session.used_percent}
            resets={me.limits.session.resets_at}
            idle="Начнётся с первого сообщения и продлится 5 часов"
          />
          <Meter
            title="За неделю"
            used={me.limits.weekly.used_percent}
            resets={me.limits.weekly.resets_at}
            idle="Начнётся с первого сообщения"
          />
        </section>
      ) : null}

      <section className="card">
        <div className="card__head">
          <span className="label">За 30 дней</span>
        </div>
        <dl className="pairs">
          <div>
            <dt>Запросов</dt>
            <dd>{count(me.usage_30d.requests)}</dd>
          </div>
        </dl>
      </section>

      {me.linked ? (
        <div className="group">
          <Row
            icon="user"
            tone="purple"
            title={`Счёт Клео Код · ${me.linked.email_masked}`}
            sub="Бот тратит тариф этого аккаунта, чеки приходят на его почту"
          />
          <Row icon="lock" tone="grey" title="Подключить другой аккаунт" onClick={() => go("link")} />
        </div>
      ) : (
        <section className="card">
          <div className="card__head">
            <span className="label">Один счёт с Клео Код</span>
          </div>
          <p className="hint">
            Есть аккаунт Клео Код? Подключите его — бот будет тратить его тариф, а отдельно платить за бота
            не придётся.
          </p>
          <button className="secondary" onClick={() => go("link")}>
            <Icon name="user" size={18} />
            Подключить аккаунт
          </button>
        </section>
      )}

      <Plans me={me} needReceipt={() => go("receipt")} onOpened={onOpened} onLinkChanged={onLinkChanged} />

      {me.linked ? null : (
        <div className="group">
          <Row
            icon="mail"
            tone="blue"
            title="Почта для чеков"
            sub={me.receipt.verified ? me.receipt.email : "не указана, нужна для оплаты"}
            onClick={() => go("receipt")}
          />
        </div>
      )}
    </>
  )
}

function Plans({
  me,
  needReceipt,
  onOpened,
  onLinkChanged,
}: {
  me: Me
  needReceipt: () => void
  onOpened: (paymentID: string) => void
  onLinkChanged: () => void
}) {
  const [plans, setPlans] = useState<Plan[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [round, setRound] = useState(0)
  const [busy, setBusy] = useState<string | null>(null)
  const [opened, setOpened] = useState<{ plan: string; id: string; url: string; fallback: boolean } | null>(null)

  // The plans are the account's: the bot's own, or the portal's once it is
  // linked. Asked again when the link or the plan changes under this screen,
  // as a finished payment does: which is current, and each one's price, move,
  // and a payment link already opened is spent. The old list goes first, so a
  // failed read can never leave old prices with live buttons.
  const sub = me.subscription
  const account = [me.linked?.email_masked, sub?.plan_id, sub?.current_period_end, sub?.paid_through, sub?.next_plan_name].join("|")
  useEffect(() => {
    let live = true
    setOpened(null)
    setPlans(null)
    setLoadError(null)
    api.plans().then(
      (p) => live && setPlans(p),
      (err) => live && setLoadError(explain(err)),
    )
    return () => {
      live = false
    }
  }, [account, round])

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
      // The bot was linked (or re-pointed) since this screen opened: ruoc
      // refused the payment, and `me` and the plans are read again.
      if (err instanceof APIError && err.kind === "link_changed") onLinkChanged()
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

  if (!plans)
    return loadError ? <ErrorNote error={loadError} retry={() => setRound((n) => n + 1)} /> : <Skeleton rows={2} />
  return (
    <>
      <span className="label">Тарифы</span>
      {error && <p className="error">{error}</p>}
      {plans.length === 0 && <p className="hint">Тарифов пока нет.</p>}
      {plans.map((plan) => (
        <section key={plan.id} className={plan.current ? "card card--current" : "card"}>
          <div className="card__head">
            <h2>{plan.name}</h2>
            {plan.current && <span className="chip chip--awake">ваш тариф</span>}
          </div>
          <p className="price">
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

/**
 * What the link form says about a refusal, in its own words: these codes are
 * the form's alone, and the shared explain() never sees them.
 */
export function linkError(err: unknown): string {
  if (!(err instanceof APIError)) return "Не получилось подключить. Попробуйте ещё раз."
  switch (err.kind) {
    case "network":
      return "Нет связи с сервером. Проверьте интернет и попробуйте ещё раз."
    case "invalid_credentials":
      return "Неверная почта или пароль."
    case "link_email_unconfirmed":
      return "Сначала подтвердите почту в Клео Код — ссылка в письме после регистрации."
    case "link_account_inactive":
      return "Этот аккаунт Клео Код приостановлен. Напишите в поддержку."
    case "link_not_allowed":
      return "Общий счёт с Клео Код пока недоступен."
    case "link_plan_active": {
      const until = err.field("until")
      return until && !Number.isNaN(Date.parse(until))
        ? `У бота оплачен свой тариф до ${date(until)}. Подключить аккаунт можно после этой даты.`
        : "У бота оплачен свой тариф. Подключить аккаунт можно, когда он закончится."
    }
    case "link_payment_pending":
      return "У бота есть незавершённая оплата. Дождитесь ответа банка и попробуйте снова."
    case "rate_limit_error":
      return "Слишком много попыток. Подождите немного."
    // The cabinet's own refusals, after which another try cannot help.
    case "init_stale":
      return "Кабинет открыт слишком давно. Закройте его и откройте снова."
    case "init_invalid":
    case "not_bound":
    case "cabinet_off":
      return "Кабинет недоступен. Откройте его заново кнопкой «Кабинет» в чате с ботом."
    case "not_owner":
      return "Подключить аккаунт может только владелец бота."
    case "account_suspended":
      return "Аккаунт бота приостановлен. Напишите в поддержку."
    default:
      return "Не получилось подключить. Попробуйте ещё раз."
  }
}

// Link takes the email and password of a Cleo Code account and points the
// bot's spending at it; on a linked bot it points it at another one. The
// password goes to ruoc and nowhere else; the form keeps nothing. «Создать»
// opens ruoc's portal outside Telegram, so the sign-up is the portal's own.
function Link({ me, done }: { me: Me; done: () => Promise<void> }) {
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [portalFallback, setPortalFallback] = useState(false)

  const submit = async () => {
    setError(null)
    setBusy(true)
    try {
      await api.link(email.trim(), password)
      setPassword("")
      await done()
    } catch (err) {
      setError(linkError(err))
      setBusy(false)
    }
  }

  const signUp = () => setPortalFallback(!openExternal(portalUrl()))

  return (
    <>
      <h1 className="screen-title">Один счёт с Клео Код</h1>
      <p className="hint">
        {me.linked
          ? `Сейчас подключён ${me.linked.email_masked}. Введите почту и пароль другого аккаунта Клео Код — бот перейдёт на него.`
          : "Введите почту и пароль от аккаунта Клео Код. Бот будет тратить его тариф, а чеки придут на его почту."}
      </p>
      {error && <p className="error">{error}</p>}
      <section className="card">
        <label className="field">
          <span>Почта</span>
          <input
            type="email"
            inputMode="email"
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="name@example.com"
          />
        </label>
        <label className="field">
          <span>Пароль</span>
          <input
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </label>
        <button className="primary" disabled={busy || !email.trim() || !password} onClick={submit}>
          {busy ? "Подключаем…" : me.linked ? "Подключить этот аккаунт" : "Подключить"}
        </button>
        {me.linked ? null : (
          <>
            <button className="link" onClick={signUp}>
              Нет аккаунта? Создать
            </button>
            {portalFallback && (
              <p className="hint">
                Если страница не открылась, нажмите:{" "}
                <a href={portalUrl()} target="_blank" rel="noreferrer">
                  открыть Клео Код
                </a>
              </p>
            )}
          </>
        )}
      </section>
    </>
  )
}
