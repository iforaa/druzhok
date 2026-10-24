import { useCallback, useEffect, useState, type ReactNode } from "react"
import { explain } from "./api"
import { inTime, moment } from "./format"

// The panel's small parts: icons, list rows, the big money figure, the
// progress ring, meters, placeholders while a screen loads, and the hook
// every screen loads its data with.

const paths: Record<string, ReactNode> = {
  home: <path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z" />,
  spark: (
    <>
      <path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z" />
      <path d="M19 15l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z" />
    </>
  ),
  wallet: (
    <>
      <path d="M4 6.5A2.5 2.5 0 0 1 6.5 4H18v3" />
      <path d="M4 6.5V18a2 2 0 0 0 2 2h14V9H6.5A2.5 2.5 0 0 1 4 6.5z" />
      <circle cx="16.5" cy="14.5" r="1" />
    </>
  ),
  more: (
    <>
      <circle cx="6" cy="12" r="1.6" />
      <circle cx="12" cy="12" r="1.6" />
      <circle cx="18" cy="12" r="1.6" />
    </>
  ),
  plus: <path d="M12 5v14M5 12h14" />,
  gift: (
    <>
      <rect x="3.5" y="8" width="17" height="4.5" rx="1" />
      <path d="M5 12.5V20h14v-7.5M12 8v12" />
      <path d="M12 8C10.5 4.5 7 4.5 7 6.5S10 8 12 8zM12 8c1.5-3.5 5-3.5 5-1.5S14 8 12 8z" />
    </>
  ),
  chat: <path d="M4 5h16v11H9l-5 4z" />,
  chevron: <path d="M9 6l6 6-6 6" />,
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  close: <path d="M6 6l12 12M18 6L6 18" />,
  face: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M8.5 14.5c1.8 2 5.2 2 7 0M9 10h.01M15 10h.01" />
    </>
  ),
  brain: (
    <>
      <path d="M9 4.5a3 3 0 0 0-3 3 3 3 0 0 0-1.5 5.5A3 3 0 0 0 9 18.5V4.5z" />
      <path d="M15 4.5a3 3 0 0 1 3 3 3 3 0 0 1 1.5 5.5 3 3 0 0 1-4.5 5.5V4.5z" />
    </>
  ),
  user: (
    <>
      <circle cx="12" cy="8.5" r="3.5" />
      <path d="M5 20c1-4 4-5.5 7-5.5s6 1.5 7 5.5" />
    </>
  ),
  clock: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </>
  ),
  puzzle: (
    <path d="M5 8h3a2 2 0 1 1 4 0h3v3a2 2 0 1 1 0 4v3H5v-3a2 2 0 1 0 0-4z" />
  ),
  globe: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17M12 3.5c2.5 2.5 2.5 14.5 0 17M12 3.5c-2.5 2.5-2.5 14.5 0 17" />
    </>
  ),
  mail: (
    <>
      <rect x="3.5" y="5.5" width="17" height="13" rx="2" />
      <path d="M4 7l8 6 8-6" />
    </>
  ),
  card: (
    <>
      <rect x="3" y="5.5" width="18" height="13" rx="2" />
      <path d="M3 10h18M7 15h3" />
    </>
  ),
  gear: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3.5v2.5M12 18v2.5M3.5 12H6M18 12h2.5M6 6l1.8 1.8M16.2 16.2 18 18M6 18l1.8-1.8M16.2 7.8 18 6" />
    </>
  ),
  lock: (
    <>
      <rect x="5" y="10.5" width="14" height="9.5" rx="2" />
      <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" />
    </>
  ),
}

