defmodule Druzhok.Cleohub.AvatarLimit do
  @moduledoc """
  At most `@per_day` avatar redraws started per bot per UTC day (each one costs
  a picture). Counted in ETS, so a druzhok restart forgets the day's count
  (accepted in the CleoHub skill spec).
  """

  use GenServer

  @table __MODULE__
  @per_day 3

  def per_day, do: @per_day

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Count one attempt for bot `id` today: `:ok`, or `:limit` when the day's are used up."
  def take(id, today \\ Date.utc_today()) do
    day = Date.to_gregorian_days(today)
    key = {id, day}

    if :ets.update_counter(@table, key, {2, 1}, {key, 0}) > @per_day do
      # Taken back, so a refused call does not count.
      :ets.update_counter(@table, key, {2, -1})
      :limit
    else
      forget_before(day)
      :ok
    end
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  # Earlier days' counts are no use to anyone. Only earlier: a call that read the
  # date just before midnight must not wipe the new day's counts.
  defp forget_before(day) do
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", day}], [true]}])
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
