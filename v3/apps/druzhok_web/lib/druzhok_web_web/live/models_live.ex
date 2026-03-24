defmodule DruzhokWebWeb.ModelsLive do
  use DruzhokWebWeb, :live_view

  import Ecto.Query

  @impl true
  def mount(_params, session, socket) do
    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    unless current_user && current_user.role == "admin" do
      {:ok, redirect(socket, to: "/")}
    else
      {:ok, assign(socket,
        current_user: current_user,
        models: list_models(),
        editing: nil,
        form_model_id: "",
        form_label: "",
        form_provider: "openai",
        form_position: "0",
        form_context_window: "32000",
        form_supports_reasoning: false,
        form_supports_tools: true,
        error: nil,
        saved: false
      )}
    end
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket,
      editing: :new,
      form_model_id: "",
      form_label: "",
      form_provider: "openai",
      form_position: "0",
      form_context_window: "32000",
      form_supports_reasoning: false,
      form_supports_tools: true,
      error: nil,
      saved: false
    )}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    model = Druzhok.Repo.get(Druzhok.Model, String.to_integer(id))
    if model do
      {:noreply, assign(socket,
        editing: model.id,
        form_model_id: model.model_id,
        form_label: model.label,
        form_provider: model.provider || "openai",
        form_position: Integer.to_string(model.position || 0),
        form_context_window: Integer.to_string(model.context_window || 32000),
        form_supports_reasoning: model.supports_reasoning,
        form_supports_tools: model.supports_tools,
        error: nil,
        saved: false
      )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, error: nil, saved: false)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    model = Druzhok.Repo.get(Druzhok.Model, String.to_integer(id))
    if model do
      Druzhok.Repo.delete(model)
      Phoenix.PubSub.broadcast(DruzhokWeb.PubSub, "settings", {:models_updated})
    end
    {:noreply, assign(socket, models: list_models(), saved: false)}
  end

  @impl true
  def handle_event("save", params, socket) do
    attrs = %{
      model_id: params["model_id"] || "",
      label: params["label"] || "",
      provider: params["provider"] || "openai",
      position: parse_int(params["position"], 0),
      context_window: parse_int(params["context_window"], 32000),
      supports_reasoning: params["supports_reasoning"] == "true",
      supports_tools: params["supports_tools"] == "true"
    }

    result = case socket.assigns.editing do
      :new ->
        %Druzhok.Model{}
        |> Druzhok.Model.changeset(attrs)
        |> Druzhok.Repo.insert()

      id when is_integer(id) ->
        model = Druzhok.Repo.get(Druzhok.Model, id)
        model
        |> Druzhok.Model.changeset(attrs)
        |> Druzhok.Repo.update()

      _ ->
        {:error, :no_editing}
    end

    case result do
      {:ok, _model} ->
        Phoenix.PubSub.broadcast(DruzhokWeb.PubSub, "settings", {:models_updated})
        {:noreply, assign(socket,
          models: list_models(),
          editing: nil,
          error: nil,
          saved: true
        )}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        error_text = errors |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end) |> Enum.join("; ")
        {:noreply, assign(socket, error: error_text)}

      {:error, _} ->
        {:noreply, assign(socket, error: "Unexpected error")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-5xl mx-auto p-6">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-xl font-bold">Model Profiles</h1>
          <a href="/" class="text-sm text-gray-500 hover:text-gray-900">&larr; Dashboard</a>
        </div>

        <%!-- Models table --%>
        <div class="bg-white rounded-xl border border-gray-200 mb-6 overflow-hidden">
          <div class="flex items-center justify-between px-6 py-4 border-b border-gray-100">
            <h2 class="text-sm font-semibold">Models</h2>
            <button phx-click="new" class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1.5 text-xs font-medium transition">
              + Add Model
            </button>
          </div>

          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-xs text-gray-500 border-b border-gray-100">
                  <th class="text-left px-6 py-3 font-medium">Model ID</th>
                  <th class="text-left px-6 py-3 font-medium">Label</th>
                  <th class="text-left px-6 py-3 font-medium">Provider</th>
                  <th class="text-right px-6 py-3 font-medium">Position</th>
                  <th class="text-right px-6 py-3 font-medium">Context</th>
                  <th class="text-center px-6 py-3 font-medium">Reasoning</th>
                  <th class="text-center px-6 py-3 font-medium">Tools</th>
                  <th class="px-6 py-3"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={m <- @models} class="border-b border-gray-50 hover:bg-gray-50 transition">
                  <td class="px-6 py-3 font-mono text-xs text-gray-700"><%= m.model_id %></td>
                  <td class="px-6 py-3 text-gray-900"><%= m.label %></td>
                  <td class="px-6 py-3 text-gray-500"><%= m.provider %></td>
                  <td class="px-6 py-3 text-right text-gray-500"><%= m.position %></td>
                  <td class="px-6 py-3 text-right text-gray-500 font-mono text-xs"><%= format_number(m.context_window || 0) %></td>
                  <td class="px-6 py-3 text-center">
                    <span class={if m.supports_reasoning, do: "text-green-600", else: "text-gray-300"}>
                      <%= if m.supports_reasoning, do: "✓", else: "—" %>
                    </span>
                  </td>
                  <td class="px-6 py-3 text-center">
                    <span class={if m.supports_tools, do: "text-green-600", else: "text-gray-300"}>
                      <%= if m.supports_tools, do: "✓", else: "—" %>
                    </span>
                  </td>
                  <td class="px-6 py-3">
                    <div class="flex items-center gap-2 justify-end">
                      <button phx-click="edit" phx-value-id={m.id}
                              class="text-xs text-gray-500 hover:text-gray-900 transition">
                        Edit
                      </button>
                      <button phx-click="delete" phx-value-id={m.id}
                              data-confirm={"Delete #{m.label}?"}
                              class="text-xs text-red-500 hover:text-red-700 transition">
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
                <tr :if={@models == []}>
                  <td colspan="8" class="px-6 py-8 text-center text-sm text-gray-400">No models yet. Add one above.</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Add / Edit form --%>
        <div :if={@editing != nil} class="bg-white rounded-xl border border-gray-200 p-6">
          <h2 class="text-sm font-semibold mb-4"><%= if @editing == :new, do: "Add Model", else: "Edit Model" %></h2>

          <form phx-submit="save" class="space-y-4">
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-xs text-gray-500 mb-1">Model ID</label>
                <input name="model_id" value={@form_model_id}
                       placeholder="e.g. claude-3-5-sonnet"
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Label</label>
                <input name="label" value={@form_label}
                       placeholder="e.g. Claude 3.5 Sonnet"
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Provider</label>
                <select name="provider"
                        class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
                  <option value="openai" selected={@form_provider == "openai"}>openai</option>
                  <option value="anthropic" selected={@form_provider == "anthropic"}>anthropic</option>
                  <option value="openrouter" selected={@form_provider == "openrouter"}>openrouter</option>
                </select>
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Position</label>
                <input name="position" value={@form_position} type="number"
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Context Window (tokens)</label>
                <input name="context_window" value={@form_context_window} type="number"
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div class="flex flex-col justify-end gap-2 pb-1">
                <label class="flex items-center gap-2 text-sm text-gray-700 cursor-pointer">
                  <input type="hidden" name="supports_reasoning" value="false" />
                  <input type="checkbox" name="supports_reasoning" value="true"
                         checked={@form_supports_reasoning}
                         class="rounded border-gray-300 focus:ring-gray-900" />
                  Supports Reasoning
                </label>
                <label class="flex items-center gap-2 text-sm text-gray-700 cursor-pointer">
                  <input type="hidden" name="supports_tools" value="false" />
                  <input type="checkbox" name="supports_tools" value="true"
                         checked={@form_supports_tools}
                         class="rounded border-gray-300 focus:ring-gray-900" />
                  Supports Tools
                </label>
              </div>
            </div>

            <div :if={@error} class="text-sm text-red-600 bg-red-50 rounded-lg px-3 py-2">
              <%= @error %>
            </div>

            <div class="flex items-center gap-3">
              <button type="submit"
                      class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-4 py-2 text-sm font-medium transition">
                Save
              </button>
              <button type="button" phx-click="cancel"
                      class="border border-gray-300 hover:border-gray-400 text-gray-700 rounded-lg px-4 py-2 text-sm font-medium transition">
                Cancel
              </button>
              <span :if={@saved} class="text-sm text-green-600">Saved</span>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp list_models do
    from(m in Druzhok.Model, order_by: m.position)
    |> Druzhok.Repo.all()
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val

  defp format_number(n), do: n |> Integer.to_string() |> String.replace(~r/(\d)(?=(\d{3})+$)/, "\\1,")
end
