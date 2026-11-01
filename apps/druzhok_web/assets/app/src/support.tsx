import { useCallback, useEffect, useRef, useState, type ReactNode } from "react"
import {
  APIError,
  explain,
  support,
  type Attachment,
  type SupportMe,
  type SupportMessage,
  type ThreadStatus,
  type ThreadSummary,
  type ThreadView,
} from "./api"
import { backButton, closingConfirmation, confirmDialog, openExternal } from "./telegram"
import { plural, when } from "./format"
import { ErrorNote, Skeleton } from "./ui"

// The Поддержка tab: the owner's conversations with the team, on ruoc-gateway's
// /tg/api/support/* routes (the same threads the operator's inbox reads).
//
// Everything a person or an agent wrote is plain text: text nodes only, line
// breaks kept by CSS, and only https:// addresses made into links.

/** store.SupportBodyMax and SupportSubjectMax; the gateway checks them too. */
const BODY_MAX = 4000
const SUBJECT_MAX = 120
const BODY_WARN = 400

const THREAD_POLL_MS = 10_000
const LIST_POLL_MS = 30_000

const IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp"]

const STATUS_LABEL: Record<ThreadStatus, string> = {
  open: "Ждёт ответа",
  answered: "Есть ответ",
  resolved: "Решено",
}

type Route = { kind: "pending" } | { kind: "list" } | { kind: "new" } | { kind: "thread"; id: string; initial?: ThreadView }

/**
 * The words for a refusal. The support routes write theirs for the person, in
 * Russian; the cabinet's own refusals (init data, owner) have words in explain().
 */
function said(cause: unknown, fallback = "Не получилось. Попробуйте ещё раз."): string {
  if (cause instanceof APIError) {
    if (cause.status === 0) return explain(cause)
    if (/[а-яё]/i.test(cause.message)) return cause.message
    if (cause.status === 429) return "Слишком часто. Подождите немного и попробуйте снова."
    if (["init_invalid", "init_stale", "not_bound", "not_owner"].includes(cause.kind)) return explain(cause)
  }
  return fallback
}

/** Characters as the gateway counts them: code points, not UTF-16 units. */
function length(text: string): number {
  return Array.from(text).length
}

/** Runs `tick` every `ms` while the page is looked at, and when it is looked at again. */
function useVisibleTick(tick: () => void, ms: number) {
  const latest = useRef(tick)
  latest.current = tick
  useEffect(() => {
    const run = () => {
      if (document.visibilityState === "visible") latest.current()
    }
    const timer = window.setInterval(run, ms)
    document.addEventListener("visibilitychange", run)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener("visibilitychange", run)
    }
  }, [ms])
}

const DISCARD = "Выйти? Написанное не сохранится."

/** While the owner is writing: no tab bar over the keyboard, and Telegram asks before closing. */
function useWriting(on: boolean) {
  useEffect(() => {
    if (!on) return
    document.body.classList.add("editing")
    closingConfirmation(true)
    return () => {
      document.body.classList.remove("editing")
      closingConfirmation(false)
    }
  }, [on])
}

/** The way off a form: asks first when something written would be lost. */
function useLeave(dirty: boolean, back: () => void): () => void {
  const dirtyRef = useRef(dirty)
  dirtyRef.current = dirty
  return useCallback(() => {
    if (!dirtyRef.current) return back()
    void confirmDialog(DISCARD, true).then((ok) => ok && back())
  }, [back])
}

