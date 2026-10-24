defmodule DruzhokWebWeb.Panel.Limiter do
  @moduledoc """
  Requests per client IP per minute for the bot panel's API: an ETS counter
  per `{ip, minute}`, swept every minute. The process only owns the table.
  """

  use GenServer

  @table :druzhok_panel_limiter

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Counts one request from `ip`; false when it is over `per_minute`."
  def allow?(ip, per_minute) do
    minute = div(System.system_time(:second), 60)
    :ets.update_counter(@table, {ip, minute}, 1, {{ip, minute}, 0}) <= per_minute
  rescue
    # No table (the process is not running): never lock the owner out.
    ArgumentError -> true
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    minute = div(System.system_time(:second), 60)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", minute}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, 60_000)
end
