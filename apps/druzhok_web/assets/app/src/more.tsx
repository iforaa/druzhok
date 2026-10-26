import { useEffect, useRef, useState } from "react"
import {
  APIError,
  explain,
  panelApi,
  type ApplyState,
  type Bot,
  type ImageModel,
  type Invite,
  type SettingChanges,
} from "./api"
import { backButton, closePanel, confirmDialog, openTelegram } from "./telegram"
import { plural, when } from "./format"
import { Choice, ErrorNote, Icon, Row, Skeleton, Toggle, useLoad } from "./ui"

// Ещё: the bot's settings, who may talk to it, invites for friends (the
// owner's referral codes, as the superbot's «🎁 Пригласить» gives them),
// support, and deleting the bot. Language, time zone, groups, pictures and
// the site are the owner's to change (panel controls spec); a choice saves
// at once, and the bot picks it up when it is not answering. A delete is
// only requested here and confirmed in the superbot.

type Screen = "main" | "invites" | "language" | "timezone" | "groups" | "images" | "delete"

const languages: Record<string, string> = { ru: "русский", en: "английский" }

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

function groupsText(bot: Bot): string {
  const s = bot.settings
  return s.mention_only
    ? `отвечает, когда зовут${s.trigger_name ? ` «${s.trigger_name}»` : " по имени"}`
    : "отвечает на всё"
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

  const save = async (changes: SettingChanges) => {
    setBusy(true)
    setError(null)
    try {
      const r = await panelApi.saveSettings(changes)
      onBot(r.bot)
      setSaved(true)
    } catch (err) {
      setError(explain(err))
    } finally {
      setBusy(false)
    }
  }

  // While a quiet restart is due, ask every 3 s for up to 2 min, then keep the last text.
  const waiting = bot.apply.state === "waiting"
  useEffect(() => {
    if (!waiting) return
    const started = Date.now()
    const timer = window.setInterval(() => {
      if (Date.now() - started > 120_000) {
        window.clearInterval(timer)
        return
      }
      panelApi.bot().then(onBot, () => {})
    }, 3000)
    return () => window.clearInterval(timer)
  }, [waiting, onBot])

  return { save, busy, error, saved, clearError: () => setError(null) }
}

type Settings = ReturnType<typeof useSettings>