export default function Support({ onUnread }: { onUnread: (n: number) => void }) {
  const [me, setMe] = useState<SupportMe | null>(null)
  const [threads, setThreads] = useState<ThreadSummary[] | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [route, setRoute] = useState<Route>({ kind: "pending" })

  const refresh = useCallback(async () => {
    try {
      const [who, list] = await Promise.all([support.me(), support.threads()])
      setMe(who)
      setThreads(list)
      setFailure(null)
      onUnread(list.filter((t) => t.unread).length)
    } catch (cause) {
      setFailure(said(cause, "Не удалось загрузить обращения. Попробуйте ещё раз."))
    }
  }, [onUnread])

  useEffect(() => {
    void refresh()
  }, [refresh])
  useVisibleTick(() => void refresh(), LIST_POLL_MS)

  // Arriving: the conversation with an unread answer if there is one, the form
  // when there is nothing to read, the list otherwise.
  useEffect(() => {
    if (route.kind !== "pending" || threads === null) return
    const unread = threads.find((t) => t.unread)
    if (unread) setRoute({ kind: "thread", id: unread.id })
    else if (threads.length === 0) setRoute({ kind: "new" })
    else setRoute({ kind: "list" })
  }, [route.kind, threads])

  const go = useCallback((next: Route) => {
    setRoute(next)
    window.scrollTo(0, 0)
  }, [])
  const toList = useCallback(() => {
    void refresh()
    go({ kind: "list" })
  }, [refresh, go])
  const setMuted = useCallback(() => setMe((m) => (m ? { ...m, muted: true } : m)), [])

  if (!me || !threads) {
    return failure ? <ErrorNote error={failure} retry={() => void refresh()} /> : <Skeleton rows={4} />
  }

  return (
    <>
      <h1 className="support__title">Поддержка</h1>
      {me.muted ? (
        <p className="note-error" role="alert">
          Обращения временно недоступны, напишите на support@cleocode.ru. Прежние обращения можно читать.
        </p>
      ) : null}
      {route.kind === "list" || route.kind === "pending" ? (
        <ThreadList threads={threads} muted={me.muted} open={(id) => go({ kind: "thread", id })} create={() => go({ kind: "new" })} />
      ) : null}
      {route.kind === "new" ? (
        <NewThread
          me={me}
          back={toList}
          created={(view) => {
            void refresh()
            go({ kind: "thread", id: view.id, initial: view })
          }}
          onMuted={setMuted}
        />
      ) : null}
      {route.kind === "thread" ? (
        <Conversation key={route.id} id={route.id} initial={route.initial} me={me} back={toList} onRead={refresh} onMuted={setMuted} />
      ) : null}
    </>
  )
}

function ThreadList({
  threads,
  muted,
  open,
  create,
}: {
  threads: ThreadSummary[]
  muted: boolean
  open: (id: string) => void
  create: () => void
}) {
  return (
    <>
      {muted ? null : (
        <button className="primary" onClick={create}>
          Новое обращение
        </button>
      )}
      {threads.length === 0 ? (
        <p className="hint">Обращений пока нет. Напишите, если что-то не работает или непонятно. Ответ придёт сюда, и бот сообщит о нём в чате.</p>
      ) : (
        <div className="group">
          {threads.map((t) => (
            <button key={t.id} className="row support__row" onClick={() => open(t.id)}>
              <span className="row__text">
                <span className="row__title">
                  {t.unread ? <span className="support__dot" role="img" aria-label="Есть непрочитанный ответ" /> : null}
                  {t.subject}
                </span>
                <span className="row__sub">
                  #{t.number} · {STATUS_LABEL[t.status] ?? t.status} · {when(t.last_message_at)}
                </span>
              </span>
            </button>
          ))}
        </div>
      )}
    </>
  )
}

function NewThread({
  me,
  back,
  created,
  onMuted,
}: {
  me: SupportMe
  back: () => void
  created: (view: ThreadView) => void
  onMuted: () => void
}) {
  const [subject, setSubject] = useState("")
  const [body, setBody] = useState("")
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const uploads = useUploads(me)
  const dirty = body !== "" || subject !== "" || uploads.items.length > 0
  const leave = useLeave(dirty, back)
  useEffect(() => backButton(leave), [leave])
  useWriting(dirty)

  async function submit() {
    if (busy || uploads.busy || me.muted) return
    const missing = bodyProblem(body)
    if (missing) return setFailure(missing)
    setFailure(null)
    setBusy(true)
    try {
      created(await support.create({ subject: subject.trim() || undefined, body, attachment_ids: uploads.ids }))
    } catch (cause) {
      setBusy(false)
      if (cause instanceof APIError && cause.kind === "support_muted") onMuted()
      if (cause instanceof APIError && cause.kind === "invalid_attachments") uploads.clear()
      setFailure(said(cause, "Не удалось отправить. Попробуйте ещё раз."))
    }
  }

  return (
    <section className="card">
      <h2 className="support__heading">Новое обращение</h2>
      <p className="hint">Обычно отвечаем в течение нескольких часов.</p>
      <label className="support__label" htmlFor="support-subject">
        Тема, если хотите
      </label>
      <input
        id="support-subject"
        className="support__field"
        type="text"
        maxLength={SUBJECT_MAX}
        value={subject}
        disabled={me.muted}
        placeholder="Например, бот не отвечает"
        onChange={(e) => setSubject(e.target.value)}
      />
      <BodyField id="support-body" label="Сообщение" value={body} rows={5} disabled={me.muted} readOnly={busy} placeholder="Что случилось и что вы уже попробовали" onChange={setBody} />
      <Uploads uploads={uploads} me={me} disabled={me.muted || busy} />
      {failure ? (
        <p className="note-error" role="alert">
          {failure}
        </p>
      ) : null}
      <button className="primary" disabled={busy || uploads.busy || me.muted} onClick={() => void submit()}>
        {busy ? "Отправляем…" : "Отправить"}
      </button>
      <button className="link" onClick={leave}>
        Все обращения
      </button>
    </section>
  )
}

