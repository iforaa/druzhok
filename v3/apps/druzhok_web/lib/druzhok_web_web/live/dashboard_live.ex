defmodule DruzhokWebWeb.DashboardLive do
  use DruzhokWebWeb, :live_view

  @max_events 200

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      :timer.send_interval(5_000, self(), :refresh)
      Druzhok.Events.subscribe_all()
    end

    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    models = Druzhok.Model.list()
    default_model = case models do
      [{id, _, _} | _] -> id
      _ -> ""
    end

    {:ok, assign(socket,
      current_user: current_user,
      instances: list_instances(),
      models: models,
      create_form: %{"name" => "", "token" => "", "model" => default_model},
      selected: nil,
      tab: :logs,
      workspace_files: [],
      file_content: nil,
      events: [],
      show_create: false,
      pairing: nil,
      owner: nil,
      groups: []
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, instances: list_instances())}
  end

  @impl true
  def handle_params(%{"name" => name}, _uri, socket) do
    case get_instance(name, socket) do
      nil ->
        {:noreply, socket |> assign(selected: nil) |> push_patch(to: "/")}
      instance ->
        files = list_workspace_files(instance)
        {:noreply, assign(socket,
          selected: name,
          workspace_files: files,
          file_content: nil,
          events: [],
          pairing: Druzhok.InstanceManager.get_pairing(name),
          owner: Druzhok.InstanceManager.get_owner(name),
          groups: Druzhok.InstanceManager.get_groups(name)
        )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, selected: nil, workspace_files: [], file_content: nil, events: [], pairing: nil, owner: nil, groups: [])}
  end

  def handle_info({:druzhok_event, instance_name, event}, socket) do
    if socket.assigns.selected == instance_name do
      events = [event | socket.assigns.events] |> Enum.take(@max_events)
      {:noreply, assign(socket, events: events)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_create", _, socket) do
    {:noreply, assign(socket, show_create: !socket.assigns.show_create)}
  end

  def handle_event("create", %{"name" => name, "token" => token, "model" => model}, socket) do
    if name != "" and token != "" do
      workspace = instance_workspace(name)

      case Druzhok.InstanceManager.create(name, %{
        workspace: workspace,
        model: model,
        telegram_token: token,
      }) do
        {:ok, _instance} ->
          {:noreply, assign(socket,
            instances: list_instances(),
            create_form: %{"name" => "", "token" => "", "model" => model},
            show_create: false
          )}
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Name and token required")}
    end
  end

  def handle_event("change_model", %{"name" => name, "model" => model}, socket) do
    Druzhok.InstanceManager.update_model(name, model)
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("change_heartbeat", %{"name" => name, "interval" => interval}, socket) do
    minutes = String.to_integer(interval)
    Druzhok.InstanceManager.update_heartbeat(name, minutes)
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("stop", %{"name" => name}, socket) do
    Druzhok.InstanceManager.stop(name)
    {:noreply, assign(socket, instances: list_instances(), selected: nil, events: [])}
  end

  def handle_event("select", %{"name" => name}, socket) do
    case get_instance(name, socket) do
      nil ->
        {:noreply, socket}
      instance ->
        files = list_workspace_files(instance)
        {:noreply,
          socket
          |> assign(selected: name, tab: :logs, workspace_files: files, file_content: nil, events: [])
          |> push_patch(to: "/instances/#{name}")}
    end
  end

  def handle_event("tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
  end

  def handle_event("clear_events", _, socket) do
    {:noreply, assign(socket, events: [])}
  end

  def handle_event("view_file", %{"path" => path}, socket) do
    if socket.assigns.selected do
      instance = get_instance(socket.assigns.selected, socket)
      if instance do
        full_path = Path.join(instance_workspace(socket.assigns.selected), path)
        content = case File.read(full_path) do
          {:ok, c} -> c
          {:error, _} -> "Cannot read file"
        end
        {:noreply, assign(socket, file_content: %{path: path, content: content})}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("back_to_files", _, socket) do
    {:noreply, assign(socket, file_content: nil)}
  end

  def handle_event("back", _, socket) do
    {:noreply,
      socket
      |> assign(selected: nil, workspace_files: [], file_content: nil, events: [])
      |> push_patch(to: "/")}
  end

  def handle_event("approve_pairing", %{"name" => name}, socket) do
    Druzhok.InstanceManager.approve_pairing(name)
    {:noreply, assign(socket,
      pairing: Druzhok.InstanceManager.get_pairing(name),
      owner: Druzhok.InstanceManager.get_owner(name)
    )}
  end

  def handle_event("approve_group", %{"name" => name, "chat_id" => chat_id}, socket) do
    Druzhok.InstanceManager.approve_group(name, String.to_integer(chat_id))
    {:noreply, assign(socket, groups: Druzhok.InstanceManager.get_groups(name))}
  end

  def handle_event("reject_group", %{"name" => name, "chat_id" => chat_id}, socket) do
    Druzhok.InstanceManager.reject_group(name, String.to_integer(chat_id))
    {:noreply, assign(socket, groups: Druzhok.InstanceManager.get_groups(name))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <%!-- Sidebar --%>
      <div class="w-72 bg-gray-50 border-r border-gray-200 flex flex-col">
        <div class="p-4 border-b border-gray-200">
          <div class="flex items-center justify-between">
            <h1 class="text-lg font-bold tracking-tight">Druzhok</h1>
            <button phx-click="toggle_create"
                    class="w-7 h-7 flex items-center justify-center rounded-full border border-gray-900 text-gray-900 hover:bg-gray-900 hover:text-white text-sm font-bold transition">
              +
            </button>
          </div>
        </div>

        <div :if={@show_create} class="p-4 border-b border-gray-200">
          <form phx-submit="create" class="space-y-3">
            <input name="name" value={@create_form["name"]} placeholder="Instance name"
                   class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900 focus:border-gray-900" />
            <input name="token" value={@create_form["token"]} placeholder="Telegram bot token"
                   class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900 focus:border-gray-900" />
            <select name="model" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
              <option :for={{id, label, _provider} <- @models} value={id}><%= label %></option>
            </select>
            <button type="submit" class="w-full bg-gray-900 hover:bg-gray-800 px-3 py-2 rounded-lg text-sm font-medium text-white transition">
              Create
            </button>
          </form>
        </div>

        <div class="flex-1 overflow-y-auto py-2">
          <div :if={@instances == []} class="px-4 py-8 text-center text-gray-400 text-sm">
            No instances yet
          </div>
          <div :for={inst <- @instances}
               phx-click="select" phx-value-name={inst.name}
               class={"flex items-center gap-3 px-4 py-3 cursor-pointer transition #{if @selected == inst.name, do: "bg-white border-l-2 border-gray-900 shadow-sm", else: "hover:bg-white/60 border-l-2 border-transparent"}"}>
            <div class="w-2 h-2 rounded-full bg-green-500 flex-shrink-0"></div>
            <div class="flex-1 min-w-0">
              <div class="text-sm font-medium truncate"><%= inst.name %></div>
              <div class="text-xs text-gray-400 truncate"><%= model_short(inst.model) %></div>
            </div>
          </div>
        </div>

        <%!-- User footer --%>
        <div :if={@current_user} class="p-4 border-t border-gray-200">
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <div class="text-sm font-medium truncate"><%= @current_user.email %></div>
              <div class="text-xs text-gray-400"><%= @current_user.role %></div>
            </div>
            <div class="flex gap-2">
              <a :if={@current_user.role == "admin"} href="/settings" class="text-xs text-gray-400 hover:text-gray-900 transition">Settings</a>
              <a href="/auth/logout" class="text-xs text-gray-400 hover:text-gray-900 transition">Logout</a>
            </div>
          </div>
        </div>
      </div>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col min-w-0">
        <div :if={!@selected} class="flex-1 flex items-center justify-center text-gray-400">
          <div class="text-center">
            <div class="text-5xl mb-4">&#128054;</div>
            <div class="text-lg font-medium text-gray-600">Select an instance</div>
            <div class="text-sm mt-1">or create a new one with the + button</div>
          </div>
        </div>

        <div :if={@selected} class="flex-1 flex flex-col min-h-0">
          <%!-- Top bar --%>
          <div class="px-6 py-3 border-b border-gray-200 flex items-center gap-4">
            <button phx-click="back" class="text-gray-400 hover:text-gray-900 transition text-sm">&larr;</button>
            <h2 class="text-sm font-semibold flex-1"><%= @selected %></h2>

            <form phx-change="change_model" class="flex items-center">
              <input type="hidden" name="name" value={@selected} />
              <select name="model" class="border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900">
                <%= for {id, label, _provider} <- @models do %>
                  <option value={id} selected={id == selected_model(@instances, @selected)}><%= label %></option>
                <% end %>
              </select>
            </form>

            <form phx-change="change_heartbeat" class="flex items-center gap-1">
              <input type="hidden" name="name" value={@selected} />
              <span class="text-[10px] text-gray-400">HB</span>
              <select name="interval" class="border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900">
                <%= for {val, label} <- heartbeat_options() do %>
                  <option value={val} selected={val == selected_heartbeat(@instances, @selected)}><%= label %></option>
                <% end %>
              </select>
            </form>

            <button phx-click="stop" phx-value-name={@selected}
                    class="text-xs text-red-500 hover:text-red-700 transition font-medium">
              Stop
            </button>
          </div>

          <%!-- Tabs --%>
          <div class="px-6 border-b border-gray-200 flex gap-0">
            <button phx-click="tab" phx-value-tab="logs"
                    class={"px-4 py-2.5 text-sm font-medium border-b-2 transition #{if @tab == :logs, do: "border-gray-900 text-gray-900", else: "border-transparent text-gray-400 hover:text-gray-600"}"}>
              Logs
              <span :if={@events != []} class="ml-1.5 px-1.5 py-0.5 rounded-full text-xs bg-gray-100 text-gray-600"><%= length(@events) %></span>
            </button>
            <button phx-click="tab" phx-value-tab="files"
                    class={"px-4 py-2.5 text-sm font-medium border-b-2 transition #{if @tab == :files, do: "border-gray-900 text-gray-900", else: "border-transparent text-gray-400 hover:text-gray-600"}"}>
              Files
            </button>
            <button phx-click="tab" phx-value-tab="security"
                    class={"px-4 py-2.5 text-sm font-medium border-b-2 transition #{if @tab == :security, do: "border-gray-900 text-gray-900", else: "border-transparent text-gray-400 hover:text-gray-600"}"}>
              Security
            </button>
          </div>

          <%!-- Tab content --%>
          <div class="flex-1 overflow-y-auto">
            <%!-- Logs tab --%>
            <div :if={@tab == :logs} class="h-full flex flex-col">
              <div :if={@events == []} class="flex-1 flex items-center justify-center text-gray-400 text-sm">
                Waiting for events...
              </div>

              <div :if={@events != []} class="flex-1 min-h-0 overflow-y-auto">
                <div class="px-2 py-2 space-y-px">
                  <div :for={event <- @events} class={"group px-4 py-2 rounded-lg #{event_bg(event.type)}"}>
                    <div class="flex items-center gap-2 mb-0.5">
                      <span class={"text-[10px] font-bold uppercase tracking-wider #{event_color(event.type)}"}><%= event_label(event.type) %></span>
                      <span class="text-[10px] text-gray-400 font-mono"><%= format_time(event.timestamp) %></span>
                    </div>
                    <div class="text-sm text-gray-700 leading-relaxed whitespace-pre-wrap break-words"><%= event_text(event) %></div>
                  </div>
                </div>
              </div>

              <div :if={@events != []} class="px-4 py-2 border-t border-gray-100 flex justify-end">
                <button phx-click="clear_events" class="text-xs text-gray-400 hover:text-gray-900 transition">Clear</button>
              </div>
            </div>

            <%!-- Files tab --%>
            <div :if={@tab == :files}>
              <div :if={@file_content} class="p-4">
                <div class="flex items-center gap-3 mb-3">
                  <button phx-click="back_to_files" class="text-xs text-gray-400 hover:text-gray-900 transition">&larr; back</button>
                  <span class="text-sm text-gray-500 font-mono"><%= @file_content.path %></span>
                </div>
                <pre class="bg-gray-50 border border-gray-200 p-4 rounded-lg text-sm overflow-auto max-h-[calc(100vh-200px)] whitespace-pre-wrap font-mono text-gray-700 leading-relaxed"><%= @file_content.content %></pre>
              </div>

              <div :if={!@file_content} class="py-1">
                <div :for={file <- @workspace_files}
                     class="flex items-center gap-3 py-2 px-6 hover:bg-gray-50 cursor-pointer transition"
                     phx-click="view_file" phx-value-path={file.path}>
                  <span :if={file.is_dir} class="text-xs text-amber-500 font-mono w-6">dir</span>
                  <span :if={!file.is_dir} class="text-xs text-gray-300 font-mono w-6">&mdash;</span>
                  <span class="flex-1 text-sm"><%= file.path %></span>
                  <span :if={!file.is_dir} class="text-xs text-gray-400 font-mono"><%= format_size(file.size) %></span>
                </div>
              </div>
            </div>

            <%!-- Security tab --%>
            <div :if={@tab == :security} class="p-6 space-y-6">
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
                    <button phx-click="approve_pairing" phx-value-name={@selected}
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
                    <button phx-click="approve_group" phx-value-name={@selected} phx-value-chat_id={group.chat_id}
                            class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1 text-xs font-medium transition">
                      Approve
                    </button>
                    <button phx-click="reject_group" phx-value-name={@selected} phx-value-chat_id={group.chat_id}
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
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Event formatting ---

  defp event_label(:user_message), do: "in"
  defp event_label(:agent_reply), do: "out"
  defp event_label(:loop_start), do: "loop"
  defp event_label(:llm_start), do: "llm"
  defp event_label(:llm_first_token), do: "token"
  defp event_label(:llm_done), do: "llm"
  defp event_label(:llm_error), do: "llm"
  defp event_label(:tool_call), do: "tool"
  defp event_label(:tool_exec), do: "exec"
  defp event_label(:tool_result), do: "result"
  defp event_label(:heartbeat), do: "hb"
  defp event_label(:reminder), do: "remind"
  defp event_label(:error), do: "err"
  defp event_label(other), do: to_string(other)

  defp event_color(:user_message), do: "text-blue-600"
  defp event_color(:agent_reply), do: "text-green-600"
  defp event_color(:loop_start), do: "text-violet-500"
  defp event_color(:llm_start), do: "text-purple-500"
  defp event_color(:llm_first_token), do: "text-purple-400"
  defp event_color(:llm_done), do: "text-purple-500"
  defp event_color(:llm_error), do: "text-red-500"
  defp event_color(:tool_call), do: "text-amber-600"
  defp event_color(:tool_exec), do: "text-amber-500"
  defp event_color(:tool_result), do: "text-amber-500"
  defp event_color(:heartbeat), do: "text-pink-500"
  defp event_color(:reminder), do: "text-pink-500"
  defp event_color(:error), do: "text-red-500"
  defp event_color(_), do: "text-gray-400"

  defp event_bg(:user_message), do: "bg-blue-50"
  defp event_bg(:agent_reply), do: "bg-green-50"
  defp event_bg(:loop_start), do: "bg-violet-50/50"
  defp event_bg(:llm_start), do: "bg-purple-50/50"
  defp event_bg(:llm_first_token), do: "bg-purple-50/30"
  defp event_bg(:llm_done), do: "bg-purple-50/50"
  defp event_bg(:llm_error), do: "bg-red-50"
  defp event_bg(:tool_call), do: "bg-amber-50/50"
  defp event_bg(:tool_exec), do: "bg-amber-50/30"
  defp event_bg(:tool_result), do: "bg-amber-50/30"
  defp event_bg(:heartbeat), do: "bg-pink-50/50"
  defp event_bg(:reminder), do: "bg-pink-50/50"
  defp event_bg(:error), do: "bg-red-50"
  defp event_bg(_), do: "bg-gray-50/50"

  defp event_text(%{type: :user_message, text: text, sender: sender}), do: "#{sender}: #{text}"
  defp event_text(%{type: :loop_start, tool_count: tc, message_count: mc, model: m}) when is_binary(m), do: "Starting loop (#{mc} msgs, #{tc} tools) model: #{m}"
  defp event_text(%{type: :loop_start, tool_count: tc, message_count: mc}), do: "Starting loop (#{mc} msgs, #{tc} tools)"
  defp event_text(%{type: :llm_start, iteration: i, message_count: mc}), do: "Requesting LLM [iteration #{i}] (#{mc} messages)"
  defp event_text(%{type: :llm_first_token}), do: "First token received"
  defp event_text(%{type: :llm_done, iteration: i, elapsed_ms: ms, has_tool_calls: true, content_length: cl, reasoning_length: rl}) do
    "LLM responded [iteration #{i}] in #{ms}ms \u2014 #{cl} chars, #{rl} reasoning, has tool calls"
  end
  defp event_text(%{type: :llm_done, iteration: i, elapsed_ms: ms, content_length: cl, reasoning_length: rl}) do
    "LLM responded [iteration #{i}] in #{ms}ms \u2014 #{cl} chars, #{rl} reasoning"
  end
  defp event_text(%{type: :llm_error, elapsed_ms: ms, error: err}), do: "LLM error after #{ms}ms: #{err}"
  defp event_text(%{type: :tool_call, name: name, arguments: args}), do: "#{name}(#{String.slice(args, 0, 300)})"
  defp event_text(%{type: :tool_exec, name: name, elapsed_ms: ms, is_error: true}), do: "#{name} failed (#{ms}ms)"
  defp event_text(%{type: :tool_exec, name: name, elapsed_ms: ms}), do: "#{name} completed (#{ms}ms)"
  defp event_text(%{type: :tool_result, name: name, content: content, is_error: true}), do: "#{name} ERROR: #{content}"
  defp event_text(%{type: :tool_result, name: name, content: content}), do: "#{name} \u2192 #{content}"
  defp event_text(%{text: text}) when is_binary(text), do: text
  defp event_text(_), do: ""

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""

  defp model_short(model) do
    model |> String.split("/") |> List.last()
  end

  defp selected_model(instances, name) do
    case Enum.find(instances, &(&1.name == name)) do
      nil -> ""
      inst -> inst.model
    end
  end

  defp selected_heartbeat(instances, name) do
    case Enum.find(instances, &(&1.name == name)) do
      nil -> 0
      inst -> inst[:heartbeat_interval] || 0
    end
  end

  defp heartbeat_options do
    [
      {0, "Off"},
      {5, "5m"},
      {15, "15m"},
      {30, "30m"},
      {60, "1h"},
      {360, "6h"},
      {1440, "24h"},
    ]
  end

  # --- Helpers ---

  defp list_instances do
    Druzhok.InstanceManager.list()
  end

  defp get_instance(name, socket) do
    Enum.find(socket.assigns.instances, & &1.name == name)
  end

  defp instance_workspace(name) do
    Path.join([File.cwd!(), "..", "data", "instances", name, "workspace"])
  end

  defp list_workspace_files(instance) do
    workspace = instance_workspace(instance.name)
    if File.exists?(workspace) do
      File.ls!(workspace)
      |> Enum.map(fn name ->
        path = Path.join(workspace, name)
        stat = File.stat!(path)
        %{path: name, is_dir: stat.type == :directory, size: stat.size}
      end)
      |> Enum.sort_by(& {!&1.is_dir, &1.path})
    else
      []
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
