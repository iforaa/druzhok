defmodule Druzhok.Usage do
  use Ecto.Schema
  import Ecto.Changeset
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
    field :request_type, :string, default: "chat"
    field :audio_duration_ms, :integer
    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:instance_id, :model, :prompt_tokens, :completion_tokens,
                    :total_tokens, :cost_cents, :requested_model, :resolved_model,
                    :provider, :latency_ms, :prompt_preview, :response_preview,
                    :request_type, :audio_duration_ms])
    |> validate_required([:instance_id, :model, :prompt_tokens, :completion_tokens, :total_tokens])
  end

  def log(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end
end
