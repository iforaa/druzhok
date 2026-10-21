defmodule Druzhok.Lifecycle do
  @moduledoc """
  The only place that starts, stops, puts to sleep, wakes or deletes a bot
  (docs/superpowers/specs/2026-10-20-sleep-wake-design.md). Everyone else
  writes a request into the instance row (`BotManager.start/stop/delete`);
  one `Druzhok.Lifecycle.Bot` per row converges the unit to it.

  Runs only in the BEAM that serves the endpoint (`DruzhokWeb.Application`),
  like the Telegram relay, so two controllers never act on one bot. A scanner
  every 2 s starts a controller for any row without one, which is also how
  requests from a one-off `ops/druzhok-run.sh` BEAM are seen; `poke/1` is a
  shortcut inside druzhok.service and a no-op elsewhere.

  Options: `scan: false` (tests) starts controllers only on `poke/1`.
  """

  use Supervisor
  import Ecto.Query
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Lifecycle.Bot

  @sup Druzhok.Lifecycle.BotSup

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    scanner =
      if Keyword.get(opts, :scan, true),
        do: [Supervisor.child_spec({Task, &scan_forever/0}, id: :scanner, restart: :permanent)],
        else: []

    # A controller rescues its actions, so a crash is a bug; a burst of them
    # (many bots) must not take the endpoint's supervisor down with it.
    bots =
      {DynamicSupervisor, name: @sup, strategy: :one_for_one, max_restarts: 50, max_seconds: 60}

    Supervisor.init([bots] ++ scanner,
      strategy: :rest_for_one
    )
  end

  @doc "Look at the bot's row now. No-op where the controller does not run."
  def poke(instance_id) do
    if running?() do
      case ensure(instance_id) do
        {:ok, pid} -> send(pid, :poke)
        _ -> :ok
      end
    end

    :ok
  end

  def running?, do: Process.whereis(@sup) != nil

  @doc false
  def ensure(instance_id) do
    case Registry.lookup(Druzhok.Registry, Bot.key(instance_id)) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@sup, {Bot, instance_id}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc """
  What `ops/druzhok list|show` shows for a bot, from its row and the unit state
  (`BotManager.status/1`): the unit state, except while the controller is
  between a request and the unit (sleep/wake spec, "States shown").
  """
  def shown_status(%Instance{} = inst, unit) do
    cond do
      inst.delete_requested -> "deleting"
      inst.active and inst.sleeping and unit in ["inactive", "unknown"] -> "sleeping"
      not inst.active and unit in ["active", "activating"] -> "stopping"
      unit == "activating" and recent?(inst.woke_at) -> "waking"
      true -> unit
    end
  end

  defp recent?(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at) < 120
  defp recent?(_), do: false

  defp scan_forever do
    from(i in Instance, select: i.id) |> Repo.all() |> Enum.each(&ensure/1)
    Process.sleep(Application.get_env(:druzhok, :lifecycle_scan_ms, 2_000))
    scan_forever()
  end
end
