defmodule DruzhokWebWeb.Live.Components.SecurityTab do
  use Phoenix.Component

  attr :pairing, :any, default: nil
  attr :owner, :any, default: nil
  attr :groups, :list, default: []
  attr :instance_name, :string, required: true
  attr :telegram_token, :string, default: nil
  attr :api_key, :string, default: nil

  def security_tab(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <%!-- Telegram section --%>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <h3 class="text-sm font-semibold mb-3">Telegram</h3>
        <div :if={@telegram_token}>
          <div class="flex items-center gap-3">
            <span class="text-sm text-gray-600 font-mono flex-1"><%= mask_token(@telegram_token) %></span>
            <button phx-click="remove_telegram_token"
                    class="text-xs text-red-500 hover:text-red-700 font-medium transition"
                    data-confirm="Remove Telegram token? The bot will stop responding on Telegram.">
              Remove
            </button>
          </div>
          <form phx-submit="save_telegram_token" class="mt-3 flex gap-2">
            <input name="token" placeholder="New token" class="flex-1 border border-gray-300 rounded-lg px-3 py-1.5 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
            <button type="submit" class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1.5 text-sm font-medium transition">Update</button>
          </form>
        </div>
        <div :if={!@telegram_token}>
          <form phx-submit="save_telegram_token" class="flex gap-2">
            <input name="token" placeholder="Bot token from @BotFather" class="flex-1 border border-gray-300 rounded-lg px-3 py-1.5 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
            <button type="submit" class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1.5 text-sm font-medium transition">Save</button>
          </form>
          <p class="text-xs text-gray-400 mt-2">Connect a Telegram bot to this instance.</p>
        </div>
      </div>

      <%!-- App Connection section --%>
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <h3 class="text-sm font-semibold mb-3">App Connection</h3>
        <div :if={@api_key}>
          <div class="flex items-center gap-3">
            <span class="text-sm text-gray-600 font-mono flex-1"><%= mask_token(@api_key) %></span>
            <button id="copy-api-key" phx-hook="CopyToClipboard" data-text={@api_key}
                    class="text-xs text-gray-500 hover:text-gray-900 font-medium transition">
              Copy
            </button>
            <button phx-click="generate_api_key"
                    class="text-xs text-amber-600 hover:text-amber-800 font-medium transition"
                    data-confirm="Regenerate API key? Existing app connections will stop working.">
              Regenerate
            </button>
          </div>
          <p class="text-xs text-gray-400 mt-2">WebSocket: <span class="font-mono">ws://host:4000/socket/chat</span></p>
        </div>
        <div :if={!@api_key}>
          <button phx-click="generate_api_key"
                  class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1.5 text-sm font-medium transition">
            Generate API Key
          </button>
          <p class="text-xs text-gray-400 mt-2">Generate a key to connect apps via WebSocket.</p>
        </div>
      </div>

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
          <div :if={group.status == "approved"} class="space-y-2">
            <div class="flex items-center gap-2">
              <select phx-change="update_group_activation" phx-value-name={@instance_name} phx-value-chat_id={group.chat_id}
                      name="activation" class="text-xs border border-gray-300 rounded px-2 py-1">
                <option value="buffer" selected={group.activation == "buffer"}>Buffer</option>
                <option value="always" selected={group.activation == "always"}>Always</option>
              </select>
            </div>
            <textarea phx-blur="update_group_prompt" phx-value-name={@instance_name} phx-value-chat_id={group.chat_id}
                      name="system_prompt" placeholder="Per-group prompt (optional)"
                      rows="2" class="w-full text-xs border border-gray-300 rounded px-2 py-1 resize-y"><%= group.system_prompt %></textarea>
          </div>
          <span :if={group.status == "rejected"} class="text-xs text-red-500 font-medium">Rejected</span>
          <span :if={group.status == "removed"} class="text-xs text-gray-400 font-medium">Removed</span>
        </div>
      </div>
    </div>
    """
  end

  defp mask_token(nil), do: ""
  defp mask_token(token) when byte_size(token) <= 8, do: "****"
  defp mask_token(token) do
    String.slice(token, 0, 4) <> "****" <> String.slice(token, -4, 4)
  end
end
