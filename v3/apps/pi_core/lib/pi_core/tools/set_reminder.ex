defmodule PiCore.Tools.SetReminder do
  alias PiCore.Tools.Tool

  def new(opts \\ %{}) do
    %Tool{
      name: "set_reminder",
      description: "Set a reminder that will fire at a specific time. The reminder message will be sent to you as a prompt when the time comes. Use this when the user asks you to remind them about something or to do something at a specific time.",
      parameters: %{
        message: %{type: :string, description: "What to remind about"},
        minutes_from_now: %{type: :number, description: "Minutes from now to fire the reminder. E.g. 30 for half an hour, 60 for one hour, 1440 for tomorrow."}
      },
      execute: fn args, context -> execute(args, context, opts) end
    }
  end

  def execute(%{"message" => message, "minutes_from_now" => minutes}, context, _opts) do
    instance_name = context[:instance_name]

    if instance_name do
      fire_at = DateTime.add(DateTime.utc_now(), trunc(minutes * 60), :second)

      case Druzhok.Reminder.create(%{
        instance_name: instance_name,
        fire_at: fire_at,
        message: message
      }) do
        {:ok, _} ->
          formatted = Calendar.strftime(fire_at, "%Y-%m-%d %H:%M UTC")
          {:ok, "Reminder set for #{formatted}: #{message}"}
        {:error, changeset} ->
          {:error, "Failed to set reminder: #{inspect(changeset.errors)}"}
      end
    else
      {:error, "No instance context available for reminders"}
    end
  end

  def execute(_, _, _), do: {:error, "Missing required parameters: message and minutes_from_now"}
end
