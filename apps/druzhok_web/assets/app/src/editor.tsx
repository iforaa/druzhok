import { useEffect, useRef, useState, type MutableRefObject } from "react"
import { APIError, explain, type Save, type Text } from "./api"
import { closingConfirmation, confirmDialog } from "./telegram"

// Editing one text page: the file's raw text in a textarea (spec
// docs/superpowers/specs/2026-10-31-panel-editable-pages-design.md). A refused
// save never loses what the owner typed; only they can throw it away.

/** Which rules the page's text goes by; a page without a note has none to explain. */
export type EditorNote = "memory" | "skill"

const discardQuestion = "Выйти без сохранения? Изменения пропадут."

/** How many characters the server counts: code points, not UTF-16 units. */
function codePoints(s: string): number {
  let n = 0
  for (const _ of s) n++
  return n
}

export function Editor({
  title,
  file,
  load,
  save,
  note,
  mnemosyne,
  onBack,
  onChanged,
  onClose,
  onSaved,
}: {
  title: string
  file: Text
  load: () => Promise<Text>
  save: Save
  note?: EditorNote
  mnemosyne: boolean
  onBack: MutableRefObject<(() => void) | null>
  /** The file as it now is, after the owner chose to see a newer version. */
  onChanged: (file: Text) => void
  onClose: () => void
  onSaved: (file: Text) => void
}) {
  // What the page was opened on, or the newer version the owner took instead.
  const [start, setStart] = useState(file)
  const [draft, setDraft] = useState(file.text)
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<APIError | Error | null>(null)
  const [copied, setCopied] = useState<"yes" | "no" | null>(null)
  const area = useRef<HTMLTextAreaElement>(null)

  const dirty = draft !== start.text
  const count = file.limit ? codePoints(draft) : 0
  const over = !!file.limit && count > file.limit
  const kind = failure instanceof APIError ? failure.kind : null

  useEffect(() => {
    document.body.classList.add("editing")
    return () => document.body.classList.remove("editing")
  }, [])

  useEffect(() => {
    closingConfirmation(dirty)
    return () => closingConfirmation(false)
  }, [dirty])

  // Read at the moment of the tap: the back button is registered once.
  const leave = useRef<() => void>(onClose)
  leave.current = async () => {
    if (busy) return
    // With no dialog to ask in, the owner's own tap on «Отмена» or back decides.
    if (!dirty || (await confirmDialog(discardQuestion, true))) onClose()
  }
  useEffect(() => {
    onBack.current = () => leave.current()
    return () => {
      onBack.current = null
    }
  }, [onBack])

  const submit = async () => {
    setBusy(true)
    setFailure(null)
    setCopied(null)
    try {
      const saved = await save(draft, start.sha256 ?? null)
      onSaved({ ...start, ...saved, text: draft, truncated: false })
    } catch (err) {
      setFailure(err instanceof Error ? err : new Error(String(err)))
      setBusy(false)
    }
  }

  const showNewer = async () => {
    if (!(await confirmDialog("Заменить ваш текст новой версией? То, что вы написали, пропадёт."))) return
    setBusy(true)
    try {
      const newer = await load()
      setStart(newer)
      setDraft(newer.text)
      onChanged(newer)
      setFailure(null)
    } catch (err) {
      setFailure(err instanceof Error ? err : new Error(String(err)))
    } finally {
      setBusy(false)
    }
  }

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(draft)
      setCopied("yes")
    } catch {
      // Not allowed in this client: leave the text selected to copy by hand.
      area.current?.focus()
      area.current?.select()
      setCopied("no")
    }
  }

  return (
    <>
      <h1 className="screen-title">{title}</h1>
      {note === "memory" ? <p className="hint">Знак § разделяет записи.</p> : null}
      {note === "memory" && mnemosyne ? (
        <p className="hint">Долгая память бота хранится отдельно: если удалить строку здесь, он всё равно может это вспомнить.</p>
      ) : null}
      {note === "skill" ? <p className="hint">Наверху, между строками ---, имя навыка (name): его менять нельзя.</p> : null}
      <textarea
        ref={area}
        className={over ? "editor__area editor__area--over" : "editor__area"}
        aria-label={title}
        value={draft}
        readOnly={busy}
        spellCheck
        onChange={(e) => {
          setDraft(e.target.value)
          setCopied(null)
        }}
      />
      {file.limit ? (
        <p className={over ? "editor__count editor__count--over" : "editor__count"}>
          {count} / {file.limit}
        </p>
      ) : null}
      {failure ? (
        <div className="card card--error" role="alert">
          <p>
            {kind === "init_stale"
              ? "Кабинет открыт слишком давно, сохранить уже нельзя. Скопируйте текст, закройте кабинет, откройте снова и вставьте."
              : explain(failure)}
          </p>
          {kind === "blocked_entry" && failure instanceof APIError && failure.field("entry") ? (
            <p className="editor__entry">{failure.field("entry")}…</p>
          ) : null}
          {kind === "file_changed" ? (
            <button className="link" disabled={busy} onClick={showNewer}>
              Показать новую версию
            </button>
          ) : null}
          {kind === "init_stale" ? (
            <button className="link" onClick={copy}>
              Скопировать
            </button>
          ) : null}
          {copied === "yes" ? <p className="hint">Скопировано.</p> : null}
          {copied === "no" ? <p className="hint">Текст выделен: скопируйте его сами.</p> : null}
        </div>
      ) : null}
      <div className="editor__actions">
        <button className="primary" disabled={busy || over || !dirty} onClick={submit}>
          {busy ? "Сохраняю…" : "Сохранить"}
        </button>
        <button className="secondary" disabled={busy} onClick={() => leave.current()}>
          Отмена
        </button>
      </div>
    </>
  )
}
