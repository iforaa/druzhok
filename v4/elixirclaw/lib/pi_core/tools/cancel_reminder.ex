defmodule PiCore.Tools.CancelReminder do
  def tool do
    %PiCore.Tools.Tool{
      name: "cancel_reminder",
      description: "Cancel a scheduled reminder by ID.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "integer", "description" => "Reminder ID to cancel"}
        },
        "required" => ["id"]
      },
      execute: fn _args, _ctx ->
        {:ok, "Reminders not available in standalone mode."}
      end
    }
  end
end
