defmodule DruzhokWebWeb.DashboardLive do
  use DruzhokWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5_000, self(), :refresh)
    end

    {:ok, assign(socket,
      instances: list_instances(),
      create_form: %{"name" => "", "token" => "", "model" => "Qwen/Qwen3.5-397B-A17B"},
      selected: nil,
      workspace_files: [],
      file_content: nil,
      logs: nil
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, instances: list_instances())}
  end

  @impl true
  def handle_event("create", %{"name" => name, "token" => token, "model" => model}, socket) do
    if name != "" and token != "" do
      workspace = Path.join([File.cwd!(), "..", "data", "instances", name, "workspace"])

      case Druzhok.InstanceManager.create(name, %{
        workspace: workspace,
        model: model,
        api_url: Application.get_env(:pi_core, :api_url),
        api_key: Application.get_env(:pi_core, :api_key),
        telegram_token: token,
      }) do
        {:ok, _instance} ->
          {:noreply, assign(socket,
            instances: list_instances(),
            create_form: %{"name" => "", "token" => "", "model" => model}
          )}
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Ошибка: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Заполни имя и токен")}
    end
  end

  def handle_event("stop", %{"name" => name}, socket) do
    case get_instance(name) do
      nil -> :ok
      instance -> Druzhok.InstanceManager.stop(instance)
    end
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("select", %{"name" => name}, socket) do
    case get_instance(name) do
      nil ->
        {:noreply, socket}
      instance ->
        files = list_workspace_files(instance)
        {:noreply, assign(socket, selected: name, workspace_files: files, file_content: nil, logs: nil)}
    end
  end

  def handle_event("view_file", %{"path" => path}, socket) do
    if socket.assigns.selected do
      instance = get_instance(socket.assigns.selected)
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

  def handle_event("back", _, socket) do
    {:noreply, assign(socket, selected: nil, workspace_files: [], file_content: nil, logs: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6">
      <h1 class="text-2xl font-bold mb-6">Druzhok Dashboard</h1>

      <%!-- Create form --%>
      <div class="bg-gray-800 rounded-lg p-4 mb-6">
        <h2 class="text-lg font-semibold mb-3">Новый экземпляр</h2>
        <form phx-submit="create" class="flex gap-3 flex-wrap">
          <input name="name" value={@create_form["name"]} placeholder="Имя"
                 class="bg-gray-900 border border-gray-700 rounded px-3 py-2 text-white flex-1 min-w-[150px]" />
          <input name="token" value={@create_form["token"]} placeholder="Telegram Bot Token"
                 class="bg-gray-900 border border-gray-700 rounded px-3 py-2 text-white flex-1 min-w-[200px]" />
          <select name="model" class="bg-gray-900 border border-gray-700 rounded px-3 py-2 text-white">
            <option value="Qwen/Qwen3.5-397B-A17B">Qwen 3.5 397B</option>
            <option value="zai-org/GLM-5">GLM-5</option>
            <option value="moonshotai/Kimi-K2.5-fast">Kimi K2.5</option>
            <option value="meta-llama/Llama-3.3-70B-Instruct-fast">Llama 3.3 70B</option>
          </select>
          <button type="submit" class="bg-blue-600 hover:bg-blue-700 px-4 py-2 rounded text-white font-medium">
            Создать
          </button>
        </form>
      </div>

      <%!-- Instance list --%>
      <div :if={!@selected} class="space-y-2">
        <div :if={@instances == []} class="text-gray-500">Нет экземпляров</div>
        <div :for={inst <- @instances} class="bg-gray-800 rounded-lg p-4 flex items-center gap-4 cursor-pointer hover:bg-gray-750"
             phx-click="select" phx-value-name={inst.name}>
          <div class="flex-1">
            <span class="font-semibold"><%= inst.name %></span>
            <span class="text-gray-400 text-sm ml-2"><%= inst.model %></span>
          </div>
          <span class="px-2 py-1 rounded-full text-xs font-semibold bg-green-900 text-green-400">running</span>
          <button phx-click="stop" phx-value-name={inst.name}
                  class="bg-red-600 hover:bg-red-700 px-3 py-1 rounded text-sm text-white"
                  onclick="event.stopPropagation()">
            Стоп
          </button>
        </div>
      </div>

      <%!-- Workspace viewer --%>
      <div :if={@selected} class="bg-gray-800 rounded-lg p-4">
        <button phx-click="back" class="bg-gray-700 hover:bg-gray-600 px-3 py-1 rounded text-sm mb-4">← Назад</button>
        <h2 class="text-lg font-semibold mb-3">Workspace: <%= @selected %></h2>

        <div :if={@file_content} class="mb-4">
          <h3 class="text-sm text-gray-400 mb-2"><%= @file_content.path %></h3>
          <pre class="bg-gray-900 p-4 rounded text-sm overflow-auto max-h-96 whitespace-pre-wrap"><%= @file_content.content %></pre>
          <button phx-click="select" phx-value-name={@selected} class="mt-2 text-blue-400 text-sm hover:underline">
            ← К файлам
          </button>
        </div>

        <div :if={!@file_content}>
          <div :for={file <- @workspace_files}
               class="flex items-center gap-2 py-2 px-3 hover:bg-gray-700 rounded cursor-pointer"
               phx-click="view_file" phx-value-path={file.path}>
            <span :if={file.is_dir}>📁</span>
            <span :if={!file.is_dir}>📄</span>
            <span class="flex-1"><%= file.path %></span>
            <span :if={!file.is_dir} class="text-gray-500 text-xs"><%= format_size(file.size) %></span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  # For now, instances are tracked in process dictionary (will use Ecto later)
  defp list_instances do
    case Process.whereis(Druzhok.InstanceRegistry) do
      nil -> []
      _ -> Agent.get(Druzhok.InstanceRegistry, & &1)
    end
  rescue
    _ -> []
  end

  defp get_instance(name) do
    Enum.find(list_instances(), & &1.name == name)
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
