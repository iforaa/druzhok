defmodule DruzhokWebWeb.Live.Components.FileBrowser do
  use Phoenix.Component

  attr :files, :list, required: true
  attr :file_content, :any, default: nil

  def file_browser(assigns) do
    ~H"""
    <div>
      <div :if={@file_content} class="p-4">
        <div class="flex items-center gap-3 mb-3">
          <button phx-click="back_to_files" class="text-xs text-gray-400 hover:text-gray-900 transition">&larr; back</button>
          <span class="text-sm text-gray-500 font-mono"><%= @file_content.path %></span>
        </div>
        <pre class="bg-gray-50 border border-gray-200 p-4 rounded-lg text-sm overflow-auto max-h-[calc(100vh-200px)] whitespace-pre-wrap font-mono text-gray-700 leading-relaxed"><%= @file_content.content %></pre>
      </div>

      <div :if={!@file_content} class="py-1">
        <div :for={file <- @files}
             class="flex items-center gap-3 py-2 px-6 hover:bg-gray-50 cursor-pointer transition"
             phx-click="view_file" phx-value-path={file.path}>
          <span :if={file.is_dir} class="text-xs text-amber-500 font-mono w-6">dir</span>
          <span :if={!file.is_dir} class="text-xs text-gray-300 font-mono w-6">&mdash;</span>
          <span class="flex-1 text-sm"><%= file.path %></span>
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
