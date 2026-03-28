defmodule DruzhokWebWeb.DashboardLive do
  use DruzhokWebWeb, :live_view

  import DruzhokWebWeb.Live.Components.EventLog
  import DruzhokWebWeb.Live.Components.FileBrowser
  import DruzhokWebWeb.Live.Components.SecurityTab
  import DruzhokWebWeb.Live.Components.SkillsTab
  import DruzhokWebWeb.Live.Components.ErrorsTab
  import DruzhokWebWeb.Live.Components.UsageTab

  @max_events 200
  @valid_tabs %{"logs" => :logs, "files" => :files, "security" => :security, "skills" => :skills, "errors" => :errors, "usage" => :usage}

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
      skills: [],
      editing_skill: nil,
      instance_errors: [],
      expanded_error: nil,
      translating: false,
      editing_file: false,
      file_saved: false,
      usage_requests: [],
      usage_summary: [],
      tool_stats: [],
      expanded_request: nil
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
          current_path: "",
          events: [],
          pairing: Druzhok.InstanceManager.get_pairing(name),
          owner: Druzhok.InstanceManager.get_owner(name),
          groups: Druzhok.InstanceManager.get_groups(name),
          skills: load_skills(name),
          editing_skill: nil,
          instance_errors: [],
          expanded_error: nil
        )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, selected: nil, workspace_files: [], file_content: nil, events: [], pairing: nil, owner: nil, groups: [], skills: [], editing_skill: nil)}
  end

  def handle_info({:druzhok_event, instance_name, event}, socket) do
    if socket.assigns.selected == instance_name do
      events = [event | socket.assigns.events] |> Enum.take(@max_events)
      {:noreply, assign(socket, events: events)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:translation_done, socket) do
    {:noreply, assign(socket, translating: false)}
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

    changes = %{
      daily_token_limit: token_limit,
      dream_hour: dream_hour,
      heartbeat_interval: heartbeat,
      language: language
    }

    # Model change needs special handling (updates running session)
    if params["model"], do: Druzhok.InstanceManager.update_model(name, params["model"])

    # Heartbeat change needs special handling (updates scheduler timer)
    if params["heartbeat"], do: Druzhok.InstanceManager.update_heartbeat(name, heartbeat)

    # All other fields in one DB write
    update_instance_field(name, changes)

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
        # LlmRequest and ToolExecution tracking removed in v4 orchestrator
        {:noreply, assign(socket, tab: :usage, usage_requests: [], usage_summary: [], tool_stats: [])}
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
        full_path = Path.join(instance_workspace(socket.assigns.selected), full_rel)
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
        if instance[:sandbox] == "docker" do
          Druzhok.Sandbox.Docker.write_file(instance.name, "/workspace/#{path}", content)
        else
          full_path = Path.join(instance_workspace(socket.assigns.selected), path)
          File.write!(full_path, content)
        end
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

  def handle_event("translate_workspace", %{"lang" => ""}, socket), do: {:noreply, socket}
  def handle_event("translate_workspace", %{"name" => name, "lang" => lang}, socket) do
    me = self()
    Task.start(fn ->
      translate_workspace_files(name, lang)
      send(me, :translation_done)
    end)
    {:noreply, assign(socket, translating: true)}
  end

  def handle_event("save_skill", params, socket) do
    name = socket.assigns.selected
    skill_name = params["skill_name"]
    description = params["description"]
    content = params["content"]
    original_dir = params["original_dir"]

    if name && Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, skill_name) do
      workspace = instance_workspace(name)
      dir = Path.join([workspace, "skills", skill_name])
      File.mkdir_p!(dir)
      skill_content = "---\nname: #{skill_name}\ndescription: #{description}\nenabled: true\n---\n\n#{content}"
      File.write!(Path.join(dir, "SKILL.md"), skill_content)

      if original_dir && original_dir != "" && original_dir != skill_name do
        File.rm_rf!(Path.join([workspace, "skills", original_dir]))
      end

      {:noreply, assign(socket, skills: load_skills(name), editing_skill: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_skill", %{"skill" => dir}, socket) do
    skill = Enum.find(socket.assigns.skills, &(&1.dir == dir))
    {:noreply, assign(socket, editing_skill: skill)}
  end

  def handle_event("cancel_edit_skill", _, socket) do
    {:noreply, assign(socket, editing_skill: nil)}
  end

  def handle_event("delete_skill", %{"name" => name, "skill" => dir}, socket) do
    workspace = instance_workspace(name)
    File.rm_rf!(Path.join([workspace, "skills", dir]))
    {:noreply, assign(socket, skills: load_skills(name), editing_skill: nil)}
  end

  def handle_event("approve_skill", %{"name" => name, "skill" => dir}, socket) do
    workspace = instance_workspace(name)
    path = Path.join([workspace, "skills", dir, "SKILL.md"])
    case File.read(path) do
      {:ok, content} ->
        updated = String.replace(content, ~r/^pending_approval:\s*true$/m, "pending_approval: false")
        File.write!(path, updated)
      _ -> :ok
    end
    {:noreply, assign(socket, skills: load_skills(name))}
  end

  def handle_event("toggle_skill", %{"name" => name, "skill" => dir, "enabled" => enabled_str}, socket) do
    workspace = instance_workspace(name)
    path = Path.join([workspace, "skills", dir, "SKILL.md"])
    new_enabled = enabled_str == "true"
    case File.read(path) do
      {:ok, content} ->
        updated = if String.contains?(content, "enabled:") do
          String.replace(content, ~r/^enabled:\s*(true|false)$/m, "enabled: #{new_enabled}")
        else
          # Insert enabled field before closing --- of frontmatter
          case Regex.run(~r/\A(---\n.*?)\n(---)/s, content) do
            [_, header, _] -> String.replace(content, header <> "\n---", header <> "\nenabled: #{new_enabled}\n---", global: false)
            _ -> content
          end
        end
        File.write!(path, updated)
      _ -> :ok
    end
    {:noreply, assign(socket, skills: load_skills(name))}
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
              <option value="zeroclaw">ZeroClaw (Rust, lightweight)</option>
              <option value="picoclaw">PicoClaw (Go, 30+ channels)</option>
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
            <% sb = selected_field(@instances, @selected, :sandbox) || "local" %>
            <span class={"px-2 py-0.5 rounded text-[10px] font-medium #{if sb == "docker", do: "bg-blue-100 text-blue-700", else: "bg-gray-100 text-gray-500"}"}><%= sb %></span>

            <form phx-change="settings_changed" class="flex items-center gap-4">
              <input type="hidden" name="name" value={@selected} />

              <select name="model" class="border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900">
                <%= for {id, label, _provider} <- @models do %>
                  <option value={id} selected={id == selected_field(@instances, @selected, :model)}><%= label %></option>
                <% end %>
              </select>

              <div class="flex items-center gap-1">
                <span class="text-[10px] text-gray-400">HB</span>
                <select name="heartbeat" class="border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900">
                  <%= for {val, label} <- heartbeat_options() do %>
                    <option value={val} selected={val == (selected_field(@instances, @selected, :heartbeat_interval) || 0)}><%= label %></option>
                  <% end %>
                </select>
              </div>

              <div class="flex items-center gap-1">
                <span class="text-[10px] text-gray-400">Tokens/day</span>
                <input type="number" name="token_limit" min="0" step="100000"
                       value={selected_field(@instances, @selected, :daily_token_limit) || 0}
                       placeholder="0"
                       class="w-24 border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900 font-mono" />
              </div>

              <div class="flex items-center gap-1">
                <span class="text-[10px] text-gray-400">Dream</span>
                <select name="dream_hour" class="border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900">
                  <option value="-1" selected={selected_field(@instances, @selected, :dream_hour) == -1 or is_nil(selected_field(@instances, @selected, :dream_hour))}>Off</option>
                  <%= for h <- 0..23 do %>
                    <option value={h} selected={selected_field(@instances, @selected, :dream_hour) == h}><%= String.pad_leading("#{h}", 2, "0") %>:00</option>
                  <% end %>
                </select>
              </div>

              <div class="flex items-center gap-1">
                <select name="language" class="border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900" title="System messages language">
                  <option value="ru" selected={selected_field(@instances, @selected, :language) == "ru" or is_nil(selected_field(@instances, @selected, :language))}>🇷🇺</option>
                  <option value="en" selected={selected_field(@instances, @selected, :language) == "en"}>🇬🇧</option>
                </select>
              </div>

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
            <button phx-click="tab" phx-value-tab="skills"
                    class={"px-4 py-2.5 text-sm font-medium border-b-2 transition #{if @tab == :skills, do: "border-gray-900 text-gray-900", else: "border-transparent text-gray-400 hover:text-gray-600"}"}>
              Skills
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

            <%!-- Security tab --%>
            <.security_tab :if={@tab == :security} pairing={@pairing} owner={@owner} groups={@groups} instance_name={@selected}
              telegram_token={selected_field(@instances, @selected, :telegram_token)}
              api_key={selected_field(@instances, @selected, :api_key)} />

            <%!-- Skills tab --%>
            <.skills_tab :if={@tab == :skills} skills={@skills} instance_name={@selected} editing_skill={@editing_skill} />

            <%!-- Usage tab --%>
            <.usage_tab :if={@tab == :usage} requests={@usage_requests} summary={@usage_summary} tool_stats={@tool_stats} instance_name={@selected} expanded_request={@expanded_request} />

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

  # --- Helpers ---

  defp list_instances do
    Druzhok.InstanceManager.list()
    |> Enum.map(fn inst ->
      Map.put(inst, :container_status, Druzhok.BotManager.status(inst.name))
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

  defp load_skills(instance_name) do
    workspace = instance_workspace(instance_name)
    skills_dir = Path.join(workspace, "skills")

    if File.dir?(skills_dir) do
      case File.ls(skills_dir) do
        {:ok, dirs} ->
          dirs
          |> Enum.filter(&File.dir?(Path.join(skills_dir, &1)))
          |> Enum.map(fn dir ->
            path = Path.join([skills_dir, dir, "SKILL.md"])
            case File.read(path) do
              {:ok, content} ->
                body = case Regex.run(~r/\A---\n.*?\n---\n\n?(.*)/s, content) do
                  [_, b] -> b
                  nil -> content
                end
                case parse_skill_frontmatter(content) do
                  {:ok, name, desc, enabled, pending} ->
                    %{dir: dir, name: name, description: desc, enabled: enabled, pending: pending, body: body}
                  :error ->
                    %{dir: dir, name: dir, description: "(invalid)", enabled: false, pending: false, body: content}
                end
              {:error, _} -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.name)
        _ -> []
      end
    else
      []
    end
  end

  defp list_workspace_files(instance, subpath \\ "") do
    dir_path = if subpath == "", do: "/workspace", else: "/workspace/#{subpath}"
    if instance[:sandbox] in ["docker", "firecracker"] do
      mod = Druzhok.Sandbox.impl(instance[:sandbox])
      case mod.list_dir(instance.name, dir_path) do
        {:ok, data} when is_binary(data) ->
          case Jason.decode(data) do
            {:ok, entries} when is_list(entries) ->
              entries
              |> Enum.map(fn e ->
                %{path: e["name"], is_dir: e["is_dir"] == true, size: e["size"] || 0}
              end)
              |> Enum.sort_by(& {!&1.is_dir, &1.path})
            _ -> []
          end
        {:ok, entries} when is_list(entries) ->
          Enum.map(entries, fn e ->
            %{path: e[:name] || e["name"], is_dir: e[:is_dir] || e["is_dir"], size: e[:size] || e["size"] || 0}
          end)
          |> Enum.sort_by(& {!&1.is_dir, &1.path})
        _ -> []
      end
    else
      workspace = instance_workspace(instance.name)
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

  defp parse_skill_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, frontmatter] ->
        name = case Regex.run(~r/^name:\s*(.+)$/m, frontmatter) do
          [_, v] -> String.trim(v)
          _ -> nil
        end
        desc = case Regex.run(~r/^description:\s*(.+)$/m, frontmatter) do
          [_, v] -> String.trim(v)
          _ -> ""
        end
        enabled = case Regex.run(~r/^enabled:\s*(true|false)$/m, frontmatter) do
          [_, "false"] -> false
          _ -> true
        end
        pending = case Regex.run(~r/^pending_approval:\s*(true|false)$/m, frontmatter) do
          [_, "true"] -> true
          _ -> false
        end
        if name, do: {:ok, name, desc, enabled, pending}, else: :error
      _ -> :error
    end
  end

  defp translate_workspace_files(_instance_name, _lang) do
    # Translation via LLM is not available in v4 orchestrator mode.
    require Logger
    Logger.info("Workspace translation is not available in v4 orchestrator mode")
    :ok
  end
end
