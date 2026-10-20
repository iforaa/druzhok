defmodule Druzhok.Telegram.Relay do
  @moduledoc """
  Hands each webhook-mode bot its queued Telegram updates
  (docs/superpowers/specs/2026-10-20-telegram-webhook-relay-design.md).

  One `Druzhok.Telegram.Relay.Worker` per bot, started at boot for every
  webhook-mode bot and on `notify/1`. The relay runs only in the BEAM that
  serves the webhook endpoint (`DruzhokWeb.Application` starts it), never in a
  one-off `ops/druzhok-run.sh` run, so there is never a second relay
  delivering the same rows. `notify/1` is a no-op where the relay is not
  running; pauses go through the DB (`Druzhok.Telegram.Webhook.pause/3`).
  """

  use Supervisor
  import Ecto.Query
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.Relay.Worker

  @sup Druzhok.Telegram.RelaySup

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: @sup, strategy: :one_for_one},
      Druzhok.Telegram.Relay.Housekeeper,
      Supervisor.child_spec({Task, &start_all/0}, id: :boot, restart: :transient)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Make sure the bot's worker runs and look at its queue now."
  def notify(instance_id) do
    if running?() do
      case ensure_worker(instance_id) do
        {:ok, pid} -> send(pid, :notify)
        _ -> :ok
      end
    end

    :ok
  end

  defp running?, do: Process.whereis(@sup) != nil

  defp ensure_worker(instance_id) do
    case Registry.lookup(Druzhok.Registry, Worker.key(instance_id)) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@sup, {Worker, instance_id}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  defp start_all do
    from(i in Instance, where: i.telegram_mode == "webhook", select: i.id)
    |> Repo.all()
    |> Enum.each(&ensure_worker/1)
  end
end
