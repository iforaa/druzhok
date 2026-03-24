defmodule DruzhokWebWeb.DashboardLive do
  use DruzhokWebWeb, :live_view

  import DruzhokWebWeb.Live.Components.EventLog
  import DruzhokWebWeb.Live.Components.FileBrowser
  import DruzhokWebWeb.Live.Components.SecurityTab

  @max_events 200
  @valid_tabs %{"logs" => :logs, "files" => :files, "security" => :security}

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

  def handle_event("create", %{"name" => name, "token" => token, "model" => model} = params, socket) do
    if name != "" and token != "" do
      workspace = instance_workspace(name)
      sandbox = params["sandbox"] || "local"

      case Druzhok.InstanceManager.create(name, %{
        workspace: workspace,
        model: model,
        telegram_token: token,
        sandbox: sandbox,
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
    case Map.get(@valid_tabs, tab) do
      nil -> {:noreply, socket}
      atom_tab -> {:noreply, assign(socket, tab: atom_tab)}
    end
  end

  def handle_event("clear_events", _, socket) do
    {:noreply, assign(socket, events: [])}
  end

  def handle_event("view_file", %{"path" => path}, socket) do
    if socket.assigns.selected do
      instance = get_instance(socket.assigns.selected, socket)
      if instance do
        content = if instance[:sandbox] == "docker" do
          case Druzhok.Sandbox.Docker.read_file(instance.name, "/workspace/#{path}") do
            {:ok, c} -> c
            {:error, _} -> "Cannot read file"
          end
        else
          full_path = Path.join(instance_workspace(socket.assigns.selected), path)
          case File.read(full_path) do
            {:ok, c} -> c
            {:error, _} -> "Cannot read file"
          end
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

  def handle_event("update_group_activation", %{"name" => name, "chat_id" => chat_id, "activation" => activation}, socket) do
    chat_id = String.to_integer(chat_id)
    Druzhok.AllowedChat.set_activation(name, chat_id, activation)
    if activation == "buffer", do: Druzhok.GroupBuffer.clear(name, chat_id)
    groups = Druzhok.AllowedChat.groups_for_instance(name)
    {:noreply, assign(socket, groups: groups)}
  end

  def handle_event("update_group_buffer_size", %{"name" => name, "chat_id" => chat_id, "value" => size}, socket) do
    chat_id = String.to_integer(chat_id)
    size = size |> String.to_integer() |> max(1) |> min(500)
    case Druzhok.AllowedChat.get(name, chat_id) do
      nil -> :ok
      chat -> Druzhok.AllowedChat.changeset(chat, %{buffer_size: size}) |> Druzhok.Repo.update()
    end
    groups = Druzhok.AllowedChat.groups_for_instance(name)
    {:noreply, assign(socket, groups: groups)}
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
            <input name="token" value={@create_form["token"]} placeholder="Telegram bot token"
                   class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900 focus:border-gray-900" />
            <select name="model" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
              <option :for={{id, label, _provider} <- @models} value={id}><%= label %></option>
            </select>
            <select name="sandbox" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
              <option value="local">Local</option>
              <option value="docker">Docker</option>
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
            <% sb = selected_sandbox(@instances, @selected) %>
            <span class={"px-2 py-0.5 rounded text-[10px] font-medium #{if sb == "docker", do: "bg-blue-100 text-blue-700", else: "bg-gray-100 text-gray-500"}"}><%= sb %></span>

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
            <.event_log :if={@tab == :logs} events={@events} />

            <%!-- Files tab --%>
            <.file_browser :if={@tab == :files} files={@workspace_files} file_content={@file_content} />

            <%!-- Security tab --%>
            <.security_tab :if={@tab == :security} pairing={@pairing} owner={@owner} groups={@groups} instance_name={@selected} />
          </div>
        </div>
      </div>
    </div>
    """
  end

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

  defp selected_sandbox(instances, name) do
    case Enum.find(instances, &(&1.name == name)) do
      nil -> "local"
      inst -> inst[:sandbox] || "local"
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
    if instance[:sandbox] in ["docker", "firecracker"] do
      mod = Druzhok.Sandbox.impl(instance[:sandbox])
      case mod.list_dir(instance.name, "/workspace") do
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
  end

end
