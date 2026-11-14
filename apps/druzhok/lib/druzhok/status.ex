defmodule Druzhok.Status do
  @moduledoc """
  What the operator's CleoHub console shows about this machine and its bots
  (`GET /internal/status`, release spec PR J). Read only: it takes nothing but
  the rows, Settings, `/proc`, `df`, the bot's cgroup (`memory.current`,
  `memory.max`) and, in queue mode, the scheduler's line, so it never wakes or
  starts a bot and runs no `sudo`.

  One read every `ttl_ms` (10 s), however many callers: this process is the
  queue. A reading that fails becomes `nil` for that field alone, except a bot's
  memory: that reads 0, and its `state` takes the unit as down, the same as when
  no unit runs. A failed read of the database fails the call, and is not cached.

  `queue` is nil outside queue mode, else `slots`, `holding` (the scheduler's
  count: rows active, not being deleted, not sleeping, together by name with
  the bots whose unit holds memory) and `waiting` (the line's length, nil when
  the scheduler does not answer within 500 ms).

  Nothing here may carry an owner id, a token or message text: each bot's map is
  written out field by field, and `last_error` is scrubbed.
  """

  use GenServer
  import Ecto.Query
  require Logger
  alias Druzhok.{BotManager, Host, Instance, Repo}
  alias Druzhok.Lifecycle.{Queue, Scheduler, StartGate}
  alias Druzhok.Telegram.Inbox

  @defaults [
    ttl_ms: 10_000,
    proc_root: "/proc",
    hermes_link: "/opt/hermes",
    disks: ["/", "/data"],
    df_bin: "df",
    df_timeout_ms: 2_000
  ]

  # Under the console's 5 s, so it gets an answer rather than its own timeout.
  @call_timeout_ms 4_000
  # Next to df's 2 s, so the whole read stays under @call_timeout_ms.
  @line_timeout_ms 500
  @mb 1024 * 1024
  @error_limit 300
  # A Telegram bot token, whichever bot's it is, also inside a `/bot<token>/` URL.
  @telegram_token ~r/(?<!\d)\d{5,}:[A-Za-z0-9_-]{20,}/

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`{:ok, map}`, at most `ttl_ms` old, or `{:error, :unavailable}`."
  def get do
    GenServer.call(__MODULE__, :get, @call_timeout_ms)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call(:get, _from, {at, status} = cached) do
    if System.monotonic_time(:millisecond) - at < opt(:ttl_ms),
      do: {:reply, {:ok, status}, cached},
      else: refresh(cached)
  end

  def handle_call(:get, _from, nil), do: refresh(nil)

  defp refresh(cached) do
    status = read()
    {:reply, {:ok, status}, {System.monotonic_time(:millisecond), status}}
  rescue
    e ->
      Logger.error("[status] #{Exception.message(e)}")
      {:reply, {:error, :unavailable}, cached}
  catch
    :exit, reason ->
      Logger.error("[status] exit #{inspect(reason)}")
      {:reply, {:error, :unavailable}, cached}
  end

  defp read do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    pending = Inbox.pending_by_instance()

    readings =
      from(i in Instance, order_by: i.name)
      |> Repo.all()
      |> Enum.map(&{&1, memory_bytes(&1.name)})

    %{
      generated_at: now,
      host: host(),
      hermes_version: hermes_version(),
      gate: %{start_min_free_mb: StartGate.min_free_mb()},
      queue: queue(readings),
      telegram: telegram(pending, now),
      bots: Enum.map(readings, fn {inst, memory} -> bot(inst, memory, pending) end)
    }
  end

  # --- queue mode -------------------------------------------------------------

  # The same count as `Scheduler.room?/0`, but from the cgroups read for the bots
  # below rather than a second unit listing.
  defp queue(readings) do
    case Queue.slots() do
      nil ->
        nil

      slots ->
        holding =
          for {inst, memory} <- readings,
              is_integer(memory) or
                (inst.active and not inst.delete_requested and not inst.sleeping),
              uniq: true,
              do: inst.name

        %{slots: slots, holding: length(holding), waiting: waiting()}
    end
  end

  # A busy scheduler costs this one figure.
  defp waiting do
    length(Scheduler.line(@line_timeout_ms))
  catch
    :exit, _ -> nil
  end

  # --- bots -------------------------------------------------------------------

  defp bot(inst, memory, pending) do
    {error, error_at} = last_error(inst)

    %{
      name: inst.name,
      display_name: inst.display_name || inst.name,
      ruoc_account_id: inst.ruoc_account_id,
      active: inst.active,
      state: state(inst, memory),
      memory_mb: if(memory, do: div(memory, @mb), else: 0),
      memory_max_mb: memory && memory_max_mb(inst.name),
      last_started_at: inst.started_at,
      last_error: error,
      last_error_at: error_at,
      queued_updates: pending |> Map.get(inst.id, {0, nil}) |> elem(0),
      created_at: DateTime.from_naive!(inst.inserted_at, "Etc/UTC")
    }
  end

  # nil is "no unit running": one bad row must not cost the response.
  defp memory_bytes(name), do: host_read(name, "memory", &Host.memory_bytes/1)

  defp memory_max_mb(name) do
    case host_read(name, "memory limit", &Host.memory_max_bytes/1) do
      bytes when is_integer(bytes) -> div(bytes, @mb)
      _ -> nil
    end
  end

  defp host_read(name, what, read) do
    read.(name)
  rescue
    e ->
      Logger.warning("[status] #{name}: #{what} read failed: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("[status] #{name}: #{what} read failed: #{inspect(reason)}")
      nil
  end

  # The row says what was asked for and what went wrong, the cgroup whether a
  # unit runs. So an active row with no unit and no error (it waits at the start
  # gate, or never had a unit) is "stopped".
  defp state(inst, memory) do
    cond do
      inst.delete_requested or not inst.active -> "stopped"
      is_integer(memory) -> "running"
      inst.sleeping -> "sleeping"
      is_binary(inst.start_error) -> "failed"
      true -> "stopped"
    end
  end

  # `{text, when}`, both nil or neither. The lifecycle controller writes each
  # error with its time; only a row edited by hand lacks one, and then gets its
  # last update, so the contract's "null exactly with last_error" holds.
  defp last_error(inst) do
    {text, at} =
      if inst.delete_requested and is_binary(inst.delete_error),
        do: {inst.delete_error, inst.delete_failed_at},
        else: {inst.start_error, inst.start_failed_at}

    if is_binary(text),
      do: {scrub(text, inst), utc_second(at || inst.updated_at)},
      else: {nil, nil}
  end

  defp utc_second(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> utc_second()

  defp utc_second(%DateTime{} = at), do: DateTime.truncate(at, :second)

  # These strings hold whatever a failed command or a gateway said.
  defp scrub(text, inst) do
    secrets =
      [
        inst.telegram_token,
        inst.telegram_webhook_secret,
        inst.tenant_key,
        inst.ruoc_api_key,
        inst.owner_telegram_id && to_string(inst.owner_telegram_id)
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    secrets
    |> Enum.reduce(text, &String.replace(&2, &1, "…"))
    |> String.replace(@telegram_token, "…")
    |> String.replace(~r/#{Regex.escape(BotManager.data_root_base())}\/\S*/, "…")
    |> String.slice(0, @error_limit)
  end

  defp telegram(pending, now) do
    rows = Map.values(pending)

    oldest_age =
      case Enum.map(rows, fn {_count, oldest} -> oldest end) do
        [] -> 0
        times -> times |> Enum.map(&DateTime.diff(now, &1)) |> Enum.max() |> max(0)
      end

    %{queued: rows |> Enum.map(&elem(&1, 0)) |> Enum.sum(), oldest_age_s: oldest_age}
  end

  # --- the machine ------------------------------------------------------------

  defp host do
    mem = meminfo()
    {load1, load5, load15} = loadavg()

    %{
      hostname: hostname(),
      uptime_s: uptime_s(),
      cpus: cpus(),
      load1: load1,
      load5: load5,
      load15: load15,
      mem_total_mb: kb_to_mb(mem["MemTotal"]),
      mem_available_mb: kb_to_mb(mem["MemAvailable"]),
      swap_used_mb:
        case {mem["SwapTotal"], mem["SwapFree"]} do
          {total, free} when is_integer(total) and is_integer(free) -> kb_to_mb(total - free)
          _ -> nil
        end,
      disks: disks()
    }
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> nil
    end
  end

  defp cpus do
    case :erlang.system_info(:logical_processors_online) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp uptime_s do
    with {:ok, text} <- proc("uptime"),
         {seconds, _} <- Float.parse(text) do
      trunc(seconds)
    else
      _ -> nil
    end
  end

  defp loadavg do
    with {:ok, text} <- proc("loadavg"),
         [one, five, fifteen | _] <- String.split(text),
         {l1, ""} <- Float.parse(one),
         {l5, ""} <- Float.parse(five),
         {l15, ""} <- Float.parse(fifteen) do
      {l1, l5, l15}
    else
      _ -> {nil, nil, nil}
    end
  end

  defp meminfo do
    case proc("meminfo") do
      {:ok, text} ->
        for [_, key, kb] <- Regex.scan(~r/^(\w+):\s+(\d+)\s+kB/m, text),
            into: %{},
            do: {key, String.to_integer(kb)}

      _ ->
        %{}
    end
  end

  defp proc(file), do: File.read(Path.join(opt(:proc_root), file))

  defp kb_to_mb(kb) when is_integer(kb), do: div(kb, 1024)
  defp kb_to_mb(_), do: nil

  # Erlang has no statvfs. One `df` per mount, so one that fails or hangs costs
  # that disk only. All of them share one deadline, which has to stay under
  # @call_timeout_ms however many hang.
  defp disks do
    mounts = opt(:disks)
    tasks = Enum.map(mounts, fn mount -> Task.async(fn -> df(mount) end) end)

    mounts
    |> Enum.zip(Task.yield_many(tasks, opt(:df_timeout_ms)))
    |> Enum.map(fn {mount, {task, result}} ->
      {total, free} =
        case result || Task.shutdown(task, :brutal_kill) do
          {:ok, sizes} -> sizes
          _ -> {nil, nil}
        end

      %{mount: mount, total_mb: total, free_mb: free}
    end)
  end

  @doc "Free MB on the disk that holds `path`, from one `df`; nil when it cannot be read."
  def free_mb(path) do
    {_total, free} = df(path)
    free
  end

  defp df(mount) do
    case System.cmd(opt(:df_bin), ["-Pk", mount], env: [{"LC_ALL", "C"}], stderr_to_stdout: true) do
      {out, 0} -> parse_df(out)
      _ -> {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  @doc false
  # POSIX output: a header, then device, 1024-blocks, used, available, capacity,
  # mount. Read from the right, since a device name may hold spaces. Rounded up,
  # as `df -m` does, so the numbers match it.
  def parse_df(out) do
    with [_header, line | _] <- String.split(out, "\n", trim: true),
         [total, _used, free, _capacity, _mount] <- line |> String.split() |> Enum.take(-5),
         {total, ""} <- Integer.parse(total),
         {free, ""} <- Integer.parse(free) do
      {div(total + 1023, 1024), div(free + 1023, 1024)}
    else
      _ -> {nil, nil}
    end
  end

  # `/opt/hermes` -> `/data/opt/hermes-<id>`: the install's pyproject and
  # `hermes --version` do not name a release, so its directory does.
  defp hermes_version do
    case File.read_link(opt(:hermes_link)) do
      {:ok, target} -> target |> Path.basename() |> String.replace_prefix("hermes-", "")
      _ -> nil
    end
  end

  defp opt(key) do
    Keyword.get(Application.get_env(:druzhok, :status, []), key, @defaults[key])
  end
end
