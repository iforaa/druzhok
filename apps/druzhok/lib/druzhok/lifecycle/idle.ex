defmodule Druzhok.Lifecycle.Idle do
  @moduledoc """
  Whether an awake bot has had nothing to do for the idle window
  (sleep/wake spec, "Falling asleep", checks 1–7). Every source that cannot be
  read counts as work: a bot is kept awake rather than put to sleep on a guess.
  One exception, queue mode's (`queue: true`): an unreadable jobs file is no
  job, or that bot would hold a slot for good (bot queue spec).
  """

  import Ecto.Query
  alias Druzhok.{Instance, Repo, Usage}
  alias Druzhok.Telegram.{Inbox, Webhook}

  @default_minutes 30
  @cron_lead_s 3 * 60
  # A run this close after the lead is not worth a sleep and a wake.
  @cron_soon_s 5 * 60
  # Queue mode's switch checks: never part of the sleep check.
  @switch_only [:acked, :inflight, :cron_lead]

  @doc "The idle window in seconds (`Settings` key `sleep_idle_minutes`)."
  def window_s do
    case Keyword.get(Application.get_env(:druzhok, :lifecycle, []), :idle_window_s) do
      s when is_integer(s) -> s
      _ -> window_from_settings()
    end
  end

  defp window_from_settings do
    case Integer.parse(to_string(Druzhok.Settings.get("sleep_idle_minutes") || "")) do
      {m, ""} when m > 0 -> m * 60
      _ -> @default_minutes * 60
    end
  end

  @doc """
  `:idle` or `{:busy, reason}`. `own_pause: true` accepts the `:sleeping`
  pause the sleep action has just set; any other pause is busy. `only:`
  runs just the named checks (`:wanted`, `:paused`, `:started`, `:telegram`,
  `:acked`, `:proxy`, `:inflight`, `:turns`, `:cron_lead`, `:processes`,
  `:cron`), in this order: the panel's quiet restart asks whether the bot is
  busy, not whether it may sleep. `:acked` (a row delivered within the
  window), `:inflight` (a proxy call open now) and `:cron_lead` (a job due
  within the cron lead) are queue mode's switch checks and run only when
  named. `queue: true` reads an unreadable jobs file as no job, as queue mode
  does (bot queue spec, "The line and admission").
  """
  def check(%Instance{} = inst, opts \\ []) do
    window = Keyword.get_lazy(opts, :window_s, &window_s/0)
    cutoff = DateTime.add(DateTime.utc_now(), -window)
    queue = Keyword.get(opts, :queue, false)

    checks = [
      wanted: fn -> wanted(inst) end,
      paused: fn -> not_paused(inst, Keyword.get(opts, :own_pause, false)) end,
      started: fn -> started_long_ago(inst, cutoff) end,
      telegram: fn -> no_telegram(inst, cutoff) end,
      acked: fn -> none_acked(inst, cutoff) end,
      proxy: fn -> no_proxy_calls(inst, cutoff) end,
      inflight: fn -> nothing_in_flight(inst) end,
      turns: fn -> no_turns(inst) end,
      cron_lead: fn -> no_cron_in_lead(inst) end,
      processes: fn -> one_process(inst) end,
      cron: fn -> no_cron(inst, queue) end
    ]

    checks =
      case Keyword.fetch(opts, :only) do
        {:ok, names} -> Enum.filter(checks, fn {name, _} -> name in names end)
        :error -> Enum.reject(checks, fn {name, _} -> name in @switch_only end)
      end

    Enum.reduce_while(checks, :idle, fn {_name, check}, :idle ->
      case check.() do
        :ok -> {:cont, :idle}
        {:busy, _} = busy -> {:halt, busy}
      end
    end)
  end

  defp wanted(inst) do
    cond do
      not inst.sleep_enabled -> {:busy, :sleep_disabled}
      inst.telegram_mode != "webhook" -> {:busy, :polling}
      inst.started_mode != "webhook" -> {:busy, :started_polling}
      inst.start_seq != inst.applied_seq -> {:busy, :start_requested}
      true -> :ok
    end
  end

  defp not_paused(inst, own_pause?) do
    case Webhook.paused(inst) do
      nil -> :ok
      {"sleeping", _} when own_pause? -> :ok
      {reason, _} -> {:busy, {:paused, reason}}
    end
  end

  defp started_long_ago(%{started_at: %DateTime{} = at}, cutoff) do
    if DateTime.compare(at, cutoff) == :lt, do: :ok, else: {:busy, :recently_started}
  end

  defp started_long_ago(_, _), do: {:busy, :recently_started}

  defp no_telegram(inst, cutoff) do
    recent =
      from(u in Inbox,
        where: u.instance_id == ^inst.id and (u.received_at > ^cutoff or is_nil(u.acked_at)),
        select: count()
      )
      |> Repo.one()

    if recent == 0, do: :ok, else: {:busy, :telegram}
  end

  # A row handed to the bot within the window (not one dropped instead):
  # hermes may still hold it in its text buffer, up to 4 s before a turn.
  defp none_acked(inst, cutoff) do
    recent =
      from(u in Inbox,
        where: u.instance_id == ^inst.id and u.acked_at > ^cutoff and is_nil(u.dropped_reason),
        select: count()
      )
      |> Repo.one()

    if recent == 0, do: :ok, else: {:busy, :delivered}
  end

  # A streamed model reply writes its usage row only after the last chunk.
  defp nothing_in_flight(inst) do
    if Druzhok.Inflight.busy?(inst.id), do: {:busy, :in_flight}, else: :ok
  end

  defp no_proxy_calls(inst, cutoff) do
    naive = DateTime.to_naive(cutoff)

    recent =
      from(l in Usage,
        where: l.instance_id == ^inst.id and l.inserted_at > ^naive,
        select: count()
      )
      |> Repo.one()

    if recent == 0, do: :ok, else: {:busy, :proxy}
  end

  # hermes rewrites gateway_state.json at every turn boundary (active_agents
  # counts running agents, cron runs and API runs).
  defp no_turns(inst) do
    path = Path.join(data_root(inst), "gateway_state.json")

    with {:ok, body} <- File.read(path),
         {:ok, %{"gateway_state" => "running", "active_agents" => 0}} <- Jason.decode(body) do
      :ok
    else
      {:ok, %{} = state} -> {:busy, {:turns, Map.take(state, ["gateway_state", "active_agents"])}}
      _ -> {:busy, :gateway_state_unreadable}
    end
  end

  # At rest a bot's cgroup holds hermes alone; a terminal or background
  # process the agent started is a child in the same cgroup.
  defp one_process(inst) do
    case Druzhok.Host.procs(inst.name) do
      1 -> :ok
      n -> {:busy, {:procs, n}}
    end
  end

  # Sleep/wake spec, "Cron": a job keeps the bot awake only when its next
  # run is close; rule 5 wakes the bot for it.
  defp no_cron(inst, queue) do
    case next_cron_run(inst) do
      {:ok, nil} ->
        :ok

      {:ok, at} ->
        soon = DateTime.add(DateTime.utc_now(), cron_lead_s() + @cron_soon_s)
        if DateTime.compare(at, soon) == :gt, do: :ok, else: {:busy, :cron}

      :error ->
        if queue, do: :ok, else: {:busy, :cron_unreadable}
    end
  end

  # Queue mode's grace: a job due within the lead would wake the bot again
  # at once. Unreadable is no job here, as everywhere in queue mode.
  defp no_cron_in_lead(inst) do
    case next_cron_run(inst) do
      {:ok, %DateTime{} = at} ->
        soon = DateTime.add(DateTime.utc_now(), cron_lead_s())
        if DateTime.compare(at, soon) == :gt, do: :ok, else: {:busy, :cron}

      _ ->
        :ok
    end
  end

  @doc """
  When a sleeping bot must be awake for its next cron run: `cron_lead_s` (3 min,
  hermes's 60 s ticker plus a start) before the earliest enabled job's
  `next_run_at`. `{:ok, nil}` without one; `:error` when `cron/jobs.json`
  cannot be read or an enabled job has no aware `next_run_at`.
  """
  def cron_wake_at(inst) do
    case next_cron_run(inst) do
      {:ok, %DateTime{} = at} -> {:ok, DateTime.add(at, -cron_lead_s())}
      other -> other
    end
  end

  @doc "The bot's `cron/jobs.json`."
  def cron_path(inst), do: Path.join([data_root(inst), "cron", "jobs.json"])

  defp next_cron_run(inst) do
    with {:ok, body} <- File.read(cron_path(inst)),
         {:ok, %{"jobs" => jobs}} when is_list(jobs) <- Jason.decode(body) do
      jobs
      |> Enum.filter(&enabled_job?/1)
      |> Enum.reduce_while({:ok, nil}, fn job, {:ok, earliest} ->
        case run_at(job) do
          nil -> {:halt, :error}
          at -> {:cont, {:ok, earliest(earliest, at)}}
        end
      end)
    else
      {:error, :enoent} -> {:ok, nil}
      _ -> :error
    end
  end

  # A naive time is in the bot's own zone, which hermes owns: not a guess
  # this makes.
  defp run_at(%{"next_run_at" => at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp run_at(_), do: nil

  defp earliest(nil, at), do: at
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp enabled_job?(%{"enabled" => false}), do: false
  defp enabled_job?(_), do: true

  defp cron_lead_s,
    do: Keyword.get(Application.get_env(:druzhok, :lifecycle, []), :cron_lead_s, @cron_lead_s)

  defp data_root(inst), do: Druzhok.Runtime.Hermes.data_root(inst)
end
