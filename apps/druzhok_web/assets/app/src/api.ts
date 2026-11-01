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
  /**
   * The Cleo Code account this bot spends from, or null when it spends its
   * own. Linked, every other field here describes that account, and the
   * receipt is its owner's verified email.
   */
  linked: Linked | null
}

export interface Linked {
  email_masked: string
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

/**
 * A refusal from the API: its error type and status, and the body it came
 * in, for a refusal that says more than its type (link_plan_active's date).
 */
export class APIError extends Error {
  constructor(
    readonly status: number,
    readonly kind: string,
    message: string,
    readonly body: Record<string, unknown> = {},
  ) {
    super(message)
  }

  /** A string field of the refusal, beside the error or inside it. */
  field(name: string): string | null {
    const inner = this.body.error
    const v = this.body[name] ?? (inner && typeof inner === "object" ? (inner as Record<string, unknown>)[name] : undefined)
    return typeof v === "string" ? v : null
  }
}

// ruoc's public origin, from GET /app/api/bot; billing calls wait for it.
let billingBase = ""

export function setBillingBase(url: string) {
  billingBase = url.replace(/\/+$/, "")
}

/** ruoc's user portal, where a Cleo Code account is made and signed into. */
export function portalUrl(): string {
  return `${billingBase}/account/`
}

function call<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  return request<T>(`${billingBase}/tg/api/${path}`, method, body)
}

function panel<T>(path: string): Promise<T> {
  return request<T>(`/app/api/${path}`, "GET")
}

function panelPost<T>(path: string, body: unknown): Promise<T> {
  return request<T>(`/app/api/${path}`, "POST", body)
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
  if (!resp.ok) throw await refused(resp)
  return (await resp.json().catch(() => ({}))) as T
}

function authHeaders(): Record<string, string> {
  return { Authorization: `tma ${initData()}`, "X-Telegram-Bot": botID() }
}

async function refused(resp: Response): Promise<APIError> {
  const data: unknown = await resp.json().catch(() => ({}))
  const answer = data && typeof data === "object" ? (data as Record<string, unknown>) : {}
  const err = answer.error as { type?: string; code?: string; message?: string } | undefined
  // ruoc names a refusal in `type`; where it also sets OpenAI's `code`,
  // that is the specific one and `type` is the generic class.
  return new APIError(resp.status, err?.code ?? err?.type ?? "unknown", err?.message ?? "", answer)
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
  /** What happens to settings saved in the panel (panel controls spec). */
  apply: { state: ApplyState; error: string | null }
  access: { allow_all_users: boolean; allowed_users: number; free_response_chats: number }
  billing_url: string
  /** The superbot's @username, where a delete is confirmed; null when unknown. */
  superbot: string | null
}

export type ApplyState = "applied" | "waiting" | "on_wake" | "on_start" | "failed"

/** The settings the owner may change; the names are those of `Bot.settings`. */
export interface SettingChanges {
  language?: string
  timezone?: string
  mention_only?: boolean
  image_gen_enabled?: boolean
  image_gen_model?: string | null
  website_hosting_enabled?: boolean
}

export interface ImageModel {
  id: string
  name: string
  rub_per_image: string
  default: boolean
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
  /** Null when there is no file yet. */
  modified_at: string | null
  truncated: boolean
  /** Of the whole file; what a save names as what it was editing. Null when there is no file. */
  sha256?: string | null
  editable?: boolean
  /** The file is there and cannot be read safely. */
  unreadable?: boolean
  /** In code points. */
  limit?: number | null
}

export interface Saved {
  sha256: string
  modified_at: string
}

export type Save = (text: string, base: string | null) => Promise<Saved>

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

export interface PublishedSite {
  name: string
  url: string
  files: number
  bytes: number
  published_at: string
  disabled: boolean
}

export const panelApi = {
  bot: () => panel<Bot>("bot"),
  files: () => panel<Files>("files"),
  file: (kind: "soul" | "memory" | "user") => panel<Text>(`files/${kind}`),
  jobs: () => panel<{ jobs: Job[]; error?: string }>("jobs"),
  saveFile: (kind: "soul" | "memory" | "user"): Save => (text, base) =>
    panelPost<Saved>(`files/${kind}`, { text, base_sha256: base }),
  skills: () => panel<{ skills: Skill[]; system?: Skill[] }>("skills"),
  skill: (s: Skill) => panel<Text>(`skills/${s.path.map(encodeURIComponent).join("/")}`),
  saveSkill: (s: Skill): Save => (text, base) =>
    panelPost<Saved>(`skills/${s.path.map(encodeURIComponent).join("/")}`, { text, base_sha256: base }),
  site: () => panel<{ files: SiteFile[] | null }>("site"),
  published: () => panel<{ published: PublishedSite[] | null }>("site/published"),
  invites: () => panel<{ links: Invite[]; used: number }>("invites"),
  imageModels: () => panel<{ models: ImageModel[] }>("image-models"),
  saveSettings: (changes: SettingChanges) => panelPost<{ bot: Bot }>("settings", { changes }),
  deleteBot: () => panelPost<{ deleted: true }>("delete", {}),
}

