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

    has_one :budget, Druzhok.Budget

    timestamps()
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id, :sandbox, :timezone, :api_key, :daily_token_limit, :dream_hour, :language, :tenant_key, :bot_runtime, :on_demand_model, :mention_only, :reject_message, :welcome_message, :pool_id])
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
end
