defmodule PiCore.Config do
  @moduledoc """
  Centralized configuration constants for PiCore.

  Each function returns the value from application env `:pi_core`,
  falling back to a compile-time default.
  """

  @defaults [
    max_iterations: 20,
    max_tool_output: 8_000,
    idle_timeout_ms: 2 * 60 * 60 * 1000,
    default_max_tokens: 16_384,
    compaction_max_messages: 40,
    compaction_keep_recent: 10,
    bash_timeout_ms: 10_000,
    anthropic_api_version: "2023-06-01"
  ]

  for {key, default} <- @defaults do
    def unquote(key)() do
      Application.get_env(:pi_core, unquote(key), unquote(default))
    end
  end
end