function bodyProblem(body: string): string | null {
  if (body.trim() === "") return "Напишите сообщение."
  if (length(body) > BODY_MAX) return `Сообщение длиннее ${BODY_MAX} знаков.`
  return null
}

function BodyField({
  id,
  label,
  value,
  rows,
  disabled,
  readOnly,
  placeholder,
  onChange,
}: {
  id: string
  label: string
  value: string
  rows: number
  disabled?: boolean
  readOnly?: boolean
  placeholder?: string
  onChange: (v: string) => void
}) {
  const left = BODY_MAX - length(value)
  return (
    <>
      <label className="support__label" htmlFor={id}>
        {label}
      </label>
      <textarea
        id={id}
        className="support__field support__field--area"
        rows={rows}
        value={value}
        disabled={disabled}
        readOnly={readOnly}
        placeholder={placeholder}
        aria-invalid={left < 0 ? true : undefined}
        onChange={(e) => onChange(e.target.value)}
      />
      {left <= BODY_WARN ? (
        <p className={left < 0 ? "note-error" : "hint"} aria-live="polite">
          {left >= 0
            ? `Осталось ${left} ${plural(left, "знак", "знака", "знаков")}`
            : `Длиннее на ${-left} ${plural(-left, "знак", "знака", "знаков")}`}
        </p>
      ) : null}
    </>
  )
}

type Upload =
  | { key: number; state: "uploading"; name: string; preview: string }
  | { key: number; state: "done"; name: string; preview: string; id: string }
  | { key: number; state: "failed"; name: string; error: string }

interface UploadList {
  items: Upload[]
  ids: string[]
  busy: boolean
  note: string | null
  pick: (files: FileList | null) => void
  remove: (key: number) => void
  clear: () => void
}

/**
 * Images go up the moment they are picked, so the message names them by id.
 * Type and size are checked here first, so a file the gateway would refuse
 * does not spend the account's uploads. The preview is the local file's own
 * blob: URL. A removed upload stays held at the gateway until its daily sweep.
 */
function useUploads(me: SupportMe): UploadList {
  const [items, setItems] = useState<Upload[]>([])
  const [note, setNote] = useState<string | null>(null)
  const next = useRef(1)
  const removed = useRef(new Set<number>())
  const previews = useRef(new Map<number, string>())
  const alive = useRef(true)

  useEffect(() => {
    alive.current = true
    const made = previews.current
    return () => {
      alive.current = false
      made.forEach((url) => URL.revokeObjectURL(url))
    }
  }, [])

  const drop = (key: number) => {
    const url = previews.current.get(key)
    if (url) URL.revokeObjectURL(url)
    previews.current.delete(key)
  }

  const update = (key: number, value: Upload) => {
    if (!alive.current || removed.current.has(key)) return
    setItems((all) => all.map((u) => (u.key === key ? value : u)))
  }

  const send = async (key: number, file: File, preview: string) => {
    try {
      let done: Attachment
      try {
        done = await support.upload(file)
      } catch (cause) {
        // The gateway decodes two images at a time; busy is worth one more try.
        if (!(cause instanceof APIError && cause.status === 503)) throw cause
        await new Promise((resolve) => window.setTimeout(resolve, 1500))
        done = await support.upload(file)
      }
      update(key, { key, state: "done", name: file.name, preview, id: done.id })
    } catch (cause) {
      drop(key)
      update(key, { key, state: "failed", name: file.name, error: said(cause, "Картинку не удалось загрузить.") })
    }
  }

  const pick = (files: FileList | null) => {
    setNote(null)
    if (!files || files.length === 0) return
    const most = me.tier.images_per_message
    const room = most - items.length
    const chosen = Array.from(files)
    if (chosen.length > room) {
      setNote(
        most === 1
          ? "К сообщению можно приложить одну картинку."
          : `К сообщению можно приложить не больше ${most} ${plural(most, "картинки", "картинок", "картинок")}.`,
      )
    }
    const added: Upload[] = []
    for (const file of chosen.slice(0, Math.max(0, room))) {
      const key = next.current++
      if (!IMAGE_TYPES.includes(file.type)) {
        added.push({ key, state: "failed", name: file.name, error: "Можно прикрепить только PNG, JPEG или WebP." })
      } else if (file.size > me.tier.max_image_bytes) {
        added.push({ key, state: "failed", name: file.name, error: `Картинка больше ${Math.floor(me.tier.max_image_bytes / (1 << 20))} МБ.` })
      } else {
        const preview = URL.createObjectURL(file)
        previews.current.set(key, preview)
        added.push({ key, state: "uploading", name: file.name, preview })
        void send(key, file, preview)
      }
    }
    setItems((all) => [...all, ...added])
  }

  return {
    items,
    ids: items.flatMap((u) => (u.state === "done" ? [u.id] : [])),
    busy: items.some((u) => u.state === "uploading"),
    note,
    pick,
    remove: (key) => {
      setNote(null)
      removed.current.add(key)
      drop(key)
      setItems((all) => all.filter((u) => u.key !== key))
    },
    clear: () => {
      setNote(null)
      items.forEach((u) => {
        removed.current.add(u.key)
        drop(u.key)
      })
      setItems([])
    },
  }
}

