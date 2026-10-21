defmodule Druzhok.LifecycleTest do
  @moduledoc "The per-bot lifecycle controller's rules (sleep/wake spec, \"Controller\")."
  # async: false — app env (host, lifecycle timings) and a named supervisor.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
  alias Druzhok.{BotManager, HostStub, Instance, Lifecycle, Repo}
  alias Druzhok.Lifecycle.{Idle, Typing}
  alias Druzhok.Telegram.{Inbox, Webhook}

  setup do
    %{data_root: root} = with_tmp_data_root()
    HostStub.use()

    prev = Application.get_env(:druzhok, :lifecycle)
    Application.put_env(:druzhok, :lifecycle, Keyword.merge(prev, idle_window_s: 60))
    on_exit(fn -> Application.put_env(:druzhok, :lifecycle, prev) end)

    start_lifecycle()
    %{root: root}
  end

  defp long_ago, do: DateTime.utc_now() |> DateTime.add(-600) |> DateTime.truncate(:second)

  # An awake webhook bot, started 10 min ago, opted in, idle in every respect.
  defp idle_bot(root, attrs \\ %{}) do
    id = 100 + rem(System.unique_integer([:positive]), 899)
    name = "life#{id}"

    inst =
      relay_instance(
        Map.merge(
          %{
            id: id,
            name: name,
            workspace: Path.join([root, name, "workspace"]),
            telegram_mode: "webhook",
            telegram_webhook_secret: "s",
            sleep_enabled: true,
            started_mode: "webhook",
            started_at: long_ago()
          },
          attrs
        )
      )

    gateway_state(inst, %{"gateway_state" => "running", "active_agents" => 0})
    if Map.get(attrs, :unit, :active) == :active, do: HostStub.set_unit(name, :active)
    inst
  end

  defp gateway_state(inst, state) do
    dir = Path.dirname(inst.workspace)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "gateway_state.json"), Jason.encode!(state))
  end

  defp reload(inst), do: Repo.get!(Instance, inst.id)
  defp poke(inst), do: Lifecycle.poke(inst.id)

  defp set(inst, changes),
    do: Repo.update_all(from(i in Instance, where: i.id == ^inst.id), set: changes)

  describe "falling asleep and waking" do
    test "an idle bot is stopped and marked asleep, with no pause left", %{root: root} do
      inst = idle_bot(root)
      poke(inst)

      assert eventually(fn -> reload(inst).sleeping end)
      assert HostStub.calls(:stop) == [inst.name]
      refute Webhook.paused(reload(inst))
      assert reload(inst).active
    end

    test "a pending update wakes it; the start runs with what the row says", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1,"message":{"chat":{"id":5}}}))
      poke(inst)

      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      row = reload(inst)
      refute row.sleeping
      assert row.woke_at
      assert HostStub.status(inst.name) == :active
    end

    test "a restart of an asleep bot wakes it (a token change reaches it)", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      assert {:ok, _} = BotManager.restart(inst.name, wait: true)
      refute reload(inst).sleeping
      assert HostStub.calls(:start) == [inst.name]
    end

    test "turning sleep off or switching to polling wakes an asleep bot", %{root: root} do
      for change <- [[sleep_enabled: false], [telegram_mode: "polling"]] do
        inst = idle_bot(root, %{sleeping: true, unit: :inactive})
        set(inst, change)
        poke(inst)
        assert eventually(fn -> not reload(inst).sleeping end)
      end
    end

    test "an asleep bot without a reason stays asleep", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      poke(inst)
      Process.sleep(200)
      assert reload(inst).sleeping
      assert HostStub.calls(:start) == []
    end

    test "a unit started by hand is taken as awake", %{root: root} do
      inst = idle_bot(root, %{sleeping: true})
      # Busy, so it does not fall straight back to sleep.
      HostStub.set_procs(2)
      poke(inst)
      assert eventually(fn -> not reload(inst).sleeping end)
      assert HostStub.calls(:start) == []
    end

    test "sleep is not entered while the relay holds another pause", %{root: root} do
      inst = idle_bot(root)
      Webhook.pause(inst.id, :wrong_owner)
      poke(inst)
      Process.sleep(200)
      refute reload(inst).sleeping
      assert {"wrong_owner", _} = Webhook.paused(reload(inst))
    end
  end

  describe "stop, start, delete" do
    test "stop of an asleep bot is acknowledged and an update no longer wakes it", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      assert :ok = BotManager.stop(inst.name, wait: true)
      row = reload(inst)
      refute row.active
      refute row.sleeping
      assert row.stopped_seq == row.stop_seq

      :ok = Inbox.enqueue(inst.id, 2, ~s({"update_id":2}))
      poke(inst)
      Process.sleep(200)
      assert HostStub.calls(:start) == []
    end

    test "stop of a running bot pauses, stops and acknowledges", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      assert :ok = BotManager.stop(inst.name, wait: true)
      assert HostStub.calls(:stop) == [inst.name]
      assert {"stopping", _} = Webhook.paused(reload(inst))
    end

    test "an active bot whose unit is down (after a reboot) is started", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(inst)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
    end

    test "a request during an activation waits for it to settle", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      HostStub.set_unit(inst.name, :activating)
      BotManager.restart(inst.name)
      Process.sleep(200)
      assert HostStub.calls(:start) == []

      HostStub.set_unit(inst.name, :active)
      poke(inst)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
    end

    test "nothing is started or resumed while the unit drains", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      HostStub.set_unit(inst.name, :stopping)
      Webhook.pause(inst.id, :stopping)
      BotManager.restart(inst.name)
      Process.sleep(200)
      assert HostStub.calls(:start) == []
      assert {"stopping", _} = Webhook.paused(reload(inst))
    end

    test "delete stops, destroys and drops the row", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      assert :ok = BotManager.delete(inst.name, wait: true)
      assert Repo.get(Instance, inst.id) == nil

      assert HostStub.calls() |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 in [:stop, :destroy])) ==
               [:stop, :destroy]
    end

    test "the first pass fills started_at for a running bot and restarts nothing", %{root: root} do
      inst = idle_bot(root, %{started_at: nil, sleep_enabled: false})
      poke(inst)
      assert eventually(fn -> reload(inst).started_at end)
      assert HostStub.calls(:start) == []
    end
  end

  describe "failures" do
    test "a failed start is recorded, stops the unit and backs off; a new request goes at once",
         %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      HostStub.on_start({:error, :boom})
      assert {:error, ":boom"} = BotManager.start(inst.name, wait: true)

      row = reload(inst)
      assert row.start_failures == 1
      assert row.failed_seq == row.start_seq
      assert :stop in Enum.map(HostStub.calls(), &elem(&1, 0))

      # Within the first 300 ms backoff nothing is retried...
      Process.sleep(100)
      assert length(HostStub.calls(:start)) == 1

      # ...but a request made after the failure is tried at once.
      HostStub.on_start(:ok)
      assert {:ok, _} = BotManager.restart(inst.name, wait: true)
      assert reload(inst).start_failures == 0
    end

    test "systemd's restart loop is a failed start: the unit is stopped and retried later",
         %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      HostStub.set_unit(inst.name, :restarting)
      poke(inst)

      assert eventually(fn -> reload(inst).start_error == "restart loop" end)
      assert HostStub.calls(:stop) == [inst.name]
      # failed_seq never moves past what is applied: nobody's request failed.
      assert reload(inst).failed_seq == reload(inst).applied_seq
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end, 40)
    end

    test "an activation past the limit is a failed start", %{root: root} do
      Application.put_env(
        :druzhok,
        :lifecycle,
        Keyword.put(Application.get_env(:druzhok, :lifecycle), :activating_limit_ms, 100)
      )

      inst = idle_bot(root, %{sleep_enabled: false})
      HostStub.set_unit(inst.name, :activating)
      poke(inst)
      assert eventually(fn -> reload(inst).start_error == "start timeout" end)
    end

    test "an exception while preparing the start is a recorded failure", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      # The workspace is a plain file (a tenant can do that): seeding raises.
      File.write!(inst.workspace, "not a dir")

      assert {:error, err} = BotManager.start(inst.name, wait: true)
      assert err =~ "workspace"
      assert Lifecycle.ensure(inst.id) |> elem(0) == :ok
    end
  end

  describe "Idle.check/2" do
    setup %{root: root}, do: %{inst: idle_bot(root)}

    defp check(inst, opts \\ []), do: Idle.check(reload(inst), opts)

    test("an idle bot", %{inst: inst}, do: assert(check(inst) == :idle))

    test "each source of work keeps it awake", %{inst: inst} do
      busy = fn change, reason ->
        set(inst, change)
        assert {:busy, ^reason} = check(inst)
        set(inst, Keyword.new(change, fn {k, _} -> {k, Map.fetch!(inst, k)} end))
      end

      busy.([sleep_enabled: false], :sleep_disabled)
      busy.([telegram_mode: "polling"], :polling)
      busy.([started_mode: "polling"], :started_polling)
      busy.([start_seq: 1], :start_requested)
      busy.([started_at: nil], :recently_started)
      busy.([started_at: DateTime.utc_now() |> DateTime.truncate(:second)], :recently_started)
    end

    test "a recent or pending update", %{inst: inst} do
      :ok = Inbox.enqueue(inst.id, 3, ~s({"update_id":3}))
      assert {:busy, :telegram} = check(inst)
    end

    test "a recent proxy call", %{inst: inst} do
      Repo.insert!(%Druzhok.Usage{
        instance_id: inst.id,
        model: "m",
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      })

      assert {:busy, :proxy} = check(inst)
    end

    test "a turn in flight, or no readable state", %{inst: inst} do
      gateway_state(inst, %{"gateway_state" => "running", "active_agents" => 1})
      assert {:busy, {:turns, _}} = check(inst)
      File.rm!(Path.join(Path.dirname(inst.workspace), "gateway_state.json"))
      assert {:busy, :gateway_state_unreadable} = check(inst)
    end

    test "a child process", %{inst: inst} do
      HostStub.set_procs(2)
      assert {:busy, {:procs, 2}} = check(inst)
    end

    test "cron: an enabled job or an unreadable file is work, a disabled job is not", %{
      inst: inst
    } do
      dir = Path.join(Path.dirname(inst.workspace), "cron")
      File.mkdir_p!(dir)
      jobs = Path.join(dir, "jobs.json")

      File.write!(jobs, ~s({"jobs":[{"id":"a","enabled":false}]}))
      assert check(inst) == :idle
      File.write!(jobs, ~s({"jobs":[{"id":"a"}]}))
      assert {:busy, :cron} = check(inst)
      File.write!(jobs, "{")
      assert {:busy, :cron_unreadable} = check(inst)
    end

    test "the sleep action's own pause is accepted, others are not", %{inst: inst} do
      Webhook.pause(inst.id, :sleeping)
      assert {:busy, {:paused, "sleeping"}} = check(inst)
      assert check(inst, own_pause: true) == :idle
      Webhook.pause(inst.id, :wrong_owner)
      assert {:busy, {:paused, "wrong_owner"}} = check(inst, own_pause: true)
    end
  end

  test "shown_status" do
    i = %Instance{active: true, sleeping: false, delete_requested: false}
    assert Lifecycle.shown_status(%{i | sleeping: true}, "inactive") == "sleeping"
    assert Lifecycle.shown_status(%{i | active: false}, "active") == "stopping"
    assert Lifecycle.shown_status(%{i | delete_requested: true}, "active") == "deleting"
    assert Lifecycle.shown_status(%{i | woke_at: DateTime.utc_now()}, "activating") == "waking"
    assert Lifecycle.shown_status(i, "failed") == "failed"
  end

  test "Typing.chat_id reads the chat of a message, an edit or a callback" do
    assert Typing.chat_id(~s({"message":{"chat":{"id":5}}})) == 5
    assert Typing.chat_id(~s({"edited_message":{"chat":{"id":6}}})) == 6
    assert Typing.chat_id(~s({"callback_query":{"message":{"chat":{"id":7}}}})) == 7
    assert Typing.chat_id(~s({"my_chat_member":{}})) == nil
  end

  describe "ordering and interleavings" do
    test "every stop holds the relay before Host.stop", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      assert :ok = BotManager.stop(inst.name, wait: true)

      sleeper = idle_bot(root)
      poke(sleeper)
      assert eventually(fn -> reload(sleeper).sleeping end)

      assert HostStub.pauses_at_stop() == ["stopping", "sleeping"]
    end

    test "a Stop during a restart's drain wins: no start, and the stop waiter is answered after",
         %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      test = self()

      HostStub.hook(:stop, fn name ->
        Task.start(fn -> send(test, {:stopped, BotManager.stop(name, wait: true)}) end)
        # Let the request land before the controller re-reads the row.
        Process.sleep(100)
      end)

      BotManager.restart(inst.name)
      assert_receive {:stopped, :ok}, 5_000
      assert HostStub.calls(:start) == []
      refute reload(inst).active
      assert HostStub.status(inst.name) == :inactive
    end

    test "a Stop during a wake's Host.start ends stopped", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      HostStub.hook(:start, fn name -> BotManager.stop(name) end)
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}))
      poke(inst)

      assert eventually(fn ->
               reload(inst).stop_seq > 0 and reload(inst).stopped_seq == reload(inst).stop_seq and
                 HostStub.status(inst.name) == :inactive
             end)

      refute reload(inst).active
    end

    test "Stop then Start during a wake ends running", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})

      HostStub.hook(:start, fn name ->
        BotManager.stop(name)
        BotManager.start(name)
      end)

      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}))
      poke(inst)

      assert eventually(fn ->
               r = reload(inst)
               r.active and r.applied_seq == r.start_seq and HostStub.status(inst.name) == :active
             end)
    end

    test "a request made before the first pass after deploy is carried out", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false, start_seq: 1, started_at: nil})
      poke(inst)
      assert eventually(fn -> reload(inst).applied_seq == 1 end)
      assert HostStub.calls(:stop) == [inst.name]
      assert HostStub.calls(:start) == [inst.name]
    end

    test "pokes do not multiply the controller's passes", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      {:ok, pid} = Lifecycle.ensure(inst.id)
      for _ <- 1..20, do: send(pid, :poke)
      Process.sleep(200)
      timers = :sys.get_state(pid).timer
      assert is_reference(timers)
      {:messages, msgs} = Process.info(pid, :messages)
      assert Enum.count(msgs, &(&1 == :tick)) <= 1
    end
  end

  describe "crashes" do
    test "a controller killed inside a sleep's Host.stop is replaced and finishes the job",
         %{root: root} do
      inst = idle_bot(root)
      HostStub.hook(:stop, fn _ -> Process.exit(self(), :kill) end)
      poke(inst)

      # The unit was still up when the controller died; its successor sees an
      # idle bot with its own leftover pause and puts it to sleep properly.
      assert eventually(fn -> reload(inst).sleeping end, 100)
      refute Webhook.paused(reload(inst))
    end

    test "a leftover sleeping pause on a running, busy bot is cleared", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false})
      Webhook.pause(inst.id, :sleeping)
      poke(inst)
      assert eventually(fn -> is_nil(Webhook.paused(reload(inst))) end)
      assert HostStub.calls(:start) == []
    end

    test "stopped after Host.stop but before it was marked asleep: started again", %{root: root} do
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      Webhook.pause(inst.id, :sleeping)
      poke(inst)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      assert eventually(fn -> is_nil(Webhook.paused(reload(inst))) end)
    end
  end

  describe "with the relay" do
    setup do
      Application.put_env(:druzhok, :telegram_relay,
        paused_poll_ms: 20,
        idle_poll_ms: 50,
        backoff_min_ms: 10,
        backoff_max_ms: 40
      )

      on_exit(fn -> Application.delete_env(:druzhok, :telegram_relay) end)
      start_supervised!(Druzhok.Telegram.Relay)
      :ok
    end

    test "an update for an asleep bot makes the relay wake it", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(inst.id, 9, ~s({"update_id":9}))
      Druzhok.Telegram.Relay.notify(inst.id)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
    end
  end

  describe "typing indicator" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:druzhok, :telegram_api_base) end)
      {:ok, seen} = Agent.start(fn -> [] end)

      Bypass.stub(bypass, "POST", "/botT1/sendChatAction", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(seen, &[body | &1])
        Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":true}))
      end)

      %{seen: seen}
    end

    test "shown in the waking update's chat until it is delivered", %{root: root, seen: seen} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive, telegram_token: "T1"})
      :ok = Inbox.enqueue(inst.id, 4, ~s({"update_id":4,"message":{"chat":{"id":555}}}))
      poke(inst)

      assert eventually(fn -> Agent.get(seen, &length/1) >= 2 end)
      assert Agent.get(seen, &hd/1) =~ "555"

      Inbox.next_pending(inst.id) |> Inbox.ack()
      Process.sleep(150)
      n = Agent.get(seen, &length/1)
      Process.sleep(200)
      assert Agent.get(seen, &length/1) == n
    end

    test "not sent for an update without a chat", %{root: root, seen: seen} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive, telegram_token: "T1"})
      :ok = Inbox.enqueue(inst.id, 5, ~s({"update_id":5,"my_chat_member":{}}))
      poke(inst)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      Process.sleep(150)
      assert Agent.get(seen, & &1) == []
    end
  end
end
