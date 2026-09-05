defmodule Druzhok.Settings do
  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :key, :string
    field :value, :string

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end

  @doc "Setting value, or nil when unset or blank."
  def get(key) do
    case Druzhok.Repo.get_by(__MODULE__, key: key) do
      %{value: v} when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  def set(key, value) do
    %__MODULE__{}
    |> changeset(%{key: key, value: value})
    |> Druzhok.Repo.insert(
      on_conflict: [set: [value: value, updated_at: DateTime.utc_now()]],
      conflict_target: :key
    )
  end

  def api_key(provider) do
    get("#{provider}_api_key") || Application.get_env(:druzhok, :"#{provider}_api_key")
  end

  def api_url(provider) do
    case provider do
      "anthropic" -> get("anthropic_api_url") || Application.get_env(:druzhok, :anthropic_api_url) || "https://api.anthropic.com"
      "openrouter" -> get("openrouter_api_url") || Application.get_env(:druzhok, :openrouter_api_url) || "https://openrouter.ai/api/v1"
      _ -> get("nebius_api_url") || Application.get_env(:druzhok, :nebius_api_url)
    end
  end
end
