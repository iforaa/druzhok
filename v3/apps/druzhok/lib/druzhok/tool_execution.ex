defmodule Druzhok.ToolExecution do
  use Ecto.Schema
  import Ecto.Query
  require Logger

  schema "tool_executions" do
    field :instance_name, :string
    field :tool_name, :string
    field :elapsed_ms, :integer
    field :is_error, :boolean, default: false
    field :output_size, :integer, default: 0

    timestamps(updated_at: false)
  end

  def log(attrs) do
    Task.start(fn ->
      case %__MODULE__{}
           |> Ecto.Changeset.cast(attrs, [:instance_name, :tool_name, :elapsed_ms, :is_error, :output_size])
           |> Druzhok.Repo.insert() do
        {:ok, _} -> :ok
        {:error, changeset} ->
          Logger.warning("ToolExecution.log failed: #{inspect(changeset.errors)}")
      end
    end)
  end

  def summary_for_instance(instance_name) do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    from(t in __MODULE__,
      where: t.inserted_at >= ^start_of_day and t.instance_name == ^instance_name,
      group_by: t.tool_name,
      select: %{
        tool_name: t.tool_name,
        call_count: count(t.id),
        avg_elapsed: avg(t.elapsed_ms),
        error_count: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", t.is_error)),
        total_output: sum(t.output_size)
      },
      order_by: [desc: count(t.id)]
    )
    |> Druzhok.Repo.all()
  end

  def recent_for_instance(instance_name, limit \\ 100) do
    from(t in __MODULE__,
      where: t.instance_name == ^instance_name,
      order_by: [desc: t.inserted_at],
      limit: ^limit
    )
    |> Druzhok.Repo.all()
  end
end
