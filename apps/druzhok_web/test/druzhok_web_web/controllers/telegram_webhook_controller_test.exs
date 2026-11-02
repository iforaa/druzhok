defmodule DruzhokWebWeb.TelegramWebhookControllerTest do
  use DruzhokWebWeb.ConnCase

  alias Druzhok.{GroupChats, Instance, Repo, Settings}
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
    "message" => %{"message_id" => 1, "text" => "привет", "chat" => %{"id" => 7, "type" => "private"}}
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
    Repo.insert!(%GroupChats{instance_id: bot.id, chat_id: -100, status: "approved"})

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

  describe "groups" do
    @group %{"id" => -100, "type" => "supergroup", "title" => "Дача"}

    defp message(id, extra \\ %{}) do
      %{
        "update_id" => id,
        "message" =>
          Map.merge(
            %{"message_id" => id, "text" => "привет", "chat" => @group, "from" => %{"id" => 77}},
            extra
          )
      }
    end

    defp mention(id, from \\ 77) do
      message(id, %{
        "text" => "@somebot привет",
        "entities" => [%{"type" => "mention", "offset" => 0, "length" => 8}],
        "from" => %{"id" => from}
      })
    end

    defp added(id, status \\ "member") do
      %{
        "update_id" => id,
        "my_chat_member" => %{"chat" => @group, "new_chat_member" => %{"status" => status}}
      }
    end

    defp send_update(bot, update),
      do: assert(response(push(build_conn(), bot.name, update, "sekret"), 200) == "")

    defp row(bot), do: Repo.get_by(GroupChats, instance_id: bot.id, chat_id: -100)
    defp approve(bot), do: Repo.insert!(%GroupChats{instance_id: bot.id, chat_id: -100, title: "Дача", status: "approved"})

    for {name, make} <- [
          {"a plain message", quote(do: message(601))},
          {"a mention", quote(do: mention(601))},
          {"my_chat_member", quote(do: added(601))}
        ] do
      test "unapproved group, sleeping bot, #{name}: no queued row and no wake, a pending row", %{
        bot: bot
      } do
        sleeping =
          Repo.update!(Ecto.Changeset.change(bot, sleeping: true, active: true, mention_only: true))

        send_update(sleeping, unquote(make))

        assert Inbox.pending_count(bot.id) == 0
        assert Inbox.next_waking(bot.id) == nil
        after_ = Repo.get!(Instance, bot.id)
        assert after_.sleeping
        assert after_.start_seq == sleeping.start_seq

        assert %{status: "pending", title: "Дача"} = row(bot)
      end
    end

    test "the owner's own message in an unapproved group is dropped too", %{bot: bot} do
      owner = Repo.update!(Ecto.Changeset.change(bot, owner_telegram_id: 77))
      send_update(owner, message(601))
      assert Inbox.pending_count(bot.id) == 0
    end

    test "a blocked group stays blocked and stores nothing", %{bot: bot} do
      Repo.insert!(%GroupChats{instance_id: bot.id, chat_id: -100, status: "blocked"})
      send_update(bot, mention(601))
      assert Inbox.pending_count(bot.id) == 0
      assert row(bot).status == "blocked"
    end

    test "every kind of update from an unapproved group is dropped", %{bot: bot} do
      kinds = [
        %{"edited_message" => %{"chat" => @group}},
        %{"channel_post" => %{"chat" => %{"id" => -100, "type" => "channel"}}},
        %{"callback_query" => %{"id" => "1", "message" => %{"chat" => @group}}},
        %{"chat_member" => %{"chat" => @group}},
        %{"chat_join_request" => %{"chat" => @group}},
        %{"message_reaction" => %{"chat" => @group}},
        %{"message_reaction_count" => %{"chat" => @group}},
        %{"chat_boost" => %{"chat" => @group}},
        %{"poll_answer" => %{"voter_chat" => @group}}
      ]

      for {kind, i} <- Enum.with_index(kinds) do
        send_update(bot, Map.put(kind, "update_id", 700 + i))
      end

      assert Inbox.pending_count(bot.id) == 0
    end

    test "a poll update names no chat, so it is dropped", %{bot: bot} do
      send_update(bot, %{"update_id" => 601, "poll" => %{"id" => "1"}})
      send_update(bot, %{"update_id" => 602, "poll_answer" => %{"user" => %{"id" => 1}}})
      assert Inbox.pending_count(bot.id) == 0
    end

    test "private chats pass as before, callbacks too", %{bot: bot} do
      private = %{"id" => 7, "type" => "private"}
      send_update(bot, %{"update_id" => 601, "callback_query" => %{"message" => %{"chat" => private}}})
      send_update(bot, %{"update_id" => 602, "my_chat_member" => %{"chat" => private}})
      assert Inbox.pending_count(bot.id) == 2
    end

    test "the bot leaving a group it never knew makes no row", %{bot: bot} do
      send_update(bot, added(601, "left"))
      send_update(bot, added(602, "kicked"))
      refute row(bot)
    end

    test "the first sight makes one row however many updates come", %{bot: bot} do
      send_update(bot, added(601))
      send_update(bot, message(602))
      assert Druzhok.GroupChats.list(bot) |> length() == 1
      assert row(bot).status == "pending"
    end

    test "a renamed group shows its new title", %{bot: bot} do
      send_update(bot, added(601))
      renamed = put_in(message(602), ["message", "chat", "title"], "Огород")
      send_update(bot, renamed)
      assert row(bot).title == "Огород"
    end

    test "no more than 50 groups wait at once", %{bot: bot} do
      for i <- 1..50 do
        Repo.insert!(%GroupChats{instance_id: bot.id, chat_id: -1000 - i, status: "pending"})
      end

      send_update(bot, added(601))
      refute row(bot)
    end

    test "an approved group's messages are queued", %{bot: bot} do
      approve(bot)
      send_update(bot, message(601))
      assert Inbox.next_pending(bot.id).update_id == 601
    end

    test "5 a minute per person: the 6th is acknowledged and not stored; someone else still can", %{
      bot: bot
    } do
      approve(bot)
      for i <- 1..6, do: send_update(bot, message(600 + i))
      assert Inbox.pending_count(bot.id) == 5

      send_update(bot, message(610, %{"from" => %{"id" => 78}}))
      assert Inbox.pending_count(bot.id) == 6
    end

    test "30 an hour per group", %{bot: bot} do
      approve(bot)
      for i <- 1..31, do: send_update(bot, message(600 + i, %{"from" => %{"id" => 1000 + i}}))
      assert Inbox.pending_count(bot.id) == 30
    end

    test "the Settings change the limits", %{bot: bot} do
      Settings.set("group_rate_user_per_min", "2")
      Settings.set("group_rate_chat_per_hour", "3")
      approve(bot)

      for i <- 1..3, do: send_update(bot, message(600 + i))
      assert Inbox.pending_count(bot.id) == 2

      for i <- 1..2, do: send_update(bot, message(610 + i, %{"from" => %{"id" => 78}}))
      assert Inbox.pending_count(bot.id) == 3
    end

    test "counts live in the database and free up as their window passes", %{bot: bot} do
      Settings.set("group_rate_user_per_min", "1")
      approve(bot)

      send_update(bot, message(601))
      send_update(bot, message(602))
      assert Inbox.pending_count(bot.id) == 1

      Repo.query!("UPDATE group_rate_events SET at = at - 61")
      send_update(bot, message(603))
      assert Inbox.pending_count(bot.id) == 2
    end

    test "an attempt over the limit does not use up the group's hour", %{bot: bot} do
      Settings.set("group_rate_user_per_min", "1")
      Settings.set("group_rate_chat_per_hour", "2")
      approve(bot)

      for i <- 1..5, do: send_update(bot, message(600 + i))
      send_update(bot, message(610, %{"from" => %{"id" => 78}}))
      assert Inbox.pending_count(bot.id) == 2
    end

    test "a redelivered update does not count twice", %{bot: bot} do
      Settings.set("group_rate_user_per_min", "1")
      approve(bot)

      send_update(bot, message(601))
      send_update(bot, message(601))
      assert Inbox.pending_count(bot.id) == 1

      [[count]] = Repo.query!("SELECT count(*) FROM group_rate_events").rows
      assert count == 1
    end

    test "over the limit a sleeping bot is not woken, and the notice is marked once an hour", %{
      bot: bot
    } do
      Settings.set("group_rate_user_per_min", "1")
      approve(bot)
      sleeping = Repo.update!(Ecto.Changeset.change(bot, sleeping: true, active: true))

      send_update(sleeping, message(601))
      refute row(bot).rate_notice_at

      send_update(sleeping, message(602))
      first = row(bot).rate_notice_at
      assert first

      send_update(sleeping, message(603))
      assert row(bot).rate_notice_at == first

      Repo.update!(Ecto.Changeset.change(row(bot), rate_notice_at: DateTime.add(first, -3601)))
      send_update(sleeping, message(604))
      assert DateTime.compare(row(bot).rate_notice_at, first) != :lt

      assert Inbox.pending_count(bot.id) == 1
      after_ = Repo.get!(Instance, bot.id)
      assert after_.sleeping
      assert after_.start_seq == sleeping.start_seq
    end

    test "chatter a mention-only bot skips neither counts nor is limited", %{bot: bot} do
      Settings.set("group_rate_user_per_min", "1")
      mention_only = Repo.update!(Ecto.Changeset.change(bot, mention_only: true))
      approve(bot)

      for i <- 1..3, do: send_update(mention_only, message(600 + i))
      assert Inbox.pending_count(bot.id) == 3
      refute Inbox.next_waking(bot.id)

      [[count]] = Repo.query!("SELECT count(*) FROM group_rate_events").rows
      assert count == 0
    end

    test "old rate events are pruned", %{bot: bot} do
      approve(bot)
      send_update(bot, message(601))
      now = System.system_time(:second)
      assert GroupChats.prune_rate_events(now) == 0
      assert GroupChats.prune_rate_events(now + 3601) == 1
    end
  end
end