function Uploads({ uploads, me, disabled }: { uploads: UploadList; me: SupportMe; disabled?: boolean }) {
  const most = me.tier.images_per_message
  const mb = Math.floor(me.tier.max_image_bytes / (1 << 20))
  return (
    <>
      {uploads.items.length > 0 ? (
        <ul className="support__thumbs">
          {uploads.items.map((u) => (
            <li key={u.key} className="support__thumb">
              {u.state === "failed" ? (
                <span className="support__thumb-note" role="alert">
                  {u.error}
                </span>
              ) : (
                <img src={u.preview} alt={u.name} className={u.state === "uploading" ? "support__img--busy" : undefined} />
              )}
              <button className="support__thumb-x" aria-label={`Убрать картинку ${u.name}`} disabled={disabled} onClick={() => uploads.remove(u.key)}>
                ×
              </button>
            </li>
          ))}
        </ul>
      ) : null}
      {uploads.items.length >= most ? null : (
        <label className={`secondary secondary--small${disabled ? " support__attach--off" : ""}`}>
          <input
            className="support__file"
            type="file"
            accept={IMAGE_TYPES.join(",")}
            multiple={most > 1}
            disabled={disabled}
            onChange={(e) => {
              uploads.pick(e.target.files)
              // The same file can be picked again after it is removed.
              e.target.value = ""
            }}
          />
          Приложить картинку
        </label>
      )}
      <p className="hint">
        PNG, JPEG или WebP, до {mb} МБ, {most === 1 ? "одна на сообщение" : `не больше ${most} на сообщение`}.
      </p>
      {uploads.note ? (
        <p className="note-error" role="alert">
          {uploads.note}
        </p>
      ) : null}
    </>
  )
}

