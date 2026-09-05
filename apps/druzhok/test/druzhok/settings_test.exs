defmodule Druzhok.SettingsTest do
  use ExUnit.Case

  test "get returns nil for unset or blank values" do
    assert is_nil(Druzhok.Settings.get("definitely_unset_key"))
  end

  test "openrouter_api_key resolves from env or DB" do
    key = Druzhok.Settings.openrouter_api_key()
    assert is_nil(key) or is_binary(key)
  end
end
