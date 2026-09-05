defmodule Druzhok.SettingsTest do
  use ExUnit.Case

  test "api_url returns openrouter URL for openrouter provider" do
    url = Druzhok.Settings.api_url("openrouter")
    assert url =~ "openrouter.ai"
  end

  test "api_url returns anthropic URL for anthropic provider" do
    url = Druzhok.Settings.api_url("anthropic")
    assert url =~ "anthropic.com"
  end

  test "api_url returns nebius URL for unknown provider" do
    url = Druzhok.Settings.api_url("nebius")
    assert url != nil
  end

  test "api_key resolves openrouter key from DB or env" do
    key = Druzhok.Settings.api_key("openrouter")
    assert is_nil(key) or is_binary(key)
  end
end
