import { useEffect, useRef, useState } from "react"
import { explain, panelApi, type ApplyState, type Bot, type ImageModel, type SettingChanges } from "./api"
import { backButton, closePanel, confirmDialog, openTelegram } from "./telegram"
import { plural, when } from "./format"
import { Choice, ErrorNote, Icon, Row, Segmented, Skeleton, Toggle, useLoad } from "./ui"

// Настройки: the bot's settings, who may talk to it, and deleting the bot.
// Language, time zone, groups, pictures and the site are the owner's to change
// (panel controls spec); a choice saves at once, and the bot picks it up when
// it is not answering. Only the two longer lists have a screen of their own. A
// delete asks once in a Telegram dialog and then deletes.

type Screen = "main" | "timezone" | "images" | "deleted"

const languages: [string, string][] = [
  ["ru", "русский"],
  ["en", "английский"],
]

const zones: [string, string][] = [
  ["Asia/Almaty", "Алматы"],
  ["Europe/Moscow", "Москва"],
  ["Asia/Tashkent", "Ташкент"],
  ["Europe/Istanbul", "Стамбул"],
  ["Asia/Tbilisi", "Тбилиси"],
  ["UTC", "UTC (Гринвич)"],
]

function zoneName(tz: string): string {
  return zones.find(([id]) => id === tz)?.[1] ?? tz
}

const applyText: Record<ApplyState, string> = {
  applied: "Сохранено",
  waiting: "Применится, когда бот закончит отвечать",
  on_wake: "Применится, когда бот проснётся",
  on_start: "Применится при следующем запуске",
  failed: "Не получилось применить. Напишите в поддержку",
}

/** Saves a change and keeps the bot fresh while it waits to be applied. */
function useSettings(bot: Bot, onBot: (b: Bot) => void) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  // Bumped by every save: a poll started before it must not overwrite what the save returned.
  const generation = useRef(0)

  const save = async (changes: SettingChanges) => {
    generation.current += 1
    setBusy(true)
    setError(null)
    try {
      const r = await panelApi.saveSettings(changes)
      // Polls sent while the save was in flight may have read the old row.
      generation.current += 1
      onBot(r.bot)
      setSaved(true)
    } catch (err) {
      setError(explain(err))
    } finally {
      setBusy(false)
    }
  }

  // While a change waits, keep asking: every 3 s for up to 2 min before a quiet
  // restart, every 15 s for up to 30 min until a wake or start, and again
  // whenever the panel comes back into view. Then keep the last text.
  const state = bot.apply.state
  const pending = state === "waiting" || state === "on_wake" || state === "on_start"
  useEffect(() => {
    if (!pending) return
    let live = true
    const started = Date.now()
    const [every, upTo] = state === "waiting" ? [3000, 120_000] : [15_000, 1_800_000]
    const refresh = () => {
      const gen = generation.current
      panelApi.bot().then(
        (b) => live && gen === generation.current && onBot(b),
        () => {},
      )
    }
    const timer = window.setInterval(() => {
      if (Date.now() - started > upTo) {
        window.clearInterval(timer)
        return
      }
      refresh()
    }, every)
    const onShow = () => document.visibilityState === "visible" && refresh()
    document.addEventListener("visibilitychange", onShow)
    return () => {
      live = false
      window.clearInterval(timer)
      document.removeEventListener("visibilitychange", onShow)
    }
  }, [pending, state, onBot])

  return { save, busy, error, saved, clearError: () => setError(null) }
}

type Settings = ReturnType<typeof useSettings>

