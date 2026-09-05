defmodule Druzhok.TokenPool do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Druzhok.Repo

  schema "tokens" do
    field :token, :string
    field :bot_username, :string
    belongs_to :instance, Druzhok.Instance
    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token, :bot_username, :instance_id])
    |> validate_required([:token])
    |> unique_constraint(:token)
  end

  def allocate(instance_id) do
    Repo.transaction(fn ->
      case Repo.one(from t in __MODULE__, where: is_nil(t.instance_id), limit: 1) do
        nil -> Repo.rollback(:no_tokens_available)
        token ->
          token
          |> changeset(%{instance_id: instance_id})
          |> Repo.update!()
      end
    end)
  end

  def release(instance_id) do
    from(t in __MODULE__, where: t.instance_id == ^instance_id)
    |> Repo.update_all(set: [instance_id: nil])
    :ok
  end

  def list_all do
    Repo.all(from t in __MODULE__, order_by: [asc: :id], preload: [:instance])
  end

  def add(token, bot_username \\ nil) do
    %__MODULE__{}
    |> changeset(%{token: token, bot_username: bot_username})
    |> Repo.insert()
  end
end