// Answers the screens share (the account shows on Бот and Счёт), kept
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
  /** Points this bot's spending at the Cleo Code account these credentials open. */
  link: (email: string, password: string) => call<{ linked: Linked }>("POST", "link", { email, password }),
}

export type ThreadStatus = "open" | "answered" | "resolved"

export interface ThreadSummary {
  id: string
  number: number
  subject: string
  status: ThreadStatus
  unread: boolean
  last_message_at: string
  created_at: string
}

export interface Attachment {
  id: string
  content_type: string
  size: number
  width: number
  height: number
}

export interface SupportMessage {
  id: number
  author: "customer" | "agent" | "system"
  agent: { name: string; avatar: string | null; ai: boolean } | null
  body: string
  created_at: string
  attachments: Attachment[]
}

export interface ThreadView {
  id: string
  number: number
  subject: string
  status: ThreadStatus
  created_at: string
  messages: SupportMessage[]
}

export interface SupportMe {
  status: string
  muted: boolean
  tier: { images_per_message: number; max_image_bytes: number }
}

export const support = {
  me: () => call<SupportMe>("GET", "support/me"),
  unread: () => call<{ unread: number }>("GET", "support/unread"),
  threads: () => call<ThreadSummary[]>("GET", "support/threads"),
  thread: (id: string, after?: number) =>
    call<ThreadView>("GET", `support/threads/${encodeURIComponent(id)}${after ? `?after=${after}` : ""}`),
  create: (input: { subject?: string; body: string; attachment_ids: string[] }) =>
    call<ThreadView>("POST", "support/threads", input),
  reply: (id: string, body: string, attachment_ids: string[]) =>
    call<ThreadView>("POST", `support/threads/${encodeURIComponent(id)}/messages`, { body, attachment_ids }),
  resolve: (id: string) => call<ThreadView>("POST", `support/threads/${encodeURIComponent(id)}/resolve`),
  /** The browser sets the multipart Content-Type, with its boundary. */
  upload: async (file: File): Promise<Attachment> => {
    const form = new FormData()
    form.append("file", file)
    let resp: Response
    try {
      resp = await fetch(`${billingBase}/tg/api/support/attachments`, { method: "POST", headers: authHeaders(), body: form })
    } catch {
      throw new APIError(0, "network", "нет связи")
    }
    if (!resp.ok) throw await refused(resp)
    return (await resp.json()) as Attachment
  },
  /** An <img> cannot send the tma header, so the bytes come here and show from a blob: URL. */
  attachment: async (id: string): Promise<Blob> => {
    let resp: Response
    try {
      resp = await fetch(`${billingBase}/tg/api/support/attachments/${encodeURIComponent(id)}`, { headers: authHeaders() })
    } catch {
      throw new APIError(0, "network", "нет связи")
    }
    if (!resp.ok) throw await refused(resp)
    return resp.blob()
  },
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
    case "unpublish_failed":
      return "Не получилось снять все сайты с публикации, поэтому настройка не изменилась. Часть сайтов могла уже перестать открываться. Попробуйте ещё раз."
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
    case "link_changed":
      return "Счёт бота изменился. Посмотрите тарифы ещё раз."
    case "linked":
      return "Чеки приходят на почту подключённого аккаунта Клео Код."
    case "plan_change_scheduled":
      return "Другой тариф уже куплен и начнётся после текущего периода."
    case "plan_change_needs_support":
      return "Эту смену тарифа можно сделать только через поддержку."
    case "payment_unavailable":
      return "Банк не ответил. Попробуйте через минуту."
    case "invites_unavailable":
      return "Не получилось загрузить приглашения. Попробуйте позже."
    case "unknown_setting":
      return "Эту настройку здесь поменять нельзя."
    case "invalid_setting":
      return "Такое значение не подходит."
    case "images_off":
      return "Сначала включите картинки."
    case "catalogue_unavailable":
      return "Не получилось загрузить список моделей. Попробуйте позже."
    case "save_failed":
      return "Не получилось сохранить. Попробуйте ещё раз."
    case "too_long":
      return "Текст слишком длинный. Сократите его и сохраните снова."
    case "invalid_text":
      return "В тексте есть символы, которые нельзя сохранить."
    case "empty_soul":
      return "Характер не может быть пустым."
    case "invalid_skill":
      return "Бот не сможет прочитать такой навык. Наверху должен остаться блок между строками ---, с тем же name и с description, а после него текст."
    case "file_changed":
      return "Пока вы редактировали, бот изменил этот файл."
    case "blocked_entry":
      return "Бот не примет эту запись. Уберите просьбы отправить что-то по ссылке, ключи доступа и скрытые символы."
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
