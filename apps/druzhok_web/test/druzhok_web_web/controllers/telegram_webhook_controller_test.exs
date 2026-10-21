defmodule DruzhokWebWeb.TelegramWebhookControllerTest do
  use DruzhokWebWeb.ConnCase

  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.Inbox

  setup do
    n = System.unique_integer([:positive])

    bot =
      Repo.insert!(%Instance{
        name: "hook#{n}",
        model: "m",
        workspace: "/tmp/hook#{n}/workspace",
        telegram_mode: "webhook",
        telegram_webhook_secret: "sekret"
      })

    polling =
      Repo.insert!(%Instance{name: "poll#{n}", model: "m", workspace: "/tmp/poll#{n}/workspace"})

    %{bot: bot, polling: polling}
  end

  defp push(conn, name, body, secret) do
    conn = put_req_header(conn, "content-type", "application/json")

    conn =
      if secret, do: put_req_header(conn, "x-telegram-bot-api-secret-token", secret), else: conn

    post(conn, "/telegram/webhook/#{name}", Jason.encode!(body))
  end

  @update %{
    "update_id" => 501,
    "message" => %{"message_id" => 1, "text" => "привет", "chat" => %{"id" => 7}}
  }

  test "a valid update is queued and acked with an empty 200", %{conn: conn, bot: bot} do
    conn = push(conn, bot.name, @update, "sekret")
    assert response(conn, 200) == ""

    row = Inbox.next_pending(bot.id)
    assert row.update_id == 501
    assert Jason.decode!(row.payload) == @update
  end

  test "group chatter a mention-only bot skips is stored as not waking", %{conn: conn, bot: bot} do
    Repo.update!(Instance.changeset(bot, %{mention_only: true}))
    chatter = put_in(@update, ["message", "chat"], %{"id" => -100, "type" => "supergroup"})

    assert response(push(conn, bot.name, chatter, "sekret"), 200) == ""
    refute Inbox.next_pending(bot.id).wakes

    assert response(push(build_conn(), bot.name, %{@update | "update_id" => 502}, "sekret"), 200)
    assert Inbox.next_waking(bot.id).update_id == 502
  end

  test "a wrong or missing secret is refused and stores nothing", %{conn: conn, bot: bot} do
    assert response(push(conn, bot.name, @update, "nope"), 401)
    assert response(push(build_conn(), bot.name, @update, nil), 401)
    assert Inbox.pending_count(bot.id) == 0
  end

  test "an unknown bot or one in polling mode is 404", %{conn: conn, polling: polling} do
    assert response(push(conn, "no-such-bot", @update, "sekret"), 404)
    assert response(push(build_conn(), polling.name, @update, "sekret"), 404)
  end

  test "Telegram redelivering the same update_id still answers 200 and stores one row", %{
    conn: conn,
    bot: bot
  } do
    assert response(push(conn, bot.name, @update, "sekret"), 200)
    assert response(push(build_conn(), bot.name, @update, "sekret"), 200)
    assert Inbox.pending_count(bot.id) == 1
  end

  test "a body without an update_id is a 400", %{conn: conn, bot: bot} do
    assert response(push(conn, bot.name, %{"message" => %{}}, "sekret"), 400)
    assert Inbox.pending_count(bot.id) == 0
  end

  test "an update that cannot be stored is a 500, so Telegram retries it", %{conn: conn, bot: bot} do
    # SQLite DDL is transactional: the sandbox rolls the rename back.
    Repo.query!("ALTER TABLE telegram_updates RENAME TO telegram_updates_gone")
    assert response(push(conn, bot.name, @update, "sekret"), 500)
  end
end
