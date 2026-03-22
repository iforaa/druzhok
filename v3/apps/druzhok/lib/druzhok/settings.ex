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

  def get(key) do
    case Druzhok.Repo.get_by(__MODULE__, key: key) do
      nil -> nil
      s -> s.value
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
    get("#{provider}_api_key") || Application.get_env(:pi_core, :"#{provider}_api_key")
  end

  def api_url(provider) do
    case provider do
      "anthropic" -> get("anthropic_api_url") || Application.get_env(:pi_core, :anthropic_api_url) || "https://api.anthropic.com"
      _ -> get("nebius_api_url") || Application.get_env(:pi_core, :api_url)
    end
  end
end
