defmodule Druzhok.Pairing do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @code_length 8
  @ttl_seconds 3600

  schema "pairing_codes" do
    field :instance_name, :string
    field :code, :string
    field :telegram_user_id, :integer
    field :username, :string
    field :display_name, :string
    field :expires_at, :utc_datetime
    timestamps()
  end

  def changeset(pairing, attrs) do
    pairing
    |> cast(attrs, [:instance_name, :code, :telegram_user_id, :username, :display_name, :expires_at])
    |> validate_required([:instance_name, :code, :telegram_user_id, :expires_at])
    |> unique_constraint(:instance_name)
  end

  def get_pending(instance_name) do
    now = DateTime.utc_now()
    from(p in __MODULE__, where: p.instance_name == ^instance_name and p.expires_at > ^now)
    |> Druzhok.Repo.one()
  end

  def create_code(instance_name, telegram_user_id, username, display_name) do
    # Delete expired codes
    from(p in __MODULE__, where: p.instance_name == ^instance_name and p.expires_at <= ^DateTime.utc_now())
    |> Druzhok.Repo.delete_all()

    code = generate_code()
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)

    %__MODULE__{}
    |> changeset(%{
      instance_name: instance_name,
      code: code,
      telegram_user_id: telegram_user_id,
      username: username,
      display_name: display_name,
      expires_at: expires_at,
    })
    |> Druzhok.Repo.insert(on_conflict: :replace_all, conflict_target: :instance_name)
  end

  def approve(instance_name) do
    case get_pending(instance_name) do
      nil -> {:error, :not_found}
      pairing ->
        case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
          nil -> {:error, :instance_not_found}
          instance ->
            Druzhok.Repo.update(Druzhok.Instance.changeset(instance, %{owner_telegram_id: pairing.telegram_user_id}))
            Druzhok.Repo.delete(pairing)
            {:ok, pairing}
        end
    end
  end

  defp generate_code do
    for _ <- 1..@code_length, into: "" do
      <<Enum.random(@alphabet)>>
    end
  end
end
