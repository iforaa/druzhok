defmodule Druzhok.Agent.ToolStatus do
  @moduledoc "Maps tool names to localized status strings."

  alias Druzhok.I18n

  @tool_keys %{
    "web_fetch" => :tool_web_fetch,
    "bash" => :tool_bash,
    "read" => :tool_read,
    "write" => :tool_write,
    "edit" => :tool_edit,
    "grep" => :tool_grep,
    "find" => :tool_find,
    "memory_search" => :tool_memory_search,
    "memory_write" => :tool_memory_write,
    "generate_image" => :tool_generate_image,
    "send_file" => :tool_send_file,
    "set_reminder" => :tool_set_reminder,
  }

  def status_text(tool_name, lang \\ "ru") do
    key = Map.get(@tool_keys, String.downcase(tool_name), :tool_default)
    I18n.t(key, lang)
  end
end
