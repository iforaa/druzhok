defmodule DruzhokWebWeb.Live.Components.FilesTab do
  use DruzhokWebWeb, :live_component

  import DruzhokWebWeb.Live.Components.FileBrowser
  import DruzhokWebWeb.Live.Components.SqliteBrowser

  alias Druzhok.{Runtime, SqliteBrowser}

  @page_size 50
  @sqlite_extensions ~w(.db .sqlite .sqlite3)
  @binary_extensions ~w(.db .sqlite .sqlite3 .jpg .jpeg .png .gif .bmp .ico .pdf .zip .tar .gz .bz2 .xz .exe .bin .so .dylib .wasm)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       workspace_files: [],
       file_content: nil,
       current_path: "",
       editing_file: false,
       file_saved: false,
       db_browser: nil,
       db_tables: [],
       db_selected_table: nil,
       db_columns: [],
       db_rows: [],
       db_total_rows: 0,
       db_offset: 0,
       db_query: "",
       db_error: nil,
       db_selected_rows: [],
       db_all_selected: false,
       db_editing: nil
     )}
  end

  @impl true
  def update(%{instance: instance} = assigns, socket) do
    # Only reset when the *identity* of the displayed instance changes.
    # The parent polls `list_instances/0` every 5s, rebuilding maps with
    # fresh container_stats — so we can't compare the whole map.
    switched? = socket.assigns[:instance][:name] != instance[:name]
    runtime = Runtime.get(instance[:bot_runtime] || "zeroclaw", Runtime.ZeroClaw)

    socket =
      if switched? do
        assign(socket,
          workspace_files: list_workspace_files(runtime, instance, ""),
          file_content: nil,
          current_path: "",
          editing_file: false,
          file_saved: false,
          db_browser: nil
        )
      else
        socket
      end

    {:ok, socket |> assign(assigns) |> assign(:runtime, runtime)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :page_size, @page_size)

    ~H"""
    <div>
      <.sqlite_browser :if={@db_browser}
        db_path={@db_browser} db_tables={@db_tables} db_selected_table={@db_selected_table}
        db_columns={@db_columns} db_rows={@db_rows} db_total_rows={@db_total_rows}
        db_offset={@db_offset} db_page_size={@page_size} db_query={@db_query}
        db_error={@db_error} db_selected_rows={@db_selected_rows}
        db_all_selected={@db_all_selected} db_editing={@db_editing} />
      <.file_browser :if={!@db_browser}
        files={@workspace_files}
        file_content={@file_content}
        current_path={@current_path}
        editing={@editing_file}
        file_saved={@file_saved} />
    </div>
    """
  end

  # --- File browser events ---

  @impl true
  def handle_event("view_file", %{"path" => path, "is_dir" => "true"}, socket) do
    instance = socket.assigns.instance
    runtime = socket.assigns.runtime
    new_path = join_path(socket.assigns.current_path, path)

    {:noreply,
     assign(socket,
       workspace_files: list_workspace_files(runtime, instance, new_path),
       file_content: nil,
       current_path: new_path
     )}
  end

  def handle_event("view_file", %{"path" => path}, socket) do
    runtime = socket.assigns.runtime
    instance = socket.assigns.instance
    root = runtime.file_browser_root(instance)
    full_rel = join_path(socket.assigns.current_path, path)
    full_path = Path.join(root, full_rel)

    if sqlite_file?(full_rel) do
      tables = SqliteBrowser.tables(full_path)

      {:noreply,
       assign(socket,
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
      content = read_file_for_display(full_path, full_rel)

      {:noreply,
       assign(socket,
         file_content: %{path: full_rel, content: content},
         editing_file: false,
         file_saved: false,
         db_browser: nil
       )}
    end
  end

  def handle_event("edit_file", _params, socket) do
    {:noreply, assign(socket, editing_file: true, file_saved: false)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_file: false)}
  end

  def handle_event("save_file", _params, socket) do
    {:noreply, push_event(socket, "request_file_content", %{})}
  end

  def handle_event("do_save_file", %{"content" => content}, socket) do
    runtime = socket.assigns.runtime
    instance = socket.assigns.instance
    root = runtime.file_browser_root(instance)

    case socket.assigns.file_content do
      %{path: path} when is_binary(path) ->
        full_path = Path.join(root, path) |> Path.expand()

        if String.starts_with?(full_path, Path.expand(root)) do
          File.write!(full_path, content)
        end

        {:noreply,
         assign(socket,
           file_content: %{path: path, content: content},
           editing_file: false,
           file_saved: true
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("back_to_files", _params, socket) do
    current_path = socket.assigns.current_path
    instance = socket.assigns.instance
    runtime = socket.assigns.runtime

    if current_path == "" do
      {:noreply, assign(socket, file_content: nil)}
    else
      parent = Path.dirname(current_path)
      parent = if parent == ".", do: "", else: parent

      {:noreply,
       assign(socket,
         file_content: nil,
         workspace_files: list_workspace_files(runtime, instance, parent),
         current_path: parent
       )}
    end
  end

  # --- SQLite browser events ---

  def handle_event("close_db", _params, socket) do
    {:noreply, assign(socket, db_browser: nil, file_content: nil)}
  end

  def handle_event("db_select_table", %{"table" => table}, socket) do
    case SqliteBrowser.browse_table(socket.assigns.db_browser, table, @page_size, 0) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply,
         assign(socket,
           db_selected_table: table,
           db_columns: columns,
           db_rows: rows,
           db_total_rows: total,
           db_offset: 0,
           db_query: ~s(SELECT * FROM "#{table}"),
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
    case SqliteBrowser.query(socket.assigns.db_browser, query, @page_size, 0) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply,
         assign(socket,
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
    {:noreply, assign(socket, db_editing: {String.to_integer(idx), col})}
  end

  def handle_event("db_save_cell", %{"idx" => idx, "col" => col, "value" => value}, socket) do
    idx = String.to_integer(idx)
    table = socket.assigns.db_selected_table

    if table do
      rowids =
        SqliteBrowser.get_rowids(
          socket.assigns.db_browser,
          table,
          @page_size,
          socket.assigns.db_offset
        )

      case Enum.at(rowids, idx) do
        nil ->
          {:noreply, assign(socket, db_editing: nil, db_error: "Could not find row")}

        rowid ->
          SqliteBrowser.update_cell(socket.assigns.db_browser, table, rowid, col, value)
          refresh_view(assign(socket, db_editing: nil))
      end
    else
      {:noreply, assign(socket, db_editing: nil)}
    end
  end

  def handle_event("db_cancel_edit", _params, socket) do
    {:noreply, assign(socket, db_editing: nil)}
  end

  def handle_event("db_delete_row", %{"idx" => idx}, socket) do
    delete_by_indices([String.to_integer(idx)], socket)
  end

  def handle_event("db_delete_selected", _params, socket) do
    delete_by_indices(socket.assigns.db_selected_rows, socket)
  end

  def handle_event("db_toggle_row", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    selected = socket.assigns.db_selected_rows

    selected =
      if idx in selected, do: List.delete(selected, idx), else: [idx | selected]

    all_selected = selected != [] and length(selected) == length(socket.assigns.db_rows)
    {:noreply, assign(socket, db_selected_rows: selected, db_all_selected: all_selected)}
  end

  def handle_event("db_toggle_all", _params, socket) do
    if socket.assigns.db_all_selected do
      {:noreply, assign(socket, db_selected_rows: [], db_all_selected: false)}
    else
      all = Enum.to_list(0..(length(socket.assigns.db_rows) - 1))
      {:noreply, assign(socket, db_selected_rows: all, db_all_selected: true)}
    end
  end

  def handle_event("db_prev_page", _params, socket) do
    new_offset = max(socket.assigns.db_offset - @page_size, 0)
    paginate(socket, new_offset)
  end

  def handle_event("db_next_page", _params, socket) do
    paginate(socket, socket.assigns.db_offset + @page_size)
  end

  # --- Helpers ---

  defp delete_by_indices(indices, socket) do
    table = socket.assigns.db_selected_table

    if table && indices != [] do
      rowids =
        SqliteBrowser.get_rowids(
          socket.assigns.db_browser,
          table,
          @page_size,
          socket.assigns.db_offset
        )

      target =
        indices
        |> Enum.map(&Enum.at(rowids, &1))
        |> Enum.reject(&is_nil/1)

      if target != [] do
        SqliteBrowser.delete_rows(socket.assigns.db_browser, table, target)
        refresh_view(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp refresh_view(socket) do
    case SqliteBrowser.query(
           socket.assigns.db_browser,
           socket.assigns.db_query,
           @page_size,
           socket.assigns.db_offset
         ) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply,
         assign(socket,
           db_columns: columns,
           db_rows: rows,
           db_total_rows: total,
           db_selected_rows: [],
           db_all_selected: false,
           db_editing: nil
         )}

      _ ->
        {:noreply, socket}
    end
  end

  defp paginate(socket, new_offset) do
    case SqliteBrowser.query(
           socket.assigns.db_browser,
           socket.assigns.db_query,
           @page_size,
           new_offset
         ) do
      {:ok, %{columns: columns, rows: rows, total: total}} ->
        {:noreply,
         assign(socket,
           db_columns: columns,
           db_rows: rows,
           db_total_rows: total,
           db_offset: new_offset,
           db_selected_rows: [],
           db_all_selected: false,
           db_editing: nil
         )}

      _ ->
        {:noreply, socket}
    end
  end

  defp join_path("", path), do: path
  defp join_path(current, path), do: Path.join(current, path)

  defp list_workspace_files(runtime, instance, subpath) do
    case runtime.file_browser_root(instance) do
      nil ->
        []

      "" ->
        []

      root ->
        target = if subpath == "", do: root, else: Path.join(root, subpath)

        case File.ls(target) do
          {:ok, names} ->
            names
            |> Enum.map(fn name ->
              path = Path.join(target, name)
              stat = File.stat!(path)
              %{path: name, is_dir: stat.type == :directory, size: stat.size}
            end)
            |> Enum.sort_by(&{!&1.is_dir, &1.path})

          {:error, _} ->
            []
        end
    end
  end

  defp read_file_for_display(full_path, rel_path) do
    cond do
      binary_file?(rel_path) ->
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

              _ ->
                "Cannot read file"
            end

          _ ->
            case File.read(full_path) do
              {:ok, c} ->
                if String.valid?(c), do: c, else: "Binary file (#{byte_size(c)} bytes)"

              {:error, _} ->
                "Cannot read file"
            end
        end
    end
  end

  defp sqlite_file?(path) do
    Path.extname(path) |> String.downcase() |> Kernel.in(@sqlite_extensions)
  end

  defp binary_file?(path) do
    Path.extname(path) |> String.downcase() |> Kernel.in(@binary_extensions)
  end

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
