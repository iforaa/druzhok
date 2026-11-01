defmodule DruzhokWebWeb.StatusControllerTest do
  use DruzhokWebWeb.ConnCase, async: false

  alias Druzhok.{HostStub, Instance, Repo}
  alias Druzhok.Telegram.Inbox

  @secret "fetch-secret-for-tests"

  @token "123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @owner 7_700_123_456

  @meminfo """
  MemTotal:        3993600 kB
  MemFree:          512000 kB
  MemAvailable:    1843200 kB
  SwapTotal:        102400 kB
  SwapFree:          61440 kB
  """

  setup do
    prev = Application.get_env(:druzhok, :status)
    on_exit(fn -> restore(:status, prev) end)

    root = Path.join(System.tmp_dir!(), "status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "meminfo"), @meminfo)
    File.write!(Path.join(root, "loadavg"), "0.50 0.40 0.30 1/123 456\n")
    File.write!(Path.join(root, "uptime"), "1234.56 789.01\n")
    File.mkdir_p!(Path.join(root, "hermes-cve1"))
    File.ln_s!(Path.join(root, "hermes-cve1"), Path.join(root, "hermes"))

    Application.put_env(:druzhok, :status,
      ttl_ms: 0,
      proc_root: root,
      hermes_link: Path.join(root, "hermes"),
      disks: ["/", Path.join(root, "no-such-disk")]
    )

    HostStub.use()
    Druzhok.Settings.set("fetch_secret", @secret)
    {:ok, root: root}
  end

  defp restore(key, nil), do: Application.delete_env(:druzhok, key)
  defp restore(key, value), do: Application.put_env(:druzhok, key, value)

  defp get_status(conn, secret \\ @secret) do
    conn |> put_req_header("authorization", "Bearer " <> secret) |> get("/internal/status")
  end

  defp status(conn), do: conn |> get_status() |> json_response(200)

  defp bot!(name, attrs \\ %{}) do
    {sets, cast} = Map.split(attrs, [:sleeping, :start_error, :delete_requested, :delete_error, :started_at])

    inst =
      %Instance{}
      |> Instance.changeset(
        Map.merge(%{name: name, model: "m", workspace: "/tmp/#{name}"}, cast)
      )
      |> Repo.insert!()

    inst |> Ecto.Changeset.change(sets) |> Repo.update!()
  end

  defp bot_named(body, name), do: Enum.find(body["bots"], &(&1["name"] == name))

  test "refuses a missing, wrong or unset secret", %{conn: conn} do
    assert get_status(conn, "nope").status == 401
    assert get(conn, "/internal/status").status == 401

    Repo.delete_all(Druzhok.Settings)
    assert get_status(conn).status == 401
  end

  test "reports the machine from /proc, the symlink and df", %{conn: conn} do
    Druzhok.Settings.set("start_min_free_mb", "1400")
    body = status(conn)

    assert {:ok, _, 0} = DateTime.from_iso8601(body["generated_at"])
    assert body["hermes_version"] == "cve1"
    assert body["gate"] == %{"start_min_free_mb" => 1400}
    assert body["telegram"] == %{"queued" => 0, "oldest_age_s" => 0}
    assert body["bots"] == []

    host = body["host"]
    assert is_binary(host["hostname"])
    assert host["uptime_s"] == 1234
    assert is_integer(host["cpus"]) and host["cpus"] > 0
    assert {host["load1"], host["load5"], host["load15"]} == {0.5, 0.4, 0.3}
    assert host["mem_total_mb"] == 3900
    assert host["mem_available_mb"] == 1800
    assert host["swap_used_mb"] == 40
  end

  test "one disk failing leaves the others", %{conn: conn, root: root} do
    assert [ok, bad] = status(conn)["host"]["disks"]

    assert ok["mount"] == "/"
    assert ok["total_mb"] > 0
    assert is_integer(ok["free_mb"])

    assert bad == %{"mount" => Path.join(root, "no-such-disk"), "total_mb" => nil, "free_mb" => nil}
  end

  # The 2.5 s deadline is shared: waited on one after the other, the two hung
  # disks would take 5 s, past the call's 4 s, and answer 503.
  test "every disk hanging costs the disks, not the response", %{conn: conn, root: root} do
    df = Path.join(root, "hung-df")
    File.write!(df, "#!/bin/sh\nexec sleep 5\n")
    File.chmod!(df, 0o755)

    Application.put_env(:druzhok, :status,
      ttl_ms: 0,
      proc_root: root,
      hermes_link: Path.join(root, "hermes"),
      disks: ["/", "/data"],
      df_bin: df,
      df_timeout_ms: 2_500
    )

    assert status(conn)["host"]["disks"] == [
             %{"mount" => "/", "total_mb" => nil, "free_mb" => nil},
             %{"mount" => "/data", "total_mb" => nil, "free_mb" => nil}
           ]
  end

  test "readings that fail are null, not an error", %{conn: conn} do
    Application.put_env(:druzhok, :status,
      ttl_ms: 0,
      proc_root: "/no/such/proc",
      hermes_link: "/no/such/link",
      disks: []
    )

    body = status(conn)
    assert body["hermes_version"] == nil

    host = body["host"]

    for key <- ~w(uptime_s load1 load5 load15 mem_total_mb mem_available_mb swap_used_mb),
        do: assert(Map.has_key?(host, key) and host[key] == nil, key)

    assert host["disks"] == []
  end

  test "an install path that is no symlink has no version", %{conn: conn, root: root} do
    Application.put_env(:druzhok, :status,
      ttl_ms: 0,
      proc_root: root,
      hermes_link: Path.join(root, "hermes-cve1"),
      disks: []
    )

    assert status(conn)["hermes_version"] == nil
  end

  test "states come from the row and the running unit", %{conn: conn} do
    bot!("running")
    HostStub.set_unit("running", :active)
    bot!("asleep", %{sleeping: true})
    bot!("broken", %{start_error: "unit failed after start"})
    bot!("off", %{active: false, start_error: "old"})
    bot!("waiting")
    bot!("leaving", %{delete_requested: true, delete_error: "ruoc suspend: 502"})

    body = status(conn)

    assert Enum.map(body["bots"], & &1["name"]) ==
             ~w(asleep broken leaving off running waiting)

    states = Map.new(body["bots"], &{&1["name"], &1["state"]})

    assert states == %{
             "running" => "running",
             "asleep" => "sleeping",
             "broken" => "failed",
             "off" => "stopped",
             "waiting" => "stopped",
             "leaving" => "stopped"
           }

    assert bot_named(body, "running")["memory_mb"] == 230
    assert bot_named(body, "asleep")["memory_mb"] == 0
    assert bot_named(body, "leaving")["last_error"] == "ruoc suspend: 502"
    assert bot_named(body, "broken")["last_error"] == "unit failed after start"
    assert bot_named(body, "running")["last_error"] == nil
    assert bot_named(body, "off")["active"] == false
  end

  test "a unit that wakes up by hand counts as running over a stale sleeping row", %{conn: conn} do
    bot!("woken", %{sleeping: true})
    HostStub.set_unit("woken", :active)

    assert bot_named(status(conn), "woken")["state"] == "running"
  end

  defmodule RaisingHost do
    def memory_bytes(_), do: raise("cgroup gone")
  end

  test "a host that raises on a read costs that bot's memory, not the response", %{conn: conn} do
    bot!("kot_4dae")
    prev = Application.get_env(:druzhok, :host)
    Application.put_env(:druzhok, :host, RaisingHost)
    on_exit(fn -> restore(:host, prev) end)

    assert %{"state" => "stopped", "memory_mb" => 0} = bot_named(status(conn), "kot_4dae")
  end

  test "lists the contract's fields, with the display name falling back to the name", %{conn: conn} do
    at = ~U[2026-11-01 10:00:00Z]
    bot!("plain", %{started_at: at})
    bot!("named", %{display_name: "Кот", ruoc_account_id: "acc_1"})

    body = status(conn)

    assert bot_named(body, "plain") == %{
             "name" => "plain",
             "display_name" => "plain",
             "ruoc_account_id" => nil,
             "active" => true,
             "state" => "stopped",
             "memory_mb" => 0,
             "last_started_at" => "2026-11-01T10:00:00Z",
             "last_error" => nil,
             "queued_updates" => 0
           }

    assert %{"display_name" => "Кот", "ruoc_account_id" => "acc_1"} = bot_named(body, "named")
  end

  test "carries no owner id, token or message text", %{conn: conn} do
    other_token = "987654:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

    inst =
      bot!("secret", %{
        telegram_token: @token,
        tenant_key: "tenant-key-value",
        ruoc_api_key: "ruoc-key-value",
        telegram_webhook_secret: "hook-secret-value",
        owner_telegram_id: @owner,
        telegram_mode: "webhook",
        start_error:
          "failed #{@token} #{other_token} tenant-key-value ruoc-key-value hook-secret-value " <>
            "for secret:#{@owner} https://api.telegram.org/bot#{other_token}/setWebhook"
      })

    :ok = Inbox.enqueue(inst.id, 1, ~s({"message":{"text":"private words"}}))

    conn = get_status(conn)
    raw = conn.resp_body

    assert conn.status == 200

    for value <- [
          @token,
          other_token,
          "tenant-key-value",
          "ruoc-key-value",
          "hook-secret-value",
          to_string(@owner),
          "private words"
        ],
        do: refute(raw =~ value, "leaked #{value}")

    assert bot_named(Jason.decode!(raw), "secret")["last_error"] =~ "failed"
  end

  test "strips tenant paths from an error and cuts it short", %{conn: conn} do
    path = Path.join(Druzhok.BotManager.data_root_base(), "paths/config.yaml")

    bot!("paths", %{start_error: "cannot write #{path} now"})
    bot!("long", %{start_error: String.duplicate("x", 2_000)})

    body = status(conn)
    assert bot_named(body, "paths")["last_error"] == "cannot write … now"
    assert String.length(bot_named(body, "long")["last_error"]) == 300
  end

  test "counts pending updates per bot and in all", %{conn: conn} do
    a = bot!("a", %{telegram_mode: "webhook"})
    b = bot!("b", %{telegram_mode: "webhook"})
    bot!("c")

    :ok = Inbox.enqueue(a.id, 1, "{}")
    :ok = Inbox.enqueue(a.id, 2, "{}")
    :ok = Inbox.enqueue(b.id, 1, "{}")
    :ok = Inbox.enqueue(b.id, 2, "{}")

    Inbox.ack(Inbox.next_pending(b.id))

    oldest = DateTime.add(DateTime.utc_now(), -90)

    import Ecto.Query

    from(u in Inbox, where: u.instance_id == ^a.id and u.update_id == 1)
    |> Repo.update_all(set: [received_at: oldest])

    body = status(conn)

    assert bot_named(body, "a")["queued_updates"] == 2
    assert bot_named(body, "b")["queued_updates"] == 1
    assert bot_named(body, "c")["queued_updates"] == 0
    assert body["telegram"]["queued"] == 3
    assert body["telegram"]["oldest_age_s"] in 89..95
  end

  test "caches for the configured time", %{conn: conn, root: root} do
    Application.put_env(:druzhok, :status,
      ttl_ms: 60_000,
      proc_root: root,
      hermes_link: "/no/such/link",
      disks: []
    )

    # An entry a test before this one left behind.
    :sys.replace_state(Druzhok.Status, fn _ -> nil end)

    first = status(conn)
    bot!("later")
    assert status(conn) == first

    Application.put_env(:druzhok, :status,
      ttl_ms: 0,
      proc_root: root,
      hermes_link: "/no/such/link",
      disks: []
    )

    assert [%{"name" => "later"}] = status(conn)["bots"]
  end

  test "a failed read answers 503, is not cached and keeps the server up", %{conn: conn, root: root} do
    pid = Process.whereis(Druzhok.Status)

    Application.put_env(:druzhok, :status,
      ttl_ms: 0,
      proc_root: root,
      hermes_link: "/no/such/link",
      disks: :not_a_list
    )

    assert %{"error" => "status_unavailable"} = conn |> get_status() |> json_response(503)
    assert Process.whereis(Druzhok.Status) == pid

    Application.put_env(:druzhok, :status,
      ttl_ms: 0,
      proc_root: root,
      hermes_link: "/no/such/link",
      disks: []
    )

    assert %{"bots" => []} = status(conn)
  end
end
