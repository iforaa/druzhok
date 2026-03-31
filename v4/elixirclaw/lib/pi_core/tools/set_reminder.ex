defmodule PiCore.Tools.SetReminder do
  def tool do
    %PiCore.Tools.Tool{
      name: "set_reminder",
      description: "Schedule a reminder. Returns a reminder ID.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string", "description" => "Reminder text"},
          "delay_minutes" => %{"type" => "integer", "description" => "Minutes from now"}
        },
        "required" => ["message", "delay_minutes"]
      },
      execute: fn args, _ctx ->
        {:ok, "Reminders not available in standalone mode. Message: #{args["message"]}"}
      end
    }
  end
end
