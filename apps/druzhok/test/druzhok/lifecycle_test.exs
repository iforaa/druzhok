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

  defp cron_file(inst) do
    dir = Path.join(Path.dirname(inst.workspace), "cron")
    File.mkdir_p!(dir)
    Path.join(dir, "jobs.json")
  end

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

    test "an update that does not wake it waits for the next wake", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}), wakes: false)
      poke(inst)
      Process.sleep(200)
      assert reload(inst).sleeping
      assert HostStub.calls(:start) == []

      :ok = Inbox.enqueue(inst.id, 2, ~s({"update_id":2}))
      poke(inst)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
    end

    test "a cron run wakes it 3 min ahead, not before", %{root: root} do
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      jobs = cron_file(inst)
      at = fn s -> DateTime.utc_now() |> DateTime.add(s) |> DateTime.to_iso8601() end

      File.write!(jobs, ~s({"jobs":[{"id":"a","next_run_at":"#{at.(600)}"}]}))
      poke(inst)
      Process.sleep(200)
      assert reload(inst).sleeping

      File.write!(jobs, ~s({"jobs":[{"id":"a","next_run_at":"#{at.(170)}"}]}))
      poke(inst)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      refute reload(inst).sleeping
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

    test "cron: a job due soon, one without a time or an unreadable file is work", %{inst: inst} do
      jobs = cron_file(inst)
      at = fn s -> DateTime.utc_now() |> DateTime.add(s) |> DateTime.to_iso8601() end

      File.write!(jobs, ~s({"jobs":[{"id":"a","enabled":false}]}))
      assert check(inst) == :idle
      File.write!(jobs, ~s({"jobs":[{"id":"a","next_run_at":"#{at.(3600)}"}]}))
      assert check(inst) == :idle

      File.write!(
        jobs,
        ~s({"jobs":[{"id":"a","next_run_at":"#{at.(3600)}"},{"id":"b","next_run_at":"#{at.(300)}"}]})
      )

      assert {:busy, :cron} = check(inst)
      File.write!(jobs, ~s({"jobs":[{"id":"a"}]}))
      assert {:busy, :cron_unreadable} = check(inst)
      File.write!(jobs, ~s({"jobs":[{"id":"a","next_run_at":"2026-10-21T10:00:00"}]}))
      assert {:busy, :cron_unreadable} = check(inst)
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

  test "Typing.chat_id reads the private chat of a message, an edit or a callback" do
    assert Typing.chat_id(~s({"message":{"chat":{"id":5,"type":"private"}}})) == 5
    assert Typing.chat_id(~s({"edited_message":{"chat":{"id":6,"type":"private"}}})) == 6

    assert Typing.chat_id(~s({"callback_query":{"message":{"chat":{"id":7,"type":"private"}}}})) ==
             7

    assert Typing.chat_id(~s({"my_chat_member":{}})) == nil
  end

  test "Typing.chat_id ignores groups, where the bot may not answer" do
    assert Typing.chat_id(~s({"message":{"chat":{"id":-100,"type":"supergroup"}}})) == nil
    assert Typing.chat_id(~s({"message":{"chat":{"id":-101,"type":"group"}}})) == nil
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

  describe "settings saved in the panel" do
    # sleep off: the bot stays awake, so only a quiet restart can apply them.
    defp pending_bot(root, attrs \\ %{}) do
      inst = idle_bot(root, Map.merge(%{sleep_enabled: false}, attrs))
      set(inst, settings_seq: 1, settings_saved_at: DateTime.utc_now())
      inst
    end

    test "a quiet awake bot is restarted once, and the start records them", %{root: root} do
      inst = pending_bot(root)
      poke(inst)

      assert eventually(fn -> reload(inst).settings_applied_seq == 1 end)
      Process.sleep(300)
      assert HostStub.calls(:start) == [inst.name]
      assert HostStub.pauses_at_stop() == ["stopping"]
      refute Webhook.paused(reload(inst))
    end

    test "a busy bot waits, without a pause, and is restarted once it is quiet", %{root: root} do
      inst = pending_bot(root)
      gateway_state(inst, %{"gateway_state" => "running", "active_agents" => 1})
      poke(inst)
      Process.sleep(300)

      assert HostStub.calls(:stop) == []
      refute Webhook.paused(reload(inst))
      assert reload(inst).settings_applied_seq == 0

      gateway_state(inst, %{"gateway_state" => "running", "active_agents" => 0})
      assert eventually(fn -> reload(inst).settings_applied_seq == 1 end)
      assert HostStub.calls(:start) == [inst.name]
    end

    test "an update or a proxy call in the last minute is busy; a child process too", %{
      root: root
    } do
      inst = pending_bot(root)
      HostStub.set_procs(2)
      poke(inst)
      Process.sleep(300)
      assert HostStub.calls(:stop) == []

      HostStub.set_procs(1)

      Repo.insert!(%Druzhok.Usage{
        instance_id: inst.id,
        model: "m",
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      })

      Process.sleep(300)
      assert HostStub.calls(:stop) == []

      Repo.delete_all(from(u in Druzhok.Usage, where: u.instance_id == ^inst.id))
      :ok = Inbox.enqueue(inst.id, 7, ~s({"update_id":7}))
      Process.sleep(300)
      assert HostStub.calls(:stop) == []
    end

    test "busy again after the hold: the relay is resumed and nothing restarts", %{root: root} do
      inst = pending_bot(root)
      # Quiet at the first look, a child process at the second, then for good.
      HostStub.set_procs([1, 2])
      poke(inst)
      Process.sleep(300)

      assert HostStub.calls(:stop) == []
      refute Webhook.paused(reload(inst))
      assert reload(inst).settings_applied_seq == 0
    end

    test "an asleep bot stays asleep; its wake applies them and nothing restarts after", %{
      root: root
    } do
      inst = pending_bot(root, %{sleep_enabled: true, sleeping: true, unit: :inactive})
      poke(inst)
      Process.sleep(300)
      assert reload(inst).sleeping
      assert HostStub.calls(:start) == []

      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1,"message":{"chat":{"id":5}}}))
      poke(inst)
      assert eventually(fn -> reload(inst).settings_applied_seq == 1 end)
      Process.sleep(300)
      assert HostStub.calls(:start) == [inst.name]
    end

    test "any start records the seq it read; a save during the start stays pending", %{root: root} do
      inst = pending_bot(root)
      # The restart request is carried out before the quiet restart's first look.
      set(inst, settings_seq: 2)

      HostStub.hook(:start, fn _ ->
        set(inst, settings_seq: 3, settings_saved_at: DateTime.utc_now())
        gateway_state(inst, %{"gateway_state" => "running", "active_agents" => 1})
      end)

      assert {:ok, _} = BotManager.restart(inst.name, wait: true)
      Process.sleep(300)
      row = reload(inst)
      assert {row.settings_seq, row.settings_applied_seq} == {3, 2}
      assert Druzhok.Panel.Settings.apply_state(row) == "waiting"
    end

    test "a failed start after the save shows as failed; an older failure does not", %{root: root} do
      inst = pending_bot(root, %{unit: :inactive})
      old = DateTime.utc_now() |> DateTime.add(-60)
      set(inst, start_error: "old", start_failed_at: old, start_failures: 0)
      assert Druzhok.Panel.Settings.apply_state(reload(inst)) == "waiting"

      HostStub.on_start({:error, :boom})
      poke(inst)
      assert eventually(fn -> reload(inst).start_failures >= 1 end)
      assert Druzhok.Panel.Settings.apply_state(reload(inst)) == "failed"
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

  describe "start gate" do
    alias Druzhok.Lifecycle.StartGate

    setup %{root: root} do
      path = Path.join(root, "meminfo")
      lifecycle_env(meminfo_path: path, start_min_free_mb: 900)
      %{meminfo: path}
    end

    defp lifecycle_env(changes) do
      Application.put_env(
        :druzhok,
        :lifecycle,
        Keyword.merge(Application.get_env(:druzhok, :lifecycle), changes)
      )
    end

    defp free_mb(path, mb) do
      File.write!(path, """
      MemTotal:        8000000 kB
      MemFree:          100000 kB
      MemAvailable:    #{mb * 1024} kB
      Buffers:           10000 kB
      """)
    end

    defp no_failure(inst) do
      row = reload(inst)
      assert row.start_failures == 0
      assert is_nil(row.start_error)
      assert is_nil(row.start_failed_at)
    end

    defp controller(inst) do
      {:ok, pid} = Lifecycle.ensure(inst.id)
      pid
    end

    defp waiting?(inst), do: is_integer(:sys.get_state(controller(inst)).waiting_since)

    test "low memory: a sleeping bot with an update stays asleep until memory returns", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 500)
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1,"message":{"chat":{"id":5}}}))
      poke(inst)

      assert eventually(fn -> waiting?(inst) end)
      pid = controller(inst)
      Process.sleep(200)
      assert HostStub.calls(:start) == []
      row = reload(inst)
      assert row.sleeping
      refute row.woke_at
      no_failure(inst)

      free_mb(mem, 2000)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      refute reload(inst).sleeping
      assert reload(inst).woke_at
      refute waiting?(inst)
      assert controller(inst) == pid
    end

    test "low memory: an active bot whose unit is down is not started, then is", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 500)
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(inst)

      assert eventually(fn -> waiting?(inst) end)
      pid = controller(inst)
      Process.sleep(200)
      assert HostStub.calls(:start) == []
      no_failure(inst)

      free_mb(mem, 2000)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      refute waiting?(inst)
      assert controller(inst) == pid
    end

    test "a threshold of exactly the free memory lets the start through", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 900)
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(inst)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
    end

    test "low memory: a restart of a running unit still happens", %{root: root, meminfo: mem} do
      free_mb(mem, 500)
      inst = idle_bot(root, %{sleep_enabled: false})
      assert {:ok, _} = BotManager.restart(inst.name, wait: true)
      assert HostStub.calls(:stop) == [inst.name]
      assert HostStub.calls(:start) == [inst.name]
    end

    test "low memory: stop and delete still happen", %{root: root, meminfo: mem} do
      free_mb(mem, 500)
      stopped = idle_bot(root, %{sleep_enabled: false})
      assert :ok = BotManager.stop(stopped.name, wait: true)
      assert HostStub.calls(:stop) == [stopped.name]

      deleted = idle_bot(root, %{sleep_enabled: false})
      assert :ok = BotManager.delete(deleted.name, wait: true)
      assert Repo.get(Instance, deleted.id) == nil
    end

    test "low memory: a running bot still falls asleep", %{root: root, meminfo: mem} do
      free_mb(mem, 500)
      inst = idle_bot(root)
      poke(inst)
      assert eventually(fn -> reload(inst).sleeping end)
    end

    test "a stop during the wait sees the unit now, however long the poll", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 500)
      lifecycle_env(unit_poll_ms: 60_000)
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(inst)
      assert eventually(fn -> waiting?(inst) end)
      pid = controller(inst)

      # Started by hand since the last read: only a fresh one can tell.
      HostStub.set_unit(inst.name, :active)
      assert :ok = BotManager.stop(inst.name, wait: true)
      assert HostStub.calls(:stop) == [inst.name]
      assert HostStub.status(inst.name) == :inactive
      refute waiting?(inst)
      assert controller(inst) == pid
    end

    test "a stop while waiting, then a start: the wait is logged anew", %{
      root: root,
      meminfo: mem
    } do
      Logger.put_module_level(Druzhok.Lifecycle.Bot, :info)
      on_exit(fn -> Logger.delete_module_level(Druzhok.Lifecycle.Bot) end)
      free_mb(mem, 500)
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          poke(inst)
          assert eventually(fn -> waiting?(inst) end)
          assert :ok = BotManager.stop(inst.name, wait: true)
          refute waiting?(inst)
          BotManager.start(inst.name)
          assert eventually(fn -> waiting?(inst) end)
        end)

      assert length(String.split(log, "start waits (free 500 MB)")) == 3
    end

    test "a wake reason that goes away ends the wait", %{root: root, meminfo: mem} do
      free_mb(mem, 500)
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}))
      poke(inst)
      assert eventually(fn -> waiting?(inst) end)
      pid = controller(inst)

      Inbox.next_pending(inst.id) |> Inbox.ack()
      assert eventually(fn -> not waiting?(inst) end)
      assert reload(inst).sleeping
      assert controller(inst) == pid
    end

    test "a unit up by hand ends the wait: a sleeping bot is awake, nothing is started", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 500)
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}))
      poke(inst)
      assert eventually(fn -> waiting?(inst) end)
      pid = controller(inst)

      # Busy, so it does not fall straight back to sleep.
      HostStub.set_procs(2)
      HostStub.set_unit(inst.name, :active)
      assert eventually(fn -> not waiting?(inst) end)
      assert eventually(fn -> not reload(inst).sleeping end)
      assert HostStub.calls(:start) == []
      assert controller(inst) == pid
    end

    test "a second wait is logged and warned about anew", %{root: root, meminfo: mem} do
      Logger.put_module_level(Druzhok.Lifecycle.Bot, :info)
      on_exit(fn -> Logger.delete_module_level(Druzhok.Lifecycle.Bot) end)
      free_mb(mem, 500)
      lifecycle_env(wait_warn_ms: 100)
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      warned? = fn -> :sys.get_state(controller(inst)).wait_warned end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          poke(inst)
          assert eventually(warned?)

          HostStub.set_unit(inst.name, :active)
          assert eventually(fn -> not waiting?(inst) end)

          HostStub.set_unit(inst.name, :inactive)
          assert eventually(fn -> waiting?(inst) end)
          assert eventually(warned?)
        end)

      assert length(String.split(log, "start waits (free 500 MB)")) == 3
      assert length(String.split(log, "for memory (free 500 MB); held updates")) == 3
    end

    defp lock_refused?(inst), do: :sys.get_state(controller(inst)).lock_refused

    test "refused on the lock: pokes do not read the unit, no log, and it starts after", %{
      root: root,
      meminfo: mem
    } do
      Logger.put_module_level(Druzhok.Lifecycle.Bot, :info)
      on_exit(fn -> Logger.delete_module_level(Druzhok.Lifecycle.Bot) end)
      free_mb(mem, 2000)
      lifecycle_env(unit_poll_ms: 60_000, wait_warn_ms: 0)
      assert :global.set_lock({StartGate, self()}, [node()], 0)
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          poke(inst)
          assert eventually(fn -> lock_refused?(inst) end)
          before = length(HostStub.calls(:status))

          for _ <- 1..10 do
            poke(inst)
            Process.sleep(10)
          end

          :sys.get_state(controller(inst))
          assert length(HostStub.calls(:status)) == before
          refute waiting?(inst)
          assert reload(inst).sleeping
          no_failure(inst)
        end)

      refute log =~ "start waits"
      refute log =~ "for memory"

      :global.del_lock({StartGate, self()}, [node()])
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      refute lock_refused?(inst)
    end

    test "refused on the lock: stop and delete see the unit now, however long the poll", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 2000)
      lifecycle_env(unit_poll_ms: 60_000)
      assert :global.set_lock({StartGate, self()}, [node()], 0)

      stopped = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(stopped)
      assert eventually(fn -> lock_refused?(stopped) end)
      HostStub.set_unit(stopped.name, :active)
      assert :ok = BotManager.stop(stopped.name, wait: true)
      assert HostStub.calls(:stop) == [stopped.name]
      refute lock_refused?(stopped)

      deleted = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(deleted)
      assert eventually(fn -> lock_refused?(deleted) end)
      HostStub.set_unit(deleted.name, :active)
      assert :ok = BotManager.delete(deleted.name, wait: true)
      assert deleted.name in HostStub.calls(:stop)
      assert HostStub.calls(:start) == []
    end

    test "refused on the lock: a wake reason that goes away, or a unit up by hand, clears it", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 2000)
      assert :global.set_lock({StartGate, self()}, [node()], 0)

      asleep = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(asleep.id, 1, ~s({"update_id":1}))
      poke(asleep)
      assert eventually(fn -> lock_refused?(asleep) end)
      Inbox.next_pending(asleep.id) |> Inbox.ack()
      assert eventually(fn -> not lock_refused?(asleep) end)

      up = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(up)
      assert eventually(fn -> lock_refused?(up) end)
      HostStub.set_unit(up.name, :active)
      assert eventually(fn -> not lock_refused?(up) end)
    end

    test "a memory wait keeps its log and warning through lock refusals", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 500)
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(inst)
      assert eventually(fn -> waiting?(inst) end)
      since = :sys.get_state(controller(inst)).waiting_since

      assert :global.set_lock({StartGate, self()}, [node()], 0)
      assert eventually(fn -> lock_refused?(inst) end)
      assert :sys.get_state(controller(inst)).waiting_since == since

      :global.del_lock({StartGate, self()}, [node()])
      assert eventually(fn -> not lock_refused?(inst) end)
      assert :sys.get_state(controller(inst)).waiting_since == since

      free_mb(mem, 2000)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      refute waiting?(inst)
    end

    test "lock held by another process: no start, nothing counted", %{root: root, meminfo: mem} do
      free_mb(mem, 2000)
      assert :global.set_lock({StartGate, self()}, [node()], 0)
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(inst)
      Process.sleep(200)
      pid = controller(inst)

      assert HostStub.calls(:start) == []
      no_failure(inst)
      # A lock is not a wait for memory: it is neither logged nor held on to.
      refute waiting?(inst)

      :global.del_lock({StartGate, self()}, [node()])
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)
      assert controller(inst) == pid
    end

    test "unreadable or unparsable meminfo: the start goes ahead", %{root: root, meminfo: mem} do
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(inst)
      assert eventually(fn -> HostStub.calls(:start) == [inst.name] end)

      File.write!(mem, "MemTotal: 8000000 kB\nMemAvailable: lots\n")
      other = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(other)
      assert eventually(fn -> other.name in HostStub.calls(:start) end)
    end

    test "two bots down at once: the second waits for the first's start to finish", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 2000)
      test = self()

      HostStub.hook(:start, fn name ->
        send(test, {:starting, name, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end
      end)

      a = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      b = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(a)
      poke(b)

      assert_receive {:starting, first, pid}, 2_000
      Process.sleep(300)
      assert HostStub.calls(:start) == [first]
      no_failure(a)
      no_failure(b)

      send(pid, :release)

      assert eventually(fn ->
               Enum.sort(HostStub.calls(:start)) == Enum.sort([a.name, b.name])
             end)
    end

    test "a memory refusal leaks no lock: another bot starts once memory returns", %{
      root: root,
      meminfo: mem
    } do
      free_mb(mem, 500)
      # A sleeping bot whose reason is gone by the time memory returns, so it
      # refuses once and then keeps its controller alive without starting.
      a = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(a.id, 1, ~s({"update_id":1}))
      poke(a)
      assert eventually(fn -> waiting?(a) end)
      pid = controller(a)
      Inbox.next_pending(a.id) |> Inbox.ack()
      assert eventually(fn -> not waiting?(a) end)

      free_mb(mem, 2000)
      b = idle_bot(root, %{sleep_enabled: false, unit: :inactive})
      poke(b)
      assert eventually(fn -> HostStub.calls(:start) == [b.name] end)
      # A dead holder would release a leaked lock and prove nothing.
      assert Process.alive?(pid)
      assert controller(a) == pid
    end

    test "while waiting, pokes do not read the unit; the poll does", %{root: root, meminfo: mem} do
      free_mb(mem, 500)
      lifecycle_env(unit_poll_ms: 60_000)
      inst = idle_bot(root, %{sleeping: true, unit: :inactive})
      :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}))
      poke(inst)
      assert eventually(fn -> waiting?(inst) end)

      before = length(HostStub.calls(:status))

      for _ <- 1..10 do
        poke(inst)
        Process.sleep(10)
      end

      :sys.get_state(controller(inst))
      assert length(HostStub.calls(:status)) == before

      lifecycle_env(unit_poll_ms: 0)
      assert eventually(fn -> length(HostStub.calls(:status)) > before end)
    end

    test "a wait is logged once at info, and once at warning when it runs long", %{
      root: root,
      meminfo: mem
    } do
      Logger.put_module_level(Druzhok.Lifecycle.Bot, :info)
      on_exit(fn -> Logger.delete_module_level(Druzhok.Lifecycle.Bot) end)
      free_mb(mem, 500)
      lifecycle_env(wait_warn_ms: 150)
      inst = idle_bot(root, %{sleep_enabled: false, unit: :inactive})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          poke(inst)
          assert eventually(fn -> :sys.get_state(controller(inst)).wait_warned end)
          Process.sleep(200)
        end)

      assert length(String.split(log, "start waits (free 500 MB)")) == 2
      assert length(String.split(log, "for memory (free 500 MB); held updates")) == 2
    end

    test "with_slot: the function's result, or why not", %{meminfo: mem} do
      free_mb(mem, 2000)
      assert StartGate.with_slot(fn -> :ran end) == :ran

      free_mb(mem, 899)
      assert StartGate.with_slot(fn -> flunk("must not run") end) == {:busy, {:memory, 899}}

      free_mb(mem, 2000)
      test = self()

      {:ok, holder} =
        Task.start(fn ->
          StartGate.with_slot(fn ->
            send(test, :holding)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :holding
      assert StartGate.with_slot(fn -> flunk("must not run") end) == {:busy, :lock}

      # The lock goes with its holder.
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert eventually(fn -> StartGate.with_slot(fn -> :ran end) == :ran end)
    end

    test "with_slot releases the lock when the function raises", %{meminfo: mem} do
      free_mb(mem, 2000)
      assert_raise RuntimeError, fn -> StartGate.with_slot(fn -> raise "boom" end) end

      assert Task.await(Task.async(fn -> StartGate.with_slot(fn -> :ran end) end)) == :ran
    end

    test "the threshold comes from Settings; unset or invalid is 900", %{meminfo: mem} do
      assert "start_min_free_mb" in Druzhok.Settings.keys()
      lifecycle_env(start_min_free_mb: nil)

      on_exit(fn ->
        Repo.delete_all(from(s in Druzhok.Settings, where: s.key == "start_min_free_mb"))
      end)

      free_mb(mem, 1000)
      assert StartGate.with_slot(fn -> :ran end) == :ran
      free_mb(mem, 899)
      assert StartGate.with_slot(fn -> :ran end) == {:busy, {:memory, 899}}

      Druzhok.Settings.set("start_min_free_mb", "1400")
      free_mb(mem, 1000)
      assert StartGate.with_slot(fn -> :ran end) == {:busy, {:memory, 1000}}

      for invalid <- ["lots", "0", "-5", "12x"] do
        Druzhok.Settings.set("start_min_free_mb", invalid)
        assert StartGate.with_slot(fn -> :ran end) == :ran
        free_mb(mem, 899)
        assert StartGate.with_slot(fn -> :ran end) == {:busy, {:memory, 899}}
        free_mb(mem, 1000)
      end
    end

    test "sleep is on by default for a new bot" do
      assert %Instance{}.sleep_enabled
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

      :ok =
        Inbox.enqueue(
          inst.id,
          4,
          ~s({"update_id":4,"message":{"chat":{"id":555,"type":"private"}}})
        )

      poke(inst)

      assert eventually(fn -> Agent.get(seen, &length/1) >= 2 end)
      assert Agent.get(seen, &hd/1) =~ "555"

      Inbox.next_pending(inst.id) |> Inbox.ack()
      Process.sleep(150)
      n = Agent.get(seen, &length/1)
      Process.sleep(200)
      assert Agent.get(seen, &length/1) == n
    end

    test "not sent while the start waits for memory", %{root: root, seen: seen} do
      path = Path.join(root, "meminfo")
      File.write!(path, "MemAvailable: 1024 kB\n")

      Application.put_env(
        :druzhok,
        :lifecycle,
        Keyword.merge(Application.get_env(:druzhok, :lifecycle),
          meminfo_path: path,
          start_min_free_mb: 900
        )
      )

      inst = idle_bot(root, %{sleeping: true, unit: :inactive, telegram_token: "T1"})

      :ok =
        Inbox.enqueue(
          inst.id,
          6,
          ~s({"update_id":6,"message":{"chat":{"id":556,"type":"private"}}})
        )

      poke(inst)
      Process.sleep(300)
      assert reload(inst).sleeping
      assert Agent.get(seen, & &1) == []
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
