defmodule Druzhok.ErrorLogger do
  @moduledoc """
  Custom Logger backend that captures error-level logs and OTP crash reports
  into the crash_logs SQLite table for dashboard viewing.
  """
  @behaviour :gen_event

  @max_message_size 4096

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_event({level, _gl, {Logger, message, _timestamp, metadata}}, state)
      when level in [:error] do
    try do
      msg = to_string(message) |> String.slice(0, @max_message_size)
      source = extract_source(metadata)
      instance = extract_instance(metadata, msg)

      Druzhok.CrashLog.insert(%{
        level: to_string(level),
        message: msg,
        source: source,
        instance_name: instance
      })
    rescue
      _ -> :ok
    end

    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  defp extract_source(metadata) do
    module = metadata[:module]
    function = metadata[:function]

    cond do
      module && function -> "#{inspect(module)}.#{function}"
      module -> inspect(module)
      true -> metadata[:registered_name] && to_string(metadata[:registered_name])
    end
  end

  defp extract_instance(metadata, message) do
    # Try metadata first
    case metadata[:instance_name] do
      name when is_binary(name) -> name
      _ ->
        # Try to extract from message (e.g. "druzhok-1-igor" or instance name references)
        case Regex.run(~r/instance[_\s]+(?:name[:\s]+)?["']?(\w+)["']?/i, message) do
          [_, name] -> name
          _ -> nil
        end
    end
  end
end
