defmodule Druzhok.Usage do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Druzhok.Repo

  schema "usage_logs" do
    belongs_to :instance, Druzhok.Instance
    field :model, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :total_tokens, :integer
    field :cost_cents, :integer, default: 0
    field :requested_model, :string
    field :resolved_model, :string
    field :provider, :string
    field :latency_ms, :integer
    field :prompt_preview, :string
    field :response_preview, :string
    field :request_body, :string
    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:instance_id, :model, :prompt_tokens, :completion_tokens,
                    :total_tokens, :cost_cents, :requested_model, :resolved_model,
                    :provider, :latency_ms, :prompt_preview, :response_preview, :request_body])
    |> validate_required([:instance_id, :model, :prompt_tokens, :completion_tokens, :total_tokens])
  end

  def log(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def daily_usage(instance_id, date \\ Date.utc_today()) do
    start_of_day = NaiveDateTime.new!(date, ~T[00:00:00])
    end_of_day = NaiveDateTime.new!(Date.add(date, 1), ~T[00:00:00])

    from(u in __MODULE__,
      where: u.instance_id == ^instance_id,
      where: u.inserted_at >= ^start_of_day and u.inserted_at < ^end_of_day,
      group_by: u.model,
      select: %{
        model: u.model,
        total_input: sum(u.prompt_tokens),
        total_output: sum(u.completion_tokens),
        request_count: count(u.id),
      }
    )
    |> Repo.all()
  end

  def recent(instance_id, limit \\ 50) do
    from(u in __MODULE__,
      where: u.instance_id == ^instance_id,
      order_by: [desc: :inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