export function Icon({ name, size = 22 }: { name: keyof typeof paths | string; size?: number }) {
  return (
    <svg
      className="icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.9}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  )
}

/** A list row: a round icon, a title and a line under it, a value or a chevron. */
export function Row({
  icon,
  tone = "blue",
  title,
  sub,
  value,
  onClick,
}: {
  icon: string
  tone?: "blue" | "green" | "orange" | "purple" | "pink" | "teal" | "grey"
  title: string
  sub?: ReactNode
  value?: ReactNode
  onClick?: (() => void) | null
}) {
  const body = (
    <>
      <span className={`bubble bubble--${tone}`}>
        <Icon name={icon} size={20} />
      </span>
      <span className="row__text">
        <span className="row__title">{title}</span>
        {sub ? <span className="row__sub">{sub}</span> : null}
      </span>
      {value !== undefined ? <span className="row__value">{value}</span> : null}
      {onClick ? (
        <span className="row__chevron">
          <Icon name="chevron" size={18} />
        </span>
      ) : null}
    </>
  )
  return onClick ? (
    <button className="row" onClick={onClick}>
      {body}
    </button>
  ) : (
    <div className="row row--still">{body}</div>
  )
}

/** The big figure: "85" large, "%" smaller, as a wallet shows its total. */
export function Figure({ whole, rest, small = false }: { whole: string; rest?: string; small?: boolean }) {
  return (
    <p className={small ? "money money--mid" : "money money--big"}>
      <span className="money__whole">{whole}</span>
      {rest ? <span className="money__rest">{rest}</span> : null}
    </p>
  )
}

/** A ring filled to `done` of `total`, with the share in the middle. */
export function Ring({ done, total }: { done: number; total: number }) {
  const share = total ? done / total : 0
  const r = 21
  const c = 2 * Math.PI * r
  return (
    <span className="ring" aria-hidden="true">
      <svg width="52" height="52" viewBox="0 0 52 52">
        <circle cx="26" cy="26" r={r} className="ring__track" />
        <circle
          cx="26"
          cy="26"
          r={r}
          className="ring__fill"
          strokeDasharray={`${c * share} ${c}`}
          transform="rotate(-90 26 26)"
        />
      </svg>
      <span className="ring__label">{Math.round(share * 100)}%</span>
    </span>
  )
}

/**
 * One limit: how much of it is used and when it comes back, always with the
 * day. A window not yet open (the 5-hour one before the first message) says
 * when it will start instead.
 */
export function Meter({
  title,
  used,
  resets,
  idle,
}: {
  title: string
  used: number
  resets: string | null
  idle: string
}) {
  const pct = Math.max(0, Math.min(100, Math.round(used)))
  const level = pct >= 100 ? " meter--full" : pct >= 80 ? " meter--high" : ""
  return (
    <div className={`meter${level}`}>
      <div className="meter__head">
        <span>{title}</span>
        <span className="meter__pct">{pct}%</span>
      </div>
      <div className="meter__bar" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
        <div style={{ width: `${pct}%` }} />
      </div>
      <p className="meter__note">
        {resets ? `${pct >= 100 ? "Вернётся" : "Обновится"} ${moment(resets)} · ${inTime(resets)}` : idle}
      </p>
    </div>
  )
}

/** Grey blocks in the shape of the screen while it loads. */
export function Skeleton({ rows = 3, hero = false }: { rows?: number; hero?: boolean }) {
  return (
    <div className="skeleton" aria-busy="true" aria-label="Загрузка">
      {hero ? <div className="skeleton__hero" /> : null}
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="skeleton__row" />
      ))}
    </div>
  )
}

export function ErrorNote({ error, retry }: { error: string; retry?: () => void }) {
  return (
    <div className="card card--error">
      <p>{error}</p>
      {retry ? (
        <button className="link" onClick={retry}>
          Попробовать ещё раз
        </button>
      ) : null}
    </div>
  )
}

/** Loads once on mount; `reload` asks again. */
export function useLoad<T>(load: () => Promise<T>, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [round, setRound] = useState(0)

  useEffect(() => {
    let live = true
    setError(null)
    load().then(
      (d) => live && setData(d),
      (err) => live && setError(explain(err)),
    )
    return () => {
      live = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [round, ...deps])

  const reload = useCallback(() => setRound((n) => n + 1), [])
  return { data, error, reload }
}
