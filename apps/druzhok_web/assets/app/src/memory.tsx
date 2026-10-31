import { useEffect, useRef } from "react"
import { panelApi, type Files, type Skill, type Text } from "./api"
import { openExternal } from "./telegram"
import { plural, size, when } from "./format"
import { render } from "./markdown"
import { ErrorNote, Row, Skeleton, useLoad } from "./ui"

// Память, a section of Бот: what the bot knows and can do, read only: its
// character, its notes and what it knows about the owner (Markdown files it
// keeps), its scheduled jobs, the skills it added, and its site's files.

export type MemoryScreen =
  | { kind: "text"; title: string; load: () => Promise<Text>; back?: MemoryScreen }
  | { kind: "jobs" }
  | { kind: "skills" }
  | { kind: "site" }

/** The list on Бот; a row with something to show opens its screen. */
export function MemoryList({
  files,
  error,
  reload,
  open,
}: {
  files: Files | null
  error: string | null
  reload: () => void
  open: (s: MemoryScreen) => void
}) {
  const meta = (m: Files["soul"]) => (m ? `${size(m.size)} · изменён ${when(m.modified_at)}` : "пока пусто")
  const text = (title: string, kind: "soul" | "memory" | "user") => () =>
    open({ kind: "text", title, load: () => panelApi.file(kind) })

  return (
    <>
      <span className="label">Память</span>
      <p className="hint">Что бот знает и умеет. Он ведёт это сам, по ходу разговоров.</p>
      {error ? <ErrorNote error={error} retry={reload} /> : null}
      {!files && !error ? <Skeleton rows={3} /> : null}
      {files ? (
        <div className="group">
          <Row icon="face" tone="purple" title="Характер" sub={meta(files.soul)} onClick={files.soul ? text("Характер", "soul") : null} />
          <Row icon="brain" tone="pink" title="Заметки бота" sub={meta(files.memory)} onClick={files.memory ? text("Заметки бота", "memory") : null} />
          <Row icon="user" tone="blue" title="О вас" sub={meta(files.user)} onClick={files.user ? text("О вас", "user") : null} />
          <Row
            icon="clock"
            tone="orange"
            title="Напоминания и задачи"
            sub={files.jobs.count ? `${files.jobs.count} ${plural(files.jobs.count, "задача", "задачи", "задач")}` : "пока нет"}
            onClick={files.jobs.count ? () => open({ kind: "jobs" }) : null}
          />
          <Row
            icon="puzzle"
            tone="green"
            title="Навыки"
            sub={`добавленные: ${files.skills.own} · встроенные: ${files.skills.bundled}`}
            onClick={files.skills.own ? () => open({ kind: "skills" }) : null}
          />
          <Row
            icon="globe"
            tone="teal"
            title="Сайт"
            sub={files.site?.files ? `${files.site.files} ${plural(files.site.files, "файл", "файла", "файлов")}` : "пока нет"}
            onClick={files.site?.files ? () => open({ kind: "site" }) : null}
          />
        </div>
      ) : null}
    </>
  )
}

/** One of the list's screens, open over Бот. */
export function MemoryView({ screen, open }: { screen: MemoryScreen; open: (s: MemoryScreen) => void }) {
  switch (screen.kind) {
    case "text":
      return <TextView title={screen.title} load={screen.load} />
    case "jobs":
      return <JobsView />
    case "skills":
      return <SkillsView open={(title, load) => open({ kind: "text", title, load, back: { kind: "skills" } })} />
    case "site":
      return <SiteView />
  }
}

function TextView({ title, load }: { title: string; load: () => Promise<Text> }) {
  const { data: text, error, reload } = useLoad(load, [load])
  const box = useRef<HTMLDivElement>(null)

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
      {error ? <ErrorNote error={error} retry={reload} /> : null}
      {!text && !error ? <Skeleton rows={5} /> : null}
      {text ? (
        <>
          <p className="hint">Изменён {when(text.modified_at)}</p>
          <div ref={box} className="card markdown" dangerouslySetInnerHTML={{ __html: render(text.text) }} />
          {text.truncated ? <p className="hint">Файл длинный, показано начало.</p> : null}
        </>
      ) : null}
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
  const { data, error, reload } = useLoad(panelApi.jobs)
  return (
    <>
      <h1 className="screen-title">Напоминания и задачи</h1>
      <p className="hint">Чтобы изменить или удалить задачу, напишите боту.</p>
      {error ? <ErrorNote error={error} retry={reload} /> : null}
      {data?.error ? <ErrorNote error="Файл задач не читается." /> : null}
      {!data && !error ? <Skeleton rows={3} /> : null}
      {data?.jobs.map((j, i) => (
        <section key={i} className="card">
          <div className="card__head">
            <h2>{j.name}</h2>
            <span className={`chip chip--${j.state === "scheduled" ? "awake" : j.state === "error" ? "error" : "asleep"}`}>
              {jobState[j.state] ?? j.state}
            </span>
          </div>
          <p className="hint">{j.schedule}</p>
          {j.prompt && j.prompt !== j.name ? <p className="prompt">{j.prompt}</p> : null}
          <dl className="pairs">
            <div>
              <dt>Следующий раз</dt>
              <dd>{when(j.next_run_at)}</dd>
            </div>
            <div>
              <dt>Прошлый раз</dt>
              <dd>
                {when(j.last_run_at)}
                {j.last_status ? ` · ${j.last_status}` : ""}
              </dd>
            </div>
          </dl>
        </section>
      ))}
    </>
  )
}

function SkillsView({ open }: { open: (title: string, load: () => Promise<Text>) => void }) {
  const { data, error, reload } = useLoad(panelApi.skills)
  return (
    <>
      <h1 className="screen-title">Навыки</h1>
      <p className="hint">Навыки, которые бот добавил сам: написал или установил. Встроенные здесь не показаны.</p>
      {error ? <ErrorNote error={error} retry={reload} /> : null}
      {!data && !error ? <Skeleton rows={6} /> : null}
      {data ? (
        <div className="group">
          {data.skills.map((s: Skill) => (
            <Row
              key={s.path.join("/")}
              icon="puzzle"
              tone="green"
              title={s.name}
              sub={[s.category, s.description].filter(Boolean).join(" · ")}
              onClick={() => open(s.name, () => panelApi.skill(s))}
            />
          ))}
        </div>
      ) : null}
    </>
  )
}

function SiteView() {
  const { data, error, reload } = useLoad(panelApi.site)
  const files = data ? (data.files ?? []) : null
  const sites = files ? Array.from(new Set(files.map((f) => f.site))) : []
  return (
    <>
      <h1 className="screen-title">Сайт</h1>
      {error ? <ErrorNote error={error} retry={reload} /> : null}
      {!files && !error ? <Skeleton rows={4} /> : null}
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
