defmodule Druzhok.Telegram.AddressedTest do
  use ExUnit.Case, async: false
  alias Druzhok.Telegram.Addressed

  setup do
    token = "#{System.unique_integer([:positive])}:t"
    Application.put_env(:druzhok, :test_usernames, %{token => "Kot_VasaBot"})
    on_exit(fn -> Application.delete_env(:druzhok, :test_usernames) end)

    %{
      inst: %{
        mention_only: true,
        telegram_token: token,
        trigger_name: "Вася",
        allowed_telegram_chats: nil
      }
    }
  end

  defp group(fields),
    do: %{"message" => Map.merge(%{"chat" => %{"id" => -100, "type" => "supergroup"}}, fields)}

  defp learn(inst) do
    Addressed.username(inst)
    wait(fn -> Addressed.username(inst) == "kot_vasabot" end)
  end

  defp wait(fun, n \\ 50) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait(fun, n - 1)
    end
  end

  test "private chats, callbacks and other updates wake", %{inst: inst} do
    assert Addressed.wakes?(inst, %{"message" => %{"chat" => %{"id" => 5, "type" => "private"}}})
    assert Addressed.wakes?(inst, %{"callback_query" => %{}})
    assert Addressed.wakes?(inst, %{"my_chat_member" => %{}})
  end

  test "group chatter does not wake a mention-only bot", %{inst: inst} do
    refute Addressed.wakes?(inst, group(%{"text" => "привет всем"}))
    refute Addressed.wakes?(inst, %{"edited_message" => group(%{"text" => "ну"})["message"]})

    refute Addressed.wakes?(
             inst,
             group(%{"text" => "Васька", "reply_to_message" => %{"from" => %{"id" => 1}}})
           )
  end

  test "a bot that answers every group message wakes on any", %{inst: inst} do
    assert Addressed.wakes?(%{inst | mention_only: false}, group(%{"text" => "привет"}))
  end

  test "reply to the bot, trigger name and free-response chat wake", %{inst: inst} do
    [id, _] = String.split(inst.telegram_token, ":")
    bot = String.to_integer(id)

    assert Addressed.wakes?(inst, group(%{"reply_to_message" => %{"from" => %{"id" => bot}}}))

    refute Addressed.wakes?(
             inst,
             group(%{
               "text" => "/new",
               "entities" => [%{"type" => "bot_command", "offset" => 0, "length" => 4}]
             })
           )

    assert Addressed.wakes?(inst, group(%{"text" => "вася, привет"}))
    assert Addressed.wakes?(inst, group(%{"caption" => "смотри, Вася!"}))

    assert Addressed.wakes?(
             %{inst | allowed_telegram_chats: ~s(["-100"])},
             group(%{"text" => "x"})
           )

    assert Addressed.wakes?(
             inst,
             group(%{
               "text" => "эй",
               "entities" => [%{"type" => "text_mention", "user" => %{"id" => bot}}]
             })
           )
  end

  test "an @mention wakes only when it names the bot, once the name is known", %{inst: inst} do
    msg = fn text, offset, length ->
      group(%{
        "text" => text,
        "entities" => [%{"type" => "mention", "offset" => offset, "length" => length}]
      })
    end

    # Pin the cache in its unknown/in-flight state so the asynchronous lookup
    # cannot finish between the foreign-bot veto and the own-mention check.
    key = {Addressed, :crypto.hash(:sha256, inst.telegram_token)}
    on_exit(fn -> :persistent_term.erase(key) end)
    :persistent_term.put(key, System.monotonic_time(:second))
    assert Addressed.wakes?(inst, msg.("@someone hi", 0, 8))
    :persistent_term.erase(key)

    learn(inst)
    refute Addressed.wakes?(inst, msg.("@someone hi", 0, 8))
    # Offsets are UTF-16: the emoji is two units.
    assert Addressed.wakes?(inst, msg.("😀 @kot_vasabot привет", 3, 12))
  end

  test "no token: no lookup, every @mention counts" do
    inst = %{
      mention_only: true,
      telegram_token: nil,
      trigger_name: nil,
      allowed_telegram_chats: nil
    }

    assert Addressed.username(inst) == nil
    refute Addressed.wakes?(inst, group(%{"text" => "hi"}))
  end

  test "group command parsing matches Hermes, independent of mention mode", %{inst: inst} do
    for bot <- [
          inst,
          %{inst | mention_only: false},
          %{inst | allowed_telegram_chats: ~s(["-100"])}
        ] do
      for text <- [
            "/help Вася",
            "  /help Вася",
            "/help@otherbot Вася",
            "@image:/tmp/x.png\n\n/help Вася"
          ] do
        refute Addressed.wakes?(bot, group(%{"text" => text}))
        refute Addressed.wakes?(bot, group(%{"caption" => text}))
      end

      for text <- ["/tmp/file Вася", " /tmp/file Вася", "/ Вася", "/@someone Вася"] do
        assert Addressed.wakes?(bot, group(%{"text" => text}))
      end
    end

    assert Addressed.wakes?(
             inst,
             group(%{
               "text" => "Вася, объясни /help",
               "entities" => [%{"type" => "bot_command", "offset" => 14, "length" => 5}]
             })
           )

    assert Addressed.wakes?(inst, %{
             "message" => %{"chat" => %{"type" => "private"}, "text" => "/help"}
           })
  end

  test "an inline command targeting this bot wakes and consumes group rate quota", %{inst: inst} do
    learn(inst)
    own = %{"type" => "bot_command", "offset" => 8, "length" => 17}
    update = group(%{"text" => "Объясни /help@KOT_VASABOT", "entities" => [own]})
    assert Addressed.wakes?(inst, update)

    assert Addressed.wakes?(
             inst,
             group(%{"caption" => "Объясни /help@KOT_VASABOT", "caption_entities" => [own]})
           )

    refute Addressed.wakes?(
             inst,
             group(%{"text" => "/help@KOT_VASABOT", "entities" => [%{own | "offset" => 0}]})
           )

    refute Addressed.wakes?(
             inst,
             group(%{
               "text" => "Объясни /help@OTHER_BOT",
               "entities" => [%{own | "length" => 15}]
             })
           )

    row = Druzhok.BotFixtures.relay_instance(Map.take(inst, [:telegram_token, :mention_only]))

    Druzhok.Repo.insert!(%Druzhok.GroupChats{
      instance_id: row.id,
      chat_id: -100,
      status: "approved"
    })

    assert :pass = Druzhok.GroupChats.gate(row, 1, update)

    assert %{rows: [[1]]} =
             Ecto.Adapters.SQL.query!(
               Druzhok.Repo,
               "SELECT update_id FROM group_rate_events WHERE instance_id = ?",
               [row.id]
             )
  end

  test "exclusive foreign bot mentions veto names, replies and free-response", %{inst: inst} do
    learn(inst)
    [id, _] = String.split(inst.telegram_token, ":")
    reply = %{"from" => %{"id" => String.to_integer(id)}}

    foreign = %{
      "text" => "Вася @otherbot",
      "entities" => [%{"type" => "mention", "offset" => 5, "length" => 9}],
      "reply_to_message" => reply
    }

    for bot <- [
          inst,
          %{inst | mention_only: false},
          %{inst | allowed_telegram_chats: ~s(["-100"])}
        ] do
      refute Addressed.wakes?(bot, group(foreign))

      refute Addressed.wakes?(
               bot,
               group(%{"caption" => foreign["text"], "caption_entities" => foreign["entities"]})
             )

      refute Addressed.wakes?(bot, group(%{"text" => "Вася @otherbot"}))
    end

    # Own mention opts in even when another bot was named.
    assert Addressed.wakes?(
             inst,
             group(%{
               "text" => "Вася @otherbot @KOT_VASABOT",
               "entities" =>
                 foreign["entities"] ++ [%{"type" => "mention", "offset" => 15, "length" => 12}]
             })
           )

    # Human handles and code/URL entities are not foreign bot addresses.
    assert Addressed.wakes?(inst, group(%{"text" => "Вася @someone"}))

    assert Addressed.wakes?(
             inst,
             group(%{
               "text" => "Вася @otherbot",
               "entities" => [%{"type" => "code", "offset" => 5, "length" => 9}]
             })
           )

    assert Addressed.wakes?(inst, group(%{"text" => "Вася /@otherbot"}))

    refute Addressed.wakes?(
             inst,
             group(%{
               "text" => "Вася /help@otherbot",
               "entities" => [%{"type" => "bot_command", "offset" => 5, "length" => 14}]
             })
           )
  end

  test "successful username cache expires after one hour", %{inst: inst} do
    learn(inst)
    key = {Addressed, :crypto.hash(:sha256, inst.telegram_token)}
    on_exit(fn -> :persistent_term.erase(key) end)
    Application.put_env(:druzhok, :test_usernames, %{inst.telegram_token => "New_Bot"})
    :persistent_term.put(key, {"kot_vasabot", System.monotonic_time(:second) - 3599})
    assert Addressed.username(inst) == "kot_vasabot"
    :persistent_term.put(key, {"kot_vasabot", System.monotonic_time(:second) - 3600})
    assert Addressed.username(inst) == "kot_vasabot"
    wait(fn -> Addressed.username(inst) == "new_bot" end)

    assert Addressed.wakes?(
             inst,
             group(%{
               "text" => "@New_Bot",
               "entities" => [%{"type" => "mention", "offset" => 0, "length" => 8}]
             })
           )

    refute Addressed.wakes?(
             inst,
             group(%{
               "text" => "@kot_vasabot",
               "entities" => [%{"type" => "mention", "offset" => 0, "length" => 12}]
             })
           )
  end

  def delayed_username(_token) do
    send(Application.fetch_env!(:druzhok, :addressed_lookup_owner), {:username_lookup, self()})

    receive do
      {:release, name} -> name
    after
      5_000 -> nil
    end
  end

  defp delay_username_lookup do
    previous = Application.fetch_env!(:druzhok, :telegram_username_fun)
    Application.put_env(:druzhok, :telegram_username_fun, {__MODULE__, :delayed_username})
    Application.put_env(:druzhok, :addressed_lookup_owner, self())

    on_exit(fn ->
      Application.put_env(:druzhok, :telegram_username_fun, previous)
      Application.delete_env(:druzhok, :addressed_lookup_owner)
    end)
  end

  defp inline_command(target) do
    command = "/help@" <> target

    group(%{
      "text" => "Объясни " <> command,
      "entities" => [
        %{"type" => "bot_command", "offset" => 8, "length" => String.length(command)}
      ]
    })
  end

  test "inline targets wake without a cached username while first lookup runs", %{inst: inst} do
    delay_username_lookup()
    key = {Addressed, :crypto.hash(:sha256, inst.telegram_token)}
    on_exit(fn -> :persistent_term.erase(key) end)
    assert Addressed.wakes?(inst, inline_command("KOT_VASABOT"))
    assert_receive {:username_lookup, lookup}
    assert Addressed.username(inst) == nil
    assert Addressed.wakes?(inst, inline_command("KOT_VASABOT"))

    refute Addressed.wakes?(
             inst,
             group(%{
               "text" => "Объясни /help",
               "entities" => [%{"type" => "bot_command", "offset" => 8, "length" => 5}]
             })
           )

    refute Addressed.wakes?(inst, group(%{"text" => "/help@KOT_VASABOT"}))
    send(lookup, {:release, "Kot_VasaBot"})
    wait(fn -> Addressed.username(inst) == "kot_vasabot" end)
  end

  test "expired username still addresses inline commands during refresh", %{inst: inst} do
    learn(inst)
    delay_username_lookup()
    key = {Addressed, :crypto.hash(:sha256, inst.telegram_token)}
    on_exit(fn -> :persistent_term.erase(key) end)
    :persistent_term.put(key, {"kot_vasabot", System.monotonic_time(:second) - 3600})
    assert Addressed.wakes?(inst, inline_command("KOT_VASABOT"))
    assert_receive {:username_lookup, lookup}
    assert Addressed.username(inst) == "kot_vasabot"
    assert Addressed.wakes?(inst, inline_command("KOT_VASABOT"))
    refute Addressed.wakes?(inst, inline_command("OTHER_BOT"))
    send(lookup, {:release, "New_Bot"})
    wait(fn -> Addressed.username(inst) == "new_bot" end)
    assert Addressed.wakes?(inst, inline_command("NEW_BOT"))
    refute Addressed.wakes?(inst, inline_command("KOT_VASABOT"))
  end

  test "failed background refresh keeps the cached username", %{inst: inst} do
    learn(inst)
    delay_username_lookup()
    key = {Addressed, :crypto.hash(:sha256, inst.telegram_token)}
    on_exit(fn -> :persistent_term.erase(key) end)
    :persistent_term.put(key, {"kot_vasabot", System.monotonic_time(:second) - 3600})
    assert Addressed.username(inst) == "kot_vasabot"
    assert_receive {:username_lookup, lookup}
    monitor = Process.monitor(lookup)
    send(lookup, {:release, nil})
    assert_receive {:DOWN, ^monitor, :process, ^lookup, _}
    assert Addressed.username(inst) == "kot_vasabot"
    assert Addressed.wakes?(inst, inline_command("KOT_VASABOT"))
  end

  test "group rate counting skips foreign-bot mentions and commands", %{inst: inst} do
    learn(inst)

    row =
      Druzhok.BotFixtures.relay_instance(
        Map.take(inst, [:telegram_token, :trigger_name, :mention_only])
      )

    Druzhok.Repo.insert!(%Druzhok.GroupChats{
      instance_id: row.id,
      chat_id: -100,
      status: "approved"
    })

    for {text, id} <-
          Enum.with_index(["Вася @otherbot", " /help Вася", "/help@otherbot", "Вася, привет"], 1) do
      assert :pass =
               Druzhok.GroupChats.gate(row, id, group(%{"text" => text, "from" => %{"id" => 42}}))
    end

    assert %{rows: [[4]]} =
             Ecto.Adapters.SQL.query!(
               Druzhok.Repo,
               "SELECT update_id FROM group_rate_events WHERE instance_id = ?",
               [row.id]
             )
  end
end
