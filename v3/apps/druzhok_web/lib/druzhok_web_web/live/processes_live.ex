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
    # Find all session processes for this instance
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
    <div class="flex h-screen">
      <div class="w-72 bg-gray-50 border-r border-gray-200 flex flex-col">
        <div class="p-4 border-b border-gray-200">
          <a href="/" class="text-lg font-bold tracking-tight hover:text-gray-600 transition">&larr; Druzhok</a>
        </div>
        <div class="flex-1 flex items-center justify-center">
          <div class="text-center text-gray-400 text-sm">
            <div class="text-3xl mb-2">&#9881;</div>
            <div>Process Tree</div>
            <div class="text-xs mt-1">Refreshes every 5s</div>
          </div>
        </div>
        <div :if={@current_user} class="p-4 border-t border-gray-200">
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <div class="text-sm font-medium truncate"><%= @current_user.email %></div>
            </div>
            <a href="/auth/logout" class="text-xs text-gray-400 hover:text-gray-900 transition">Logout</a>
          </div>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto p-6">
        <div class="flex gap-6">
          <%!-- Process Tree --%>
          <div class="flex-1">
            <h2 class="text-lg font-bold mb-4">Process Tree</h2>

            <%= for inst <- @tree do %>
              <div class="mb-6 bg-white rounded-lg border border-gray-200 p-4">
                <h3 class="text-sm font-bold text-gray-900 mb-3"><%= inst.name %></h3>

                <div class="ml-4 space-y-1">
                  <.proc_row label="Supervisor" info={inst.sup} selected={@selected_pid} />
                  <.proc_row label="Telegram" info={inst.telegram} selected={@selected_pid} />
                  <.proc_row label="Scheduler" info={inst.scheduler} selected={@selected_pid} />
                  <.proc_row label="Sandbox" info={inst.sandbox} selected={@selected_pid} />
                  <.proc_row label="SessionSup" info={inst.session_sup} selected={@selected_pid} />

                  <%= if inst.sessions != [] do %>
                    <div class="ml-4 space-y-1">
                      <%= for s <- inst.sessions do %>
                        <.proc_row label={"Session #{s.chat_id}"} info={s} selected={@selected_pid} />
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <div :if={@tree == []} class="text-gray-400 text-center py-8">No active instances</div>
          </div>

          <%!-- Process Inspector --%>
          <div :if={@process_info} class="w-96 bg-white rounded-lg border border-gray-200 p-4 sticky top-6 self-start">
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-sm font-bold">Process Inspector</h3>
              <button phx-click="close_inspect" class="text-gray-400 hover:text-gray-900 text-xs">&times;</button>
            </div>

            <div class="space-y-2 text-xs">
              <div><span class="text-gray-500">PID:</span> <span class="font-mono"><%= @process_info.pid %></span></div>
              <div :if={@process_info.name}><span class="text-gray-500">Name:</span> <span class="font-mono"><%= inspect(@process_info.name) %></span></div>
              <div><span class="text-gray-500">Status:</span> <%= @process_info.status %></div>
              <div><span class="text-gray-500">Function:</span> <span class="font-mono"><%= @process_info.function %></span></div>
              <div><span class="text-gray-500">Queue:</span> <span class={"font-mono #{if @process_info.queue > 0, do: "text-orange-600 font-bold", else: ""}"}><%= @process_info.queue %></span></div>
              <div><span class="text-gray-500">Memory:</span> <span class="font-mono"><%= @process_info.memory %>KB</span></div>
              <div><span class="text-gray-500">Heap:</span> <span class="font-mono"><%= @process_info.heap %></span></div>
              <div><span class="text-gray-500">Reductions:</span> <span class="font-mono"><%= @process_info.reductions %></span></div>
              <div><span class="text-gray-500">Links:</span> <%= length(@process_info.links) %></div>
              <div><span class="text-gray-500">Monitors:</span> <%= @process_info.monitors %></div>

              <div class="mt-3">
                <div class="text-gray-500 mb-1">State:</div>
                <pre class="bg-gray-50 rounded p-2 overflow-x-auto whitespace-pre-wrap max-h-64 overflow-y-auto border border-gray-200 text-[10px] font-mono"><%= @process_info.state %></pre>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp proc_row(assigns) do
    ~H"""
    <div :if={@info} class={"flex items-center gap-2 text-xs py-1 px-2 rounded cursor-pointer transition #{if @selected == @info.pid, do: "bg-blue-50 border border-blue-200", else: "hover:bg-gray-50"}"}
         phx-click="inspect" phx-value-pid={@info.pid}>
      <div class={"w-2 h-2 rounded-full #{if @info.alive, do: "bg-green-500", else: "bg-red-500"}"}></div>
      <span class="text-gray-600 w-20 truncate"><%= @label %></span>
      <span class="font-mono text-gray-400"><%= @info.pid %></span>
      <span :if={@info[:queue] && @info.queue > 0} class="text-orange-600 font-mono">q:<%= @info.queue %></span>
      <span class="text-gray-300 font-mono ml-auto"><%= @info[:memory] || 0 %>KB</span>
    </div>
    <div :if={is_nil(@info)} class="flex items-center gap-2 text-xs py-1 px-2 text-gray-300">
      <div class="w-2 h-2 rounded-full bg-gray-200"></div>
      <span><%= @label %> — not running</span>
    </div>
    """
  end
end
