defmodule Druzhok.Telegram.Relay.Housekeeper do
  @moduledoc """
  Hourly, for every bot that has rows in `telegram_updates`, whatever its
  mode now: expire pending rows past 24 h and delete handled rows past 3 days.
  A bot switched back to polling has no worker, but its old rows hold users'
  messages and must still go.
  """

  use GenServer
  require Logger
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.Inbox

  @interval_ms 60 * 60 * 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "One pass, now. Returns `[{instance_id, expired, pruned}]` for bots where anything changed."
  def sweep(now \\ DateTime.utc_now()) do
    for id <- Inbox.instance_ids(),
        {expired, pruned} = Inbox.housekeep(id, now),
        expired + pruned > 0 do
      if expired > 0 do
        name = (Repo.get(Instance, id) || %{name: "##{id}"}).name
        Logger.warning("[relay] #{name}: #{expired} update(s) expired after 24 h undelivered")
      end

      {id, expired, pruned}
    end
  end

  @impl true
  def init(:ok) do
    send(self(), :sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @interval_ms)
    {:noreply, state}
  end
end