export default function Settings({ bot, onBot }: { bot: Bot; onBot: (b: Bot) => void }) {
  const [screen, setScreen] = useState<Screen>("main")
  const settings = useSettings(bot, onBot)
  const published = useLoad(panelApi.published, [bot.settings.website_hosting_enabled])
  const [deleting, setDeleting] = useState(false)
  const [deleteError, setDeleteError] = useState<string | null>(null)
  const open = (s: Screen) => {
    settings.clearError()
    setScreen(s)
  }
  useEffect(() => {
    window.scrollTo(0, 0)
    return backButton(screen === "main" || screen === "deleted" ? null : () => open("main"))
  }, [screen])

  switch (screen) {
    case "timezone":
      return <TimezoneScreen bot={bot} settings={settings} />
    case "images":
      return <ImagesScreen bot={bot} settings={settings} />
    case "deleted":
      return <Deleted />
  }

  const s = bot.settings
  const a = bot.access
  // Only the gateway knows the address, and only after the first publish.
  const siteAddress = published.data?.published?.[0]?.url?.replace(/^https:\/\//, "").replace(/\/.*$/, "")
  const name = s.trigger_name

  const toggleSite = async (on: boolean) => {
    const ok = await confirmDialog(
      on
        ? "Сайты, которые опубликует бот, будут открыты всем, у кого есть ссылка. Бот пришлёт её сам."
        : "Все опубликованные сайты бота перестанут открываться. Файлы останутся у бота, а если включить снова, сайты нужно будет опубликовать заново.",
    )
    if (!ok) return
    settings.save({ website_hosting_enabled: on })
  }

  const remove = async () => {
    const ok = await confirmDialog(
      `Удалить бота ${bot.title || bot.name} навсегда? Память, файлы, напоминания и сайт будут удалены. Оплаченный тариф не возвращается. Это нельзя отменить.`,
    )
    if (!ok) return
    setDeleting(true)
    setDeleteError(null)
    try {
      await panelApi.deleteBot()
      setScreen("deleted")
    } catch (err) {
      setDeleteError(explain(err))
    } finally {
      setDeleting(false)
    }
  }

  return (
    <>
      <h1 className="screen-title">Настройки</h1>

      <div className="group">
        <Segmented
          icon="chat"
          tone="blue"
          title="Язык ответов"
          options={languages}
          value={s.language}
          busy={settings.busy}
          onPick={(language) => settings.save({ language })}
        />
        <Segmented
          icon="group"
          tone="purple"
          title="В группах"
          sub={
            s.mention_only
              ? name
                ? `по имени «${name}» или упоминанию`
                : "по имени или упоминанию"
              : "на каждое сообщение в группе"
          }
          options={[
            ["mention", "когда зовут"],
            ["all", "на всё"],
          ]}
          value={s.mention_only ? "mention" : "all"}
          busy={settings.busy}
          onPick={(v) => settings.save({ mention_only: v === "mention" })}
        />
        <Row icon="clock" tone="teal" title="Часовой пояс" sub={zoneName(s.timezone)} onClick={() => open("timezone")} />
        <Row icon="image" tone="orange" title="Картинки" sub={s.image_gen_enabled ? "рисует" : "выключены"} onClick={() => open("images")} />
        <Toggle
          icon="globe"
          tone="green"
          title="Сайт"
          sub={s.website_hosting_enabled ? (siteAddress ?? "может публиковать") : "выключен"}
          on={s.website_hosting_enabled}
          busy={settings.busy}
          onChange={toggleSite}
        />
      </div>
      <ApplyNote bot={bot} settings={settings} />

      <section className="card">
        <dl className="pairs">
          <div>
            <dt>Модель</dt>
            <dd>{s.model_name ?? s.model}</dd>
          </div>
          <div>
            <dt>Сон</dt>
            <dd>{s.sleep_enabled ? `засыпает через ${s.sleep_idle_minutes} мин тишины` : "не засыпает"}</dd>
          </div>
          <div>
            <dt>Память</dt>
            <dd>{s.memory_provider === "mnemosyne" ? "долгая, ищет по смыслу" : "обычная"}</dd>
          </div>
          <div>
            <dt>Память в группах</dt>
            <dd>{s.group_shared_memory ? "общая на группу" : "своя у каждого"}</dd>
          </div>
          <div>
            <dt>Пишут лично</dt>
            <dd>
              {a.allow_all_users
                ? "любой человек"
                : `${a.allowed_users} ${plural(a.allowed_users, "человек", "человека", "человек")}`}
            </dd>
          </div>
          <div>
            <dt>Группы без упоминания</dt>
            <dd>{a.free_response_chats || "нет"}</dd>
          </div>
        </dl>
      </section>

      <div className="group">
        <button className="row row--danger" disabled={deleting} onClick={remove}>
          <span className="bubble bubble--grey">
            <Icon name="trash" size={20} />
          </span>
          <span className="row__text">
            <span className="row__title">Удалить бота</span>
          </span>
        </button>
      </div>
      {deleteError ? <p className="note-error">{deleteError}</p> : null}

      <p className="hint hint--center">Последний запуск бота: {when(bot.started_at)}</p>
    </>
  )
}

/** What happens to a saved change, and a save's error. */
function ApplyNote({ bot, settings }: { bot: Bot; settings: Settings }) {
  if (settings.error) return <p className="note-error">{settings.error}</p>
  const state = bot.apply.state
  if (state === "applied" && !settings.saved) return null
  return (
    <p className="hint">
      {applyText[state]}
      {state === "failed" && bot.support_url ? (
        <>
          {" "}
          <button className="link" onClick={() => openTelegram(bot.support_url!)}>
            Поддержка
          </button>
        </>
      ) : null}
    </p>
  )
}

function TimezoneScreen({ bot, settings }: { bot: Bot; settings: Settings }) {
  const current = bot.settings.timezone
  const listed = zones.some(([id]) => id === current)
  const [other, setOther] = useState(listed ? "" : current)
  const pick = (tz: string) => tz !== current && settings.save({ timezone: tz })
  return (
    <>
      <h1 className="screen-title">Часовой пояс</h1>
      <p className="hint">По нему бот понимает «завтра в 9» и присылает напоминания вовремя.</p>
      <div className="group">
        {zones.map(([id, label]) => (
          <Choice key={id} title={label} sub={id === "UTC" ? undefined : id} on={current === id} busy={settings.busy} onPick={() => pick(id)} />
        ))}
      </div>
      <label className="field">
        Другой (например, Asia/Bishkek)
        <div className="field-row">
          <input
            value={other}
            onChange={(e) => setOther(e.target.value)}
            placeholder="Континент/Город"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
          />
          <button className="secondary secondary--small" disabled={settings.busy || !other.trim()} onClick={() => pick(other.trim())}>
            Сохранить
          </button>
        </div>
      </label>
      <ApplyNote bot={bot} settings={settings} />
    </>
  )
}

function ImagesScreen({ bot, settings }: { bot: Bot; settings: Settings }) {
  const on = bot.settings.image_gen_enabled
  const current = bot.settings.image_gen_model
  const { data, error, reload } = useLoad(panelApi.imageModels)
  const chosen = (m: ImageModel) => (current ? current === m.id : m.default)
  return (
    <>
      <h1 className="screen-title">Картинки</h1>
      <div className="group">
        <Toggle
          icon="image"
          tone="orange"
          title="Рисовать картинки"
          sub={on ? "бот рисует по описанию" : "выключены"}
          on={on}
          busy={settings.busy}
          onChange={(v) => settings.save({ image_gen_enabled: v })}
        />
      </div>
      <ApplyNote bot={bot} settings={settings} />
      {on ? (
        <>
          <span className="label">Модель</span>
          {error ? <ErrorNote error={error} retry={reload} /> : null}
          {!data && !error ? <Skeleton rows={2} /> : null}
          {data ? (
            <div className="group">
              {data.models.map((m) => (
                <Choice
                  key={m.id}
                  title={m.name}
                  sub={`${m.rub_per_image.replace(".", ",")} ₽ за картинку${m.default ? " · по умолчанию" : ""}`}
                  on={chosen(m)}
                  busy={settings.busy}
                  onPick={() => !chosen(m) && settings.save({ image_gen_model: m.default ? null : m.id })}
                />
              ))}
            </div>
          ) : null}
        </>
      ) : null}
    </>
  )
}

function Deleted() {
  return (
    <>
      <h1 className="screen-title">Бот удалён</h1>
      <p className="hint">Его память, файлы и напоминания удаляются.</p>
      <button className="primary" onClick={closePanel}>
        Закрыть
      </button>
    </>
  )
}
