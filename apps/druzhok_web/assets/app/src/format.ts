// How the panel writes money, counts and dates: in Russian. Copied from
// ruoc-gateway's portal (web/portal/src/format.ts, web/src/lib/money.ts) when
// the cabinet moved to druzhok; money is split through BigInt so a displayed
// figure is the stored nanoruble figure.

const NANO = 1_000_000_000n

function digits(nano: number): string | null {
  if (!Number.isFinite(nano)) return null
  const n = BigInt(Math.trunc(nano))
  const negative = n < 0n
  const abs = negative ? -n : n
  const whole = (abs / NANO).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ")
  const frac = (abs % NANO).toString().padStart(9, "0")
  // A ruble or more gets two places; less gets three significant digits.
  let p = 2
  if (whole === "0") {
    const first = frac.search(/[1-9]/)
    if (first >= 0) p = Math.min(9, first + 3)
  }
  const shown = `${whole}.${frac.slice(0, p).replace(/0+$/, "").padEnd(2, "0")}`
  return `${negative ? "−" : ""}${shown}`
}

/** "1 248 ₽", "597,82 ₽", "0,0035 ₽" (no-break spaces). */
export function rub(nanorub: number): string {
  const d = digits(nanorub)
  if (d === null) return "—"
  return `${d.replace(/\.00$/, "").replace(".", ",").replace(/ /g, " ")} ₽`
}

const grouped = new Intl.NumberFormat("ru-RU")

/** "12 480" */
export function count(n: number): string {
  return Number.isFinite(n) ? grouped.format(n) : "—"
}

/** Picks the Russian plural: plural(21, "день", "дня", "дней") is "день". */
export function plural(n: number, one: string, few: string, many: string): string {
  const abs = Math.abs(n)
  const tens = abs % 100
  const units = abs % 10
  if (tens >= 11 && tens <= 14) return many
  if (units === 1) return one
  if (units >= 2 && units <= 4) return few
  return many
}

/** "30 дней", "1 день" */
export function days(n: number): string {
  return `${n} ${plural(n, "день", "дня", "дней")}`
}

/** "2,1 КБ" */
export function size(bytes: number): string {
  if (bytes < 1024) return `${bytes} Б`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toLocaleString("ru-RU", { maximumFractionDigits: 1 })} КБ`
  return `${(bytes / 1024 / 1024).toLocaleString("ru-RU", { maximumFractionDigits: 1 })} МБ`
}

const dayMonth = new Intl.DateTimeFormat("ru-RU", { day: "numeric", month: "long" })
const dayMonthTime = new Intl.DateTimeFormat("ru-RU", {
  day: "numeric",
  month: "long",
  hour: "2-digit",
  minute: "2-digit",
})

/** "17 ноября" */
export function date(iso: string): string {
  return dayMonth.format(new Date(iso))
}

/** "24 октября, 14:17", or "—". */
export function when(iso: string | null | undefined): string {
  if (!iso) return "—"
  const t = new Date(iso)
  return Number.isNaN(t.getTime()) ? "—" : dayMonthTime.format(t)
}

/** A money figure split for a big display: "956" and ",42 ₽". */
export function rubParts(nanorub: number): { whole: string; rest: string } {
  const text = rub(nanorub)
  const i = text.indexOf(",")
  if (i < 0) return { whole: text.replace(/ ₽$/, ""), rest: " ₽" }
  return { whole: text.slice(0, i), rest: text.slice(i) }
}

const hhmm = new Intl.DateTimeFormat("ru-RU", { hour: "2-digit", minute: "2-digit" })
const weekdayDate = new Intl.DateTimeFormat("ru-RU", { weekday: "short", day: "numeric", month: "long" })

function dayStart(d: Date): number {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

/** A moment ahead, always with its day: "сегодня в 17:56", "завтра в 09:10", "сб, 25 октября в 17:56". */
export function moment(iso: string): string {
  const at = new Date(iso)
  if (Number.isNaN(at.getTime())) return "—"
  const time = hhmm.format(at)
  const days = Math.round((dayStart(at) - dayStart(new Date())) / 86_400_000)
  if (days <= 0) return `сегодня в ${time}`
  if (days === 1) return `завтра в ${time}`
  return `${weekdayDate.format(at)} в ${time}`
}

/** How long until a moment: "через 40 мин", "через 2 ч 15 мин", "через 21 ч", "через 3 дня 4 ч". */
export function inTime(iso: string): string {
  const ms = new Date(iso).getTime() - Date.now()
  if (!Number.isFinite(ms) || ms <= 60_000) return "меньше минуты"
  const min = Math.ceil(ms / 60_000)
  if (min < 60) return `через ${min} мин`
  const h = Math.floor(min / 60)
  if (h < 3) return `через ${h} ч${min % 60 ? ` ${min % 60} мин` : ""}`
  if (h < 24) return `через ${h} ч`
  const d = Math.floor(h / 24)
  return `через ${d} ${plural(d, "день", "дня", "дней")}${h % 24 ? ` ${h % 24} ч` : ""}`
}

/** Up to two initials for an avatar: "Кот Вася" is "КВ". */
export function initials(name: string): string {
  const words = name.replace(/[^\p{L}\p{N}\s]/gu, " ").trim().split(/\s+/).filter(Boolean)
  const letters = words.length > 1 ? words[0][0] + words[1][0] : (words[0] ?? "?").slice(0, 2)
  return letters.toUpperCase()
}
