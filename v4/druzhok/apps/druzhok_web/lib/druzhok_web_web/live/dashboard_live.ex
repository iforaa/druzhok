defmodule DruzhokWebWeb.DashboardLive do
  use DruzhokWebWeb, :live_view

  import DruzhokWebWeb.Live.Components.EventLog
  import DruzhokWebWeb.Live.Components.FileBrowser
  import DruzhokWebWeb.Live.Components.ErrorsTab
  import DruzhokWebWeb.Live.Components.UsageTab

  @max_events 200
  @valid_tabs %{"logs" => :logs, "files" => :files, "settings" => :settings, "usage" => :usage, "errors" => :errors}

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
      current_path: "",
      pairing: nil,
      owner: nil,
      groups: [],
      instance_errors: [],
      expanded_error: nil,
      editing_file: false,
      file_saved: false,
      usage_requests: [],
      usage_summary: [],
      expanded_request: nil
    )}
  end

  @impl true
  def handle_params(%{"name" => name}, _uri, socket) do
    case get_instance(name, socket) do
      nil ->
        {:noreply, socket |> assign(selected: nil) |> push_patch(to: "/")}
      instance ->
        files = list_workspace_files(instance, "")
        {:noreply, assign(socket,
          selected: name,
          workspace_files: files,
          file_content: nil,
          current_path: "",
          events: [],
          pairing: Druzhok.InstanceManager.get_pairing(name),
          owner: Druzhok.InstanceManager.get_owner(name),
          groups: Druzhok.InstanceManager.get_groups(name),
          instance_errors: [],
          expanded_error: nil
        )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, selected: nil, workspace_files: [], file_content: nil, events: [], pairing: nil, owner: nil, groups: [])}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, instances: list_instances())}
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

  def handle_event("create", %{"name" => name, "model" => model} = params, socket) do
    if name != "" do
      token = params["token"]
      token = if token == "", do: nil, else: token
      bot_runtime = params["bot_runtime"] || "zeroclaw"

      case Druzhok.BotManager.create(name, %{
        model: model,
        telegram_token: token,
        bot_runtime: bot_runtime,
      }) do
        {:ok, _instance} ->
          {:noreply, assign(socket,
            instances: list_instances(),
            create_form: %{"name" => "", "token" => "", "model" => model},
            show_create: false
          )}
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Name is required")}
    end
  end

  def handle_event("settings_changed", params, socket) do
    name = params["name"]

    token_limit = case Integer.parse(params["token_limit"] || "0") do
      {n, _} -> max(n, 0)
      :error -> 0
    end

    dream_hour = case Integer.parse(params["dream_hour"] || "-1") do
      {n, _} -> n
      :error -> -1
    end

    heartbeat = case Integer.parse(params["heartbeat"] || "0") do
      {n, _} -> n
      :error -> 0
    end

    language = params["language"] || "ru"

    bot_runtime = params["bot_runtime"]

    changes = %{
      daily_token_limit: token_limit,
      dream_hour: dream_hour,
      heartbeat_interval: heartbeat,
      language: language
    }

    # Add bot_runtime if changed
    changes = if bot_runtime, do: Map.put(changes, :bot_runtime, bot_runtime), else: changes
    # Add model if changed
    changes = if params["model"], do: Map.put(changes, :model, params["model"]), else: changes

    update_instance_field(name, changes)

    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("stop", %{"name" => name}, socket) do
    Druzhok.BotManager.stop(name)
    {:noreply, assign(socket, instances: list_instances(), selected: nil, events: [])}
  end

  def handle_event("start_bot", %{"name" => name}, socket) do
    Druzhok.BotManager.start(name)
    Process.sleep(1_000)
    {:noreply, assign(socket, instances: list_instances())}
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
    case Map.get(@valid_tabs, tab) do
      nil ->
        {:noreply, socket}
      :errors ->
        errors = if socket.assigns.selected do
          Druzhok.CrashLog.recent_for_instance(socket.assigns.selected, 100)
        else
          []
        end
        {:noreply, assign(socket, tab: :errors, instance_errors: errors)}
      :usage ->
        {requests, summary} = if socket.assigns.selected do
          inst = get_instance(socket.assigns.selected, socket)
          if inst do
            requests = Druzhok.Usage.recent(inst[:id], 50)
            summary = Druzhok.Usage.daily_usage(inst[:id])
            {requests, summary}
          else
            {[], nil}
          end
        else
          {[], nil}
        end
        {:noreply, assign(socket, tab: :usage, usage_requests: requests, usage_summary: summary)}
      atom_tab ->
        {:noreply, assign(socket, tab: atom_tab)}
    end
  end

  def handle_event("clear_events", _, socket) do
    {:noreply, assign(socket, events: [])}
  end

  def handle_event("toggle_request", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = if socket.assigns.expanded_request == id, do: nil, else: id
    {:noreply, assign(socket, expanded_request: expanded)}
  end

  def handle_event("view_file", %{"path" => path, "is_dir" => "true"}, socket) do
    # Navigate into directory
    if socket.assigns.selected do
      instance = get_instance(socket.assigns.selected, socket)
      if instance do
        current_path = socket.assigns[:current_path] || ""
        new_path = if current_path == "", do: path, else: Path.join(current_path, path)
        files = list_workspace_files(instance, new_path)
        {:noreply, assign(socket, workspace_files: files, file_content: nil, current_path: new_path)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("view_file", %{"path" => path}, socket) do
    if socket.assigns.selected do
      instance = get_instance(socket.assigns.selected, socket)
      if instance do
        current_path = socket.assigns[:current_path] || ""
        full_rel = if current_path == "", do: path, else: Path.join(current_path, path)
        full_path = Path.join(instance[:workspace] || instance_workspace(socket.assigns.selected), full_rel)
        content = case File.stat(full_path) do
          {:ok, %{size: size}} when size > 500_000 ->
            case File.open(full_path, [:read]) do
              {:ok, f} ->
                data = IO.read(f, 50_000)
                File.close(f)
                "#{data}\n\n... [truncated, file is #{div(size, 1024)}KB]"
              _ -> "Cannot read file"
            end
          _ ->
            case File.read(full_path) do
              {:ok, c} -> c
              {:error, _} -> "Cannot read file"
            end
        end
        {:noreply, assign(socket, file_content: %{path: full_rel, content: content}, editing_file: false, file_saved: false)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_file", _, socket) do
    {:noreply, assign(socket, editing_file: true, file_saved: false)}
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, assign(socket, editing_file: false)}
  end

  def handle_event("save_file", _, socket) do
    {:noreply, push_event(socket, "request_file_content", %{})}
  end

  def handle_event("do_save_file", %{"content" => content}, socket) do
    if socket.assigns.selected && socket.assigns.file_content do
      path = socket.assigns.file_content.path
      instance = get_instance(socket.assigns.selected, socket)
      if instance do
        workspace = instance[:workspace] || instance_workspace(socket.assigns.selected)
        full_path = Path.join(workspace, path)
        File.write!(full_path, content)
        {:noreply, assign(socket, file_content: %{path: path, content: content}, editing_file: false, file_saved: true)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("back_to_files", _, socket) do
    current_path = socket.assigns[:current_path] || ""
    if current_path == "" do
      {:noreply, assign(socket, file_content: nil)}
    else
      # Go up one directory
      parent = Path.dirname(current_path)
      parent = if parent == ".", do: "", else: parent
      instance = get_instance(socket.assigns.selected, socket)
      files = if instance, do: list_workspace_files(instance, parent), else: []
      {:noreply, assign(socket, file_content: nil, workspace_files: files, current_path: parent)}
    end
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

  def handle_event("update_group_activation", %{"name" => name, "chat_id" => chat_id, "activation" => activation}, socket) do
    chat_id = String.to_integer(chat_id)
    Druzhok.AllowedChat.set_activation(name, chat_id, activation)
    groups = Druzhok.AllowedChat.groups_for_instance(name)
    {:noreply, assign(socket, groups: groups)}
  end

  def handle_event("toggle_error", %{"id" => id}, socket) do
    expanded = if to_string(socket.assigns.expanded_error) == id, do: nil, else: id
    {:noreply, assign(socket, expanded_error: expanded)}
  end

  def handle_event("clear_errors", _, socket) do
    Druzhok.CrashLog.clear_all()
    {:noreply, assign(socket, instance_errors: [])}
  end

  def handle_event("save_telegram_token", %{"token" => token}, socket) do
    token = case String.trim(token) do "" -> nil; t -> t end
    update_instance_field(socket.assigns.selected, %{telegram_token: token}, _restart = true)
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("remove_telegram_token", _, socket) do
    update_instance_field(socket.assigns.selected, %{telegram_token: nil}, _restart = true)
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("generate_api_key", _, socket) do
    update_instance_field(socket.assigns.selected, %{api_key: Druzhok.Instance.generate_api_key()})
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("update_group_prompt", %{"name" => name, "chat_id" => chat_id, "value" => prompt}, socket) do
    chat_id = String.to_integer(chat_id)
    prompt = case String.trim(prompt) do
      "" -> nil
      p -> p
    end
    case Druzhok.AllowedChat.get(name, chat_id) do
      nil -> :ok
      chat -> Druzhok.AllowedChat.changeset(chat, %{system_prompt: prompt}) |> Druzhok.Repo.update()
    end
    groups = Druzhok.AllowedChat.groups_for_instance(name)
    {:noreply, assign(socket, groups: groups)}
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
            <input name="token" value={@create_form["token"]} placeholder="Telegram bot token (optional)"
                   class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900 focus:border-gray-900" />
            <select name="model" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
              <option :for={{id, label, _provider} <- @models} value={id}><%= label %></option>
            </select>
            <select name="bot_runtime" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
              <option :for={name <- Druzhok.Runtime.names()} value={name} selected={name == "zeroclaw"}><%= name %></option>
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
            <div class={"w-2 h-2 rounded-full flex-shrink-0 #{container_status_color(inst[:container_status])}"}></div>
            <div class="flex-1 min-w-0">
              <div class="text-sm font-medium truncate"><%= inst.name %></div>
              <div class="text-xs text-gray-400 truncate"><%= inst[:bot_runtime] || "zeroclaw" %> &middot; <%= model_short(inst.model) %></div>
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
              <a href="/processes" class="text-xs text-gray-400 hover:text-gray-600 transition">Processes</a>
              <a href="/errors" class="text-xs text-gray-400 hover:text-red-600 transition">Errors</a>
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
            <span class={"px-2 py-0.5 rounded text-[10px] font-medium #{runtime_badge_color(selected_field(@instances, @selected, :bot_runtime))}"}><%= selected_field(@instances, @selected, :bot_runtime) || "zeroclaw" %></span>
            <span class={"px-2 py-0.5 rounded text-[10px] font-medium #{container_status_badge(selected_field(@instances, @selected, :container_status))}"}><%= selected_field(@instances, @selected, :container_status) || "unknown" %></span>
            <button phx-click="start_bot" phx-value-name={@selected}
                    class="text-xs text-green-600 hover:text-green-800 transition font-medium">
              Start
            </button>
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
            <button phx-click="tab" phx-value-tab="settings"
                    class={"px-4 py-2.5 text-sm font-medium border-b-2 transition #{if @tab == :settings, do: "border-gray-900 text-gray-900", else: "border-transparent text-gray-400 hover:text-gray-600"}"}>
              Settings
            </button>
            <button phx-click="tab" phx-value-tab="usage"
                    class={"px-4 py-2.5 text-sm font-medium border-b-2 transition #{if @tab == :usage, do: "border-blue-500 text-blue-600", else: "border-transparent text-gray-400 hover:text-gray-600"}"}>
              Usage
            </button>
            <button phx-click="tab" phx-value-tab="errors"
                    class={"px-4 py-2.5 text-sm font-medium border-b-2 transition #{if @tab == :errors, do: "border-red-500 text-red-600", else: "border-transparent text-gray-400 hover:text-gray-600"}"}>
              Errors
              <span :if={@instance_errors != []} class="ml-1.5 px-1.5 py-0.5 rounded-full text-xs bg-red-100 text-red-600"><%= length(@instance_errors) %></span>
            </button>
          </div>

          <%!-- Tab content --%>
          <div class="flex-1 overflow-y-auto">
            <%!-- Logs tab --%>
            <.event_log :if={@tab == :logs} events={@events} />

            <%!-- Files tab --%>
            <.file_browser :if={@tab == :files} files={@workspace_files} file_content={@file_content} current_path={@current_path} editing={@editing_file} file_saved={@file_saved} />

            <%!-- Settings tab --%>
            <div :if={@tab == :settings} class="p-6 space-y-6">
              <form phx-change="settings_changed" class="space-y-4">
                <input type="hidden" name="name" value={@selected} />

                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Model</label>
                    <select name="model" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
                      <%= for {id, label, _provider} <- @models do %>
                        <option value={id} selected={id == selected_field(@instances, @selected, :model)}><%= label %></option>
                      <% end %>
                    </select>
                  </div>

                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Runtime</label>
                    <select name="bot_runtime" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
                      <option :for={name <- Druzhok.Runtime.names()} value={name} selected={name == (selected_field(@instances, @selected, :bot_runtime) || "zeroclaw")}><%= name %></option>
                    </select>
                  </div>

                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Heartbeat interval</label>
                    <select name="heartbeat" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
                      <%= for {val, label} <- heartbeat_options() do %>
                        <option value={val} selected={val == (selected_field(@instances, @selected, :heartbeat_interval) || 0)}><%= label %></option>
                      <% end %>
                    </select>
                  </div>

                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Daily token limit</label>
                    <input type="number" name="token_limit" min="0" step="100000"
                           value={selected_field(@instances, @selected, :daily_token_limit) || 0}
                           class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono" />
                  </div>

                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Language</label>
                    <select name="language" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
                      <option value="ru" selected={selected_field(@instances, @selected, :language) == "ru"}>Russian</option>
                      <option value="en" selected={selected_field(@instances, @selected, :language) == "en"}>English</option>
                    </select>
                  </div>

                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Dream hour</label>
                    <select name="dream_hour" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
                      <option value="-1" selected={selected_field(@instances, @selected, :dream_hour) == -1}>Off</option>
                      <%= for h <- 0..23 do %>
                        <option value={h} selected={selected_field(@instances, @selected, :dream_hour) == h}><%= String.pad_leading("#{h}", 2, "0") %>:00</option>
                      <% end %>
                    </select>
                  </div>
                </div>
              </form>

              <hr class="border-gray-200" />

              <%!-- Telegram token --%>
              <div>
                <h3 class="text-sm font-medium text-gray-700 mb-2">Telegram Token</h3>
                <% token = selected_field(@instances, @selected, :telegram_token) %>
                <div :if={token} class="flex items-center gap-2">
                  <code class="text-xs bg-gray-100 px-2 py-1 rounded flex-1 truncate"><%= String.slice(token, 0, 10) %>...</code>
                  <button phx-click="remove_telegram_token" class="text-xs text-red-500 hover:text-red-700">Remove</button>
                </div>
                <form :if={!token} phx-submit="save_telegram_token" class="flex gap-2">
                  <input name="token" placeholder="Bot token" class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm" />
                  <button type="submit" class="px-3 py-2 bg-gray-900 text-white rounded-lg text-sm">Save</button>
                </form>
              </div>
            </div>

            <%!-- Usage tab --%>
            <.usage_tab :if={@tab == :usage} requests={@usage_requests} summary={@usage_summary} tool_stats={[]} instance_name={@selected} expanded_request={@expanded_request} />

            <%!-- Errors tab --%>
            <.errors_tab :if={@tab == :errors} errors={@instance_errors} instance_name={@selected} expanded={@expanded_error} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp model_short(model) do
    model |> String.split("/") |> List.last()
  end

  defp container_status_color("running"), do: "bg-green-500"
  defp container_status_color("exited"), do: "bg-red-400"
  defp container_status_color("not_found"), do: "bg-gray-300"
  defp container_status_color(_), do: "bg-yellow-400"

  defp runtime_badge_color("picoclaw"), do: "bg-amber-100 text-amber-700"
  defp runtime_badge_color(_), do: "bg-emerald-100 text-emerald-700"

  defp container_status_badge("running"), do: "bg-green-100 text-green-700"
  defp container_status_badge("exited"), do: "bg-red-100 text-red-700"
  defp container_status_badge("not_found"), do: "bg-gray-100 text-gray-500"
  defp container_status_badge(_), do: "bg-yellow-100 text-yellow-700"

  defp selected_field(instances, name, field) do
    case Enum.find(instances, &(&1.name == name)) do
      nil -> nil
      inst -> Map.get(inst, field)
    end
  end

  defp update_instance_field(name, changes, restart \\ false) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
      nil -> :ok
      inst ->
        inst |> Druzhok.Instance.changeset(changes) |> Druzhok.Repo.update()
        if restart do
          Druzhok.InstanceManager.stop(name)
        end
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

  defp list_instances do
    Druzhok.InstanceManager.list()
    |> Enum.map(fn inst ->
      inst
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.put(:container_status, Druzhok.BotManager.status(inst.name))
    end)
  end

  defp get_instance(name, socket) do
    Enum.find(socket.assigns.instances, & &1.name == name)
  end

  defp instance_workspace(name) do
    data_dir = Application.get_env(:druzhok, Druzhok.Repo)[:database]
    |> Path.dirname()

    Path.join([data_dir, "instances", name, "workspace"])
  end

  defp list_workspace_files(instance, subpath \\ "") do
    workspace = instance[:workspace] || instance_workspace(instance.name)
    target = if subpath == "", do: workspace, else: Path.join(workspace, subpath)
    if File.exists?(target) do
      File.ls!(target)
      |> Enum.map(fn name ->
        path = Path.join(target, name)
        stat = File.stat!(path)
        %{path: name, is_dir: stat.type == :directory, size: stat.size}
      end)
      |> Enum.sort_by(& {!&1.is_dir, &1.path})
    else
      []
    end
  end
end
