defmodule Druzhok.SettingsTest do
  use ExUnit.Case

  test "get returns nil for unset or blank values" do
    assert is_nil(Druzhok.Settings.get("definitely_unset_key"))
  end
end
