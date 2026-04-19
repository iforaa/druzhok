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
      :timer.send_interval(15_000, self(), :refresh)
      Druzhok.Events.subscribe_all()
      send(self(), :load_instances)
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

    # Render immediately with lightweight instance list (no docker stats).
    # Full stats load async via :load_instances message.
    {:ok, assign(socket,
      current_user: current_user,
      instances: list_instances_fast(),
      models: models,
      create_form: %{"name" => "", "token" => "", "model" => default_model, "bot_runtime" => "hermes"},
      selected: nil,
      tab: :settings,
      tab_loading: false,
      events: [],
      show_create: false,
      pairing_requests: [],
      allowed_users: [],
      instance_errors: [],
      expanded_error: nil,
      usage_requests: [],
      usage_summary: [],
      expanded_request: nil,
      palette_open: false,
      palette_query: "",
      palette_cursor: 0
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
  def handle_info(:load_instances, socket) do
    {:noreply, assign_instances_if_changed(socket, list_instances())}
  end

  def handle_info(:refresh, socket) do
    if socket.assigns[:selected] == nil do
      {:noreply, assign_instances_if_changed(socket, list_instances())}
    else
      {:noreply, socket}
    end
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

  def handle_event("update_create_form", params, socket) do
    {:noreply, assign(socket, create_form: Map.merge(socket.assigns.create_form, params))}
  end

  def handle_event("create", %{"name" => name, "model" => model} = params, socket) do
    if name != "" do
      token = params["token"]
      token = if token == "", do: nil, else: token
      bot_runtime = params["bot_runtime"] || "hermes"

      case Druzhok.BotManager.create(name, %{
        model: model,
        telegram_token: token,
        bot_runtime: bot_runtime,
      }) do
        {:ok, _instance} ->
          {:noreply, assign(socket,
            instances: list_instances(),
            create_form: %{"name" => "", "token" => "", "model" => model, "bot_runtime" => bot_runtime},
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
         |> assign(selected: name, tab: :settings, events: [])
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

  # --- Command palette (⌘K / Ctrl+K) -----------------------------------------
  def handle_event("toggle_palette", _, socket) do
    {:noreply, reset_palette(socket, open: !socket.assigns.palette_open)}
  end

  def handle_event("close_palette", _, socket) do
    {:noreply, reset_palette(socket, open: false)}
  end

  def handle_event("palette_query", %{"q" => q}, socket) do
    {:noreply, assign(socket, palette_query: q, palette_cursor: 0)}
  end

  def handle_event("palette_move", %{"dir" => dir}, socket) do
    total = length(palette_matches(socket.assigns.instances, socket.assigns.palette_query))
    cursor =
      if total == 0, do: 0,
         else: rem(socket.assigns.palette_cursor + dir + total, total)
    {:noreply, assign(socket, palette_cursor: cursor)}
  end

  def handle_event("palette_select", _, socket) do
    case Enum.at(
           palette_matches(socket.assigns.instances, socket.assigns.palette_query),
           socket.assigns.palette_cursor
         ) do
      nil -> {:noreply, reset_palette(socket, open: false)}
      inst ->
        {:noreply,
         socket
         |> reset_palette(open: false)
         |> push_patch(to: "/instances/#{inst.name}")}
    end
  end

  def handle_event("palette_pick", %{"name" => name}, socket) do
    {:noreply,
     socket
     |> reset_palette(open: false)
     |> push_patch(to: "/instances/#{name}")}
  end

  defp reset_palette(socket, open: open) do
    assign(socket, palette_open: open, palette_query: "", palette_cursor: 0)
  end

  defp palette_matches(instances, ""), do: instances
  defp palette_matches(instances, q) do
    q = String.downcase(q)
    Enum.filter(instances, fn inst ->
      String.contains?(String.downcase(inst.name), q) or
        String.contains?(String.downcase(inst[:bot_runtime] || ""), q) or
        String.contains?(String.downcase(inst.model || ""), q)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="dashboard-root" phx-hook="CmdK" class="flex h-screen bg-bg text-fg">
      <%!-- ══════════════════════════════ SIDEBAR ══════════════════════════════ --%>
      <aside class="w-72 bg-panel border-r border-line flex flex-col scanlines relative">
        <%!-- Brand --%>
        <div class="px-5 py-5 border-b border-line flex items-center justify-between">
          <a href="/" class="group flex items-center gap-2.5">
            <span class="w-1.5 h-1.5 bg-accent rounded-full group-hover:animate-dot-pulse"></span>
            <span class="font-display text-[13px] font-semibold tracking-caps uppercase">Druzhok</span>
          </a>
          <button phx-click="toggle_create"
                  aria-label="Create instance"
                  class={"w-7 h-7 flex items-center justify-center border font-display text-sm transition " <>
                         if @show_create,
                           do: "bg-accent border-accent text-bg",
                           else: "border-line2 text-muted hover:border-accent hover:text-accent"}>
            <%= if @show_create, do: "×", else: "+" %>
          </button>
        </div>

        <%!-- Create form --%>
        <div :if={@show_create} class="px-5 py-4 border-b border-line space-y-3 animate-reveal">
          <form phx-submit="create" phx-change="update_create_form" class="space-y-3">
            <.term_input name="name" value={@create_form["name"]} placeholder="instance name" />
            <.term_input name="token" value={@create_form["token"]} placeholder="telegram token (optional)" />
            <.term_select name="model">
              <option :for={{id, label, _provider} <- @models} value={id}
                      selected={id == @create_form["model"]}>
                <%= label %>
              </option>
            </.term_select>
            <.term_select name="bot_runtime">
              <option :for={name <- Druzhok.Runtime.names()} value={name}
                      selected={name == (@create_form["bot_runtime"] || "hermes")}>
                <%= String.upcase(name) %>
              </option>
            </.term_select>
            <button type="submit"
                    class="w-full bg-accent text-bg font-display uppercase tracking-wider2 text-xs py-2 hover:bg-fg hover:text-bg transition-colors">
              Create instance
            </button>
          </form>
        </div>

        <%!-- Instance list --%>
        <div class="flex-1 overflow-y-auto py-1">
          <div :if={@instances == []} class="px-5 py-10 text-center text-subtle text-xs font-display uppercase tracking-wider2">
            no instances yet
          </div>

          <div :for={{inst, idx} <- Enum.with_index(@instances)}
               phx-click="select"
               phx-value-name={inst.name}
               style={"animation-delay: #{idx * 28}ms"}
               class={[
                 "relative group flex items-center gap-3 px-5 py-3 cursor-pointer transition-all animate-reveal",
                 !inst[:active] && "opacity-55",
                 @selected == inst.name && "bg-raised",
                 "hover:bg-raised/60"
               ]}>
            <%!-- accent bar, expands on selection --%>
            <span class={[
              "absolute left-0 top-0 bottom-0 w-[2px] bg-accent transition-all duration-200",
              (if @selected == inst.name, do: "opacity-100 scale-y-100", else: "opacity-0 scale-y-0")
            ]}></span>

            <span class={[
              "w-1.5 h-1.5 rounded-full flex-shrink-0",
              status_dot(inst),
              (if inst[:container_status] in ["restarting", "starting"], do: "animate-dot-pulse")
            ]}></span>

            <div class="flex-1 min-w-0">
              <div class="font-display text-sm text-fg truncate"><%= inst.name %></div>
              <div class="text-[10px] text-muted uppercase tracking-wider2 font-display truncate">
                <%= String.upcase(inst[:bot_runtime] || "hermes") %>
                <span class="text-faint">·</span>
                <%= model_short(inst.model) %><%= if !inst[:active], do: " · stopped" %>
              </div>
            </div>
          </div>
        </div>

        <%!-- User footer --%>
        <div :if={@current_user} class="px-5 py-4 border-t border-line">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <div class="font-display text-xs text-fg truncate"><%= @current_user.email %></div>
              <div class="text-[10px] text-subtle uppercase tracking-wider2 font-display"><%= @current_user.role %></div>
            </div>
            <button phx-click="toggle_palette"
                    title="Command palette (⌘K)"
                    class="text-[10px] font-display uppercase tracking-wider2 text-muted hover:text-accent border border-line2 px-1.5 py-0.5 transition-colors">
              ⌘K
            </button>
          </div>
          <div class="mt-3 flex gap-4 text-[10px] font-display uppercase tracking-wider2">
            <a href="/processes" class="text-muted hover:text-fg transition-colors">procs</a>
            <a href="/errors" class="text-muted hover:text-err transition-colors">errors</a>
            <a :if={@current_user.role == "admin"} href="/settings"
               class="text-muted hover:text-accent transition-colors">settings</a>
            <a href="/auth/logout" class="ml-auto text-muted hover:text-fg transition-colors">logout</a>
          </div>
        </div>
      </aside>

      <%!-- ══════════════════════════════ MAIN ══════════════════════════════ --%>
      <main class="flex-1 flex flex-col min-w-0 relative">
        <%!-- Empty state --%>
        <div :if={!@selected} class="flex-1 flex items-center justify-center">
          <div class="text-center">
            <div class="text-6xl mb-5 grayscale opacity-60">&#128054;</div>
            <div class="font-display uppercase tracking-caps text-sm text-muted">select an instance</div>
            <div class="mt-2 text-xs text-subtle font-display tracking-wider2">
              press <kbd class="border border-line2 px-1.5 py-0.5 text-fg">⌘K</kbd>
              <span class="mx-1">or</span>
              <span class="text-fg">+</span>
              <span class="ml-1">to create one</span>
            </div>
          </div>
        </div>

        <div :if={@selected} class="flex-1 flex flex-col min-h-0">
          <%!-- Top bar --%>
          <% runtime = selected_field(@instances, @selected, :bot_runtime) || "hermes" %>
          <% status  = selected_field(@instances, @selected, :container_status) || "unknown" %>
          <% stats   = selected_field(@instances, @selected, :container_stats) %>
          <% active? = selected_field(@instances, @selected, :active) %>

          <div class="px-6 py-3.5 border-b border-line flex items-center gap-5">
            <button phx-click="back"
                    class="font-display text-muted hover:text-accent transition-colors text-sm">
              ←
            </button>

            <h2 class="font-display text-base text-fg truncate"><%= @selected %></h2>

            <%!-- Runtime: uppercase label + 1px accent underline --%>
            <span class="font-display text-[10px] uppercase tracking-caps text-fg border-b border-accent pb-0.5 px-0.5"><%= String.upcase(runtime) %></span>

            <%!-- Status dot + text --%>
            <span class="flex items-center gap-1.5">
              <span class={[
                "w-1.5 h-1.5 rounded-full",
                status_dot_color(status),
                (if status in ["restarting", "starting"], do: "animate-dot-pulse")
              ]}></span>
              <span class="font-display text-[10px] uppercase tracking-wider2 text-muted"><%= status %></span>
            </span>

            <%!-- mem this · all bots total · cpu --%>
            <span :if={stats} class="font-mono text-xs text-fg ml-auto flex items-center gap-2">
              <span><span class="text-muted">bot</span> <%= bot_mem(stats.mem) %></span>
              <span class="text-faint">·</span>
              <span><span class="text-muted">all</span> <%= total_mem_across_instances(@instances) %></span>
              <span class="text-faint">·</span>
              <span><span class="text-muted">cpu</span> <%= stats.cpu %></span>
            </span>

            <button :if={!active?} phx-click="start_bot" phx-value-name={@selected}
                    class="font-display uppercase tracking-wider2 text-[10px] text-ok hover:text-fg border border-line2 hover:border-ok px-2 py-1 transition-colors">
              ▶ start
            </button>
            <button :if={active?} phx-click="stop" phx-value-name={@selected}
                    class="font-display uppercase tracking-wider2 text-[10px] text-err hover:text-fg border border-line2 hover:border-err px-2 py-1 transition-colors">
              ■ stop
            </button>
          </div>

          <%!-- Tabs --%>
          <nav class="px-6 border-b border-line flex gap-0" role="tablist">
            <.tab_btn tab={:settings} active={@tab} label="settings" />
            <.tab_btn tab={:logs}   active={@tab} label="logs"     count={length(@events)} />
            <.tab_btn tab={:files}  active={@tab} label="files" />
            <.tab_btn tab={:usage}  active={@tab} label="usage" />
            <.tab_btn tab={:errors} active={@tab} label="errors" count={length(@instance_errors)} color={:err} />
          </nav>

          <%!-- Tab content --%>
          <div class="flex-1 overflow-y-auto relative">
            <div :if={@tab_loading} class="absolute inset-0 flex items-center justify-center bg-bg/80 z-10 backdrop-blur-sm">
              <div class="w-5 h-5 border border-faint border-t-accent rounded-full animate-spin"></div>
            </div>

            <.event_log :if={@tab == :logs} events={@events} />

            <.live_component :if={@tab == :files && @selected}
              module={FilesTab}
              id={"files-tab-#{@selected}"}
              instance={Enum.find(@instances, &(&1.name == @selected))} />

            <.live_component :if={@tab == :settings && @selected}
              module={SettingsTab}
              id={"settings-tab-#{@selected}"}
              instance={Enum.find(@instances, &(&1.name == @selected))}
              pairing_requests={@pairing_requests}
              allowed_users={@allowed_users} />

            <.usage_tab :if={@tab == :usage} requests={@usage_requests} summary={@usage_summary} tool_stats={[]} instance_name={@selected} expanded_request={@expanded_request} />

            <.errors_tab :if={@tab == :errors} errors={@instance_errors} instance_name={@selected} expanded={@expanded_error} />
          </div>
        </div>
      </main>

      <%!-- ═══════════════════════════ COMMAND PALETTE ═══════════════════════════ --%>
      <div :if={@palette_open}
           phx-click="close_palette"
           class="fixed inset-0 z-50 bg-bg/85 backdrop-blur-[2px] flex items-start justify-center pt-[18vh]">
        <div phx-click-away="close_palette"
             onclick="event.stopPropagation()"
             class="w-[560px] max-w-[90vw] bg-panel border border-line2 shadow-2xl scanlines animate-reveal">
          <form phx-change="palette_query" phx-submit="palette_select"
                class="flex items-center gap-3 border-b border-line px-4 py-3">
            <span class="font-display text-accent text-sm">›</span>
            <input id="palette-input" phx-hook="PaletteInput"
                   name="q" value={@palette_query}
                   placeholder="jump to instance…"
                   autocomplete="off" spellcheck="false"
                   class="flex-1 bg-transparent border-0 outline-none focus:ring-0 font-display text-sm text-fg placeholder:text-subtle p-0" />
            <span class="font-display text-[10px] text-subtle uppercase tracking-wider2">ESC</span>
          </form>

          <% matches = palette_matches(@instances, @palette_query) %>
          <div class="max-h-[40vh] overflow-y-auto">
            <div :if={matches == []} class="px-4 py-6 text-center text-subtle text-xs font-display uppercase tracking-wider2">
              no match
            </div>
            <button :for={{inst, i} <- Enum.with_index(matches)}
                    phx-click="palette_pick" phx-value-name={inst.name}
                    class={[
                      "w-full text-left px-4 py-2.5 flex items-center gap-3 transition-colors",
                      (if i == @palette_cursor, do: "bg-raised", else: "hover:bg-raised/50")
                    ]}>
              <span class={"w-1.5 h-1.5 rounded-full flex-shrink-0 #{status_dot(inst)}"}></span>
              <span class="font-display text-sm text-fg flex-1 truncate"><%= inst.name %></span>
              <span class="font-display text-[10px] text-muted uppercase tracking-wider2">
                <%= String.upcase(inst[:bot_runtime] || "hermes") %>
              </span>
              <span class="font-mono text-[10px] text-subtle"><%= model_short(inst.model) %></span>
            </button>
          </div>

          <div class="border-t border-line px-4 py-2 flex gap-4 text-[10px] font-display uppercase tracking-wider2 text-subtle">
            <span><kbd class="text-muted">↑↓</kbd> move</span>
            <span><kbd class="text-muted">↵</kbd> open</span>
            <span class="ml-auto"><kbd class="text-muted">esc</kbd> close</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Sub-components ─────────────────────────────────────────────────────────

  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: ""

  defp term_input(assigns) do
    ~H"""
    <input name={@name} value={@value} placeholder={@placeholder}
           autocomplete="off" spellcheck="false"
           class="w-full bg-transparent border-0 border-b border-line2 text-sm text-fg
                  placeholder:text-subtle px-0 py-1.5
                  focus:outline-none focus:border-accent focus:ring-0 transition-colors" />
    """
  end

  attr :name, :string, required: true
  slot :inner_block, required: true

  defp term_select(assigns) do
    ~H"""
    <select name={@name}
            class="w-full bg-transparent border-0 border-b border-line2 text-sm text-fg
                   px-0 py-1.5 focus:outline-none focus:border-accent focus:ring-0 transition-colors">
      <%= render_slot(@inner_block) %>
    </select>
    """
  end

  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true
  attr :count, :integer, default: 0
  attr :color, :atom, default: :accent

  defp tab_btn(assigns) do
    ~H"""
    <button phx-click="tab" phx-value-tab={Atom.to_string(@tab)}
            class={[
              "relative px-4 py-3 font-display uppercase tracking-wider2 text-[11px] transition-colors",
              (if @tab == @active, do: "text-fg", else: "text-muted hover:text-fg"),
              "after:absolute after:left-3 after:right-3 after:bottom-0 after:h-[2px]",
              "after:transition-transform after:duration-200 after:origin-left",
              (if @tab == @active,
                 do: "after:scale-x-100 " <> (if @color == :err, do: "after:bg-err", else: "after:bg-accent"),
                 else: "after:scale-x-0 after:bg-accent")
            ]}>
      <%= @label %>
      <span :if={@count > 0}
            class={[
              "ml-2 font-mono text-[10px]",
              (if @color == :err, do: "text-err", else: "text-muted")
            ]}><%= @count %></span>
    </button>
    """
  end

  # ── Style helpers ──────────────────────────────────────────────────────────

  defp model_short(model) when is_binary(model), do: model |> String.split("/") |> List.last()
  defp model_short(_), do: ""

  defp status_dot(inst) do
    cond do
      !inst[:active] -> "bg-idle"
      inst[:container_status] == "running" -> "bg-ok"
      inst[:container_status] in ["exited", "dead"] -> "bg-err"
      inst[:container_status] == "not_found" -> "bg-idle"
      true -> "bg-warn"
    end
  end

  defp status_dot_color("running"), do: "bg-ok"
  defp status_dot_color("exited"), do: "bg-err"
  defp status_dot_color("dead"), do: "bg-err"
  defp status_dot_color("not_found"), do: "bg-idle"
  defp status_dot_color(_), do: "bg-warn"

  defp selected_field(instances, name, field) do
    case Enum.find(instances, &(&1.name == name)) do
      nil -> nil
      inst -> Map.get(inst, field)
    end
  end

  # docker stats .MemUsage looks like "31.02MiB / 1.921GiB" — keep only the
  # actual-usage side; the denominator is just host RAM and misleads.
  defp bot_mem(mem_string) when is_binary(mem_string) do
    mem_string |> String.split("/") |> List.first() |> String.trim()
  end

  defp bot_mem(_), do: "-"

  defp total_mem_across_instances(instances) do
    instances
    |> Enum.map(&Map.get(&1, :container_stats))
    |> Enum.filter(& &1)
    |> Enum.map(&parse_mem_bytes(&1.mem))
    |> Enum.sum()
    |> format_bytes()
  end

  defp parse_mem_bytes(mem_string) when is_binary(mem_string) do
    case Regex.run(~r/^\s*([\d.]+)\s*(KiB|MiB|GiB|TiB|B)?/, mem_string) do
      [_, n, unit] ->
        value = String.to_float(if String.contains?(n, "."), do: n, else: n <> ".0")
        round(value * unit_factor(unit))

      _ ->
        0
    end
  end

  defp parse_mem_bytes(_), do: 0

  defp unit_factor("B"), do: 1
  defp unit_factor("KiB"), do: 1024
  defp unit_factor("MiB"), do: 1024 * 1024
  defp unit_factor("GiB"), do: 1024 * 1024 * 1024
  defp unit_factor("TiB"), do: 1024 * 1024 * 1024 * 1024
  defp unit_factor(_), do: 1

  defp format_bytes(bytes) when bytes >= 1024 * 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GiB"
  end

  defp format_bytes(bytes) when bytes >= 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024), 1)} MiB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KiB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"

  defp refresh_instance_in_list(instances, name) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
      nil ->
        instances

      fresh ->
        fresh_map = instance_to_map(fresh)

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
        data_root = Path.dirname(instance.workspace || "")

        # Merge both sources: DB allowlist + runtime's pairing file.
        # Hermes uses its own telegram-approved.json for users who pair
        # through the bot; druzhok stores manually-added IDs in the DB.
        db_ids = if runtime.supports_feature?(:db_allowlist),
          do: Druzhok.Instance.get_allowed_ids(instance), else: []
        file_ids = runtime.read_allowed_users(data_root)
          |> Enum.reject(&(&1 == "__closed__"))

        (db_ids ++ file_ids)
        |> Enum.uniq()
        |> Enum.sort()
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

  defp instance_to_map(inst), do: inst |> Map.from_struct() |> Map.drop([:__meta__])

  # Skip re-render if instance data (names + statuses) hasn't changed.
  defp assign_instances_if_changed(socket, new_instances) do
    old = socket.assigns[:instances] || []
    if instances_same?(old, new_instances),
      do: socket,
      else: assign(socket, instances: new_instances)
  end

  defp instances_same?(old, new) when length(old) != length(new), do: false
  defp instances_same?(old, new) do
    Enum.zip(old, new)
    |> Enum.all?(fn {o, n} ->
      o[:name] == n[:name] and o[:container_status] == n[:container_status] and
        o[:container_stats] == n[:container_stats] and o[:active] == n[:active]
    end)
  end

  # Fast listing: DB only, no docker calls. Used for initial render so the
  # page appears instantly. Full stats arrive via :load_instances async.
  defp list_instances_fast do
    Druzhok.InstanceManager.list()
    |> Enum.map(fn inst ->
      inst
      |> instance_to_map()
      |> Map.put(:container_status, if(inst.active, do: "loading", else: "stopped"))
      |> Map.put(:container_stats, nil)
    end)
  end

  defp list_instances do
    Druzhok.InstanceManager.list()
    |> Task.async_stream(
      fn inst ->
        container = Druzhok.BotManager.container_name(inst.name)

        [status_task, stats_task] =
          Enum.map(
            [
              fn -> Druzhok.BotManager.status_for_container(container) end,
              fn -> Druzhok.BotManager.stats_for_container(container) end
            ],
            &Task.async/1
          )

        inst
        |> instance_to_map()
        |> Map.put(:container_status, Task.await(status_task, 4_000))
        |> Map.put(:container_stats, Task.await(stats_task, 4_000))
      end,
      max_concurrency: 8,
      timeout: 6_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, inst} -> [inst]
      _ -> []
    end)
  end

  defp get_instance(name, socket) do
    Enum.find(socket.assigns.instances, & &1.name == name)
  end
end
