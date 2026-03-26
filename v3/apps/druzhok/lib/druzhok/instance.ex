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

    timestamps()
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id, :sandbox, :timezone, :api_key])
    |> validate_required([:name, :model, :workspace])
    |> unique_constraint(:name)
  end

  def get_by_api_key(nil), do: nil
  def get_by_api_key(key), do: Druzhok.Repo.get_by(__MODULE__, api_key: key)

  def generate_api_key do
    "dk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
