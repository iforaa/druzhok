defmodule DruzhokWebWeb.Live.Components.SecurityTab do
  use Phoenix.Component

  attr :pairing, :any, default: nil
  attr :owner, :any, default: nil
  attr :groups, :list, default: []
  attr :instance_name, :string, required: true

  def security_tab(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <%!-- Owner section --%>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <h3 class="text-sm font-semibold mb-3">Owner</h3>
        <div :if={@owner}>
          <span class="text-sm text-gray-600">Telegram ID: <%= @owner %></span>
        </div>
        <div :if={!@owner && @pairing}>
          <div class="flex items-center justify-between">
            <div>
              <div class="text-sm">Pending pairing from <b><%= @pairing.display_name %></b></div>
              <div class="text-xs text-gray-500 font-mono mt-1">Code: <%= @pairing.code %></div>
            </div>
            <button phx-click="approve_pairing" phx-value-name={@instance_name}
                    class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1.5 text-sm font-medium transition">
              Approve
            </button>
          </div>
        </div>
        <div :if={!@owner && !@pairing} class="text-sm text-gray-400">
          No owner yet. Send a message to the bot to start pairing.
        </div>
      </div>

      <%!-- Groups section --%>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <h3 class="text-sm font-semibold mb-3">Groups</h3>
        <div :if={@groups == []} class="text-sm text-gray-400">
          No groups yet. Add the bot to a Telegram group.
        </div>
        <div :for={group <- @groups} class="flex items-center justify-between py-2 border-b border-gray-100 last:border-0">
          <div>
            <div class="text-sm font-medium"><%= group.title || "Chat #{group.chat_id}" %></div>
            <div class="text-xs text-gray-400"><%= group.chat_type %> &middot; <%= group.status %></div>
          </div>
          <div :if={group.status == "pending"} class="flex gap-2">
            <button phx-click="approve_group" phx-value-name={@instance_name} phx-value-chat_id={group.chat_id}
                    class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1 text-xs font-medium transition">
              Approve
            </button>
            <button phx-click="reject_group" phx-value-name={@instance_name} phx-value-chat_id={group.chat_id}
                    class="border border-gray-300 hover:bg-gray-100 rounded-lg px-3 py-1 text-xs font-medium transition">
              Reject
            </button>
          </div>
          <span :if={group.status == "approved"} class="text-xs text-green-600 font-medium">Approved</span>
          <span :if={group.status == "rejected"} class="text-xs text-red-500 font-medium">Rejected</span>
          <span :if={group.status == "removed"} class="text-xs text-gray-400 font-medium">Removed</span>
        </div>
      </div>
    </div>
    """
  end
end
