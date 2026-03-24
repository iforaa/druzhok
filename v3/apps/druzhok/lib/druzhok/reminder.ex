defmodule Druzhok.Reminder do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "reminders" do
    field :instance_name, :string
    field :fire_at, :utc_datetime
    field :message, :string
    field :fired, :boolean, default: false
    field :chat_id, :integer

    timestamps()
  end

  def changeset(reminder, attrs) do
    reminder
    |> cast(attrs, [:instance_name, :fire_at, :message, :fired, :chat_id])
    |> validate_required([:instance_name, :fire_at, :message])
  end

  def pending(instance_name) do
    now = DateTime.utc_now()
    from(r in __MODULE__,
      where: r.instance_name == ^instance_name and r.fired == false and r.fire_at <= ^now,
      order_by: r.fire_at
    )
    |> Druzhok.Repo.all()
  end

  def upcoming(instance_name) do
    from(r in __MODULE__,
      where: r.instance_name == ^instance_name and r.fired == false,
      order_by: r.fire_at
    )
    |> Druzhok.Repo.all()
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Druzhok.Repo.insert()
  end

  def mark_fired(id) do
    case Druzhok.Repo.get(__MODULE__, id) do
      nil -> :ok
      r -> Druzhok.Repo.update(changeset(r, %{fired: true}))
    end
  end

  def cancel(id) do
    case Druzhok.Repo.get(__MODULE__, id) do
      nil -> {:error, :not_found}
      r -> Druzhok.Repo.delete(r)
    end
  end
end
