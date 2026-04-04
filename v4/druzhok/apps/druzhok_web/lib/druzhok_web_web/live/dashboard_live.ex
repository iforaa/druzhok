defmodule DruzhokWebWeb.DashboardLive do
  use DruzhokWebWeb, :live_view

  import DruzhokWebWeb.Live.Components.EventLog
  import DruzhokWebWeb.Live.Components.FileBrowser
  import DruzhokWebWeb.Live.Components.ErrorsTab
  import DruzhokWebWeb.Live.Components.UsageTab
  import DruzhokWebWeb.Live.Components.SqliteBrowser

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
      pools: Druzhok.PoolManager.pools(),
      models: models,
      create_form: %{"name" => "", "token" => "", "model" => default_model},
      selected: nil,
      selected_pool: nil,
      tab: :logs,
      workspace_files: [],
      file_content: nil,
      events: [],
      show_create: false,
      current_path: "",
      pairing_requests: [],
      owner: nil,
      groups: [],
      allowed_users: [],
      instance_errors: [],
      expanded_error: nil,
      editing_file: false,
      file_saved: false,
      usage_requests: [],
      usage_summary: [],
      expanded_request: nil,
      db_browser: nil,
      db_tables: [],
      db_selected_table: nil,
      db_columns: [],
      db_rows: [],
      db_total_rows: 0,
      db_offset: 0,
      db_page_size: 50,
      db_query: "",
      db_error: nil,
      db_selected_rows: [],
      db_all_selected: false,
      db_editing: nil
    )}
  end

  @impl true
  def handle_params(%{"name" => name} = params, _uri, socket) do
    case get_instance(name, socket) do
      nil ->
        {:noreply, socket |> assign(selected: nil) |> push_patch(to: "/")}
      instance ->
        tab = Map.get(@valid_tabs, params["tab"], :logs)
        files = list_workspace_files(instance, "")

        # Load tab-specific data
        {usage_requests, usage_summary} = if tab == :usage do
          load_usage_data(instance)
        else
          {socket.assigns[:usage_requests] || [], socket.assigns[:usage_summary] || []}
        end

        instance_errors = if tab == :errors do
          Druzhok.CrashLog.recent_for_instance(name, 100)
        else
          socket.assigns[:instance_errors] || []
        end

        {:noreply, assign(socket,
          selected: name,
          tab: tab,
          workspace_files: files,
          file_content: nil,
          current_path: "",
          events: [],
          pairing_requests: Druzhok.Pairing.pending_for_instance(name),
          owner: Druzhok.InstanceManager.get_owner(name),
          groups: Druzhok.InstanceManager.get_groups(name),
          allowed_users: load_allowed_users(name),
          instance_errors: instance_errors,
          expanded_error: nil,
          usage_requests: usage_requests,
          usage_summary: usage_summary
        )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, selected: nil, workspace_files: [], file_content: nil, events: [], pairing_requests: [], owner: nil, groups: [], allowed_users: [])}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, instances: list_instances(), pools: Druzhok.PoolManager.pools())}
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

    language = params["language"] || "ru"

    changes = %{
      daily_token_limit: token_limit,
      language: language
    }

    update_instance_field(name, changes)

    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("stop", %{"name" => name}, socket) do
    Druzhok.BotManager.stop(name)
    Process.sleep(500)
    {:noreply, assign(socket, instances: list_instances(), pools: Druzhok.PoolManager.pools())}
  end

  def handle_event("start_bot", %{"name" => name}, socket) do
    Druzhok.BotManager.start(name)
    Process.sleep(1_000)
    {:noreply, assign(socket, instances: list_instances(), pools: Druzhok.PoolManager.pools())}
  end

  def handle_event("select_pool", %{"pool" => pool_name}, socket) do
    pool = Enum.find(socket.assigns.pools, &(&1.name == pool_name))
    {:noreply, assign(socket, :selected_pool, pool)}
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

        if sqlite_file?(full_rel) do
          tables = Druzhok.SqliteBrowser.tables(full_path)
          {:noreply, assign(socket,
            db_browser: full_path,
            db_tables: tables,
            db_selected_table: nil,
            db_columns: [],
            db_rows: [],
            db_total_rows: 0,
            db_offset: 0,
            db_query: "",
            db_error: nil,
            db_selected_rows: [],
            db_all_selected: false,
            db_editing: nil,
            file_content: %{path: full_rel, content: ""}
          )}
        else
          content = cond do
            binary_file?(full_rel) ->
              case File.stat(full_path) do
                {:ok, %{size: size}} -> "Binary file (#{format_file_size(size)})"
                _ -> "Binary file"
              end

            true ->
              case File.stat(full_path) do
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
                    {:ok, c} ->
                      if String.valid?(c), do: c, else: "Binary file (#{byte_size(c)} bytes)"
                    {:error, _} -> "Cannot read file"
                  end
              end
          end

          {:noreply, assign(socket, file_content: %{path: full_rel, content: content}, editing_file: false, file_saved: false, db_browser: nil)}
        end
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
        full_path = Path.join(workspace, path) |> Path.expand()
        if String.starts_with?(full_path, Path.expand(workspace)) do
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

  # SQLite browser events

  def handle_event("close_db", _, socket) do
    {:noreply, assign(socket, db_browser: nil, file_content: nil)}
  end

  def handle_event("db_select_table", %{"table" => table}, socket) do
    case Druzhok.SqliteBrowser.browse_table(socket.assigns.db_browser, table, socket.assigns.db_page_size, 0) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply, assign(socket,
          db_selected_table: table,
          db_columns: columns,
          db_rows: rows,
          db_total_rows: total,
          db_offset: 0,
          db_query: "SELECT * FROM \"#{table}\"",
          db_error: nil,
          db_selected_rows: [],
          db_all_selected: false,
          db_editing: nil
        )}
      {:error, reason} ->
        {:noreply, assign(socket, db_error: reason)}
    end
  end

  def handle_event("db_run_query", %{"query" => query}, socket) do
    case Druzhok.SqliteBrowser.query(socket.assigns.db_browser, query, socket.assigns.db_page_size, 0) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply, assign(socket,
          db_columns: columns,
          db_rows: rows,
          db_total_rows: total,
          db_offset: 0,
          db_query: query,
          db_error: nil,
          db_selected_rows: [],
          db_all_selected: false,
          db_editing: nil
        )}
      {:error, reason} ->
        {:noreply, assign(socket, db_error: reason, db_columns: [], db_rows: [])}
    end
  end

  def handle_event("db_edit_cell", %{"idx" => idx, "col" => col}, socket) do
    idx = String.to_integer(idx)
    {:noreply, assign(socket, db_editing: {idx, col})}
  end

  def handle_event("db_save_cell", %{"idx" => idx, "col" => col, "value" => value}, socket) do
    idx = String.to_integer(idx)
    table = socket.assigns.db_selected_table

    if table do
      rowids = Druzhok.SqliteBrowser.get_rowids(
        socket.assigns.db_browser, table,
        socket.assigns.db_page_size, socket.assigns.db_offset
      )
      rowid = Enum.at(rowids, idx)

      if rowid do
        Druzhok.SqliteBrowser.update_cell(socket.assigns.db_browser, table, rowid, col, value)
        # Refresh current view
        case Druzhok.SqliteBrowser.query(socket.assigns.db_browser, socket.assigns.db_query, socket.assigns.db_page_size, socket.assigns.db_offset) do
          {:ok, %{columns: columns, rows: rows, total: total}} ->
            {:noreply, assign(socket, db_columns: columns, db_rows: rows, db_total_rows: total, db_editing: nil)}
          _ ->
            {:noreply, assign(socket, db_editing: nil)}
        end
      else
        {:noreply, assign(socket, db_editing: nil, db_error: "Could not find row")}
      end
    else
      {:noreply, assign(socket, db_editing: nil)}
    end
  end

  def handle_event("db_cancel_edit", _, socket) do
    {:noreply, assign(socket, db_editing: nil)}
  end

  def handle_event("db_delete_row", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    table = socket.assigns.db_selected_table

    if table do
      rowids = Druzhok.SqliteBrowser.get_rowids(
        socket.assigns.db_browser, table,
        socket.assigns.db_page_size, socket.assigns.db_offset
      )
      rowid = Enum.at(rowids, idx)

      if rowid do
        Druzhok.SqliteBrowser.delete_rows(socket.assigns.db_browser, table, [rowid])
        refresh_db_view(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("db_delete_selected", _, socket) do
    table = socket.assigns.db_selected_table

    if table do
      rowids = Druzhok.SqliteBrowser.get_rowids(
        socket.assigns.db_browser, table,
        socket.assigns.db_page_size, socket.assigns.db_offset
      )
      selected_rowids = Enum.map(socket.assigns.db_selected_rows, &Enum.at(rowids, &1))
                        |> Enum.reject(&is_nil/1)

      if selected_rowids != [] do
        Druzhok.SqliteBrowser.delete_rows(socket.assigns.db_browser, table, selected_rowids)
        refresh_db_view(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("db_toggle_row", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    selected = socket.assigns.db_selected_rows

    selected = if idx in selected do
      List.delete(selected, idx)
    else
      [idx | selected]
    end

    all_selected = length(selected) == length(socket.assigns.db_rows) and selected != []
    {:noreply, assign(socket, db_selected_rows: selected, db_all_selected: all_selected)}
  end

  def handle_event("db_toggle_all", _, socket) do
    if socket.assigns.db_all_selected do
      {:noreply, assign(socket, db_selected_rows: [], db_all_selected: false)}
    else
      all = Enum.to_list(0..(length(socket.assigns.db_rows) - 1))
      {:noreply, assign(socket, db_selected_rows: all, db_all_selected: true)}
    end
  end

  def handle_event("db_prev_page", _, socket) do
    new_offset = max(socket.assigns.db_offset - socket.assigns.db_page_size, 0)
    case Druzhok.SqliteBrowser.query(socket.assigns.db_browser, socket.assigns.db_query, socket.assigns.db_page_size, new_offset) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply, assign(socket, db_columns: columns, db_rows: rows, db_total_rows: total, db_offset: new_offset, db_selected_rows: [], db_all_selected: false, db_editing: nil)}
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("db_next_page", _, socket) do
    new_offset = socket.assigns.db_offset + socket.assigns.db_page_size
    case Druzhok.SqliteBrowser.query(socket.assigns.db_browser, socket.assigns.db_query, socket.assigns.db_page_size, new_offset) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply, assign(socket, db_columns: columns, db_rows: rows, db_total_rows: total, db_offset: new_offset, db_selected_rows: [], db_all_selected: false, db_editing: nil)}
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("back", _, socket) do
    {:noreply,
      socket
      |> assign(selected: nil, workspace_files: [], file_content: nil, events: [])
      |> push_patch(to: "/")}
  end

  def handle_event("approve_pairing", %{"user_id" => user_id_str}, socket) do
    name = socket.assigns.selected
    user_id = String.to_integer(user_id_str)

    with_runtime(name, fn runtime, data_root ->
      runtime.add_allowed_user(data_root, user_id_str)
      Druzhok.Pairing.approve_request(name, user_id)

      # Send welcome message using cached instance data from assigns
      welcome = selected_field(socket.assigns.instances, name, :welcome_message) ||
        Druzhok.I18n.t(:welcome_default, selected_field(socket.assigns.instances, name, :language) || "ru")
      token = selected_field(socket.assigns.instances, name, :telegram_token)
      if token, do: Druzhok.Telegram.API.send_message(token, user_id, welcome)

      # Broadcast and reload
      Druzhok.Events.broadcast(name, %{type: :pairing_approved, user_id: user_id_str})

      {:noreply, assign(socket,
        pairing_requests: Druzhok.Pairing.pending_for_instance(name),
        allowed_users: runtime.read_allowed_users(data_root)
      )}
    end) || {:noreply, socket}
  end

  def handle_event("update_" <> field, %{"name" => name, "value" => value}, socket)
      when field in ["reject_message", "welcome_message"] do
    value = if String.trim(value) == "", do: nil, else: String.trim(value)
    case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
      nil -> {:noreply, socket}
      inst ->
        Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{String.to_existing_atom(field) => value}))
        {:noreply, socket}
    end
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

  def handle_event("approve_user", %{"user_input" => input}, socket) do
    user_id = Druzhok.Runtime.parse_user_input(input)
    if user_id != "" and socket.assigns.selected do
      name = socket.assigns.selected
      instance = Druzhok.Repo.get_by(Druzhok.Instance, name: name)
      runtime = instance && Druzhok.Runtime.get(instance.bot_runtime, Druzhok.Runtime.ZeroClaw)

      if instance && runtime.pooled?() do
        Druzhok.Instance.add_allowed_id(instance, user_id)
        restart_bot(name)
        {:noreply, assign(socket, allowed_users: load_allowed_users(name), instances: list_instances())}
      else
        with_runtime(name, fn runtime, data_root ->
          runtime.add_allowed_user(data_root, user_id)
          restart_bot(name)
          {:noreply, assign(socket, allowed_users: load_allowed_users(name), instances: list_instances())}
        end) || {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Invalid user ID")}
    end
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    if socket.assigns.selected do
      name = socket.assigns.selected
      instance = Druzhok.Repo.get_by(Druzhok.Instance, name: name)
      runtime = instance && Druzhok.Runtime.get(instance.bot_runtime, Druzhok.Runtime.ZeroClaw)

      if instance && runtime.pooled?() do
        Druzhok.Instance.remove_allowed_id(instance, user_id)
        restart_bot(name)
        {:noreply, assign(socket, allowed_users: load_allowed_users(name), instances: list_instances())}
      else
        with_runtime(name, fn runtime, data_root ->
          runtime.remove_allowed_user(data_root, user_id)
          restart_bot(name)
          {:noreply, assign(socket, allowed_users: load_allowed_users(name), instances: list_instances())}
        end) || {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_mention_only", %{"name" => name}, socket) do
    current = selected_field(socket.assigns.instances, name, :mention_only)
    new_val = !current
    update_instance_field(name, %{mention_only: new_val})
    restart_bot(name)
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("save_trigger_name", %{"trigger_name" => trigger_name}, socket) do
    trigger_name = case String.trim(trigger_name) do "" -> nil; t -> t end
    update_instance_field(socket.assigns.selected, %{trigger_name: trigger_name})
    restart_bot(socket.assigns.selected)
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("clear_history", %{"name" => name}, socket) do
    with_runtime(name, fn runtime, data_root ->
      runtime.clear_sessions(data_root)
      restart_bot(name)
      {:noreply, assign(socket, instances: list_instances())}
    end) || {:noreply, socket}
  end

  def handle_event("generate_api_key", _, socket) do
    update_instance_field(socket.assigns.selected, %{api_key: Druzhok.Instance.generate_api_key()})
    {:noreply, assign(socket, instances: list_instances())}
  end

  def handle_event("update_models", %{"name" => name, "default_model" => default_model} = params, socket) do
    on_demand = case params["on_demand_model"] do
      "" -> nil
      nil -> nil
      model -> model
    end

    update_instance_field(name, %{model: default_model, on_demand_model: on_demand})
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
          <div :if={@instances == [] and @pools == []} class="px-4 py-8 text-center text-gray-400 text-sm">
            No instances yet
          </div>

          <%!-- Solo instances (not in any pool) --%>
          <div :for={inst <- @instances} :if={is_nil(inst[:pool_id])}
               phx-click="select" phx-value-name={inst.name}
               class={"flex items-center gap-3 px-4 py-3 cursor-pointer transition #{if !inst[:active], do: "opacity-50 "} #{if @selected == inst.name, do: "bg-white border-l-2 border-gray-900 shadow-sm", else: "hover:bg-white/60 border-l-2 border-transparent"}"}>
            <div class={"w-2 h-2 rounded-full flex-shrink-0 #{if inst[:active], do: container_status_color(inst[:container_status]), else: "bg-gray-300"}"}></div>
            <div class="flex-1 min-w-0">
              <div class="text-sm font-medium truncate"><%= inst.name %></div>
              <div class="text-xs text-gray-400 truncate"><%= inst[:bot_runtime] || "zeroclaw" %> &middot; <%= model_short(inst.model) %><%= unless inst[:active], do: " · stopped" %></div>
            </div>
          </div>

          <%!-- Separator between solo and pools --%>
          <div :if={@pools != [] and Enum.any?(@instances, &is_nil(&1[:pool_id]))} class="mx-4 my-2 border-t border-gray-200"></div>

          <%!-- Pool groups --%>
          <div :for={pool <- @pools} class="mb-1">
            <div class="flex items-center gap-2 px-4 py-1.5 cursor-pointer hover:bg-white/40 transition"
                 phx-click="select_pool" phx-value-pool={pool.name}>
              <div class={"w-2 h-2 rounded-full flex-shrink-0 #{if pool.status == "running", do: "bg-green-400", else: "bg-gray-300"}"}></div>
              <span class="text-xs font-semibold text-gray-500 uppercase tracking-wide flex-1 truncate"><%= pool.name %></span>
              <span class="text-[10px] text-gray-400"><%= length(pool.instances) %>/<%= pool.max_tenants %></span>
            </div>
            <div :for={inst <- pool.instances}
                 phx-click="select" phx-value-name={inst.name}
                 class={"flex items-center gap-3 pl-8 pr-4 py-2 cursor-pointer transition #{if @selected == inst.name, do: "bg-white border-l-2 border-gray-900 shadow-sm", else: "hover:bg-white/60 border-l-2 border-transparent"}"}>
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium truncate"><%= inst.name %></div>
                <div class="text-xs text-gray-400 truncate"><%= model_short(inst.model) %></div>
              </div>
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
            <.sqlite_browser :if={@tab == :files && @db_browser}
              db_path={@db_browser} db_tables={@db_tables} db_selected_table={@db_selected_table}
              db_columns={@db_columns} db_rows={@db_rows} db_total_rows={@db_total_rows}
              db_offset={@db_offset} db_page_size={@db_page_size} db_query={@db_query}
              db_error={@db_error} db_selected_rows={@db_selected_rows}
              db_all_selected={@db_all_selected} db_editing={@db_editing} />
            <.file_browser :if={@tab == :files && !@db_browser} files={@workspace_files} file_content={@file_content} current_path={@current_path} editing={@editing_file} file_saved={@file_saved} />

            <%!-- Settings tab --%>
            <div :if={@tab == :settings} class="p-6 space-y-6">
              <form phx-change="settings_changed" class="space-y-4">
                <input type="hidden" name="name" value={@selected} />

                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Runtime</label>
                    <div class="w-full border border-gray-200 bg-gray-50 rounded-lg px-3 py-2 text-sm text-gray-600"><%= selected_field(@instances, @selected, :bot_runtime) || "zeroclaw" %></div>
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

              <hr class="border-gray-200" />

              <%!-- Model Selection --%>
              <% is_running = selected_field(@instances, @selected, :container_status) == "running" %>
              <div>
                <h3 class="text-sm font-medium text-gray-700 mb-3">Models</h3>
                <div :if={is_running} class="text-xs text-amber-600 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-3">
                  Stop the bot to change model settings
                </div>
                <form phx-change="update_models">
                  <input type="hidden" name="name" value={@selected} />
                  <div class="grid grid-cols-2 gap-4">
                    <div>
                      <label class="block text-xs font-medium text-gray-500 mb-1">Default (all messages)</label>
                      <select name="default_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                        <%= for m <- Druzhok.ModelCatalog.default_options() do %>
                          <option value={m.id} selected={m.id == selected_field(@instances, @selected, :model)}><%= m.name %> (<%= m.price %>)</option>
                        <% end %>
                      </select>
                    </div>
                    <div>
                      <label class="block text-xs font-medium text-gray-500 mb-1">On-demand (user requests)</label>
                      <select name="on_demand_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                        <option value="">None</option>
                        <%= for m <- Druzhok.ModelCatalog.smart() do %>
                          <option value={m.id} selected={m.id == (selected_field(@instances, @selected, :on_demand_model) || "")}><%= m.name %> (<%= m.price %>)</option>
                        <% end %>
                      </select>
                    </div>
                  </div>
                </form>
              </div>

              <hr class="border-gray-200" />

              <%!-- Pending Pairing Requests --%>
              <%= if @pairing_requests != [] do %>
                <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-4">
                  <h3 class="text-sm font-medium text-yellow-800 mb-2">Pending Access Requests</h3>
                  <%= for req <- @pairing_requests do %>
                    <div class="flex items-center justify-between py-2 border-b border-yellow-100 last:border-0">
                      <div>
                        <span class="font-mono text-sm"><%= req.telegram_user_id %></span>
                        <%= if req.username do %>
                          <span class="text-gray-500 text-sm ml-2">@<%= req.username %></span>
                        <% end %>
                      </div>
                      <button phx-click="approve_pairing"
                              phx-value-user_id={req.telegram_user_id}
                              class="px-3 py-1 bg-green-600 text-white text-sm rounded hover:bg-green-700">
                        Approve
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Security: Approved Users --%>
              <div>
                <h3 class="text-sm font-medium text-gray-700 mb-3">Approved Telegram Users</h3>
                <div :if={@allowed_users == []} class="text-xs text-gray-400 mb-3">
                  No users approved yet. When someone messages the bot, it will show them an ID to paste here.
                </div>
                <div :if={@allowed_users != []} class="space-y-1 mb-3">
                  <div :for={user_id <- @allowed_users} class="flex items-center justify-between bg-gray-50 rounded-lg px-3 py-2">
                    <code class="text-sm font-mono"><%= user_id %></code>
                    <button phx-click="remove_user" phx-value-user_id={user_id}
                            class="text-xs text-red-500 hover:text-red-700 transition">Remove</button>
                  </div>
                </div>
                <form phx-submit="approve_user" class="flex gap-2">
                  <input name="user_input" placeholder="Paste user ID or bind command"
                         class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm" />
                  <button type="submit" class="px-3 py-2 bg-gray-900 text-white rounded-lg text-sm">Approve</button>
                </form>
                <p class="text-xs text-gray-400 mt-1">Paste the number from the bot's approval message</p>
              </div>

              <hr class="border-gray-200" />

              <%!-- Group Chat Behavior --%>
              <div>
                <h3 class="text-sm font-medium text-gray-700 mb-3">Group Chats</h3>
                <label class="flex items-center gap-3 cursor-pointer">
                  <input type="checkbox" phx-click="toggle_mention_only" phx-value-name={@selected}
                         checked={selected_field(@instances, @selected, :mention_only)}
                         class="rounded border-gray-300" />
                  <span class="text-sm text-gray-600">Mention only — respond only when @mentioned in groups</span>
                </label>
                <form phx-submit="save_trigger_name" class="flex gap-2 mt-3">
                  <input name="trigger_name" value={selected_field(@instances, @selected, :trigger_name) || ""}
                         placeholder="Trigger name (e.g. Igz)"
                         class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm" />
                  <button type="submit" class="px-3 py-2 bg-gray-900 text-white rounded-lg text-sm">Save</button>
                </form>
                <p class="text-xs text-gray-400 mt-1">Bot also responds when this name is mentioned in groups (case-insensitive)</p>
              </div>

              <hr class="border-gray-200" />

              <%!-- Message Settings --%>
              <div>
                <h3 class="text-sm font-medium text-gray-700 mb-3">Messages</h3>
                <div class="space-y-4">
                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Rejection Message</label>
                    <textarea phx-blur="update_reject_message" phx-value-name={@selected}
                              class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm"
                              placeholder="Uses default if empty. Use %{user_id} for the user's ID."
                              rows="2"><%= selected_field(@instances, @selected, :reject_message) %></textarea>
                  </div>
                  <div>
                    <label class="block text-xs font-medium text-gray-500 mb-1">Welcome Message</label>
                    <textarea phx-blur="update_welcome_message" phx-value-name={@selected}
                              class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm"
                              placeholder="Uses default if empty."
                              rows="2"><%= selected_field(@instances, @selected, :welcome_message) %></textarea>
                  </div>
                </div>
              </div>

              <hr class="border-gray-200" />

              <%!-- Session Management --%>
              <div>
                <h3 class="text-sm font-medium text-gray-700 mb-3">Session</h3>
                <button phx-click="clear_history" phx-value-name={@selected}
                        class="px-3 py-2 bg-red-50 text-red-600 border border-red-200 rounded-lg text-sm hover:bg-red-100 transition"
                        data-confirm="Clear all conversation history? The bot will restart with a fresh session.">
                  Clear History & Restart
                </button>
                <p class="text-xs text-gray-400 mt-1">Clears all conversation history and restarts the bot</p>
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

  defp load_allowed_users(name) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
      nil -> []
      instance ->
        runtime = Druzhok.Runtime.get(instance.bot_runtime, Druzhok.Runtime.ZeroClaw)
        if runtime.pooled?() do
          Druzhok.Instance.get_allowed_ids(instance)
        else
          data_root = Path.dirname(instance.workspace)
          users = runtime.read_allowed_users(data_root)
          Enum.reject(users, &(&1 == "__closed__"))
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
        request_body: r.request_body
      }
    end)
    summary = Druzhok.Usage.daily_usage(instance[:id])
    {requests, summary}
  end

  defp with_runtime(name, fun) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
      %{workspace: workspace, bot_runtime: bot_runtime} when workspace != nil ->
        runtime = Druzhok.Runtime.get(bot_runtime || "zeroclaw", Druzhok.Runtime.ZeroClaw)
        fun.(runtime, Path.dirname(workspace))
      _ -> nil
    end
  end

  defp restart_bot(name) do
    Task.start(fn -> Druzhok.BotManager.restart(name) end)
  end

  @sqlite_extensions ~w(.db .sqlite .sqlite3)
  @binary_extensions ~w(.db .sqlite .sqlite3 .jpg .jpeg .png .gif .bmp .ico .pdf .zip .tar .gz .bz2 .xz .exe .bin .so .dylib .wasm)

  defp sqlite_file?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @sqlite_extensions
  end

  defp binary_file?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @binary_extensions
  end

  defp refresh_db_view(socket) do
    case Druzhok.SqliteBrowser.query(socket.assigns.db_browser, socket.assigns.db_query, socket.assigns.db_page_size, socket.assigns.db_offset) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply, assign(socket, db_columns: columns, db_rows: rows, db_total_rows: total, db_selected_rows: [], db_all_selected: false, db_editing: nil)}
      _ ->
        {:noreply, socket}
    end
  end

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp list_instances do
    instances = Druzhok.InstanceManager.list()

    # Build pool_id -> container name cache to avoid per-instance DB lookups
    pool_ids = instances |> Enum.map(& &1.pool_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    pool_containers = case pool_ids do
      [] -> %{}
      ids ->
        import Ecto.Query
        Druzhok.Repo.all(from p in Druzhok.Pool, where: p.id in ^ids, select: {p.id, p.container})
        |> Map.new()
    end

    # Cache Docker status/stats per container to avoid duplicate calls for pooled instances
    container_cache = %{}

    {results, _cache} = Enum.map_reduce(instances, container_cache, fn inst, cache ->
      container = case inst.pool_id do
        nil -> Druzhok.BotManager.container_name(inst.name)
        pool_id -> Map.get(pool_containers, pool_id, Druzhok.BotManager.container_name(inst.name))
      end

      {status, stats, cache} = case Map.get(cache, container) do
        nil ->
          s = Druzhok.BotManager.status_for_container(container)
          st = Druzhok.BotManager.stats_for_container(container)
          {s, st, Map.put(cache, container, {s, st})}
        {s, st} ->
          {s, st, cache}
      end

      mapped = inst
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.put(:container_status, status)
      |> Map.put(:container_stats, stats)

      {mapped, cache}
    end)

    results
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
