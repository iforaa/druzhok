defmodule Druzhok.CrashLog do
  use Ecto.Schema
  import Ecto.Query

  schema "crash_logs" do
    field :level, :string
    field :message, :string
    field :source, :string
    field :instance_name, :string

    timestamps(updated_at: false)
  end

  def insert(attrs) do
    result =
      %__MODULE__{}
      |> Ecto.Changeset.cast(attrs, [:level, :message, :source, :instance_name])
      |> Ecto.Changeset.validate_required([:level, :message])
      |> Druzhok.Repo.insert()

    counter = :persistent_term.get(:crash_log_counter, 0) + 1
    :persistent_term.put(:crash_log_counter, counter)
    if rem(counter, 100) == 0, do: cleanup_old()

    result
  end

  def recent(limit \\ 100) do
    from(c in __MODULE__, order_by: [desc: c.inserted_at], limit: ^limit)
    |> Druzhok.Repo.all()
  end

  def recent_for_instance(instance_name, limit \\ 100) do
    from(c in __MODULE__,
      where: c.instance_name == ^instance_name,
      order_by: [desc: c.inserted_at],
      limit: ^limit
    )
    |> Druzhok.Repo.all()
  end

  def clear_all do
    Druzhok.Repo.delete_all(__MODULE__)
  end

  def count do
    Druzhok.Repo.aggregate(__MODULE__, :count)
  end

  defp cleanup_old do
    cutoff = DateTime.utc_now() |> DateTime.add(-7, :day)
    from(c in __MODULE__, where: c.inserted_at < ^cutoff)
    |> Druzhok.Repo.delete_all()
  end
end
