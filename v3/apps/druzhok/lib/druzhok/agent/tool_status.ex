defmodule Druzhok.Agent.ToolStatus do
  @moduledoc "Maps tool names to Russian status strings for Telegram."

  @status_map %{
    "web_fetch" => "Ищу в интернете...",
    "bash" => "Выполняю команду...",
    "read" => "Читаю файл...",
    "write" => "Пишу файл...",
    "edit" => "Редактирую файл...",
    "grep" => "Ищу в файлах...",
    "find" => "Ищу в файлах...",
    "memory_search" => "Ищу в памяти...",
    "memory_write" => "Сохраняю в память...",
    "generate_image" => "Генерирую изображение...",
    "send_file" => "Отправляю файл...",
    "set_reminder" => "Устанавливаю напоминание...",
  }

  def status_text(tool_name) do
    Map.get(@status_map, String.downcase(tool_name), "Работаю...")
  end
end
