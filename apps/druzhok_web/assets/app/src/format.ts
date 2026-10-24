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
