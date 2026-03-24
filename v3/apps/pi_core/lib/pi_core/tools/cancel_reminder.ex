defmodule PiCore.Tools.CancelReminder do
  alias PiCore.Tools.Tool

  def new(opts \\ %{}) do
    %Tool{
      name: "cancel_reminder",
      description: "List or cancel reminders. Call with action=\"list\" to see all pending reminders with their IDs. Call with action=\"cancel\" and id=<number> to cancel a specific reminder.",
      parameters: %{
        action: %{type: :string, description: "\"list\" to see pending reminders, \"cancel\" to cancel one"},
        id: %{type: :number, description: "Reminder ID to cancel (required when action is \"cancel\")", required: false}
      },
      execute: fn args, context -> execute(args, context, opts) end
    }
  end

  def execute(%{"action" => "list"}, context, _opts) do
    instance_name = context[:instance_name]
    if !instance_name, do: throw({:error, "No instance context"})

    reminders = Druzhok.Reminder.upcoming(instance_name)

    if reminders == [] do
      {:ok, "No pending reminders."}
    else
      lines = Enum.map(reminders, fn r ->
        time = Calendar.strftime(r.fire_at, "%Y-%m-%d %H:%M UTC")
        "ID #{r.id}: #{time} — #{r.message}"
      end)
      {:ok, Enum.join(lines, "\n")}
    end
  catch
    {:error, msg} -> {:error, msg}
  end

  def execute(%{"action" => "cancel", "id" => id}, _context, _opts) do
    case Druzhok.Reminder.cancel(trunc(id)) do
      {:ok, _} -> {:ok, "Reminder #{trunc(id)} cancelled."}
      {:error, :not_found} -> {:error, "Reminder #{trunc(id)} not found."}
      {:error, reason} -> {:error, "Failed to cancel: #{inspect(reason)}"}
    end
  end

  def execute(_, _, _), do: {:error, "Use action=\"list\" or action=\"cancel\" with id=<number>"}
end
