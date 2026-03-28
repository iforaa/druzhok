defmodule Druzhok.ErrorLogger do
  @moduledoc """
  Erlang :logger handler that captures error-level logs into the crash_logs
  SQLite table for dashboard viewing.

  Installed via :logger.add_handler/3 in Application.start/2.
  """

  @max_message_size 4096

  # Called by :logger to check if this handler wants the log event
  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_action, _old, new), do: {:ok, new}

  # The main callback — receives every log event at configured level
  def log(%{level: :error, msg: msg, meta: meta}, _config) do
    try do
      message = format_message(msg) |> String.slice(0, @max_message_size)
      source = extract_source(meta)
      instance = extract_instance(meta, message)

      Druzhok.CrashLog.insert(%{
        level: "error",
        message: message,
        source: source,
        instance_name: instance
      })
    rescue
      _ -> :ok
    end
  end

  def log(_event, _config), do: :ok

  defp format_message({:string, msg}), do: to_string(msg)
  defp format_message({:report, report}) do
    try do
      inspect(report, limit: 500, printable_limit: 2000)
    rescue
      _ -> "#{inspect(report)}"
    end
  end
  defp format_message({fmt, args}) when is_list(args) do
    try do
      :io_lib.format(fmt, args) |> to_string()
    rescue
      _ -> "#{inspect(fmt)} #{inspect(args)}"
    end
  end
  defp format_message(other), do: inspect(other)

  defp extract_source(meta) do
    mfa = meta[:mfa]
    module = meta[:module] || (mfa && elem(mfa, 0))
    function = meta[:function] || (mfa && "#{elem(mfa, 1)}/#{elem(mfa, 2)}")

    cond do
      module && function -> "#{inspect(module)}.#{function}"
      module -> inspect(module)
      true ->
        case meta[:registered_name] do
          nil -> nil
          name -> to_string(name)
        end
    end
  end

  defp extract_instance(meta, message) do
    case meta[:instance_name] do
      name when is_binary(name) -> name
      _ ->
        case Regex.run(~r/instance[_\s]+(?:name[:\s]+)?["']?(\w+)["']?/i, message) do
          [_, name] -> name
          _ -> nil
        end
    end
  end
end
