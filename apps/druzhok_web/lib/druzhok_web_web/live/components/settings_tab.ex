defmodule DruzhokWebWeb.Live.Components.SettingsTab do
  use DruzhokWebWeb, :live_component

  alias Druzhok.{Instance, Repo, Runtime, Pairing, Telegram, I18n, BotManager, SiteLister, Budget, Ruoc}
  alias DruzhokWebWeb.LlmProxyController, as: ImageGen

  # Vision options for a bot still on the OpenRouter path; migrated bots pick
  # from the ruoc catalog.
  @legacy_vision_models [
    %{id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite"},
    %{id: "google/gemini-3-flash-preview", name: "Gemini 3 Flash"},
    %{id: "openai/gpt-5.4-mini", name: "GPT-5.4 Mini"}
  ]
  @legacy_default_vision_model "google/gemini-2.5-flash-lite"

  # Hermes pairing code: 8 characters from the unambiguous alphabet
  # (A–Z minus IO, 2–9), per hermes-agent/gateway/pairing.py.
  @pairing_code_re ~r/^[A-HJ-NP-Z2-9]{8}$/

  @impl true
  def update(%{instance: instance} = assigns, socket) do
    runtime = Runtime.for_instance(instance)

    sites =
      case assigns[:instance] do
        %{website_hosting_enabled: true} = inst -> SiteLister.list(inst)
        _ -> []
      end

    migrated = migrated?(instance)
    spent_cents = if migrated, do: 0, else: Budget.spent_today_cents(instance[:id] || instance.id)

    balance =
      if migrated do
        case Ruoc.balance(instance[:ruoc_api_key]) do
          {:ok, %{balance_rub: rub}} -> rub
          _ -> nil
        end
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:runtime, runtime)
     |> assign(:sites, sites)
     |> assign(:spent_cents, spent_cents)
     |> assign(:migrated, migrated)
     |> assign(:balance, balance)
     |> assign(:console_url, migrated && Ruoc.console_url(instance[:ruoc_account_id]))
     |> assign(:can_migrate, !migrated && Ruoc.configured?())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-5 max-w-2xl">
      <div class="grid grid-cols-2 gap-4">
        <%!-- ═══ LEFT COLUMN ═══ --%>
        <div class="space-y-4">

          <%!-- Card: General --%>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">General</h3>
            <form phx-change="settings_changed" phx-target={@myself} class="space-y-2">
              <div class="grid grid-cols-2 gap-2">
                <div :if={@migrated}>
                  <label class="block text-[10px] text-muted mb-0.5">Balance (ruoc)</label>
                  <div class="text-xs font-mono"><%= if @balance, do: "#{@balance} ₽", else: "—" %></div>
                  <a :if={@console_url} href={@console_url} target="_blank" class="text-[10px] text-accent hover:text-accent/80">open in ruoc console</a>
                </div>
                <div :if={!@migrated}>
                  <label class="block text-[10px] text-muted mb-0.5">Daily budget ($)</label>
                  <input type="number" name="daily_budget_dollars" min="0" step="0.10" phx-debounce="blur"
                         value={budget_dollars(@instance)}
                         class="w-full border border-line2 rounded px-2 py-1 text-xs font-mono" />
                  <div class="text-[10px] text-muted mt-0.5 font-mono"><%= usage_line(@instance, @spent_cents) %></div>
                  <div class="h-1 bg-line2 rounded mt-1 overflow-hidden">
                    <div class={"h-full #{usage_bar_color(@instance, @spent_cents)}"} style={"width: #{usage_bar_width(@instance, @spent_cents)}%"}></div>
                  </div>
                </div>
                <div>
                  <label class="block text-[10px] text-muted mb-0.5">Language</label>
                  <select name="language" class="w-full border border-line2 rounded px-2 py-1 text-xs">
                    <option value="ru" selected={@instance[:language] == "ru"}>Russian</option>
                    <option value="en" selected={@instance[:language] == "en"}>English</option>
                  </select>
                </div>
              </div>
            </form>
            <div :if={@can_migrate} class="flex items-center gap-2">
              <button phx-click="migrate_to_ruoc" phx-target={@myself}
                      class="px-2 py-1 bg-accent/10 text-accent border border-accent/20 rounded text-[10px] hover:bg-accent/20 transition"
                      data-confirm="Create a ruoc-gateway account for this bot, remap its model and restart it? Fund it in the ruoc console afterwards.">
                Migrate to ruoc
              </button>
              <span class="text-[10px] text-subtle">Moves billing to ruoc-gateway</span>
            </div>
            <div>
              <label class="block text-[10px] text-muted mb-0.5">Telegram token</label>
              <% token = @instance[:telegram_token] %>
              <div :if={token} class="flex items-center gap-2">
                <code class="text-[10px] bg-raised text-muted px-1.5 py-0.5 rounded flex-1 truncate"><%= String.slice(token, 0, 12) %>...</code>
                <button phx-click="remove_telegram_token" phx-target={@myself} class="text-[10px] text-err hover:text-err/80">remove</button>
              </div>
              <form :if={!token} phx-submit="save_telegram_token" phx-target={@myself} class="flex gap-1.5">
                <input name="token" placeholder="Bot token" class="flex-1 border border-line2 rounded px-2 py-1 text-xs" />
                <button type="submit" class="px-2 py-1 bg-accent text-bg rounded text-xs">Save</button>
              </form>
            </div>
          </div>

          <%!-- Card: Models --%>
          <% is_running = @instance[:container_status] == "active" %>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">Models</h3>
            <div :if={is_running} class="text-[10px] text-warn bg-warn/10 border border-warn/20 rounded px-2 py-1">
              Stop bot to change models
            </div>
            <form phx-change="update_models" phx-target={@myself} class="space-y-2">
              <div>
                <label class="block text-[10px] text-muted mb-0.5">Default</label>
                <select name="default_model" disabled={is_running} class={"w-full border border-line2 rounded px-2 py-1 text-xs #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                  <%= for m <- Ruoc.models() do %>
                    <option value={m.id} selected={m.id == @instance[:model]}><%= m.name %><%= if p = Ruoc.price_label(m), do: " (#{p})" %></option>
                  <% end %>
                  <option :if={@instance[:model] && !Ruoc.find_model(@instance[:model])} value={@instance[:model]} selected><%= @instance[:model] %> (legacy)</option>
                </select>
              </div>
              <div>
                <label class="block text-[10px] text-muted mb-0.5">Vision / image</label>
                <select name="image_model" disabled={is_running} class={"w-full border border-line2 rounded px-2 py-1 text-xs #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                  <%= for m <- vision_options(@migrated) do %>
                    <option value={m.id} selected={m.id == (@instance[:image_model] || default_vision_model(@migrated, @instance))}><%= m.name %></option>
                  <% end %>
                </select>
              </div>
            </form>
          </div>

        </div>

        <%!-- ═══ RIGHT COLUMN ═══ --%>
        <div class="space-y-4">

          <%!-- Card: Telegram Users --%>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">Telegram Users</h3>

            <%= if @pairing_requests != [] do %>
              <div class="bg-warn/10 border border-warn/20 rounded p-2 space-y-1">
                <div class="text-[10px] text-warn font-medium">Pending requests</div>
                <%= for req <- @pairing_requests do %>
                  <div class="flex items-center justify-between">
                    <span class="font-mono text-[10px] text-fg"><%= req.telegram_user_id %><%= if req.username, do: " @#{req.username}" %></span>
                    <button phx-click="approve_pairing" phx-target={@myself}
                            phx-value-user_id={req.telegram_user_id}
                            class="px-1.5 py-0.5 bg-ok text-bg text-[10px] rounded">Approve</button>
                  </div>
                <% end %>
              </div>
            <% end %>

            <div :if={@allowed_users != []} class="space-y-0.5">
              <div :for={user_id <- @allowed_users} class="flex items-center justify-between bg-raised rounded px-2 py-0.5">
                <code class="text-[10px] font-mono text-fg"><%= user_id %></code>
                <button phx-click="remove_user" phx-target={@myself} phx-value-user_id={user_id}
                        class="text-[10px] text-err hover:text-err/80">×</button>
              </div>
            </div>
            <div :if={@allowed_users == []} class="text-[10px] text-subtle">No approved users yet</div>

            <form phx-submit="approve_user" phx-target={@myself} class="flex gap-1.5">
              <input name="user_input"
                     placeholder={if @runtime.supports_feature?(:pairing_code_approval), do: "Code or ID", else: "User ID"}
                     class="flex-1 border border-line2 rounded px-2 py-1 text-xs" />
              <button type="submit" class="px-2 py-1 bg-accent text-bg rounded text-xs">Add</button>
            </form>
          </div>

          <%!-- Card: Group Chats --%>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">Group Chats</h3>
            <div class="space-y-1">
              <label class="flex items-center gap-2 cursor-pointer select-none">
                <input type="checkbox" phx-click="toggle_mention_only" phx-target={@myself}
                       phx-throttle="1000" checked={@instance[:mention_only]}
                       class="w-3 h-3 border border-line2 bg-panel accent-accent focus:ring-0 focus:ring-offset-0 rounded-sm" />
                <span class="text-[11px] text-fg">Mention only</span>
              </label>
              <label class="flex items-center gap-2 cursor-pointer select-none">
                <input type="checkbox" phx-click="toggle_group_sessions_per_user" phx-target={@myself}
                       phx-throttle="1000" checked={!@instance[:group_sessions_per_user]}
                       class="w-3 h-3 border border-line2 bg-panel accent-accent focus:ring-0 focus:ring-offset-0 rounded-sm" />
                <span class="text-[11px] text-fg">Shared group memory</span>
              </label>
              <label class="flex items-center gap-2 cursor-pointer select-none">
                <input type="checkbox" phx-click="toggle_group_shared_memory" phx-target={@myself}
                       phx-throttle="1000" checked={@instance[:group_shared_memory]}
                       class="w-3 h-3 border border-line2 bg-panel accent-accent focus:ring-0 focus:ring-offset-0 rounded-sm" />
                <span class="text-[11px] text-fg">Record all messages</span>
              </label>
            </div>
            <form phx-submit="save_trigger_name" phx-target={@myself} class="flex gap-1.5">
              <input name="trigger_name" value={@instance[:trigger_name] || ""}
                     placeholder="Trigger name"
                     class="flex-1 border border-line2 rounded px-2 py-1 text-xs" />
              <button type="submit" class="px-2 py-1 bg-accent text-bg rounded text-xs">Save</button>
            </form>
          </div>

          <%!-- Card: Memory --%>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">Memory</h3>
          </div>

          <%!-- Card: Image Generation --%>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">Image Generation</h3>
            <label class="flex items-center gap-2 cursor-pointer select-none">
              <input type="checkbox" phx-click="toggle_image_gen" phx-target={@myself}
                     phx-throttle="1000" checked={@instance[:image_gen_enabled]}
                     class="w-3 h-3 border border-line2 bg-panel accent-accent focus:ring-0 focus:ring-offset-0 rounded-sm" />
              <span class="text-[11px] text-fg">Enable <code class="text-accent text-[10px]">image_generate</code> tool</span>
            </label>
            <%= if @instance[:image_gen_enabled] do %>
              <form phx-change="set_image_gen_model" phx-target={@myself}>
                <label class="block text-[10px] text-muted mb-0.5">Model</label>
                <select name="image_gen_model"
                        class="w-full border border-line2 rounded px-2 py-1 text-xs">
                  <%= for m <- ImageGen.image_gen_models() do %>
                    <option value={m.id} selected={m.id == (@instance[:image_gen_model] || ImageGen.default_image_gen_model())}><%= m.name %></option>
                  <% end %>
                </select>
              </form>
            <% end %>
          </div>

          <%!-- Card: Website Hosting --%>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">Website Hosting</h3>
            <label class="flex items-center gap-2 cursor-pointer select-none">
              <input type="checkbox" phx-click="toggle_website_hosting" phx-target={@myself}
                     phx-throttle="1000" checked={@instance[:website_hosting_enabled]}
                     class="w-3 h-3 border border-line2 bg-panel accent-accent focus:ring-0 focus:ring-offset-0 rounded-sm" />
              <span class="text-[11px] text-fg">
                Publish at <code class="text-accent text-[10px]">{@instance.name}.oldey.dev</code>
              </span>
            </label>
            <%= if @instance[:website_hosting_enabled] && !Enum.empty?(@sites) do %>
              <div class="space-y-0.5">
                <%= for site <- @sites do %>
                  <div class="flex items-center gap-2 text-[10px] bg-raised rounded px-2 py-0.5">
                    <a href={site.url} target="_blank" class="font-mono text-accent hover:text-accent/80 truncate">{site.url}</a>
                    <span class="text-muted">{format_bytes(site.size)}</span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Card: Auto-messages --%>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">Auto-messages</h3>
            <div class="space-y-2">
              <div>
                <label class="block text-[10px] text-muted mb-0.5">Sent on user approval</label>
                <textarea phx-blur="update_welcome_message" phx-target={@myself}
                          class="w-full border border-line2 rounded px-2 py-1 text-xs resize-none"
                          placeholder="Default welcome" rows="1"><%= @instance[:welcome_message] %></textarea>
              </div>
            </div>
          </div>

          <%!-- Danger zone --%>
          <div class="flex items-center gap-2">
            <button phx-click="clear_history" phx-target={@myself}
                    class="px-2 py-1 bg-err/10 text-err border border-err/20 rounded text-[10px] hover:bg-err/20 transition"
                    data-confirm="Clear all conversation history? The bot will restart with a fresh session.">
              Clear History
            </button>
            <span class="text-[10px] text-subtle">Wipes sessions & restarts</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("settings_changed", params, socket) do
    daily_budget_cents =
      case Float.parse(params["daily_budget_dollars"] || "0") do
        {value, _} -> max(round(value * 100), 0)
        :error -> 0
      end

    update_instance(socket.assigns.instance.name, %{
      daily_budget_cents: daily_budget_cents,
      language: params["language"] || "ru"
    })

    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("update_models", params, socket) do
    name = socket.assigns.instance.name
    changes = %{model: params["default_model"]}
    changes = if p = non_empty(params, "image_model"), do: Map.put(changes, :image_model, p), else: changes

    update_instance(name, changes)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("save_telegram_token", %{"token" => token}, socket) do
    token = case String.trim(token) do "" -> nil; t -> t end
    name = socket.assigns.instance.name
    update_instance(name, %{telegram_token: token})
    Task.start(fn -> BotManager.restart(name) end)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("remove_telegram_token", _params, socket) do
    name = socket.assigns.instance.name
    update_instance(name, %{telegram_token: nil})
    Task.start(fn -> BotManager.restart(name) end)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("toggle_mention_only", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:mention_only]
    update_instance(name, %{mention_only: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("toggle_group_sessions_per_user", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:group_sessions_per_user]
    # UI shows "shared" when DB value is false; toggling flips it.
    update_instance(name, %{group_sessions_per_user: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("toggle_group_shared_memory", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:group_shared_memory]
    update_instance(name, %{group_shared_memory: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("toggle_website_hosting", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:website_hosting_enabled]
    update_instance(name, %{website_hosting_enabled: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("migrate_to_ruoc", _params, socket) do
    name = socket.assigns.instance.name

    case BotManager.migrate_to_ruoc(name) do
      {:ok, %{account_id: id, model: model}} ->
        notify_parent(socket)
        {:noreply, put_flash(socket, :info, "Migrated: account #{id}, model #{model}. Fund it in the ruoc console.")}

      {:already_migrated, _} ->
        notify_parent(socket)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Migration failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_image_gen", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:image_gen_enabled]
    update_instance(name, %{image_gen_enabled: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("set_image_gen_model", %{"image_gen_model" => model}, socket)
      when is_binary(model) and model != "" do
    name = socket.assigns.instance.name
    update_instance(name, %{image_gen_model: model})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("save_trigger_name", %{"trigger_name" => trigger_name}, socket) do
    trigger_name = case String.trim(trigger_name) do "" -> nil; t -> t end
    update_instance(socket.assigns.instance.name, %{trigger_name: trigger_name})
    restart_bot(socket.assigns.instance.name)
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("clear_history", _params, socket) do
    name = socket.assigns.instance.name

    with_runtime(name, fn runtime, data_root ->
      runtime.clear_sessions(data_root)
      restart_bot(name)
    end)

    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("generate_api_key", _params, socket) do
    update_instance(socket.assigns.instance.name, %{api_key: Instance.generate_api_key()})
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("update_welcome_message", %{"value" => value}, socket) do
    update_instance(socket.assigns.instance.name, %{welcome_message: non_empty_string(value)})

    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("approve_pairing", %{"user_id" => user_id_str}, socket) do
    name = socket.assigns.instance.name
    user_id = String.to_integer(user_id_str)

    with_runtime(name, fn runtime, data_root ->
      runtime.add_allowed_user(data_root, user_id_str)
      Pairing.approve_request(name, user_id)

      welcome = socket.assigns.instance[:welcome_message] ||
        I18n.t(:welcome_default, socket.assigns.instance[:language] || "ru")

      if token = socket.assigns.instance[:telegram_token] do
        Telegram.API.send_message(token, user_id, welcome)
      end

      Druzhok.Events.broadcast(name, %{type: :pairing_approved, user_id: user_id_str})
    end)

    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("approve_user", %{"user_input" => input}, socket) do
    trimmed = String.trim(input || "") |> String.upcase()
    runtime = socket.assigns.runtime

    cond do
      trimmed == "" ->
        {:noreply, socket}

      Regex.match?(@pairing_code_re, trimmed) and
          runtime.supports_feature?(:pairing_code_approval) ->
        approve_pairing_code(socket, trimmed)

      true ->
        user_id = Runtime.parse_user_input(input)

        if user_id != "" do
          mutate_allowlist(socket, user_id, :add)
          notify_parent(socket)
        end

        {:noreply, socket}
    end
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    mutate_allowlist(socket, user_id, :remove)
    notify_parent(socket)
    {:noreply, socket}
  end

  defp approve_pairing_code(socket, code) do
    name = socket.assigns.instance.name
    {output, exit_code} =
      BotManager.exec(name, [Runtime.Hermes.bin(), "pairing", "approve", "telegram", code])

    trimmed = String.trim(output)
    # Hermes exits 0 even when the code isn't found — sniff the text.
    looks_like_error =
      trimmed
      |> String.downcase()
      |> String.contains?(["not found", "expired", "invalid", "error", "failed"])

    flash_kind = if exit_code == 0 and not looks_like_error, do: :info, else: :error
    {:noreply, put_flash(socket, flash_kind, trimmed)}
  end

  defp mutate_allowlist(socket, user_id, op) do
    name = socket.assigns.instance.name

    case Repo.get_by(Instance, name: name) do
      nil ->
        :ok

      instance ->
        runtime = Runtime.for_instance(instance)

        if runtime.supports_feature?(:db_allowlist) do
          case op do
            :add -> Instance.add_allowed_id(instance, user_id)
            :remove -> Instance.remove_allowed_id(instance, user_id)
          end
        else
          with_runtime(name, fn r, data_root ->
            case op do
              :add -> r.add_allowed_user(data_root, user_id)
              :remove -> r.remove_allowed_user(data_root, user_id)
            end
          end)
        end

        restart_bot(name)
    end
  end

  # --- Helpers ---

  defp update_instance(name, changes) do
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> inst |> Instance.changeset(changes) |> Repo.update()
    end
  end

  defp non_empty_string(value) do
    case String.trim(value || "") do
      "" -> nil
      v -> v
    end
  end

  defp with_runtime(name, fun) do
    case Repo.get_by(Instance, name: name) do
      %{workspace: workspace} = instance when workspace != nil ->
        runtime = Runtime.for_instance(instance)
        fun.(runtime, runtime.data_root(instance))

      _ ->
        nil
    end
  end

  defp restart_bot(name) do
    Task.start(fn -> BotManager.restart(name) end)
    :ok
  end

  defp non_empty(params, key) do
    case params[key] do
      nil -> nil
      "" -> nil
      val -> val
    end
  end

  defp notify_parent(_socket) do
    send(self(), :settings_updated)
    :ok
  end

  defp format_bytes(n) when n < 1024, do: "#{n} B"
  defp format_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"

  defp migrated?(instance), do: instance[:ruoc_api_key] not in [nil, ""]

  defp vision_options(true), do: Ruoc.vision_models()
  defp vision_options(false), do: @legacy_vision_models

  defp default_vision_model(true, instance), do: instance[:model]
  defp default_vision_model(false, _instance), do: @legacy_default_vision_model

  defp budget_dollars(instance) do
    Budget.cents_to_dollars(instance[:daily_budget_cents] || 0)
  end

  defp usage_line(instance, spent) do
    limit = instance[:daily_budget_cents] || 0

    if limit == 0 do
      "Unlimited — $#{Budget.cents_to_dollars(spent)} spent today"
    else
      pct = round(spent * 100 / limit)
      "$#{Budget.cents_to_dollars(spent)} / $#{Budget.cents_to_dollars(limit)} (#{pct}%)"
    end
  end

  defp usage_bar_width(instance, spent) do
    limit = instance[:daily_budget_cents] || 0
    if limit == 0, do: 0, else: min(round(spent * 100 / limit), 100)
  end

  defp usage_bar_color(instance, spent) do
    limit = instance[:daily_budget_cents] || 0
    pct = if limit == 0, do: 0, else: spent * 100 / limit

    cond do
      pct >= 80 -> "bg-red-500"
      pct >= 50 -> "bg-yellow-500"
      true -> "bg-green-500"
    end
  end
end
