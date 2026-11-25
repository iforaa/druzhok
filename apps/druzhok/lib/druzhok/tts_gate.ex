defmodule Druzhok.TtsGate do
  @moduledoc """
  What a bot may ask of `POST /v1/audio/speech`. Text-to-speech is paid from
  the operator's own OpenAI key, not the bot's ruoc account, so ruoc's plan
  and limits never see it. This gate stands in for them:

    * the bot's ruoc account must be able to pay for anything at all: an
      active subscription or money on the balance, and no plan window spent
      right now (`allowed?/1`); ruoc not answering is a refusal;
    * at most `@per_hour` calls per bot per UTC hour, counted in ETS (a
      druzhok restart forgets the hour's count).

  The model and the text length are fixed in the controller.
  """

  use GenServer

  @table __MODULE__
  @per_hour 60

  def per_hour, do: @per_hour

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`:ok`, or `{:error, :plan}` when the bot's account may not spend now."
  def check_plan(%{ruoc_api_key: key}) when is_binary(key) and key != "" do
    case Druzhok.Ruoc.balance(key, receive_timeout: 10_000) do
      {:ok, balance} -> if allowed?(balance), do: :ok, else: {:error, :plan}
      {:error, _} -> {:error, :plan}
    end
  end

  def check_plan(_inst), do: {:error, :plan}

  @doc "Whether a `Druzhok.Ruoc.balance/2` result lets the bot spend."
  def allowed?(balance) do
    paying? =
      match?(%{status: "active"}, balance[:subscription]) or
        (is_integer(balance[:balance_nanorub]) and balance.balance_nanorub > 0)

    not_spent? =
      case balance[:limits] do
        %{spent: spent} when is_binary(spent) -> false
        _ -> true
      end

    paying? and not_spent?
  end

  @doc "Count one call for bot `id` this hour: `:ok`, or `:limit` when the hour's are used up."
  def take(id, now \\ System.system_time(:second)) do
    hour = div(now, 3600)
    key = {id, hour}

    if :ets.update_counter(@table, key, {2, 1}, {key, 0}) > @per_hour do
      :ets.update_counter(@table, key, {2, -1})
      :limit
    else
      :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", hour}], [true]}])
      :ok
    end
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
