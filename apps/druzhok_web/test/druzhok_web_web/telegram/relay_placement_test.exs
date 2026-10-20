defmodule DruzhokWebWeb.Telegram.RelayPlacementTest do
  use ExUnit.Case, async: true

  # A BEAM that boots the app without serving the endpoint (tests here, a
  # one-off druzhok-run.sh, mix druzhok.migrate_ruoc, iex -S mix) must not run
  # a second Telegram relay next to druzhok.service's.
  test "no relay where the endpoint does not serve" do
    refute Phoenix.Endpoint.server?(:druzhok_web, DruzhokWebWeb.Endpoint)
    assert Process.whereis(Druzhok.Telegram.Relay) == nil
  end
end