/** One conversation: the owner on the right, the team on the left, the system's lines between. */
function Conversation({
  id,
  initial,
  me,
  back,
  onRead,
  onMuted,
}: {
  id: string
  initial?: ThreadView
  me: SupportMe
  back: () => void
  onRead: () => Promise<void>
  onMuted: () => void
}) {
  const [view, setView] = useState<ThreadView | null>(initial ?? null)
  const [failure, setFailure] = useState<string | null>(null)
  const [gone, setGone] = useState(false)
  const viewRef = useRef(view)
  viewRef.current = view
  // Bumped by every full answer, so a poll that left before it cannot put an
  // older status back on screen.
  const generation = useRef(0)
  const polling = useRef(false)
  const end = useRef<HTMLDivElement>(null)
  const follow = useRef(true)
  const readRef = useRef(onRead)
  readRef.current = onRead

  const [writing, setWriting] = useState(false)
  const leave = useLeave(writing, back)
  useEffect(() => backButton(leave), [leave])

  const replace = useCallback((next: ThreadView) => {
    generation.current += 1
    follow.current = true
    setView(next)
  }, [])

  const load = useCallback(async () => {
    try {
      replace(await support.thread(id))
      setFailure(null)
      void readRef.current()
    } catch (cause) {
      if (cause instanceof APIError && cause.kind === "not_found") setGone(true)
      else setFailure(said(cause, "Не удалось открыть обращение. Попробуйте ещё раз."))
    }
  }, [id, replace])

  useEffect(() => {
    if (!initial) void load()
    // A thread just created arrives with its view.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [load])

  useVisibleTick(() => {
    const current = viewRef.current
    if (!current || polling.current) return
    polling.current = true
    const started = generation.current
    const last = current.messages[current.messages.length - 1]?.id
    support
      .thread(id, last)
      .then((fresh) => {
        const stale = started !== generation.current
        setView((prev) => {
          if (!prev) return prev
          const have = new Set(prev.messages.map((m) => m.id))
          const added = fresh.messages.filter((m) => !have.has(m.id))
          if (added.length === 0 && stale) return prev
          return {
            ...prev,
            ...(stale ? {} : { status: fresh.status, subject: fresh.subject }),
            messages: added.length > 0 ? [...prev.messages, ...added] : prev.messages,
          }
        })
        if (fresh.messages.length > 0) void readRef.current()
      })
      // The next tick asks again.
      .catch(() => {})
      .finally(() => {
        polling.current = false
      })
  }, THREAD_POLL_MS)

  const count = view?.messages.length ?? 0
  useEffect(() => {
    if (!follow.current || count === 0) return
    follow.current = false
    end.current?.scrollIntoView({ block: "nearest" })
  }, [count])

  if (gone) {
    return (
      <section className="card">
        <p>Обращение не найдено.</p>
        <button className="link" onClick={back}>
          Все обращения
        </button>
      </section>
    )
  }
  if (!view) return failure ? <ErrorNote error={failure} retry={() => void load()} /> : <Skeleton rows={4} />

  return (
    <>
      <button className="link support__back" onClick={leave}>
        ← Все обращения
      </button>
      <div>
        <h2 className="support__heading">{view.subject}</h2>
        <p className="hint">
          #{view.number} · {STATUS_LABEL[view.status] ?? view.status}
        </p>
      </div>
      <ol className="support__chat">
        {view.messages.map((m) => (
          <Message key={m.id} message={m} />
        ))}
      </ol>
      <div ref={end} />
      {view.status === "resolved" ? null : <Resolve id={view.id} done={replace} />}
      {me.muted ? null : (
        <Reply
          id={view.id}
          me={me}
          resolved={view.status === "resolved"}
          onWriting={setWriting}
          sent={(next) => {
            replace(next)
            void readRef.current()
          }}
          onMuted={onMuted}
        />
      )}
    </>
  )
}

function Message({ message }: { message: SupportMessage }) {
  if (message.author === "system") {
    return (
      <li className="support__msg support__msg--system">
        <span>
          <Text text={message.body} /> · <time dateTime={message.created_at}>{when(message.created_at)}</time>
        </span>
      </li>
    )
  }
  const mine = message.author === "customer"
  const name = message.agent?.name ?? "Поддержка"
  return (
    <li className={`support__msg ${mine ? "support__msg--mine" : "support__msg--team"}`}>
      {mine ? null : (
        <span className="support__who">
          {name}
          {message.agent?.ai ? <span className="support__ai">ИИ-помощник</span> : null}
        </span>
      )}
      <div className="support__bubble">
        <Text text={message.body} />
        {message.attachments.map((a) => (
          <AttachmentImage key={a.id} attachment={a} />
        ))}
      </div>
      <time className="support__time" dateTime={message.created_at}>
        {when(message.created_at)}
      </time>
    </li>
  )
}

/**
 * An attached image. The route wants the tma header, which an <img src> cannot
 * send, so the bytes are fetched and shown from a blob: URL, revoked when the
 * message leaves the screen. Full size is an overlay on this page, since the
 * URL belongs to this document.
 */
function AttachmentImage({ attachment }: { attachment: Attachment }) {
  const [url, setUrl] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)
  const [big, setBig] = useState(false)
  const [round, setRound] = useState(0)

  useEffect(() => {
    let live = true
    let made: string | null = null
    setFailed(false)
    support.attachment(attachment.id).then(
      (blob) => {
        if (!live) return
        made = URL.createObjectURL(blob)
        setUrl(made)
      },
      () => live && setFailed(true),
    )
    return () => {
      live = false
      if (made) URL.revokeObjectURL(made)
    }
  }, [attachment.id, round])

  const ratio = attachment.width > 0 && attachment.height > 0 ? `${attachment.width} / ${attachment.height}` : "4 / 3"
  if (failed) {
    return (
      <p className="support__img-failed">
        Картинку не удалось загрузить.{" "}
        <button className="link" onClick={() => setRound((n) => n + 1)}>
          Повторить
        </button>
      </p>
    )
  }
  return (
    <>
      <button className="support__img" style={{ aspectRatio: ratio }} disabled={!url} aria-label="Открыть картинку" onClick={() => setBig(true)}>
        {url ? <img src={url} alt="Приложенная картинка" /> : null}
      </button>
      {big && url ? (
        <button className="support__lightbox" aria-label="Закрыть картинку" onClick={() => setBig(false)}>
          <img src={url} alt="Приложенная картинка, полный размер" />
        </button>
      ) : null}
    </>
  )
}

const LINK = /https:\/\/[^\s<>"'«»]+/g

/** Plain text with its line breaks, and https:// addresses as links. Text nodes only. */
function Text({ text }: { text: string }) {
  const parts: ReactNode[] = []
  let at = 0
  for (const match of text.matchAll(LINK)) {
    let url = match[0]
    // A sentence's full stop or a closing bracket is not part of the address.
    const tail = /[.,;:!?)\]}]+$/.exec(url)
    if (tail) url = url.slice(0, -tail[0].length)
    const start = match.index ?? 0
    let good = false
    try {
      good = new URL(url).protocol === "https:" && url.length > "https://".length
    } catch {
      good = false
    }
    if (!good) continue
    if (start > at) parts.push(text.slice(at, start))
    const href = url
    parts.push(
      <a
        key={start}
        href={href}
        target="_blank"
        rel="noopener noreferrer nofollow"
        onClick={(e) => {
          // Telegram's own browser when it can; the plain link otherwise.
          if (openExternal(href)) e.preventDefault()
        }}
      >
        {url}
      </a>,
    )
    at = start + url.length
  }
  if (at < text.length) parts.push(text.slice(at))
  return <span className="support__text">{parts}</span>
}

