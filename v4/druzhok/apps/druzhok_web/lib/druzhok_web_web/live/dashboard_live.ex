defmodule DruzhokWebWeb.DashboardLive do
  use DruzhokWebWeb, :live_view

  import DruzhokWebWeb.Live.Components.EventLog
  import DruzhokWebWeb.Live.Components.ErrorsTab
  import DruzhokWebWeb.Live.Components.UsageTab

  alias DruzhokWebWeb.Live.Components.{SettingsTab, FilesTab}

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
      tab_loading: false,
      events: [],
      show_create: false,
      pairing_requests: [],
      allowed_users: [],
      instance_errors: [],
      expanded_error: nil,
      usage_requests: [],
      usage_summary: [],
      expanded_request: nil
    )}
  end

  @impl true
  def handle_params(%{"name" => name} = params, _uri, socket) do
    case get_instance(name, socket) do
      nil ->
        {:noreply, socket |> assign(selected: nil) |> push_patch(to: "/")}
      _instance ->
        tab = Map.get(@valid_tabs, params["tab"], :logs)
        switched_instance = socket.assigns[:selected] != name

        socket = assign(socket, selected: name, tab: tab, tab_loading: true)

        if switched_instance do
          socket = assign(socket,
            events: [],
            expanded_error: nil,
            pairing_requests: [],
            allowed_users: [],
            instance_errors: [],
            usage_requests: [],
            usage_summary: []
          )
          send(self(), {:load_instance_data, name, tab})
          {:noreply, socket}
        else
          send(self(), {:load_tab_data, name, tab})
          {:noreply, socket}
        end
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket,
      selected: nil,
      events: [],
      pairing_requests: [],
      allowed_users: []
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_info({:druzhok_event, instance_name, %{type: :pairing_request} = _event}, socket) do
    if socket.assigns.selected == instance_name do
      {:noreply, assign(socket,
        pairing_requests: Druzhok.Pairing.pending_for_instance(instance_name)
      )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:druzhok_event, instance_name, event}, socket) do
    if socket.assigns.selected == instance_name do
      events = [event | socket.assigns.events] |> Enum.take(@max_events)
      {:noreply, assign(socket, events: events)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:load_instance_data, name, tab}, socket) do
    # Guard: user may have switched away
    if socket.assigns.selected == name do
      socket = assign(socket,
        pairing_requests: Druzhok.Pairing.pending_for_instance(name),
        allowed_users: load_allowed_users(name)
      )
      send(self(), {:load_tab_data, name, tab})
      {:noreply, socket}
    else
      {:noreply, assign(socket, tab_loading: false)}
    end
  end

  def handle_info({:load_tab_data, name, tab}, socket) do
    if socket.assigns.selected == name and socket.assigns.tab == tab do
      tab_assigns = load_tab_assigns(tab, name, get_instance(name, socket))
      {:noreply, assign(socket, Map.put(tab_assigns, :tab_loading, false))}
    else
      {:noreply, assign(socket, tab_loading: false)}
    end
  rescue
    _ -> {:noreply, assign(socket, tab_loading: false)}
  end

  def handle_info(:settings_updated, socket) do
    # Refresh only the selected instance from the DB. Container status/stats
    # stay cached — the next :refresh tick (≤5s) picks up docker changes.
    # Avoids an N*2 docker sweep on every settings keystroke.
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      name ->
        {:noreply,
         assign(socket,
           instances: refresh_instance_in_list(socket.assigns.instances, name),
           pairing_requests: Druzhok.Pairing.pending_for_instance(name),
           allowed_users: load_allowed_users(name)
         )}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_tab_assigns(:usage, _name, nil), do: %{}

  defp load_tab_assigns(:usage, _name, instance) do
    {reqs, summary} = load_usage_data(instance)
    %{usage_requests: reqs, usage_summary: summary}
  end

  defp load_tab_assigns(:errors, name, _instance) do
    %{instance_errors: Druzhok.CrashLog.recent_for_instance(name, 100)}
  end

  defp load_tab_assigns(_, _name, _instance), do: %{}

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

  def handle_event("stop", %{"name" => name}, socket) do
    Druzhok.BotManager.stop(name)
    Process.sleep(500)
    {:noreply, assign(socket, instances: list_instances())}
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

      _instance ->
        {:noreply,
         socket
         |> assign(selected: name, tab: :logs, events: [])
         |> push_patch(to: "/instances/#{name}")}
    end
  end

  def handle_event("tab", %{"tab" => tab}, socket) do
    if socket.assigns.selected && Map.has_key?(@valid_tabs, tab) do
      {:noreply, push_patch(socket, to: "/instances/#{socket.assigns.selected}/#{tab}")}
    else
      {:noreply, socket}
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

  def handle_event("back", _, socket) do
    {:noreply,
      socket
      |> assign(selected: nil, events: [])
      |> push_patch(to: "/")}
  end

  def handle_event("toggle_error", %{"id" => id}, socket) do
    expanded = if to_string(socket.assigns.expanded_error) == id, do: nil, else: id
    {:noreply, assign(socket, expanded_error: expanded)}
  end

  def handle_event("clear_errors", _, socket) do
    Druzhok.CrashLog.clear_all()
    {:noreply, assign(socket, instance_errors: [])}
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
               class={"flex items-center gap-3 px-4 py-3 cursor-pointer transition #{if !inst[:active], do: "opacity-50 "} #{if @selected == inst.name, do: "bg-white border-l-2 border-gray-900 shadow-sm", else: "hover:bg-white/60 border-l-2 border-transparent"}"}>
            <div class={"w-2 h-2 rounded-full flex-shrink-0 #{if inst[:active], do: container_status_color(inst[:container_status]), else: "bg-gray-300"}"}></div>
            <div class="flex-1 min-w-0">
              <div class="text-sm font-medium truncate"><%= inst.name %></div>
              <div class="text-xs text-gray-400 truncate"><%= inst[:bot_runtime] || "zeroclaw" %> &middot; <%= model_short(inst.model) %><%= unless inst[:active], do: " · stopped" %></div>
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
            <% stats = selected_field(@instances, @selected, :container_stats) %>
            <span :if={stats} class="text-[10px] text-gray-400 font-mono">
              <%= stats.mem %> · <%= stats.cpu %>
            </span>
            <% is_active = selected_field(@instances, @selected, :active) %>
            <button :if={!is_active} phx-click="start_bot" phx-value-name={@selected}
                    class="text-xs text-green-600 hover:text-green-800 transition font-medium">
              Start
            </button>
            <button :if={is_active} phx-click="stop" phx-value-name={@selected}
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
          <div class="flex-1 overflow-y-auto relative">
            <%!-- Loading spinner --%>
            <div :if={@tab_loading} class="absolute inset-0 flex items-center justify-center bg-white/80 z-10">
              <div class="w-6 h-6 border-2 border-gray-300 border-t-gray-900 rounded-full animate-spin"></div>
            </div>

            <%!-- Logs tab --%>
            <.event_log :if={@tab == :logs} events={@events} />

            <%!-- Files tab --%>
            <.live_component :if={@tab == :files && @selected}
              module={FilesTab}
              id={"files-tab-#{@selected}"}
              instance={Enum.find(@instances, &(&1.name == @selected))} />

            <%!-- Settings tab --%>
            <.live_component :if={@tab == :settings && @selected}
              module={SettingsTab}
              id={"settings-tab-#{@selected}"}
              instance={Enum.find(@instances, &(&1.name == @selected))}
              pairing_requests={@pairing_requests}
              allowed_users={@allowed_users} />

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

  defp runtime_badge_color("hermes"), do: "bg-rose-100 text-rose-700"
  defp runtime_badge_color("picoclaw"), do: "bg-amber-100 text-amber-700"
  defp runtime_badge_color("openclaw"), do: "bg-blue-100 text-blue-700"
  defp runtime_badge_color("nullclaw"), do: "bg-purple-100 text-purple-700"
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

  defp refresh_instance_in_list(instances, name) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
      nil ->
        instances

      fresh ->
        fresh_map = fresh |> Map.from_struct() |> Map.drop([:__meta__])

        Enum.map(instances, fn inst ->
          if inst.name == name do
            Map.merge(inst, fresh_map)
          else
            inst
          end
        end)
    end
  end

  defp load_allowed_users(name) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
      nil ->
        []

      instance ->
        runtime = Druzhok.Runtime.get(instance.bot_runtime, Druzhok.Runtime.ZeroClaw)

        if runtime.supports_feature?(:db_allowlist) do
          Druzhok.Instance.get_allowed_ids(instance)
        else
          data_root = Path.dirname(instance.workspace)

          data_root
          |> runtime.read_allowed_users()
          |> Enum.reject(&(&1 == "__closed__"))
        end
    end
  end

  defp load_usage_data(instance) do
    raw_requests = Druzhok.Usage.recent(instance[:id], 50)
    requests = Enum.map(raw_requests, fn r ->
      %{
        id: r.id,
        inserted_at: r.inserted_at,
        model: r.model,
        input_tokens: r.prompt_tokens || 0,
        output_tokens: r.completion_tokens || 0,
        tool_calls_count: 0,
        elapsed_ms: r.latency_ms,
        prompt_preview: r.prompt_preview,
        response_preview: r.response_preview,
        request_body: r.request_body,
        request_type: r.request_type || "chat",
        audio_duration_ms: r.audio_duration_ms
      }
    end)
    summary = Druzhok.Usage.daily_usage(instance[:id])
    {requests, summary}
  end

  defp list_instances do
    instances = Druzhok.InstanceManager.list()

    Enum.map(instances, fn inst ->
      container = Druzhok.BotManager.container_name(inst.name)
      status = Druzhok.BotManager.status_for_container(container)
      stats = Druzhok.BotManager.stats_for_container(container)

      inst
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.put(:container_status, status)
      |> Map.put(:container_stats, stats)
    end)
  end

  defp get_instance(name, socket) do
    Enum.find(socket.assigns.instances, & &1.name == name)
  end
end
