defmodule Druzhok.Lifecycle.Idle do
  @moduledoc """
  Whether an awake bot has had nothing to do for the idle window
  (sleep/wake spec, "Falling asleep", checks 1–7). Every source that cannot be
  read counts as work: a bot is kept awake rather than put to sleep on a guess.
  """

  import Ecto.Query
  alias Druzhok.{Instance, Repo, Usage}
  alias Druzhok.Telegram.{Inbox, Webhook}

  @default_minutes 30

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
  pause the sleep action has just set; any other pause is busy.
  """
  def check(%Instance{} = inst, opts \\ []) do
    window = Keyword.get_lazy(opts, :window_s, &window_s/0)
    cutoff = DateTime.add(DateTime.utc_now(), -window)

    checks = [
      fn -> wanted(inst) end,
      fn -> not_paused(inst, Keyword.get(opts, :own_pause, false)) end,
      fn -> started_long_ago(inst, cutoff) end,
      fn -> no_telegram(inst, cutoff) end,
      fn -> no_proxy_calls(inst, cutoff) end,
      fn -> no_turns(inst) end,
      fn -> one_process(inst) end,
      fn -> no_cron(inst) end
    ]

    Enum.reduce_while(checks, :idle, fn check, :idle ->
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

  defp no_cron(inst) do
    path = Path.join([data_root(inst), "cron", "jobs.json"])

    case File.read(path) do
      {:error, :enoent} ->
        :ok

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"jobs" => jobs}} when is_list(jobs) ->
            if Enum.any?(jobs, &enabled_job?/1), do: {:busy, :cron}, else: :ok

          _ ->
            {:busy, :cron_unreadable}
        end

      _ ->
        {:busy, :cron_unreadable}
    end
  end

  defp enabled_job?(%{"enabled" => false}), do: false
  defp enabled_job?(_), do: true

  defp data_root(inst), do: Druzhok.Runtime.for_instance(inst).data_root(inst)
end
