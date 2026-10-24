import { useCallback, useEffect, useRef, useState } from "react"
import { api, cached, explain, fatal, invalidate, type Me, type Payment, type Plan } from "./api"
import { backButton, openExternal } from "./telegram"
import { count, date, days, rub } from "./format"
import { ErrorNote, Meter, Money, Row, Skeleton } from "./ui"

// Счёт: ruoc-gateway's bot cabinet (ruoc internal/httpapi/miniapp.go), called
// cross-origin: the plan and when its period ends, the balance and what it is
// spent on, the plan's limits with the day each comes back, and the plans
// and payments. A payment takes two taps: one to open it at the bank, one to
// go there, because Telegram opens an outside link only from a tap and the
// bank can take seconds to answer.

type Screen = "account" | "plans" | "receipt"

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

/** What the balance is for on this plan, as the portal explains it. */
function spentNote(me: Me): string {
  if (!me.limits) return "Запросы бота оплачиваются с баланса."
  return me.limits.overflow
    ? "Пока лимиты тарифа не исчерпаны, баланс не тратится. Дальше запросы оплачиваются с баланса."
    : "На этом тарифе баланс не тратится: когда лимит исчерпан, бот ждёт, пока он обновится."
}

// ruoc's grant kinds, labelled as its portal labels them.
const grantLabel: Record<string, string> = {
  topup: "Пополнение",
  subscription: "По тарифу",
  promo: "Бонус",
  adjustment: "Корректировка",
}

export default function Billing({ start }: { start?: string }) {
  const [me, setMe] = useState<Me | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [screen, setScreen] = useState<Screen>(start === "plans" || start === "receipt" ? start : "account")
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

  useEffect(() => backButton(screen === "account" ? null : () => setScreen("account")), [screen])

  if (failure) return <ErrorNote error={failure} retry={() => load(true)} />
  if (!me) return <Skeleton hero rows={4} />

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
      {screen === "account" ? <Account me={me} go={setScreen} /> : null}
      {screen === "plans" ? (
        <Plans
          me={me}
          needReceipt={() => setScreen("receipt")}
          onOpened={(id) => {
            invalidate("me")
            setWatching(id)
          }}
        />
      ) : null}
      {screen === "receipt" ? <Receipt me={me} onChanged={() => load(true)} done={() => setScreen("account")} /> : null}
    </>
  )
}

function Account({ me, go }: { me: Me; go: (s: Screen) => void }) {
  const sub = me.subscription
  return (
    <>
      <section className="hero hero--plain">
        <p className="hero__label">Баланс</p>
        <Money nanorub={me.balance_nanorub} />
        {me.balance_nanorub < 0 ? (
          <p className="hero__hint">Минус — это долг: запрос стоил больше, чем оставалось. Пополнение сначала покроет его.</p>
        ) : null}
      </section>

      <section className="card">
        <div className="card__head">
          <span className="label">Тариф</span>
        </div>
        <h2 className="card__title">{sub ? sub.plan_name : "Тариф не выбран"}</h2>
        {sub ? <p className="hint">{periodNote(sub)}</p> : null}
        <p className="hint">{spentNote(me)}</p>
        {me.grants.length > 0 ? (
          <ul className="grants">
            {me.grants.map((g, i) => (
              <li key={i}>
                <span>{grantLabel[g.kind] ?? "Начисление"}</span>
                <span>{rub(g.remaining_nanorub)}</span>
                <span className="hint">{g.expires_at ? `до ${date(g.expires_at)}` : "бессрочно"}</span>
              </li>
            ))}
          </ul>
        ) : null}
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
          <div>
            <dt>Списано с баланса</dt>
            <dd>{rub(me.usage_30d.charged_nanorub)}</dd>
          </div>
        </dl>
      </section>

      <button className="primary" onClick={() => go("plans")}>
        Тарифы и оплата
      </button>
      <div className="group">
        <Row
          icon="mail"
          tone="blue"
          title="Почта для чеков"
          sub={me.receipt.verified ? me.receipt.email : "не указана"}
          onClick={() => go("receipt")}
        />
      </div>
    </>
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

  if (!plans) return error ? <ErrorNote error={error} /> : <Skeleton rows={3} />
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
