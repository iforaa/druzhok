// The two APIs the bot panel calls, both with Telegram's init data and the
// bot's id and no cookie: druzhok's own (/app/api/, the bot's state and
// files) and ruoc-gateway's bot cabinet (<billing_url>/tg/api/, the account
// and payments; ruoc's internal/httpapi/miniapp.go), called cross-origin.

import { botID, initData } from "./telegram"

export interface Window {
  used_percent: number
  resets_at: string | null
}

export interface Me {
  account: { id: string; status: string }
  // ruoc also sends balance_nanorub and grants; a bot's plan is all it
  // spends, so the panel shows neither.
  usage_30d: { requests: number }
  subscription: {
    plan_id: string
    plan_name: string
    status: string
    period_days: number
    current_period_end: string
    paid_through: string | null
    next_plan_name: string | null
  } | null
  limits: { session: Window; weekly: Window; overflow: boolean } | null
  bot_id: number
  product_name: string
  receipt: {
    email: string
    verified: boolean
    pending?: { stage: "new" | "current"; email: string }
  }
  pending_payment: Payment | null
}

export interface Plan {
  id: string
  name: string
  price_nanorub: number
  period_days: number
  kind: "credit" | "windowed"
  credit_nanorub: number | null
  current: boolean
  description: string
  change?: string
  amount_nanorub?: number
  discount_percent?: number
  starts_at?: string
  blocked?: string
}

export interface Payment {
  id: string
  plan_name: string
  amount_nanorub: number
  state: "pending" | "paid" | "failed" | "refunded"
}

/** A refusal from the API: its error type and status. */
export class APIError extends Error {
  constructor(
    readonly status: number,
    readonly kind: string,
    message: string,
  ) {
    super(message)
  }
}

// ruoc's public origin, from GET /app/api/bot; billing calls wait for it.
let billingBase = ""

export function setBillingBase(url: string) {
  billingBase = url.replace(/\/+$/, "")
}

function call<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  return request<T>(`${billingBase}/tg/api/${path}`, method, body)
}

function panel<T>(path: string): Promise<T> {
  return request<T>(`/app/api/${path}`, "GET")
}

