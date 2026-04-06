defmodule Druzhok.Instance do
  use Ecto.Schema
  import Ecto.Changeset

  schema "instances" do
    field :name, :string
    field :telegram_token, :string
    field :model, :string
    field :workspace, :string
    field :active, :boolean, default: true
    field :heartbeat_interval, :integer, default: 0
    field :owner_telegram_id, :integer
    field :sandbox, :string, default: "local"
    field :timezone, :string, default: "UTC"
    field :api_key, :string
    field :daily_token_limit, :integer, default: 0
    field :dream_hour, :integer, default: -1
    field :language, :string, default: "ru"
    field :tenant_key, :string
    field :bot_runtime, :string, default: "zeroclaw"
    field :on_demand_model, :string
    field :mention_only, :boolean, default: false
    field :reject_message, :string
    field :welcome_message, :string
    field :pool_id, :id
    field :allowed_telegram_ids, :string
    field :trigger_name, :string
    field :image_model, :string
    field :audio_model, :string
    field :embedding_model, :string

    has_one :budget, Druzhok.Budget

    timestamps()
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id, :sandbox, :timezone, :api_key, :daily_token_limit, :dream_hour, :language, :tenant_key, :bot_runtime, :on_demand_model, :mention_only, :reject_message, :welcome_message, :pool_id, :allowed_telegram_ids, :trigger_name, :image_model, :audio_model, :embedding_model])
    |> validate_required([:name, :model, :workspace])
    |> unique_constraint(:name)
  end

  def get_by_api_key(nil), do: nil
  def get_by_api_key(key), do: Druzhok.Repo.get_by(__MODULE__, api_key: key)

  def generate_api_key do
    "dk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  def generate_tenant_key(name) do
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "dk-#{name}-#{random}"
  end

  def get_allowed_ids(instance) do
    case Map.get(instance, :allowed_telegram_ids) do
      nil -> []
      "" -> []
      json -> Jason.decode!(json) |> Enum.map(&to_string/1)
    end
  end

  def add_allowed_id(instance, user_id) do
    ids = get_allowed_ids(instance)
    user_id = to_string(user_id)
    if user_id in ids do
      {:ok, instance}
    else
      instance
      |> changeset(%{allowed_telegram_ids: Jason.encode!(ids ++ [user_id])})
      |> Druzhok.Repo.update()
    end
  end

  def remove_allowed_id(instance, user_id) do
    ids = get_allowed_ids(instance) |> Enum.reject(&(&1 == to_string(user_id)))
    instance
    |> changeset(%{allowed_telegram_ids: Jason.encode!(ids)})
    |> Druzhok.Repo.update()
  end
end
