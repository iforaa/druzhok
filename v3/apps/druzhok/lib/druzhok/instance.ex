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

    timestamps()
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id])
    |> validate_required([:name, :telegram_token, :model, :workspace])
    |> unique_constraint(:name)
  end
end
