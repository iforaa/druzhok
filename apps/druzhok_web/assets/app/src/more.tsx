import { useEffect, useState } from "react"
import { panelApi, type Bot, type Invite } from "./api"
import { backButton, openTelegram } from "./telegram"
import { plural, when } from "./format"
import { ErrorNote, Icon, Row, Skeleton, useLoad } from "./ui"

// Ещё: the bot's settings in plain words, who may talk to it, invites for
// friends (the owner's referral codes, as the superbot's «🎁 Пригласить»
// gives them) and support. Settings are read only in v1.

type Screen = "main" | "invites"

const languages: Record<string, string> = { ru: "русский", en: "английский" }

function settingRows(bot: Bot): [string, string][] {
  const s = bot.settings
  return [
    ["Модель", s.model_name ?? s.model],
    ["Язык ответов", languages[s.language] ?? s.language],
    ["Часовой пояс", s.timezone === "UTC" ? "UTC (Гринвич)" : s.timezone],
    ["В группах", s.mention_only ? `отвечает, когда зовут${s.trigger_name ? ` «${s.trigger_name}»` : " по имени"}` : "отвечает на всё"],
    ["Сон", s.sleep_enabled ? `засыпает через ${s.sleep_idle_minutes} мин тишины` : "не засыпает"],
    ["Картинки", s.image_gen_enabled ? "рисует" : "выключены"],
    ["Сайт", s.website_hosting_enabled ? "может публиковать" : "выключен"],
    ["Память", s.memory_provider === "mnemosyne" ? "долгая, ищет по смыслу" : "обычная"],
    ["Память в группах", s.group_shared_memory ? "общая на группу" : "своя у каждого"],
  ]
}

export default function More({ bot, start }: { bot: Bot; start?: string }) {
  const [screen, setScreen] = useState<Screen>(start === "invites" ? "invites" : "main")
  useEffect(() => backButton(screen === "main" ? null : () => setScreen("main")), [screen])

  if (screen === "invites") return <Invites />

  const a = bot.access
  return (
    <>
      <h1 className="screen-title">Ещё</h1>

      <div className="group">
        <Row icon="gift" tone="pink" title="Пригласить друга" sub="Друг сможет создать своего бота" onClick={() => setScreen("invites")} />
        {bot.support_url ? (
          <Row icon="chat" tone="blue" title="Поддержка" sub="Ответим в Telegram" onClick={() => openTelegram(bot.support_url!)} />
        ) : null}
      </div>

      <section className="card">
        <div className="card__head">
          <span className="label">Настройки</span>
        </div>
        <dl className="pairs">
          {settingRows(bot).map(([k, v]) => (
            <div key={k}>
              <dt>{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
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

      <p className="hint hint--center">
        Изменить настройки пока можно через поддержку.
        <br />
        Последний запуск бота: {when(bot.started_at)}
      </p>
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