function Resolve({ id, done }: { id: string; done: (v: ThreadView) => void }) {
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)

  async function resolve() {
    setBusy(true)
    setFailure(null)
    try {
      done(await support.resolve(id))
    } catch (cause) {
      setFailure(said(cause))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <button className="secondary secondary--small" disabled={busy} onClick={() => void resolve()}>
        Вопрос решён
      </button>
      {failure ? (
        <p className="note-error" role="alert">
          {failure}
        </p>
      ) : null}
    </>
  )
}

function Reply({
  id,
  me,
  resolved,
  onWriting,
  sent,
  onMuted,
}: {
  id: string
  me: SupportMe
  resolved: boolean
  onWriting: (on: boolean) => void
  sent: (view: ThreadView) => void
  onMuted: () => void
}) {
  const [body, setBody] = useState("")
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const uploads = useUploads(me)
  const dirty = body !== "" || uploads.items.length > 0
  useWriting(dirty)
  useEffect(() => {
    onWriting(dirty)
    return () => onWriting(false)
  }, [dirty, onWriting])

  async function submit() {
    if (busy || uploads.busy) return
    const missing = bodyProblem(body)
    if (missing) return setFailure(missing)
    setFailure(null)
    setBusy(true)
    try {
      const view = await support.reply(id, body, uploads.ids)
      setBody("")
      uploads.clear()
      sent(view)
    } catch (cause) {
      if (cause instanceof APIError && cause.kind === "support_muted") onMuted()
      if (cause instanceof APIError && cause.kind === "invalid_attachments") uploads.clear()
      setFailure(said(cause, "Не удалось отправить. Попробуйте ещё раз."))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="card">
      <BodyField
        id={`reply-${id}`}
        label={resolved ? "Написать ещё. Обращение откроется снова" : "Ответ"}
        value={body}
        rows={3}
        readOnly={busy}
        onChange={setBody}
      />
      <Uploads uploads={uploads} me={me} disabled={busy} />
      {failure ? (
        <p className="note-error" role="alert">
          {failure}
        </p>
      ) : null}
      <button className="primary" disabled={busy || uploads.busy} onClick={() => void submit()}>
        {busy ? "Отправляем…" : "Отправить"}
      </button>
    </section>
  )
}
