defmodule Druzhok.DiskCheckTest do
  # async: false — app env (Telegram stub), the Host stub and settings rows.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
  alias Druzhok.{DiskCheck, HostStub, Instance, Repo, Settings}

  @keys ~w(bot_disk_mb bot_disk_files disk_quota_seen disk_quota manager_bot_token operator_telegram_id)
  @gb 1024 * 1024

  setup do
    clear = fn -> Repo.delete_all(from(s in Settings, where: s.key in ^@keys)) end
    clear.()
    on_exit(clear)
    HostStub.use()

    tg = Bypass.open()
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{tg.port}")
    on_exit(fn -> Application.delete_env(:druzhok, :telegram_api_base) end)

    # `fail`: token => status to answer with; everything else is 200.
    {:ok, agent} = Agent.start(fn -> %{sent: [], fail: %{}} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    Bypass.stub(tg, "POST", "/:bot/:method", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      "bot" <> token = hd(conn.path_info)
      body = Jason.decode!(body)

      case Agent.get(agent, & &1.fail[token]) do
        nil ->
          Agent.update(agent, &%{&1 | sent: [{token, body["chat_id"], body["text"]} | &1.sent]})
          Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":{}}))

        status ->
          Plug.Conn.resp(conn, status, ~s({"ok":false,"error_code":#{status},"description":"no"}))
      end
    end)

    Settings.set("manager_bot_token", "999:super")
    Settings.set("operator_telegram_id", "555")

    inst = relay_instance(%{telegram_token: "123:bot", owner_telegram_id: 456})
    %{inst: inst, agent: agent}
  end

  defp sent(agent), do: agent |> Agent.get(& &1.sent) |> Enum.reverse()
  defp to_owner(agent), do: for({"123:bot", 456, text} <- sent(agent), do: text)
  defp to_operator(agent), do: for({"999:super", "555", text} <- sent(agent), do: text)
  defp fail(agent, token, status), do: Agent.update(agent, &put_in(&1, [:fail, token], status))
  defp heal(agent, token), do: Agent.update(agent, &%{&1 | fail: Map.delete(&1.fail, token)})
  defp reload(inst), do: Repo.get(Instance, inst.id)

  # One check where the bot uses `pct` percent of a 1 GB limit and few files.
  defp check(inst, pct, state \\ %{reported: %{}}) do
    HostStub.set_disk_all(
      {:ok,
       %{
         inst.name => %{
           used_kb: div(@gb * pct, 100),
           limit_kb: @gb,
           files: 10,
           file_limit: 100_000
         }
       }}
    )

    DiskCheck.run(state, DateTime.utc_now())
  end

  describe "the state table" do
    test "every row" do
      assert DiskCheck.transition(nil, 50) == {nil, nil}
      assert DiskCheck.transition(nil, 80) == {:warn, "80"}
      assert DiskCheck.transition(nil, 97.9) == {:warn, "80"}
      assert DiskCheck.transition(nil, 98) == {:full, "full"}
      assert DiskCheck.transition("80", 98) == {:full, "full"}
      assert DiskCheck.transition("80", 85) == {nil, "80"}
      assert DiskCheck.transition("80", 70) == {nil, "80"}
      assert DiskCheck.transition("80", 69.9) == {nil, nil}
      assert DiskCheck.transition("full", 99) == {nil, "full"}
      assert DiskCheck.transition("full", 90) == {nil, "full"}
      assert DiskCheck.transition("full", 89) == {nil, "80"}
      assert DiskCheck.transition("full", 10) == {nil, "80"}
    end

    test "no limit clears the state, with no message" do
      for state <- [nil, "80", "full"],
          do: assert(DiskCheck.transition(state, nil) == {nil, nil})
    end
  end

  test "readings are written to the row", %{inst: inst} do
    check(inst, 50)
    row = reload(inst)
    assert row.disk_used_kb == div(@gb, 2)
    assert row.disk_limit_kb == @gb
    assert row.disk_files == 10
    assert row.disk_file_limit == 100_000
    assert %DateTime{} = row.disk_checked_at
    assert row.disk_warned == nil
    assert Settings.get("disk_quota_seen") == "1"
    assert Settings.get("disk_quota") == "on"
  end

  test "80% warns the owner once, by size", %{inst: inst, agent: agent} do
    check(inst, 85)
    check(inst, 90)
    assert [text] = to_owner(agent)
    assert text =~ "Память бота почти заполнена: 870 МБ из 1 ГБ"
    assert reload(inst).disk_warned == "80"
    assert to_operator(agent) == []
  end

  test "80% by file count says files", %{inst: inst, agent: agent} do
    HostStub.set_disk_all(
      {:ok, %{inst.name => %{used_kb: 10, limit_kb: @gb, files: 85_000, file_limit: 100_000}}}
    )

    DiskCheck.run()
    assert [text] = to_owner(agent)
    assert text =~ "место под файлы: 85 000 из 100 000"
  end

  test "straight past 98%: one full message, no 80%, and the operator told once", %{
    inst: inst,
    agent: agent
  } do
    check(inst, 99)
    check(inst, 99)
    assert [text] = to_owner(agent)
    assert text =~ "Память бота заполнена"
    assert [alert] = to_operator(agent)
    assert alert =~ inst.name
    assert alert =~ "sudo ops/druzhok set #{inst.name} disk_mb=2048"
    row = reload(inst)
    assert row.disk_warned == "full"
    assert %DateTime{} = row.disk_operator_alerted_at
  end

  test "full → 80 → full: the full message and the operator alert again", %{
    inst: inst,
    agent: agent
  } do
    check(inst, 99)
    check(inst, 85)
    row = reload(inst)
    assert row.disk_warned == "80"
    assert row.disk_operator_alerted_at == nil
    check(inst, 99)
    assert length(to_owner(agent)) == 2
    assert length(to_operator(agent)) == 2
  end

  test "80 → below 70 → nil, and 80% warns again later", %{inst: inst, agent: agent} do
    check(inst, 85)
    check(inst, 60)
    assert reload(inst).disk_warned == nil
    check(inst, 81)
    assert length(to_owner(agent)) == 2
  end

  test "a send that may pass writes no state, and the next check sends again", %{
    inst: inst,
    agent: agent
  } do
    fail(agent, "123:bot", 500)
    check(inst, 85)
    assert reload(inst).disk_warned == nil
    heal(agent, "123:bot")
    check(inst, 85)
    assert reload(inst).disk_warned == "80"
    assert length(to_owner(agent)) == 1
  end

  test "an owner who blocked the bot is settled", %{inst: inst, agent: agent} do
    fail(agent, "123:bot", 403)
    check(inst, 99)
    assert reload(inst).disk_warned == "full"
    # The operator is told even so.
    assert [_] = to_operator(agent)
  end

  test "the owner's message goes first: no operator alert while it has not settled", %{
    inst: inst,
    agent: agent
  } do
    fail(agent, "123:bot", 502)
    check(inst, 99)
    assert to_operator(agent) == []
    assert reload(inst).disk_warned == nil
  end

  test "a bot without an owner settles without a message", %{agent: agent} do
    inst = relay_instance(%{telegram_token: "777:other", owner_telegram_id: nil})
    check(inst, 85)
    assert reload(inst).disk_warned == "80"
    assert for({"777:other", _, _} <- sent(agent), do: 1) == []
  end

  test "the operator alert is retried until it gets through", %{inst: inst, agent: agent} do
    fail(agent, "999:super", 500)
    check(inst, 99)
    assert reload(inst).disk_operator_alerted_at == nil
    heal(agent, "999:super")
    check(inst, 99)
    assert reload(inst).disk_operator_alerted_at
    assert length(to_owner(agent)) == 1
    assert length(to_operator(agent)) == 1
  end

  test "a missing superbot setting logs and leaves the alert for later", %{inst: inst} do
    Repo.delete_all(from(s in Settings, where: s.key == "manager_bot_token"))

    log = ExUnit.CaptureLog.capture_log(fn -> check(inst, 99) end)
    assert log =~ "no manager_bot_token or operator_telegram_id"
    assert reload(inst).disk_warned == "full"
    assert reload(inst).disk_operator_alerted_at == nil
  end

  # A full bot whose operator alert has not gone through, then the limit is
  # taken off (bot_disk_mb=off + disk-apply): no alert, and the episode ends.
  test "full with the alert pending, then no limit: no alert, state cleared", %{
    inst: inst,
    agent: agent
  } do
    fail(agent, "999:super", 500)
    ExUnit.CaptureLog.capture_log(fn -> check(inst, 99) end)
    row = reload(inst)
    assert row.disk_warned == "full" and row.disk_operator_alerted_at == nil
    heal(agent, "999:super")
    Settings.set("bot_disk_mb", "off")

    HostStub.set_disk_all(
      {:ok, %{inst.name => %{used_kb: @gb, limit_kb: 0, files: 10, file_limit: 0}}}
    )

    DiskCheck.run()
    assert to_operator(agent) == []
    row = reload(inst)
    assert row.disk_warned == nil
    assert row.disk_operator_alerted_at == nil
  end

  test "a limit cleared by hand also ends an alerted full episode", %{inst: inst} do
    check(inst, 99)
    assert reload(inst).disk_operator_alerted_at

    HostStub.set_disk_all(
      {:ok, %{inst.name => %{used_kb: @gb, limit_kb: 0, files: 10, file_limit: 0}}}
    )

    ExUnit.CaptureLog.capture_log(fn -> DiskCheck.run() end)
    row = reload(inst)
    assert row.disk_warned == nil
    assert row.disk_operator_alerted_at == nil
  end

  test "the alert never suggests disk_mb=0" do
    r = %{used_kb: 5, limit_kb: 0, files: 1, file_limit: 100}
    assert DiskCheck.operator_alert(%Instance{name: "kot", disk_mb: nil}, r) =~ "disk_mb=2048"
    assert DiskCheck.operator_alert(%Instance{name: "kot", disk_mb: 300}, r) =~ "disk_mb=600"
    Settings.set("bot_disk_mb", "off")
    alert = DiskCheck.operator_alert(%Instance{name: "kot"}, r)
    refute alert =~ "set kot disk_mb"
    assert alert =~ "disk-apply"
  end

  describe "self-reports" do
    test "quotas off before they were ever on: silent, readings dropped", %{
      inst: inst,
      agent: agent
    } do
      inst
      |> Ecto.Changeset.change(disk_checked_at: ~U[2026-11-21 10:00:00Z], disk_used_kb: 1)
      |> Repo.update!()

      HostStub.set_disk_all(:off)
      DiskCheck.run()
      assert to_operator(agent) == []
      assert Settings.get("disk_quota") == "off"
      assert Settings.disk_quota() == nil
      row = reload(inst)
      assert row.disk_checked_at == nil and row.disk_used_kb == nil
    end

    test "quotas that were on and are now off: reported, at most once an hour", %{
      inst: inst,
      agent: agent
    } do
      state = check(inst, 10)
      HostStub.set_disk_all(:off)
      now = DateTime.utc_now()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          state = DiskCheck.run(state, now)
          state = DiskCheck.run(state, DateTime.add(now, 600))
          DiskCheck.run(state, DateTime.add(now, 3600))
        end)

      assert log =~ "были включены и теперь выключены"
      assert length(to_operator(agent)) == 2
      assert Settings.disk_quota() == "off"
    end

    test "quotas off with bot_disk_mb=off is the operator's choice: silent", %{
      inst: inst,
      agent: agent
    } do
      check(inst, 10)
      Settings.set("bot_disk_mb", "off")
      HostStub.set_disk_all(:off)
      DiskCheck.run()
      assert to_operator(agent) == []
    end

    test "a bot with no limit while it should have one", %{inst: inst, agent: agent} do
      HostStub.set_disk_all(
        {:ok, %{inst.name => %{used_kb: 5, limit_kb: 0, files: 1, file_limit: 0}}}
      )

      ExUnit.CaptureLog.capture_log(fn -> DiskCheck.run() end)
      assert [text] = to_operator(agent)
      assert text =~ inst.name
      assert to_owner(agent) == []

      Settings.set("bot_disk_mb", "off")
      DiskCheck.run()
      assert length(to_operator(agent)) == 1
    end
  end

  test "a host without quotas (Host.Process) changes nothing", %{inst: inst, agent: agent} do
    HostStub.set_disk_all(:unknown)
    assert DiskCheck.run(%{reported: %{}}) == %{reported: %{}}
    assert reload(inst).disk_checked_at == nil
    assert sent(agent) == []
    assert Settings.get("disk_quota") == nil
  end
end