export default function More({ bot, start, onBot }: { bot: Bot; start?: string; onBot: (b: Bot) => void }) {
  const [screen, setScreen] = useState<Screen>(start === "invites" ? "invites" : "main")
  const settings = useSettings(bot, onBot)
  const open = (s: Screen) => {
    settings.clearError()
    setScreen(s)
  }
  useEffect(() => backButton(screen === "main" ? null : () => open("main")), [screen])

  switch (screen) {
    case "invites":
      return <Invites />
    case "language":
      return <LanguageScreen bot={bot} settings={settings} />
    case "timezone":
      return <TimezoneScreen bot={bot} settings={settings} />
    case "groups":
      return <GroupsScreen bot={bot} settings={settings} />
    case "images":
      return <ImagesScreen bot={bot} settings={settings} />
    case "delete":
      return <DeleteScreen bot={bot} />
  }

  const s = bot.settings
  const a = bot.access

  const toggleSite = async (on: boolean) => {
    if (on) {
      const ok = await confirmDialog(
        `Сайты, которые сделает бот, будут открыты всем по ссылке ${bot.name}.oldey.dev`,
      )
      if (!ok) return
    }
    settings.save({ website_hosting_enabled: on })
  }

  return (
    <>
      <h1 className="screen-title">Ещё</h1>

      <div className="group">
        <Row icon="gift" tone="pink" title="Пригласить друга" sub="Друг сможет создать своего бота" onClick={() => open("invites")} />
        {bot.support_url ? (
          <Row icon="chat" tone="blue" title="Поддержка" sub="Ответим в Telegram" onClick={() => openTelegram(bot.support_url!)} />
        ) : null}
      </div>

      <span className="label">Настройки</span>
      <div className="group">
        <Row icon="chat" tone="blue" title="Язык ответов" sub={languages[s.language] ?? s.language} onClick={() => open("language")} />
        <Row icon="clock" tone="teal" title="Часовой пояс" sub={zoneName(s.timezone)} onClick={() => open("timezone")} />
        <Row icon="group" tone="purple" title="В группах" sub={groupsText(bot)} onClick={() => open("groups")} />
        <Row icon="image" tone="orange" title="Картинки" sub={s.image_gen_enabled ? "рисует" : "выключены"} onClick={() => open("images")} />
        <Toggle
          icon="globe"
          tone="green"
          title="Сайт"
          sub={s.website_hosting_enabled ? "может публиковать" : "выключен"}
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
        </dl>
      </section>

      <section className="card">
        <div className="card__head">
          <span className="label">Доступ</span>
        </div>
        <dl className="pairs">
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
        <button className="row row--danger" onClick={() => open("delete")}>
          <span className="bubble bubble--grey">
            <Icon name="trash" size={20} />
          </span>
          <span className="row__text">
            <span className="row__title">Удалить бота</span>
          </span>
        </button>
      </div>

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

function LanguageScreen({ bot, settings }: { bot: Bot; settings: Settings }) {
  const current = bot.settings.language
  return (
    <>
      <h1 className="screen-title">Язык ответов</h1>
      <div className="group">
        {Object.entries(languages).map(([id, label]) => (
          <Choice
            key={id}
            title={label}
            on={current === id}
            busy={settings.busy}
            onPick={() => id !== current && settings.save({ language: id })}
          />
        ))}
      </div>
      <ApplyNote bot={bot} settings={settings} />
    </>
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

function GroupsScreen({ bot, settings }: { bot: Bot; settings: Settings }) {
  const mention = bot.settings.mention_only
  const name = bot.settings.trigger_name
  return (
    <>
      <h1 className="screen-title">В группах</h1>
      <div className="group">
        <Choice
          title="Отвечает, когда зовут"
          sub={name ? `по имени «${name}» или упоминанию` : "по имени или упоминанию"}
          on={mention}
          busy={settings.busy}
          onPick={() => !mention && settings.save({ mention_only: true })}
        />
        <Choice
          title="Отвечает на всё"
          sub="на каждое сообщение в группе"
          on={!mention}
          busy={settings.busy}
          onPick={() => mention && settings.save({ mention_only: false })}
        />
      </div>
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

type DeleteStep = { kind: "ask" } | { kind: "sent"; superbot: string } | { kind: "done" }

function DeleteScreen({ bot }: { bot: Bot }) {
  const [step, setStep] = useState<DeleteStep>({ kind: "ask" })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<{ text: string; superbot: boolean } | null>(null)
  const polling = useRef<number | null>(null)

  useEffect(() => () => {
    if (polling.current) window.clearInterval(polling.current)
  }, [])

  const request = async () => {
    setBusy(true)
    setError(null)
    try {
      const r = await panelApi.deleteBot()
      setStep({ kind: "sent", superbot: r.confirm_in.replace(/^@/, "") })
      // Once the owner confirms, the bot is gone from the panel's API.
      polling.current = window.setInterval(() => {
        panelApi.bot().catch((err) => {
          if (err instanceof APIError && err.status === 404) {
            if (polling.current) window.clearInterval(polling.current)
            setStep({ kind: "done" })
          }
        })
      }, 3000)
    } catch (err) {
      setError({ text: explain(err), superbot: err instanceof APIError && err.kind === "superbot_unreachable" })
    } finally {
      setBusy(false)
    }
  }

  if (step.kind === "done")
    return (
      <>
        <h1 className="screen-title">Бот удалён</h1>
        <p className="hint">Его память, файлы и напоминания удаляются.</p>
        <button className="primary" onClick={closePanel}>
          Закрыть
        </button>
      </>
    )

  if (step.kind === "sent")
    return (
      <>
        <h1 className="screen-title">Подтвердите удаление</h1>
        <p className="hint">Мы отправили вопрос в @{step.superbot}. Нажмите там «✅ Удалить» в течение 10 минут.</p>
        <button className="primary" onClick={() => openTelegram(`https://t.me/${step.superbot}`)}>
          Открыть @{step.superbot}
        </button>
      </>
    )

  return (
    <>
      <h1 className="screen-title">Удалить бота</h1>
      <section className="card">
        <ul className="hint">
          <li>Бот перестанет отвечать.</li>
          <li>Его память, файлы, напоминания и сайт будут удалены.</li>
          <li>Это нельзя отменить.</li>
          <li>Оплаченный тариф не возвращается.</li>
        </ul>
      </section>
      {error ? (
        <div className="card card--error">
          <p>{error.text}</p>
          {error.superbot && bot.superbot ? (
            <button className="link" onClick={() => openTelegram(`https://t.me/${bot.superbot}`)}>
              Открыть @{bot.superbot}
            </button>
          ) : null}
        </div>
      ) : null}
      <button className="danger" disabled={busy} onClick={request}>
        Удалить бота
      </button>
      <p className="hint hint--center">Удаление нужно будет подтвердить в {bot.superbot ? `@${bot.superbot}` : "боте-создателе"}.</p>
    </>
  )
}

function Invites() {
  const { data, error, reload } = useLoad(panelApi.invites)
  return (
    <>
      <h1 className="screen-title">Пригласить друга</h1>
      <p className="hint">По ссылке друг сможет создать своего бота. Каждая ссылка — на одного человека.</p>
      {error ? <ErrorNote error={error} retry={reload} /> : null}
      {!data && !error ? <Skeleton rows={2} /> : null}
      {data && data.links.length === 0 ? (
        <section className="card">
          <p className="hint">Свободных приглашений пока нет.</p>
        </section>
      ) : null}
      {data?.links.map((inv) => <InviteCard key={inv.link} invite={inv} />)}
      {data && data.used > 0 ? (
        <p className="hint hint--center">
          Уже использовано: {data.used}
        </p>
      ) : null}
    </>
  )
}

function InviteCard({ invite }: { invite: Invite }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(invite.link)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    } catch {
      setCopied(false)
    }
  }
  return (
    <section className="card">
      <p className="invite__link">{invite.link.replace("https://", "")}</p>
      {invite.you_rub !== "0.00" ? (
        <p className="hint">Вам начислят {invite.you_rub.replace(".", ",")} ₽, когда друг создаст бота.</p>
      ) : null}
      {invite.friend_rub !== "0.00" ? <p className="hint">Другу — {invite.friend_rub.replace(".", ",")} ₽ на счёт.</p> : null}
      <div className="buttons">
        <button className="primary" onClick={() => openTelegram(invite.share_url)}>
          <Icon name="gift" size={18} /> Поделиться
        </button>
        <button className="secondary" onClick={copy}>
          {copied ? "Скопировано" : "Скопировать"}
        </button>
      </div>
    </section>
  )
}
