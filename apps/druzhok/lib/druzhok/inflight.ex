defmodule Druzhok.Inflight do
  @moduledoc """
  Proxy calls a bot has open right now (bot queue spec, "In-flight counter").
  `LlmProxyController` and `SitesController` wrap every action in
  `enter/1` … `leave/1`; the controller process runs a streamed reply to its
  last chunk, so an entry lasts as long as the call. A switch does not stop a
  bot while one is open. An entry older than `inflight_stale_s` (15 min) is
  ignored, so a process killed before its `after` cannot pin a bot.

  Written always, read only by queue mode. The table belongs to this process,
  which does nothing else.
  """

  use GenServer

  @table :druzhok_inflight

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, nil}
  end

  @doc "Record a call for the bot; returns the ref for `leave/1`."
  def enter(instance_id) do
    ref = make_ref()
    :ets.insert(@table, {ref, instance_id, System.monotonic_time(:millisecond)})
    ref
  rescue
    # No table (a BEAM without the app's supervisor): nothing to record.
    ArgumentError -> nil
  end

  def leave(nil), do: :ok

  def leave(ref) do
    :ets.delete(@table, ref)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Whether the bot has a call open that started within the stale limit."
  def busy?(instance_id) do
    cutoff =
      System.monotonic_time(:millisecond) -
        Druzhok.Lifecycle.Queue.opt(:inflight_stale_s) * 1000

    match = [{{:_, instance_id, :"$1"}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(@table, match) > 0
  rescue
    ArgumentError -> false
  end
end
