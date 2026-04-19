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
    field :request_type, :string, default: "chat"
    field :audio_duration_ms, :integer
    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:instance_id, :model, :prompt_tokens, :completion_tokens,
                    :total_tokens, :cost_cents, :requested_model, :resolved_model,
                    :provider, :latency_ms, :prompt_preview, :response_preview, :request_body,
                    :request_type, :audio_duration_ms])
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

  @doc """
  List recent usage logs for a bot, newest first. Omits `request_body` because
  it can be tens of kilobytes per row — fetch it on demand with `get_body/1`.
  """
  def recent(instance_id, limit \\ 20, offset \\ 0) do
    from(u in __MODULE__,
      where: u.instance_id == ^instance_id,
      order_by: [desc: :inserted_at],
      limit: ^limit,
      offset: ^offset,
      select: %{
        id: u.id,
        inserted_at: u.inserted_at,
        model: u.model,
        prompt_tokens: u.prompt_tokens,
        completion_tokens: u.completion_tokens,
        cost_cents: u.cost_cents,
        latency_ms: u.latency_ms,
        prompt_preview: u.prompt_preview,
        response_preview: u.response_preview,
        request_type: u.request_type,
        audio_duration_ms: u.audio_duration_ms
      }
    )
    |> Repo.all()
  end

  def get_body(log_id) do
    from(u in __MODULE__, where: u.id == ^log_id, select: u.request_body)
    |> Repo.one()
  end
end
