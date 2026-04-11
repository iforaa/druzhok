defmodule DruzhokWebWeb.Live.Components.SettingsTab do
  use DruzhokWebWeb, :live_component

  alias Druzhok.{Instance, Repo, Runtime, Pairing, Telegram, I18n, BotManager, ModelCatalog}

  @impl true
  def update(%{instance: instance} = assigns, socket) do
    runtime = Runtime.get(instance[:bot_runtime] || "zeroclaw", Runtime.ZeroClaw)
    {:ok, socket |> assign(assigns) |> assign(:runtime, runtime)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <form phx-change="settings_changed" phx-target={@myself} class="space-y-4">

        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="block text-xs font-medium text-gray-500 mb-1">Runtime</label>
            <div class="w-full border border-gray-200 bg-gray-50 rounded-lg px-3 py-2 text-sm text-gray-600"><%= @instance[:bot_runtime] || "zeroclaw" %></div>
          </div>

          <div>
            <label class="block text-xs font-medium text-gray-500 mb-1">Daily token limit</label>
            <input type="number" name="token_limit" min="0" step="100000"
                   phx-debounce="blur"
                   value={@instance[:daily_token_limit] || 0}
                   class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono" />
          </div>

          <div>
            <label class="block text-xs font-medium text-gray-500 mb-1">Language</label>
            <select name="language" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
              <option value="ru" selected={@instance[:language] == "ru"}>Russian</option>
              <option value="en" selected={@instance[:language] == "en"}>English</option>
            </select>
          </div>
        </div>
      </form>

      <hr class="border-gray-200" />

      <%!-- Telegram token --%>
      <div>
        <h3 class="text-sm font-medium text-gray-700 mb-2">Telegram Token</h3>
        <% token = @instance[:telegram_token] %>
        <div :if={token} class="flex items-center gap-2">
          <code class="text-xs bg-gray-100 px-2 py-1 rounded flex-1 truncate"><%= String.slice(token, 0, 10) %>...</code>
          <button phx-click="remove_telegram_token" phx-target={@myself} class="text-xs text-red-500 hover:text-red-700">Remove</button>
        </div>
        <form :if={!token} phx-submit="save_telegram_token" phx-target={@myself} class="flex gap-2">
          <input name="token" placeholder="Bot token" class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm" />
          <button type="submit" class="px-3 py-2 bg-gray-900 text-white rounded-lg text-sm">Save</button>
        </form>
      </div>

      <hr class="border-gray-200" />

      <%!-- Model Selection --%>
      <% is_running = @instance[:container_status] == "running" %>
      <div>
        <h3 class="text-sm font-medium text-gray-700 mb-3">Models</h3>
        <div :if={is_running} class="text-xs text-amber-600 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-3">
          Stop the bot to change model settings
        </div>
        <form phx-change="update_models" phx-target={@myself}>
            <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Default (all messages)</label>
              <select name="default_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                <%= for m <- ModelCatalog.default_options() do %>
                  <option value={m.id} selected={m.id == @instance[:model]}><%= m.name %> (<%= m.price %>)</option>
                <% end %>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">On-demand (user requests)</label>
              <select name="on_demand_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                <option value="">None</option>
                <%= for m <- ModelCatalog.smart() do %>
                  <option value={m.id} selected={m.id == (@instance[:on_demand_model] || "")}><%= m.name %> (<%= m.price %>)</option>
                <% end %>
              </select>
            </div>
          </div>
          <div class="grid grid-cols-3 gap-4 mt-4">
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Image model</label>
              <select name="image_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                <%= for m <- ModelCatalog.image_models() do %>
                  <option value={m.id} selected={m.id == (@instance[:image_model] || ModelCatalog.default_image_model())}><%= m.name %></option>
                <% end %>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Audio model</label>
              <select name="audio_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                <%= for m <- ModelCatalog.audio_models() do %>
                  <option value={m.id} selected={m.id == (@instance[:audio_model] || ModelCatalog.default_audio_model())}><%= m.name %></option>
                <% end %>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Embedding model</label>
              <select name="embedding_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                <%= for m <- ModelCatalog.embedding_models() do %>
                  <option value={m.id} selected={m.id == (@instance[:embedding_model] || ModelCatalog.default_embedding_model())}><%= m.name %></option>
                <% end %>
              </select>
            </div>
          </div>
          <div :if={@runtime.supports_feature?(:fallback_models)} class="mt-4">
            <label class="block text-xs font-medium text-gray-500 mb-1">Fallback models (JSON array)</label>
            <input name="fallback_models" value={@instance[:fallback_models] || ""} disabled={is_running}
                   phx-debounce="blur"
                   placeholder='["google/gemini-3-flash-preview","openai/gpt-5.4-mini"]'
                   class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono #{if is_running, do: "opacity-50 cursor-not-allowed"}"} />
          </div>
        </form>
      </div>

      <hr :if={@runtime.supports_feature?(:heartbeat)} class="border-gray-200" />

      <%!-- Heartbeat --%>
      <div :if={@runtime.supports_feature?(:heartbeat)}>
        <h3 class="text-sm font-medium text-gray-700 mb-3">Heartbeat</h3>
        <form phx-change="update_models" phx-target={@myself}>
          <input type="hidden" name="default_model" value={@instance[:model]} />
          <div class="grid grid-cols-3 gap-4">
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Target</label>
              <select name="heartbeat_target" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
                <option value="" selected={is_nil(@instance[:heartbeat_target])}>Default (none)</option>
                <option value="none" selected={@instance[:heartbeat_target] == "none"}>None (silent)</option>
                <option value="last" selected={@instance[:heartbeat_target] == "last"}>Last contact</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Active from</label>
              <input name="heartbeat_active_start" value={@instance[:heartbeat_active_start] || ""}
                     phx-debounce="blur"
                     placeholder="08:00" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono" />
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Active until</label>
              <input name="heartbeat_active_end" value={@instance[:heartbeat_active_end] || ""}
                     phx-debounce="blur"
                     placeholder="24:00" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono" />
            </div>
          </div>
        </form>
      </div>

      <hr :if={@runtime.supports_feature?(:dreaming)} class="border-gray-200" />

      <%!-- Dreaming --%>
      <div :if={@runtime.supports_feature?(:dreaming)}>
        <h3 class="text-sm font-medium text-gray-700 mb-3">Dreaming</h3>
        <p class="text-xs text-gray-500 mb-2">Background memory consolidation. Runs at 3 AM, promotes strong memories to MEMORY.md.</p>
        <form phx-change="update_models" phx-target={@myself}>
          <input type="hidden" name="default_model" value={@instance[:model]} />
          <select name="dreaming" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
            <option value="false" selected={!@instance[:dreaming]}>Disabled</option>
            <option value="true" selected={@instance[:dreaming] == true}>Enabled</option>
          </select>
        </form>
      </div>

      <hr class="border-gray-200" />

      <%!-- Pending Pairing Requests --%>
      <%= if @pairing_requests != [] do %>
        <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-4">
          <h3 class="text-sm font-medium text-yellow-800 mb-2">Pending Access Requests</h3>
          <%= for req <- @pairing_requests do %>
            <div class="flex items-center justify-between py-2 border-b border-yellow-100 last:border-0">
              <div>
                <span class="font-mono text-sm"><%= req.telegram_user_id %></span>
                <%= if req.username do %>
                  <span class="text-gray-500 text-sm ml-2">@<%= req.username %></span>
                <% end %>
              </div>
              <button phx-click="approve_pairing" phx-target={@myself}
                      phx-value-user_id={req.telegram_user_id}
                      class="px-3 py-1 bg-green-600 text-white text-sm rounded hover:bg-green-700">
                Approve
              </button>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Approved Users --%>
      <div>
        <h3 class="text-sm font-medium text-gray-700 mb-3">Approved Telegram Users</h3>
        <div :if={@allowed_users == []} class="text-xs text-gray-400 mb-3">
          No users approved yet. When someone messages the bot, it will show them an ID to paste here.
        </div>
        <div :if={@allowed_users != []} class="space-y-1 mb-3">
          <div :for={user_id <- @allowed_users} class="flex items-center justify-between bg-gray-50 rounded-lg px-3 py-2">
            <code class="text-sm font-mono"><%= user_id %></code>
            <button phx-click="remove_user" phx-target={@myself} phx-value-user_id={user_id}
                    class="text-xs text-red-500 hover:text-red-700 transition">Remove</button>
          </div>
        </div>
        <form phx-submit="approve_user" phx-target={@myself} class="flex gap-2">
          <input name="user_input" placeholder="Paste user ID or bind command"
                 class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm" />
          <button type="submit" class="px-3 py-2 bg-gray-900 text-white rounded-lg text-sm">Approve</button>
        </form>
        <p class="text-xs text-gray-400 mt-1">Paste the number from the bot's approval message</p>
      </div>

      <hr class="border-gray-200" />

      <%!-- Group Chats --%>
      <div>
        <h3 class="text-sm font-medium text-gray-700 mb-3">Group Chats</h3>
        <label class="flex items-center gap-3 cursor-pointer">
          <input type="checkbox" phx-click="toggle_mention_only" phx-target={@myself}
                 checked={@instance[:mention_only]}
                 class="rounded border-gray-300" />
          <span class="text-sm text-gray-600">Mention only — respond only when @mentioned in groups</span>
        </label>
        <form phx-submit="save_trigger_name" phx-target={@myself} class="flex gap-2 mt-3">
          <input name="trigger_name" value={@instance[:trigger_name] || ""}
                 placeholder="Trigger name (e.g. Igz)"
                 class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm" />
          <button type="submit" class="px-3 py-2 bg-gray-900 text-white rounded-lg text-sm">Save</button>
        </form>
        <p class="text-xs text-gray-400 mt-1">Bot also responds when this name is mentioned in groups (case-insensitive)</p>
      </div>

      <hr class="border-gray-200" />

      <%!-- Messages --%>
      <div>
        <h3 class="text-sm font-medium text-gray-700 mb-3">Messages</h3>
        <div class="space-y-4">
          <div>
            <label class="block text-xs font-medium text-gray-500 mb-1">Rejection Message</label>
            <textarea phx-blur="update_reject_message" phx-target={@myself}
                      class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm"
                      placeholder="Uses default if empty. Use %{user_id} for the user's ID."
                      rows="2"><%= @instance[:reject_message] %></textarea>
          </div>
          <div>
            <label class="block text-xs font-medium text-gray-500 mb-1">Welcome Message</label>
            <textarea phx-blur="update_welcome_message" phx-target={@myself}
                      class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm"
                      placeholder="Uses default if empty."
                      rows="2"><%= @instance[:welcome_message] %></textarea>
          </div>
        </div>
      </div>

      <hr class="border-gray-200" />

      <%!-- Session --%>
      <div>
        <h3 class="text-sm font-medium text-gray-700 mb-3">Session</h3>
        <button phx-click="clear_history" phx-target={@myself}
                class="px-3 py-2 bg-red-50 text-red-600 border border-red-200 rounded-lg text-sm hover:bg-red-100 transition"
                data-confirm="Clear all conversation history? The bot will restart with a fresh session.">
          Clear History & Restart
        </button>
        <p class="text-xs text-gray-400 mt-1">Clears all conversation history and restarts the bot</p>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("settings_changed", params, socket) do
    token_limit =
      case Integer.parse(params["token_limit"] || "0") do
        {n, _} -> max(n, 0)
        :error -> 0
      end

    update_instance(socket.assigns.instance.name, %{
      daily_token_limit: token_limit,
      language: params["language"] || "ru"
    })

    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("update_models", params, socket) do
    name = socket.assigns.instance.name
    changes = %{model: params["default_model"], on_demand_model: non_empty(params, "on_demand_model")}
    changes = if p = non_empty(params, "image_model"), do: Map.put(changes, :image_model, p), else: changes
    changes = if p = non_empty(params, "audio_model"), do: Map.put(changes, :audio_model, p), else: changes
    changes = if p = non_empty(params, "embedding_model"), do: Map.put(changes, :embedding_model, p), else: changes
    changes = if p = non_empty(params, "heartbeat_target"), do: Map.put(changes, :heartbeat_target, p), else: changes
    changes = if p = non_empty(params, "heartbeat_active_start"), do: Map.put(changes, :heartbeat_active_start, p), else: changes
    changes = if p = non_empty(params, "heartbeat_active_end"), do: Map.put(changes, :heartbeat_active_end, p), else: changes
    changes = if p = non_empty(params, "fallback_models"), do: Map.put(changes, :fallback_models, p), else: changes

    changes =
      case params["dreaming"] do
        "true" -> Map.put(changes, :dreaming, true)
        "false" -> Map.put(changes, :dreaming, false)
        _ -> changes
      end

    update_instance(name, changes)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("save_telegram_token", %{"token" => token}, socket) do
    token = case String.trim(token) do "" -> nil; t -> t end
    name = socket.assigns.instance.name
    update_instance(name, %{telegram_token: token})
    Task.start(fn -> BotManager.restart(name) end)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("remove_telegram_token", _params, socket) do
    name = socket.assigns.instance.name
    update_instance(name, %{telegram_token: nil})
    Task.start(fn -> BotManager.restart(name) end)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("toggle_mention_only", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:mention_only]
    update_instance(name, %{mention_only: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("save_trigger_name", %{"trigger_name" => trigger_name}, socket) do
    trigger_name = case String.trim(trigger_name) do "" -> nil; t -> t end
    update_instance(socket.assigns.instance.name, %{trigger_name: trigger_name})
    restart_bot(socket.assigns.instance.name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("clear_history", _params, socket) do
    name = socket.assigns.instance.name

    with_runtime(name, fn runtime, data_root ->
      runtime.clear_sessions(data_root)
      restart_bot(name)
    end)

    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("generate_api_key", _params, socket) do
    update_instance(socket.assigns.instance.name, %{api_key: Instance.generate_api_key()})
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("update_" <> field, %{"value" => value}, socket)
      when field in ["reject_message", "welcome_message"] do
    update_instance(socket.assigns.instance.name, %{
      String.to_existing_atom(field) => non_empty_string(value)
    })

    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("approve_pairing", %{"user_id" => user_id_str}, socket) do
    name = socket.assigns.instance.name
    user_id = String.to_integer(user_id_str)

    with_runtime(name, fn runtime, data_root ->
      runtime.add_allowed_user(data_root, user_id_str)
      Pairing.approve_request(name, user_id)

      welcome = socket.assigns.instance[:welcome_message] ||
        I18n.t(:welcome_default, socket.assigns.instance[:language] || "ru")

      if token = socket.assigns.instance[:telegram_token] do
        Telegram.API.send_message(token, user_id, welcome)
      end

      Druzhok.Events.broadcast(name, %{type: :pairing_approved, user_id: user_id_str})
    end)

    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("approve_user", %{"user_input" => input}, socket) do
    user_id = Runtime.parse_user_input(input)

    if user_id != "" do
      mutate_allowlist(socket, user_id, :add)
      notify_parent(socket)
    end

    {:noreply, socket}
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    mutate_allowlist(socket, user_id, :remove)
    notify_parent(socket)
    {:noreply, socket}
  end

  defp mutate_allowlist(socket, user_id, op) do
    name = socket.assigns.instance.name

    case Repo.get_by(Instance, name: name) do
      nil ->
        :ok

      instance ->
        runtime = Runtime.get(instance.bot_runtime, Runtime.ZeroClaw)

        if runtime.supports_feature?(:db_allowlist) do
          case op do
            :add -> Instance.add_allowed_id(instance, user_id)
            :remove -> Instance.remove_allowed_id(instance, user_id)
          end
        else
          with_runtime(name, fn r, data_root ->
            case op do
              :add -> r.add_allowed_user(data_root, user_id)
              :remove -> r.remove_allowed_user(data_root, user_id)
            end
          end)
        end

        restart_bot(name)
    end
  end

  # --- Helpers ---

  defp update_instance(name, changes) do
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> inst |> Instance.changeset(changes) |> Repo.update()
    end
  end

  defp non_empty_string(value) do
    case String.trim(value || "") do
      "" -> nil
      v -> v
    end
  end

  defp with_runtime(name, fun) do
    case Repo.get_by(Instance, name: name) do
      %{workspace: workspace, bot_runtime: bot_runtime} when workspace != nil ->
        runtime = Runtime.get(bot_runtime || "zeroclaw", Runtime.ZeroClaw)
        fun.(runtime, Path.dirname(workspace))

      _ ->
        nil
    end
  end

  defp restart_bot(name) do
    Task.start(fn -> BotManager.restart(name) end)
    :ok
  end

  defp non_empty(params, key) do
    case params[key] do
      nil -> nil
      "" -> nil
      val -> val
    end
  end

  defp notify_parent(_socket) do
    send(self(), :settings_updated)
    :ok
  end
end
