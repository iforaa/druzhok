defmodule Druzhok.Model do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger

  schema "models" do
    field :model_id, :string
    field :label, :string
    field :provider, :string, default: "openai"
    field :position, :integer, default: 0
    field :context_window, :integer, default: 32_000
    field :supports_reasoning, :boolean, default: false
    field :supports_tools, :boolean, default: true
    field :supports_vision, :boolean, default: false

    timestamps()
  end

  def changeset(model, attrs) do
    model
    |> cast(attrs, [:model_id, :label, :provider, :position, :context_window, :supports_reasoning, :supports_tools, :supports_vision])
    |> validate_required([:model_id, :label])
    |> unique_constraint(:model_id)
  end

  def list do
    from(m in __MODULE__, order_by: m.position)
    |> Druzhok.Repo.all()
    |> Enum.map(fn m -> {m.model_id, m.label, m.provider} end)
  end

  def get_provider(model_id) do
    case Druzhok.Repo.get_by(__MODULE__, model_id: model_id) do
      nil ->
        Logger.debug("Model #{model_id} not in DB, defaulting to openai provider")
        "openai"
      m -> m.provider || "openai"
    end
  end
end
