defmodule DruzhokWebWeb.Live.Components.ErrorsTab do
  use Phoenix.Component

  attr :errors, :list, default: []
  attr :instance_name, :string, default: nil
  attr :expanded, :string, default: nil

  def errors_tab(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-sm font-semibold">
          Errors
          <span :if={@errors != []} class="ml-1.5 px-1.5 py-0.5 rounded-full text-xs bg-red-100 text-red-600"><%= length(@errors) %></span>
        </h3>
        <button :if={@errors != []} phx-click="clear_errors" class="text-xs text-red-500 hover:text-red-700 font-medium transition">
          Clear all
        </button>
      </div>

      <div :if={@errors == []} class="text-sm text-gray-400 py-8 text-center">
        No errors recorded
      </div>

      <div :if={@errors != []} class="space-y-1">
        <div :for={error <- @errors}
             class="bg-white rounded-lg border border-gray-200 hover:border-red-200 transition">
          <div class="flex items-center gap-3 px-4 py-2.5 cursor-pointer"
               phx-click="toggle_error" phx-value-id={error.id}>
            <span class="text-xs text-red-400 font-mono flex-shrink-0"><%= format_time(error.inserted_at) %></span>
            <span :if={!@instance_name && error.instance_name} class="text-xs text-gray-400 font-medium flex-shrink-0"><%= error.instance_name %></span>
            <span :if={error.source} class="text-xs text-gray-400 font-mono flex-shrink-0 max-w-[200px] truncate"><%= error.source %></span>
            <span class="text-sm text-gray-700 truncate flex-1"><%= String.slice(error.message, 0, 120) %></span>
          </div>
          <div :if={to_string(@expanded) == to_string(error.id)} class="px-4 pb-3 border-t border-gray-100">
            <pre class="text-xs text-gray-600 font-mono whitespace-pre-wrap mt-2 max-h-64 overflow-auto select-all"><%= error.message %></pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_time(nil), do: ""
  defp format_time(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_time(_), do: ""
end
