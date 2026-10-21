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

  test "reply to the bot, command, trigger name and free-response chat wake", %{inst: inst} do
    [id, _] = String.split(inst.telegram_token, ":")
    bot = String.to_integer(id)

    assert Addressed.wakes?(inst, group(%{"reply_to_message" => %{"from" => %{"id" => bot}}}))

    assert Addressed.wakes?(
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

    # Name not known yet: any @mention counts.
    assert Addressed.wakes?(inst, msg.("@someone hi", 0, 8))

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
end
