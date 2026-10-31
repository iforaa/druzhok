import { useState } from "react"
import { panelApi, type Invite } from "./api"
import { openTelegram } from "./telegram"
import { ErrorNote, Icon, Skeleton, useLoad } from "./ui"

// Invites for friends: the owner's referral codes, as the superbot's
// «🎁 Пригласить» gives them.

export default function Invites() {
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
