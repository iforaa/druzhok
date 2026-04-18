defmodule DruzhokWebWeb.ProcessesLive do
  use DruzhokWebWeb, :live_view

  @refresh_ms 5_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    {:ok, assign(socket,
      current_user: current_user,
      tree: build_tree(),
      selected_pid: nil,
      process_info: nil
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, tree: build_tree())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("inspect", %{"pid" => pid_str}, socket) do
    case parse_pid(pid_str) do
      nil -> {:noreply, socket}
      pid ->
        info = get_process_info(pid)
        {:noreply, assign(socket, selected_pid: pid_str, process_info: info)}
    end
  end

  def handle_event("close_inspect", _, socket) do
    {:noreply, assign(socket, selected_pid: nil, process_info: nil)}
  end

  # --- Build process tree ---

  defp build_tree do
    import Ecto.Query
    instances = Druzhok.Repo.all(from(i in Druzhok.Instance, where: i.active == true))

    Enum.map(instances, fn inst ->
      name = inst.name
      %{
        name: name,
        sup: find_process(name, :sup),
        telegram: find_process(name, :telegram),
        scheduler: find_process(name, :scheduler),
        sandbox: find_process(name, :sandbox),
        session_sup: find_process(name, :session_sup),
        sessions: find_sessions(name)
      }
    end)
  end

  defp find_process(instance_name, type) do
    case Registry.lookup(Druzhok.Registry, {instance_name, type}) do
      [{pid, _}] -> process_summary(pid)
      [] -> nil
    end
  end

  defp find_sessions(instance_name) do
    Registry.select(Druzhok.Registry, [
      {{{instance_name, :session, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.map(fn {chat_id, pid} ->
      Map.put(process_summary(pid), :chat_id, chat_id)
    end)
  end

  defp process_summary(pid) do
    case Process.info(pid, [:message_queue_len, :memory, :status, :current_function]) do
      nil -> %{pid: inspect(pid), alive: false}
      info ->
        %{
          pid: inspect(pid),
          alive: true,
          queue: info[:message_queue_len] || 0,
          memory: div(info[:memory] || 0, 1024),
          status: info[:status],
          function: format_function(info[:current_function])
        }
    end
  end

  defp get_process_info(pid) do
    case Process.info(pid, [
      :message_queue_len, :memory, :status, :current_function,
      :registered_name, :links, :monitors, :monitored_by,
      :heap_size, :stack_size, :reductions
    ]) do
      nil -> nil
      info ->
        state = try do
          :sys.get_state(pid, 1000)
          |> inspect(pretty: true, limit: 500, printable_limit: 500)
        catch
          _, _ -> "(timeout or not a GenServer)"
        end

        %{
          pid: inspect(pid),
          name: info[:registered_name],
          queue: info[:message_queue_len],
          memory: div(info[:memory] || 0, 1024),
          heap: info[:heap_size],
          stack: info[:stack_size],
          reductions: info[:reductions],
          status: info[:status],
          function: format_function(info[:current_function]),
          links: Enum.map(info[:links] || [], &inspect/1),
          monitors: length(info[:monitors] || []),
          monitored_by: length(info[:monitored_by] || []),
          state: state
        }
    end
  end

  defp format_function({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_function(nil), do: "-"
  defp format_function(other), do: inspect(other)

  defp parse_pid(pid_str) do
    try do
      cleaned = pid_str |> String.replace("#PID", "") |> String.trim()
      :erlang.list_to_pid(String.to_charlist(cleaned))
    rescue
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-bg">
      <%!-- Nav bar --%>
      <div class="border-b border-line px-6 py-3 flex items-center gap-4">
        <a href="/" class="font-display text-sm text-muted hover:text-accent transition">← Dashboard</a>
        <span class="text-faint">·</span>
        <span class="font-display text-[10px] uppercase tracking-wider2 text-accent border-b border-accent pb-0.5">Processes</span>
        <a href="/errors" class="font-display text-[10px] uppercase tracking-wider2 text-muted hover:text-err transition">Errors</a>
        <a href="/settings" class="font-display text-[10px] uppercase tracking-wider2 text-muted hover:text-fg transition">Settings</a>
      </div>

      <div class="p-5 flex gap-5 max-w-5xl">
        <%!-- Process Tree --%>
        <div class="flex-1 space-y-3">
          <%= for inst <- @tree do %>
            <div class="bg-raised/50 border border-line rounded-lg p-3">
              <h3 class="label mb-2"><%= inst.name %></h3>
              <div class="space-y-0.5">
                <.proc_row label="Supervisor" info={inst.sup} selected={@selected_pid} />
                <.proc_row label="Telegram" info={inst.telegram} selected={@selected_pid} />
                <.proc_row label="Scheduler" info={inst.scheduler} selected={@selected_pid} />
                <.proc_row label="Sandbox" info={inst.sandbox} selected={@selected_pid} />
                <.proc_row label="SessionSup" info={inst.session_sup} selected={@selected_pid} />

                <%= if inst.sessions != [] do %>
                  <div class="ml-3 space-y-0.5">
                    <%= for s <- inst.sessions do %>
                      <.proc_row label={"Session #{s.chat_id}"} info={s} selected={@selected_pid} />
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <div :if={@tree == []} class="text-subtle text-center py-6 text-xs">No active instances</div>
        </div>

        <%!-- Process Inspector --%>
        <div :if={@process_info} class="w-80 bg-raised/50 border border-line rounded-lg p-3 sticky top-5 self-start">
          <div class="flex items-center justify-between mb-2">
            <h3 class="label">Inspector</h3>
            <button phx-click="close_inspect" class="text-muted hover:text-fg text-xs">×</button>
          </div>

          <div class="space-y-1 text-[10px]">
            <div><span class="text-muted">PID:</span> <span class="font-mono text-fg"><%= @process_info.pid %></span></div>
            <div :if={@process_info.name}><span class="text-muted">Name:</span> <span class="font-mono text-fg"><%= inspect(@process_info.name) %></span></div>
            <div><span class="text-muted">Status:</span> <span class="text-fg"><%= @process_info.status %></span></div>
            <div><span class="text-muted">Function:</span> <span class="font-mono text-fg"><%= @process_info.function %></span></div>
            <div><span class="text-muted">Queue:</span> <span class={"font-mono #{if @process_info.queue > 0, do: "text-warn font-bold", else: "text-fg"}"}><%= @process_info.queue %></span></div>
            <div><span class="text-muted">Memory:</span> <span class="font-mono text-fg"><%= @process_info.memory %>KB</span></div>
            <div><span class="text-muted">Heap:</span> <span class="font-mono text-fg"><%= @process_info.heap %></span></div>
            <div><span class="text-muted">Reductions:</span> <span class="font-mono text-fg"><%= @process_info.reductions %></span></div>
            <div><span class="text-muted">Links:</span> <span class="text-fg"><%= length(@process_info.links) %></span></div>
            <div><span class="text-muted">Monitors:</span> <span class="text-fg"><%= @process_info.monitors %></span></div>

            <div class="mt-2">
              <div class="text-muted mb-0.5">State:</div>
              <pre class="bg-raised rounded p-2 overflow-x-auto whitespace-pre-wrap max-h-56 overflow-y-auto border border-line text-[9px] font-mono text-fg"><%= @process_info.state %></pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp proc_row(assigns) do
    ~H"""
    <div :if={@info} class={"flex items-center gap-2 text-[10px] py-0.5 px-1.5 rounded cursor-pointer transition #{if @selected == @info.pid, do: "bg-accent/10 border border-accent/20", else: "hover:bg-raised"}"}
         phx-click="inspect" phx-value-pid={@info.pid}>
      <div class={"w-1.5 h-1.5 rounded-full #{if @info.alive, do: "bg-ok", else: "bg-err"}"}></div>
      <span class="text-muted w-16 truncate"><%= @label %></span>
      <span class="font-mono text-subtle"><%= @info.pid %></span>
      <span :if={@info[:queue] && @info.queue > 0} class="text-warn font-mono">q:<%= @info.queue %></span>
      <span class="text-faint font-mono ml-auto"><%= @info[:memory] || 0 %>KB</span>
    </div>
    <div :if={is_nil(@info)} class="flex items-center gap-2 text-[10px] py-0.5 px-1.5 text-subtle">
      <div class="w-1.5 h-1.5 rounded-full bg-faint"></div>
      <span><%= @label %> — not running</span>
    </div>
    """
  end
end
