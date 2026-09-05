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

  @doc "OpenRouter key: env wins, otherwise the value entered in dashboard Settings."
  def openrouter_api_key do
    Application.get_env(:druzhok, :openrouter_api_key) || get("openrouter_api_key")
  end

  @doc """
  Telegram user id of the platform operator, or nil. Hermes makes this id the
  slash-command admin on every bot; tenants get the user tier.
  """
  def operator_telegram_id do
    Application.get_env(:druzhok, :operator_telegram_id) || get("operator_telegram_id")
  end

  @doc "Setting keys the ruoc-gateway integration reads (see `Druzhok.Ruoc`)."
  def ruoc_keys, do: ["ruoc_url", "ruoc_admin_host", "ruoc_admin_token", "ruoc_catalog_key"]
end
