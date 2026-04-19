defmodule DruzhokWebWeb.Live.Components.FileBrowser do
  use Phoenix.Component

  attr :files, :list, required: true
  attr :target, :any, required: true
  attr :file_content, :any, default: nil
  attr :current_path, :string, default: ""
  attr :editing, :boolean, default: false
  attr :file_saved, :boolean, default: false

  def file_browser(assigns) do
    ~H"""
    <div>
      <div :if={@file_content} class="p-4 flex flex-col" style="height: calc(100vh - 160px);">
        <div class="flex items-center gap-3 mb-3">
          <button phx-click="back_to_files" phx-target={@target} class="text-xs text-muted hover:text-fg transition">&larr; back</button>
          <span class="text-sm text-muted font-mono flex-1"><%= @file_content.path %></span>
          <span :if={@file_saved} class="text-xs text-ok font-medium">Saved</span>
          <button phx-click="save_file" phx-target={@target} class="bg-accent hover:brightness-110 text-bg rounded-lg px-3 py-1 text-xs font-medium transition">Save</button>
        </div>

        <textarea
          id="file-editor"
          phx-hook="FileEditor"
          name="file_content"
          class="flex-1 bg-panel border border-line2 p-4 rounded-lg text-sm font-mono text-fg leading-relaxed resize-none focus:outline-none focus:ring-1 focus:ring-accent focus:border-accent"
          spellcheck="false"><%= @file_content.content %></textarea>
      </div>

      <div :if={!@file_content} class="py-1">
        <div :if={@current_path != ""} class="flex items-center gap-3 py-2 px-6 border-b border-line">
          <button phx-click="back_to_files" phx-target={@target} class="text-xs text-muted hover:text-fg transition">&larr; back</button>
          <span class="text-xs text-muted font-mono"><%= @current_path %></span>
        </div>
        <div :for={file <- @files}
             class="flex items-center gap-3 py-2 px-6 hover:bg-raised/50 cursor-pointer transition"
             phx-click="view_file" phx-target={@target} phx-value-path={file.path} phx-value-is_dir={to_string(file.is_dir)}>
          <span :if={file.is_dir} class="text-xs text-accent font-mono w-6">dir</span>
          <span :if={!file.is_dir} class="text-xs text-subtle font-mono w-6">&mdash;</span>
          <span class="flex-1 text-sm text-fg"><%= file.path %></span>
          <span :if={file.is_dir} class="text-xs text-subtle">&rsaquo;</span>
          <span :if={!file.is_dir} class="text-xs text-muted font-mono"><%= format_size(file.size) %></span>
        </div>
      </div>
    </div>
    """
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