async function request<T>(url: string, method: "GET" | "POST", body?: unknown): Promise<T> {
  const headers: Record<string, string> = {
    Authorization: `tma ${initData()}`,
    "X-Telegram-Bot": botID(),
  }
  if (body !== undefined) headers["Content-Type"] = "application/json"
  let resp: Response
  try {
    resp = await fetch(url, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
  } catch {
    throw new APIError(0, "network", "нет связи")
  }
  const data = await resp.json().catch(() => ({}))
  if (!resp.ok) {
    const err = (data as { error?: { type?: string; message?: string } }).error
    throw new APIError(resp.status, err?.type ?? "unknown", err?.message ?? "")
  }
  return data as T
}

export interface Bot {
  name: string
  bot_id: number
  /** Telegram's name for the bot, from getMe; null when Telegram did not answer. */
  title: string | null
  username: string | null
  state: "awake" | "asleep" | "starting" | "stopped" | "error"
  started_at: string | null
  start_error: string | null
  settings: {
    model: string
    model_name: string | null
    language: string
    timezone: string
    mention_only: boolean
    trigger_name: string | null
    sleep_enabled: boolean
    sleep_idle_minutes: number
    image_gen_enabled: boolean
    image_gen_model: string | null
    website_hosting_enabled: boolean
    memory_provider: string
    group_shared_memory: boolean
  }
  access: { allow_all_users: boolean; allowed_users: number; free_response_chats: number }
  billing_url: string
  support_url: string | null
}

export interface Invite {
  link: string
  share_url: string
  you_rub: string
  friend_rub: string
}

export interface FileMeta {
  size: number
  modified_at: string
}

export interface Files {
  soul: FileMeta | null
  memory: FileMeta | null
  user: FileMeta | null
  jobs: { count: number }
  skills: { own: number; bundled: number }
  site: { files: number; sites: string[] } | null
}

export interface Text {
  text: string
  modified_at: string
  truncated: boolean
}

export interface Job {
  name: string
  prompt: string
  schedule: string
  state: string
  next_run_at: string | null
  last_run_at: string | null
  last_status: string | null
  repeat: { times: number | null; completed: number | null } | null
}

export interface Skill {
  name: string
  category: string | null
  description: string
  /** The directory segments that open it; the front-matter name may differ. */
  path: string[]
}

export interface SiteFile {
  site: string
  path: string
  size: number
  type: "file" | "dir"
}

export const panelApi = {
  bot: () => panel<Bot>("bot"),
  files: () => panel<Files>("files"),
  file: (kind: "soul" | "memory" | "user") => panel<Text>(`files/${kind}`),
  jobs: () => panel<{ jobs: Job[]; error?: string }>("jobs"),
  skills: () => panel<{ skills: Skill[] }>("skills"),
  skill: (s: Skill) => panel<Text>(`skills/${s.path.map(encodeURIComponent).join("/")}`),
  site: () => panel<{ files: SiteFile[] | null }>("site"),
  invites: () => panel<{ links: Invite[]; used: number }>("invites"),
}

// Answers the screens share (the account shows on Главная and Счёт), kept
// for the life of the page; a failure is not kept, and invalidate() drops
// one after a change so the next read asks again.
const cache = new Map<string, Promise<unknown>>()

export function cached<T>(key: string, load: () => Promise<T>): Promise<T> {
  let p = cache.get(key) as Promise<T> | undefined
  if (!p) {
    p = load()
    cache.set(key, p)
    p.catch(() => cache.delete(key))
  }
  return p
}

export function invalidate(key: string) {
  cache.delete(key)
}

export const api = {
  me: () => call<Me>("GET", "me"),
  plans: () => call<Plan[]>("GET", "plans"),
  checkout: (planID: string, expected?: number) =>
    call<{ payment_id: string; payment_url: string }>(
      "POST",
      `plans/${encodeURIComponent(planID)}/checkout`,
      expected === undefined ? {} : { expected_nanorub: expected },
    ),
  payment: (id: string) => call<Payment>("GET", `payments/${encodeURIComponent(id)}`),
  receiptEmail: (email: string) => call<{ stage: "new" | "current"; sent_to: string }>("POST", "receipt-email", { email }),
  confirmReceipt: (code: string) => call<{ done: boolean; sent_to?: string }>("POST", "receipt-email/confirm", { code }),
}

/** What to tell the owner about a refusal, in their words. */
export function explain(err: unknown): string {
  if (!(err instanceof APIError)) return "Что-то пошло не так. Попробуйте ещё раз."
  switch (err.kind) {
    case "network":
      return "Нет связи с сервером. Проверьте интернет и попробуйте ещё раз."
    case "init_invalid":
      return "Откройте кабинет кнопкой «Кабинет» в чате с ботом."
    case "not_found":
      return "Не найдено."
    case "cabinet_off":
      return "Кабинет для этого бота выключен."
    case "not_text":
      return "Этот файл не текстовый, показать его нельзя."
    case "init_stale":
      return "Кабинет открыт слишком давно. Закройте его и откройте снова."
    case "not_bound":
      return "У этого бота пока нет кабинета."
    case "not_owner":
      return "Кабинет доступен только владельцу бота."
    case "account_suspended":
      return "Аккаунт бота приостановлен. Напишите в поддержку."
    case "email_not_verified":
      return "Сначала подтвердите почту для чеков."
    case "invalid_email":
      return "Это не похоже на адрес почты."
    case "same_address":
      return "Чеки уже приходят на этот адрес."
    case "bad_code":
      return "Неверный код."
    case "code_expired":
      return "Код больше не действует. Запросите новый."
    case "rate_limit_error":
      return "Слишком много попыток. Подождите немного."
    case "mail_failed":
    case "mail_unavailable":
      return "Не получилось отправить письмо. Попробуйте чуть позже."
    case "price_changed":
      return "Цена изменилась. Посмотрите тарифы ещё раз."
    case "plan_change_scheduled":
      return "Другой тариф уже куплен и начнётся после текущего периода."
    case "plan_change_needs_support":
      return "Эту смену тарифа можно сделать только через поддержку."
    case "payment_unavailable":
      return "Банк не ответил. Попробуйте через минуту."
    case "invites_unavailable":
      return "Не получилось загрузить приглашения. Попробуйте позже."
    default:
      return "Что-то пошло не так. Попробуйте ещё раз."
  }
}

/** Refusals after which nothing in the cabinet can work. */
export function fatal(err: unknown): boolean {
  return (
    err instanceof APIError &&
    ["init_invalid", "init_stale", "not_bound", "not_owner", "account_suspended", "cabinet_off"].includes(err.kind)
  )
}
