defmodule DruzhokWebWeb.Live.Components.FileBrowser do
  use Phoenix.Component

  attr :files, :list, required: true
  attr :file_content, :any, default: nil
  attr :current_path, :string, default: ""
  attr :editing, :boolean, default: false
  attr :file_saved, :boolean, default: false

  def file_browser(assigns) do
    ~H"""
    <div>
      <div :if={@file_content} class="p-4 flex flex-col" style="height: calc(100vh - 160px);">
        <div class="flex items-center gap-3 mb-3">
          <button phx-click="back_to_files" class="text-xs text-gray-400 hover:text-gray-900 transition">&larr; back</button>
          <span class="text-sm text-gray-500 font-mono flex-1"><%= @file_content.path %></span>
          <span :if={@file_saved} class="text-xs text-green-500 font-medium">Saved</span>
          <button :if={!@editing} phx-click="edit_file" class="text-xs text-gray-500 hover:text-gray-900 font-medium transition">Edit</button>
          <button :if={@editing} phx-click="save_file" class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1 text-xs font-medium transition">Save</button>
          <button :if={@editing} phx-click="cancel_edit" class="text-xs text-gray-400 hover:text-gray-900 font-medium transition">Cancel</button>
        </div>

        <textarea :if={@editing}
          id="file-editor"
          phx-hook="FileEditor"
          name="file_content"
          class="flex-1 bg-gray-50 border border-gray-200 p-4 rounded-lg text-sm font-mono text-gray-700 leading-relaxed resize-none focus:outline-none focus:ring-1 focus:ring-gray-900 focus:border-gray-900"
          spellcheck="false"><%= @file_content.content %></textarea>

        <pre :if={!@editing}
          class="flex-1 bg-gray-50 border border-gray-200 p-4 rounded-lg text-sm overflow-auto whitespace-pre-wrap font-mono text-gray-700 leading-relaxed"><%= @file_content.content %></pre>
      </div>

      <div :if={!@file_content} class="py-1">
        <div :if={@current_path != ""} class="flex items-center gap-3 py-2 px-6 border-b border-gray-100">
          <button phx-click="back_to_files" class="text-xs text-gray-400 hover:text-gray-900 transition">&larr; back</button>
          <span class="text-xs text-gray-400 font-mono"><%= @current_path %></span>
        </div>
        <div :for={file <- @files}
             class="flex items-center gap-3 py-2 px-6 hover:bg-gray-50 cursor-pointer transition"
             phx-click="view_file" phx-value-path={file.path} phx-value-is_dir={to_string(file.is_dir)}>
          <span :if={file.is_dir} class="text-xs text-amber-500 font-mono w-6">dir</span>
          <span :if={!file.is_dir} class="text-xs text-gray-300 font-mono w-6">&mdash;</span>
          <span class="flex-1 text-sm"><%= file.path %></span>
          <span :if={file.is_dir} class="text-xs text-gray-300">&rsaquo;</span>
          <span :if={!file.is_dir} class="text-xs text-gray-400 font-mono"><%= format_size(file.size) %></span>
        </div>
      </div>
    </div>
    """
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
