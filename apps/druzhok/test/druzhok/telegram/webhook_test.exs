defmodule Druzhok.Telegram.WebhookTest do
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.{Inbox, Webhook}

  test "port is 20000 + id inside the isolated range, nil outside it" do
    assert Webhook.port(%{id: 9}) == 20_009
    assert Webhook.port(%{id: 999}) == 20_999
    assert Webhook.port(%{id: 1000}) == nil
    assert Webhook.port(%{id: nil}) == nil
  end

  test "the public URL is the bot's path on PHX_HOST" do
    prev = System.get_env("PHX_HOST")
    System.put_env("PHX_HOST", "druzhok.example.org")

    on_exit(fn ->
      if prev, do: System.put_env("PHX_HOST", prev), else: System.delete_env("PHX_HOST")
    end)

    assert Webhook.public_url(%{name: "kot"}) ==
             "https://druzhok.example.org/telegram/webhook/kot"
  end

  describe "set_mode/3" do
    test "webhook generates the secret once and keeps it" do
      inst = relay_instance()

      assert {:ok, %{telegram_mode: "webhook", telegram_webhook_secret: secret}, 0} =
               Webhook.set_mode(inst.name, "webhook")

      assert secret =~ ~r/^[0-9a-f]{64}$/
      assert {:ok, _, 0} = Webhook.set_mode(inst.name, "polling")

      assert {:ok, %{telegram_webhook_secret: ^secret}, 0} =
               Webhook.set_mode(inst.name, "webhook")
    end

    test "refuses an id outside the port range" do
      inst =
        Repo.insert!(%Instance{
          name: "relaybig#{System.unique_integer([:positive])}",
          model: "m",
          workspace: "/tmp/x/workspace"
        })

      on_exit(fn -> Repo.delete(inst) end)
      assert inst.id > 999
      assert {:error, {:id_out_of_range, _}} = Webhook.set_mode(inst.name, "webhook")
    end

    test "leaving webhook mode with queued updates needs force, which drops them" do
      inst = relay_instance(%{telegram_mode: "webhook", telegram_webhook_secret: "s"})
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}))
      :ok = Inbox.enqueue(inst.id, 2, ~s({"update_id":2}))

      assert {:error, {:pending, 2}} = Webhook.set_mode(inst.name, "polling")
      assert Repo.get!(Instance, inst.id).telegram_mode == "webhook"

      assert {:ok, %{telegram_mode: "polling"}, 2} =
               Webhook.set_mode(inst.name, "polling", force: true)

      assert Inbox.pending_count(inst.id) == 0
    end

    test "once switched to polling, the endpoint can no longer queue for the bot" do
      inst = relay_instance(%{telegram_mode: "webhook", telegram_webhook_secret: "s"})
      assert {:ok, %{telegram_mode: "polling"}, 0} = Webhook.set_mode(inst.name, "polling")
      assert {:error, :not_webhook} = Inbox.enqueue(inst.id, 1, "{}")
    end

    test "unknown bot" do
      assert {:error, :not_found} = Webhook.set_mode("no-such-bot", "webhook")
    end
  end

  describe "pause/3 and resume/1" do
    test "a pause holds until its time, resume clears it" do
      inst = relay_instance()
      refute Webhook.paused(Repo.get!(Instance, inst.id))

      :ok = Webhook.pause(inst.id, :stopping)
      assert {"stopping", until} = Webhook.paused(Repo.get!(Instance, inst.id))
      assert DateTime.diff(until, DateTime.utc_now()) in 290..300

      :ok = Webhook.resume(inst.id)
      refute Webhook.paused(Repo.get!(Instance, inst.id))
    end

    test "a pause whose time has passed no longer holds" do
      inst = relay_instance()
      :ok = Webhook.pause(inst.id, :rejected_config, -1)
      refute Webhook.paused(Repo.get!(Instance, inst.id))
    end
  end
end
