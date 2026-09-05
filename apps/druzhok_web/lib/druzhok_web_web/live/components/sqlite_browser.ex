defmodule DruzhokWebWeb.Live.Components.SqliteBrowser do
  use Phoenix.Component

  attr :db_path, :string, required: true
  attr :target, :any, required: true
  attr :db_tables, :list, default: []
  attr :db_selected_table, :string, default: nil
  attr :db_columns, :list, default: []
  attr :db_rows, :list, default: []
  attr :db_total_rows, :integer, default: 0
  attr :db_offset, :integer, default: 0
  attr :db_page_size, :integer, default: 50
  attr :db_query, :string, default: ""
  attr :db_error, :string, default: nil
  attr :db_selected_rows, :list, default: []
  attr :db_all_selected, :boolean, default: false
  attr :db_editing, :any, default: nil

  def sqlite_browser(assigns) do
    ~H"""
    <div class="p-4 space-y-4">
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-semibold text-fg"><%= @db_path %></h3>
        <button phx-click="close_db" phx-target={@target} class="text-xs text-muted hover:text-fg">Close</button>
      </div>

      <%!-- Table selector --%>
      <div class="flex gap-2 flex-wrap">
        <button :for={table <- @db_tables}
                phx-click="db_select_table" phx-target={@target} phx-value-table={table}
                class={"px-3 py-1.5 rounded-lg text-xs font-medium border transition #{if @db_selected_table == table, do: "bg-accent text-bg border-accent", else: "bg-panel text-fg border-line2 hover:border-accent"}"}>
          <%= table %>
        </button>
      </div>

      <%!-- SQL Query box --%>
      <div>
        <form phx-submit="db_run_query" phx-target={@target} class="flex gap-2">
          <input name="query" value={@db_query} placeholder="SELECT * FROM ..."
                 class="flex-1 bg-panel text-fg placeholder:text-subtle border border-line2 rounded-lg px-3 py-2 text-xs font-mono focus:outline-none focus:ring-1 focus:ring-accent" />
          <button type="submit" class="px-3 py-2 bg-accent text-bg rounded-lg text-xs">Run</button>
        </form>
        <p :if={@db_error} class="text-xs text-err mt-1"><%= @db_error %></p>
      </div>

      <%!-- Results table --%>
      <div :if={@db_columns != []} class="overflow-x-auto border border-line2 rounded-lg">
        <table class="w-full text-xs">
          <thead>
            <tr class="bg-raised/50 border-b border-line2">
              <th class="px-3 py-2 text-left w-8">
                <input type="checkbox" phx-click="db_toggle_all" phx-target={@target} checked={@db_all_selected} class="rounded" />
              </th>
              <th :for={col <- @db_columns} class="px-3 py-2 text-left font-medium text-muted"><%= col %></th>
              <th class="px-3 py-2 w-16"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{row, idx} <- Enum.with_index(@db_rows)} class="border-b border-line hover:bg-raised/30">
              <td class="px-3 py-2">
                <input type="checkbox" phx-click="db_toggle_row" phx-target={@target} phx-value-idx={idx}
                       checked={idx in @db_selected_rows} class="rounded" />
              </td>
              <td :for={{col, val} <- Enum.zip(@db_columns, row)} class="px-3 py-2 font-mono max-w-xs truncate text-fg"
                  phx-click="db_edit_cell" phx-target={@target} phx-value-idx={idx} phx-value-col={col}
                  title={to_string(val)}>
                <%= if @db_editing == {idx, col} do %>
                  <form phx-submit="db_save_cell" phx-target={@target} class="flex gap-1">
                    <input type="hidden" name="idx" value={idx} />
                    <input type="hidden" name="col" value={col} />
                    <input name="value" value={val} autofocus
                           class="w-full bg-panel text-fg border border-line2 rounded px-1 py-0.5 text-xs font-mono focus:outline-none focus:ring-1 focus:ring-accent" />
                    <button type="submit" class="text-ok text-xs">ok</button>
                    <button type="button" phx-click="db_cancel_edit" phx-target={@target} class="text-muted text-xs">x</button>
                  </form>
                <% else %>
                  <span class={"#{if val == nil, do: "text-subtle italic", else: ""}"}>
                    <%= if val == nil, do: "NULL", else: truncate_cell(val) %>
                  </span>
                <% end %>
              </td>
              <td class="px-3 py-2">
                <button phx-click="db_delete_row" phx-target={@target} phx-value-idx={idx}
                        class="text-err/70 hover:text-err text-xs">del</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Pagination & bulk actions --%>
      <div class="flex items-center justify-between">
        <div class="flex gap-2">
          <button :if={@db_selected_rows != []}
                  phx-click="db_delete_selected" phx-target={@target}
                  class="px-3 py-1.5 bg-err/10 text-err border border-err/30 rounded-lg text-xs hover:bg-err/20">
            Delete selected (<%= length(@db_selected_rows) %>)
          </button>
        </div>
        <div class="flex gap-2 items-center text-xs text-muted">
          <span><%= @db_total_rows %> rows</span>
          <button :if={@db_offset > 0} phx-click="db_prev_page" phx-target={@target} class="px-2 py-1 border border-line2 rounded hover:bg-raised/50">&larr;</button>
          <span>Page <%= div(@db_offset, @db_page_size) + 1 %></span>
          <button :if={@db_offset + @db_page_size < @db_total_rows} phx-click="db_next_page" phx-target={@target} class="px-2 py-1 border border-line2 rounded hover:bg-raised/50">&rarr;</button>
        </div>
      </div>
    </div>
    """
  end

  defp truncate_cell(val) when is_binary(val) and byte_size(val) > 100 do
    String.slice(val, 0, 100) <> "..."
  end
  defp truncate_cell(val), do: to_string(val)
end
