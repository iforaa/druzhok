defmodule Druzhok.SqliteBrowser do
  @moduledoc """
  Direct SQLite access for browsing arbitrary .db files.
  """

  @page_size 50

  def open(db_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    result = tables(conn)
    Exqlite.Sqlite3.close(conn)
    result
  end

  def tables(db_path) when is_binary(db_path) do
    with_conn(db_path, &tables/1)
  end

  def tables(conn) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    rows = fetch_all(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    Enum.map(rows, fn [name] -> name end)
  end

  def query(db_path, sql, page_size \\ @page_size, offset \\ 0) do
    with_conn(db_path, fn conn ->
      # Get total count for the table if it's a simple SELECT
      total = if String.match?(sql, ~r/^\s*SELECT/i) do
        count_sql = "SELECT COUNT(*) FROM (#{String.trim_trailing(sql, ";")}) __count_sub"
        case safe_query(conn, count_sql) do
          {:ok, [[count]]} -> count
          _ -> 0
        end
      else
        0
      end

      # Run paginated query
      paginated = "#{String.trim_trailing(sql, ";")} LIMIT #{page_size} OFFSET #{offset}"
      case safe_query(conn, paginated) do
        {:ok, rows} ->
          columns = column_names(conn, paginated)
          {:ok, %{columns: columns, rows: rows, total: total}}
        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def browse_table(db_path, table, page_size \\ @page_size, offset \\ 0) do
    query(db_path, "SELECT * FROM \"#{table}\"", page_size, offset)
  end

  def update_cell(db_path, table, rowid, column, value) do
    with_conn(db_path, fn conn ->
      sql = "UPDATE \"#{table}\" SET \"#{column}\" = ?1 WHERE rowid = ?2"
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      :ok = Exqlite.Sqlite3.bind(stmt, [value, rowid])
      Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
      :ok
    end)
  end

  def delete_rows(db_path, table, rowids) when is_list(rowids) do
    with_conn(db_path, fn conn ->
      placeholders = Enum.map_join(1..length(rowids), ",", &"?#{&1}")
      sql = "DELETE FROM \"#{table}\" WHERE rowid IN (#{placeholders})"
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      :ok = Exqlite.Sqlite3.bind(stmt, rowids)
      Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
      :ok
    end)
  end

  def get_rowids(db_path, table, page_size, offset) do
    with_conn(db_path, fn conn ->
      sql = "SELECT rowid FROM \"#{table}\" LIMIT #{page_size} OFFSET #{offset}"
      case safe_query(conn, sql) do
        {:ok, rows} -> Enum.map(rows, fn [id] -> id end)
        _ -> []
      end
    end)
  end

  defp with_conn(db_path, fun) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    result = fun.(conn)
    Exqlite.Sqlite3.close(conn)
    result
  end

  defp safe_query(conn, sql) do
    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      rows = fetch_all(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
      {:ok, rows}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :error, reason -> {:error, inspect(reason)}
    end
  end

  defp fetch_all(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all(conn, stmt, acc ++ [row])
      :done -> acc
      _ -> acc
    end
  end

  defp column_names(conn, sql) do
    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      {:ok, names} = Exqlite.Sqlite3.columns(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
      names
    rescue
      _ -> []
    end
  end
end
