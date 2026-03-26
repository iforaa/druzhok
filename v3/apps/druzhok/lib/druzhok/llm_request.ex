defmodule Druzhok.LlmRequest do
  use Ecto.Schema
  import Ecto.Query

  schema "llm_requests" do
    field :instance_name, :string
    field :chat_id, :integer
    field :model, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :tool_calls_count, :integer, default: 0
    field :elapsed_ms, :integer
    field :iteration, :integer, default: 0

    timestamps(updated_at: false)
  end

  require Logger

  def log(attrs) do
    Task.start(fn ->
      case %__MODULE__{}
           |> Ecto.Changeset.cast(attrs, [:instance_name, :chat_id, :model, :input_tokens, :output_tokens, :tool_calls_count, :elapsed_ms, :iteration])
           |> Druzhok.Repo.insert() do
        {:ok, _} ->
          counter = :persistent_term.get(:llm_request_counter, 0) + 1
          :persistent_term.put(:llm_request_counter, counter)
          if rem(counter, 500) == 0, do: cleanup_old()
        {:error, changeset} ->
          Logger.warning("LlmRequest.log failed: #{inspect(changeset.errors)}")
      end
    end)
  end

  def recent(limit \\ 100) do
    from(r in __MODULE__, order_by: [desc: r.inserted_at], limit: ^limit)
    |> Druzhok.Repo.all()
  end

  def recent_filtered(opts) do
    query = from(r in __MODULE__, order_by: [desc: r.inserted_at])

    query = if opts[:instance_name] && opts[:instance_name] != "",
      do: where(query, [r], r.instance_name == ^opts[:instance_name]),
      else: query

    query = if opts[:model] && opts[:model] != "",
      do: where(query, [r], r.model == ^opts[:model]),
      else: query

    query = if opts[:since],
      do: where(query, [r], r.inserted_at >= ^opts[:since]),
      else: query

    query
    |> limit(^(opts[:limit] || 200))
    |> Druzhok.Repo.all()
  end

  def summary_today do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    from(r in __MODULE__,
      where: r.inserted_at >= ^start_of_day,
      group_by: r.instance_name,
      select: %{
        instance_name: r.instance_name,
        total_input: sum(r.input_tokens),
        total_output: sum(r.output_tokens),
        request_count: count(r.id)
      }
    )
    |> Druzhok.Repo.all()
  end

  def summary_for_instance(instance_name) do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    from(r in __MODULE__,
      where: r.inserted_at >= ^start_of_day and r.instance_name == ^instance_name,
      group_by: r.model,
      select: %{
        model: r.model,
        total_input: sum(r.input_tokens),
        total_output: sum(r.output_tokens),
        request_count: count(r.id)
      },
      order_by: [desc: sum(r.input_tokens)]
    )
    |> Druzhok.Repo.all()
  end

  def summary_by_model do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    from(r in __MODULE__,
      where: r.inserted_at >= ^start_of_day,
      group_by: r.model,
      select: %{
        model: r.model,
        total_input: sum(r.input_tokens),
        total_output: sum(r.output_tokens),
        request_count: count(r.id)
      },
      order_by: [desc: sum(r.input_tokens)]
    )
    |> Druzhok.Repo.all()
  end

  def cleanup_old do
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :day)
    from(r in __MODULE__, where: r.inserted_at < ^cutoff)
    |> Druzhok.Repo.delete_all()
  end
end
