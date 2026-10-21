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
      Process.sleep(400)
      # 200 ms then 400 ms backoff would allow 2 attempts; capped at 10 ms, many.
      assert Inbox.next_pending(inst.id).attempts >= 5
    end
  end
end
