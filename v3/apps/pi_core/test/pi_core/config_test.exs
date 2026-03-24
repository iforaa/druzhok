defmodule PiCore.ConfigTest do
  use ExUnit.Case, async: true

  test "returns default values" do
    assert PiCore.Config.max_iterations() == 20
    assert PiCore.Config.max_tool_output() == 8_000
    assert PiCore.Config.idle_timeout_ms() == 7_200_000
    assert PiCore.Config.default_max_tokens() == 16_384
    assert PiCore.Config.compaction_max_messages() == 40
    assert PiCore.Config.compaction_keep_recent() == 10
    assert PiCore.Config.bash_timeout_ms() == 10_000
    assert PiCore.Config.anthropic_api_version() == "2023-06-01"
  end

  test "reads overrides from application env" do
    Application.put_env(:pi_core, :max_iterations, 10)
    assert PiCore.Config.max_iterations() == 10
  after
    Application.delete_env(:pi_core, :max_iterations)
  end
end
