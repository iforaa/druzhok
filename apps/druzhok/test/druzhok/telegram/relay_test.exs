defmodule Druzhok.Telegram.RelayTest do
  # async: false — app env and a supervised relay shared by the whole test.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.{Inbox, Relay, Webhook}

  defmodule WrongOwner do
    def check(_name, _port), do: {:error, {:wrong_owner, [4242]}}
  end

  setup do
    bypass = Bypass.open()
    Application.put_env(:druzhok, :telegram_relay_base_url, "http://localhost:#{bypass.port}")

    Application.put_env(:druzhok, :telegram_relay,
      notice_poll_ms: 20,
      backoff_min_ms: 10,
      backoff_max_ms: 40,
      paused_poll_ms: 20,
      idle_poll_ms: 50,
      timeout_ms: 1_000,
      wrong_owner_pause_s: 30,
      rejected_pause_s: 300
    )

    on_exit(fn ->
      Application.delete_env(:druzhok, :telegram_relay_base_url)
      Application.delete_env(:druzhok, :telegram_relay)
      Application.delete_env(:druzhok, :telegram_listener_owner)
    end)

    inst = relay_instance(%{telegram_mode: "webhook", telegram_webhook_secret: "sekret"})
    start_supervised!(Relay)
    %{bypass: bypass, inst: inst, seen: start_supervised!({Agent, fn -> [] end})}
  end

  defp notice_stub(inst) do
    tg = Bypass.open()
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{tg.port}")
    on_exit(fn -> Application.delete_env(:druzhok, :telegram_api_base) end)
    {:ok, calls} = Agent.start_link(fn -> [] end)
    for method <- ["sendMessage", "editMessageText", "deleteMessage"] do
    Bypass.stub(tg, "POST", "/botTOK/#{method}", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(raw)
      Agent.update(calls, &[{List.last(conn.path_info), params} | &1])
      Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":{"message_id":99}}))
    end)
    end
    inst |> Instance.changeset(%{active: true, telegram_token: "TOK"}) |> Repo.update!()
    {tg, calls}
  end

  defp private_update(inst, id, chat, type \\ "private") do
    Inbox.enqueue(inst.id, id, Jason.encode!(%{update_id: id, message: %{
      chat: %{id: chat, type: type}, from: %{id: chat}, text: "/start"}}))
    row = Repo.get_by!(Inbox, instance_id: inst.id, update_id: id)
    row |> Ecto.Changeset.change(received_at: DateTime.add(DateTime.utc_now(), -4)) |> Repo.update!()
  end

  test "held private updates get one notice, one edit at 60 seconds, and deletion on 2xx", %{inst: inst, bypass: bypass, seen: seen} do
    {_tg, calls} = notice_stub(inst)
    Webhook.pause(inst.id, :stopping)
    private_update(inst, 1, 123)
    private_update(inst, 2, 123)
    Relay.notify(inst.id)
    assert eventually(fn -> length(Agent.get(calls, & &1)) == 1 end)
    Process.sleep(350)
    assert [{"sendMessage", %{"text" => "⏳ Готовлюсь, немного подождите…"}}] = Agent.get(calls, & &1)
    row = Repo.get_by!(Inbox, instance_id: inst.id, update_id: 1)
    row |> Ecto.Changeset.change(received_at: DateTime.add(DateTime.utc_now(), -61)) |> Repo.update!()
    assert eventually(fn -> Enum.count(Agent.get(calls, & &1), &(elem(&1, 0) == "editMessageText")) == 1 end)
    Process.sleep(350)
    assert Enum.count(Agent.get(calls, & &1), &(elem(&1, 0) == "editMessageText")) == 1
    ptb(bypass, inst, seen)
    Webhook.resume(inst.id)
    assert eventually(fn -> seen(seen) == [1, 2] end)
    assert eventually(fn -> Enum.any?(Agent.get(calls, & &1), &match?({"deleteMessage", %{"message_id" => 99}}, &1)) end)
  end

  test "waits three seconds from storage and falls back to English", %{inst: inst} do
    {_tg, calls} = notice_stub(inst)
    inst |> Repo.reload!() |> Instance.changeset(%{language: "unknown"}) |> Repo.update!()
    Webhook.pause(inst.id, :stopping)
    row = private_update(inst, 1, 123)
    row |> Ecto.Changeset.change(received_at: DateTime.utc_now()) |> Repo.update!()
    Relay.notify(inst.id)
    Process.sleep(100)
    assert Agent.get(calls, & &1) == []
    row |> Ecto.Changeset.change(received_at: DateTime.add(DateTime.utc_now(), -4)) |> Repo.update!()
    assert eventually(fn -> Enum.any?(Agent.get(calls, & &1), &match?({"sendMessage", %{"text" => "⏳ Getting ready, please wait…"}}, &1)) end)
    row |> Ecto.Changeset.change(received_at: DateTime.add(DateTime.utc_now(), -61)) |> Repo.update!()
    assert eventually(fn -> Enum.any?(Agent.get(calls, & &1), &match?({"editMessageText", %{"text" => "⏳ Almost there…"}}, &1)) end)
  end

  test "a slow relay POST does not delay the preparing notice", %{inst: inst, bypass: bypass, seen: seen} do
    {_tg, calls} = notice_stub(inst)
    parent = self()
    ptb(bypass, inst, seen, fn _ ->
      send(parent, {:posting_slowly, self()})
      receive do :finish -> 200 after 900 -> 200 end
    end)
    private_update(inst, 1, 123)
    Relay.notify(inst.id)
    assert_receive {:posting_slowly, sender}, 1_000
    assert eventually(fn -> Enum.any?(Agent.get(calls, & &1), &match?({"sendMessage", _}, &1)) end, 10)
    assert Inbox.pending_count(inst.id) == 1
    send(sender, :finish)
    assert eventually(fn -> Inbox.pending_count(inst.id) == 0 end)
  end

  test "a notice finishing after delivery is deleted without blocking delivery", %{inst: inst, bypass: bypass, seen: seen} do
    {tg, calls} = notice_stub(inst)
    parent = self()
    Bypass.stub(tg, "POST", "/botTOK/sendMessage", fn conn ->
      send(parent, {:sending_notice, self()})
      receive do :finish -> :ok after 3_000 -> flunk("send not released") end
      Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":{"message_id":99}}))
    end)
    Webhook.pause(inst.id, :stopping)
    private_update(inst, 1, 123)
    Relay.notify(inst.id)
    assert_receive {:sending_notice, sender}, 2_000
    ptb(bypass, inst, seen)
    Webhook.resume(inst.id)
    assert eventually(fn -> seen(seen) == [1] end)
    send(sender, :finish)
    assert eventually(fn -> Enum.any?(Agent.get(calls, & &1), &match?({"deleteMessage", _}, &1)) end)
  end

  test "groups, non-waking updates and deliberately stopped bots get no notices", %{inst: inst} do
    {_tg, calls} = notice_stub(inst)
    Webhook.pause(inst.id, :stopping)
    private_update(inst, 1, -1, "group")
    private_update(inst, 2, 123)
    Repo.get_by!(Inbox, instance_id: inst.id, update_id: 2) |> Ecto.Changeset.change(wakes: false) |> Repo.update!()
    Relay.notify(inst.id)
    Process.sleep(350)
    assert Agent.get(calls, & &1) == []
    inst |> Repo.reload!() |> Instance.changeset(%{active: false}) |> Repo.update!()
    private_update(inst, 3, 456)
    Process.sleep(350)
    assert Agent.get(calls, & &1) == []
    inst |> Repo.reload!() |> Ecto.Changeset.change(%{active: true, delete_requested: true}) |> Repo.update!()
    Process.sleep(350)
    assert Agent.get(calls, & &1) == []
  end

  test "expired and dropped waiting updates remove their notice", %{inst: inst} do
    {_tg, calls} = notice_stub(inst)
    Webhook.pause(inst.id, :stopping)
    private_update(inst, 1, 123)
    Relay.notify(inst.id)
    assert eventually(fn -> length(Agent.get(calls, & &1)) == 1 end)
    Inbox.housekeep(inst.id, DateTime.add(DateTime.utc_now(), 86_400))
    assert eventually(fn -> Enum.count(Agent.get(calls, & &1), &(elem(&1, 0) == "deleteMessage")) == 1 end)
    private_update(inst, 2, 123)
    Relay.notify(inst.id)
    assert eventually(fn -> Enum.count(Agent.get(calls, & &1), &(elem(&1, 0) == "sendMessage")) == 2 end)
    Inbox.drop_pending(inst.id, "mode_switch")
    assert eventually(fn -> Enum.count(Agent.get(calls, & &1), &(elem(&1, 0) == "deleteMessage")) == 2 end)
  end

  # PTB's TelegramHandler: 403 unless the content type is exactly
  # application/json and the secret matches; tornado 404s another path.
  defp ptb(bypass, inst, seen, reply \\ fn _id -> 200 end) do
    path = "/telegram/webhook/#{inst.name}"

    Bypass.stub(bypass, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      cond do
        Plug.Conn.get_req_header(conn, "content-type") != ["application/json"] ->
          Plug.Conn.resp(conn, 403, "")

        Plug.Conn.get_req_header(conn, "x-telegram-bot-api-secret-token") != ["sekret"] ->
          Plug.Conn.resp(conn, 403, "")

        true ->
          id = Jason.decode!(body)["update_id"]
          status = reply.(id)
          if status in 200..299, do: Agent.update(seen, &(&1 ++ [id]))
          Plug.Conn.resp(conn, status, "")
      end
    end)
  end

  defp enqueue(inst, ids),
    do: for(id <- ids, do: :ok = Inbox.enqueue(inst.id, id, ~s({"update_id":#{id}})))

  defp seen(agent), do: Agent.get(agent, & &1)
  defp reload(inst), do: Repo.get!(Instance, inst.id)

  test "delivers in update_id order with PTB's exact headers", %{
    bypass: bypass,
    inst: inst,
    seen: seen
  } do
    ptb(bypass, inst, seen)
    # Queue all three before the relay looks: otherwise its idle poll may run
    # between the inserts and hand over 30 first, which is arrival order.
    stop_supervised!(Relay)
    enqueue(inst, [30, 10, 20])
    start_supervised!(Relay)

    assert eventually(fn -> seen(seen) == [10, 20, 30] end)
    assert Inbox.pending_count(inst.id) == 0
  end

  test "a bot that is down keeps the head of the line until it is back", %{
    bypass: bypass,
    inst: inst,
    seen: seen
  } do
    Bypass.down(bypass)
    enqueue(inst, [1, 2])
    Relay.notify(inst.id)

    assert eventually(fn -> Inbox.next_pending(inst.id).attempts >= 2 end)
    assert Inbox.pending_count(inst.id) == 2

    Bypass.up(bypass)
    ptb(bypass, inst, seen)
    assert eventually(fn -> seen(seen) == [1, 2] end)
  end

  test "5xx and 429 retry the same row", %{bypass: bypass, inst: inst, seen: seen} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    ptb(bypass, inst, seen, fn _ ->
      Agent.get_and_update(calls, &{if(&1 < 2, do: Enum.at([503, 429], &1), else: 200), &1 + 1})
    end)

    enqueue(inst, [5])
    Relay.notify(inst.id)

    assert eventually(fn -> seen(seen) == [5] end)
    assert Repo.get_by!(Inbox, instance_id: inst.id, update_id: 5).attempts == 2
  end

  test "a 403 pauses the bot and keeps every row; fixing the config resumes", %{
    bypass: bypass,
    inst: inst,
    seen: seen
  } do
    ptb(bypass, inst, seen)
    inst |> Instance.changeset(%{telegram_webhook_secret: "stale"}) |> Repo.update!()
    enqueue(inst, [1, 2, 3])
    Relay.notify(inst.id)

    assert eventually(fn -> match?({"rejected_config", _}, Webhook.paused(reload(inst))) end)
    assert Inbox.pending_count(inst.id) == 3
    assert seen(seen) == []

    # What a successful start does: the env is re-synced and every pause but
    # wrong_owner is lifted.
    inst |> reload() |> Instance.changeset(%{telegram_webhook_secret: "sekret"}) |> Repo.update!()
    Webhook.resume_except(inst.id, :wrong_owner)
    assert eventually(fn -> seen(seen) == [1, 2, 3] end)
  end

  test "another 4xx rejects only that row", %{bypass: bypass, inst: inst, seen: seen} do
    ptb(bypass, inst, seen, fn id -> if id == 1, do: 400, else: 200 end)
    enqueue(inst, [1, 2])
    Relay.notify(inst.id)

    assert eventually(fn -> seen(seen) == [2] end)

    assert %{dropped_reason: "rejected", last_error: "HTTP 400"} =
             Repo.get_by!(Inbox, instance_id: inst.id, update_id: 1)
  end

  test "acked rows are not sent again when the worker restarts", %{
    bypass: bypass,
    inst: inst,
    seen: seen
  } do
    ptb(bypass, inst, seen)
    enqueue(inst, [1])
    Relay.notify(inst.id)
    assert eventually(fn -> seen(seen) == [1] end)

    assert eventually(fn -> Inbox.pending_count(inst.id) == 0 end)

    stop_supervised!(Relay)
    start_supervised!(Relay)
    enqueue(inst, [2])
    Relay.notify(inst.id)
    assert eventually(fn -> seen(seen) == [1, 2] end)
  end

  test "nothing is delivered while paused for a stop", %{bypass: bypass, inst: inst, seen: seen} do
    ptb(bypass, inst, seen)
    Webhook.pause(inst.id, :stopping)
    enqueue(inst, [1])
    Relay.notify(inst.id)

    Process.sleep(150)
    assert seen(seen) == []

    Webhook.resume(inst.id)
    assert eventually(fn -> seen(seen) == [1] end)
  end

  test "a listener owned by another uid gets nothing and pauses the bot", %{
    bypass: bypass,
    inst: inst,
    seen: seen
  } do
    Application.put_env(:druzhok, :telegram_listener_owner, WrongOwner)
    ptb(bypass, inst, seen)
    enqueue(inst, [1])
    Relay.notify(inst.id)

    assert eventually(fn -> match?({"wrong_owner", _}, Webhook.paused(reload(inst))) end)
    assert seen(seen) == []
    assert Inbox.pending_count(inst.id) == 1
  end

  test "the boot task starts a worker for every webhook bot", %{
    bypass: bypass,
    inst: inst,
    seen: seen
  } do
    ptb(bypass, inst, seen)
    stop_supervised!(Relay)
    enqueue(inst, [9])
    start_supervised!(Relay)

    assert eventually(fn -> seen(seen) == [9] end)
  end

  test "a bot switched back to polling stops its worker", %{inst: inst} do
    Relay.notify(inst.id)

    assert eventually(fn ->
             Registry.lookup(Druzhok.Registry, {:telegram_relay, inst.id}) != []
           end)

    inst |> Instance.changeset(%{telegram_mode: "polling"}) |> Repo.update!()
    Relay.notify(inst.id)

    assert eventually(fn ->
             Registry.lookup(Druzhok.Registry, {:telegram_relay, inst.id}) == []
           end)
  end

  describe "sleep/wake" do
    test "rows wait while the bot is stopped and go once it should run", %{
      bypass: bypass,
      inst: inst,
      seen: seen
    } do
      ptb(bypass, inst, seen)
      inst |> Ecto.Changeset.change(%{active: false}) |> Repo.update!()
      enqueue(inst, [1])
      Relay.notify(inst.id)
      Process.sleep(150)
      assert seen(seen) == []

      inst |> reload() |> Ecto.Changeset.change(%{active: true}) |> Repo.update!()
      Relay.notify(inst.id)
      assert eventually(fn -> seen(seen) == [1] end)
    end

    test "an asleep bot's rows wait until it is awake", %{bypass: bypass, inst: inst, seen: seen} do
      ptb(bypass, inst, seen)
      inst |> Ecto.Changeset.change(%{sleeping: true}) |> Repo.update!()
      enqueue(inst, [7])
      Relay.notify(inst.id)
      Process.sleep(150)
      assert seen(seen) == []

      inst |> reload() |> Ecto.Changeset.change(%{sleeping: false}) |> Repo.update!()
      assert eventually(fn -> seen(seen) == [7] end)
    end

    test "quiesce waits for a POST in flight", %{bypass: bypass, inst: inst} do
      test = self()

      Bypass.stub(bypass, "POST", "/telegram/webhook/#{inst.name}", fn conn ->
        send(test, :posting)
        Process.sleep(300)
        send(test, :answered)
        Plug.Conn.resp(conn, 200, "")
      end)

      enqueue(inst, [1])
      Relay.notify(inst.id)
      assert_receive :posting, 2_000

      assert :ok = Relay.quiesce(inst.id)
      # The worker answered only after the POST had its reply.
      assert_received :answered
      assert :ok = Relay.quiesce(-1)
    end

    test "just after a wake the retry backoff is capped", %{bypass: bypass, inst: inst} do
      Application.put_env(
        :druzhok,
        :telegram_relay,
        Keyword.merge(Application.get_env(:druzhok, :telegram_relay),
          backoff_min_ms: 200,
          backoff_max_ms: 5_000,
          waking_backoff_ms: 10
        )
      )

      Bypass.down(bypass)
      enqueue(inst, [1])

      inst
      |> Ecto.Changeset.change(%{woke_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update!()

      Relay.notify(inst.id)
      # The waking cap allows repeated attempts without the normal backoff.
      assert eventually(fn -> Inbox.next_pending(inst.id).attempts >= 5 end)
    end
  end
end
