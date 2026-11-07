defmodule DruzhokWebWeb.LlmProxy.InflightTest do
  @moduledoc "Every proxy call counts as open for its bot until it ends (bot queue spec)."
  use DruzhokWebWeb.ProxyCase

  setup do
    Druzhok.Settings.set("openai_api_key", "sk-test-openai")
    :ok
  end

  test "the bot is busy while its call is upstream, and not after", %{
    conn: conn,
    bypass: bypass,
    instance: instance
  } do
    test = self()

    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      send(test, {:during, Druzhok.Inflight.busy?(instance.id)})
      Plug.Conn.resp(req, 200, "audio")
    end)

    refute Druzhok.Inflight.busy?(instance.id)
    conn = post(conn, "/v1/audio/speech", %{"model" => "m", "voice" => "v", "input" => "x"})
    assert conn.status == 200
    assert_receive {:during, true}
    refute Druzhok.Inflight.busy?(instance.id)
  end

  test "a call that fails upstream is not left open", %{
    conn: conn,
    bypass: bypass,
    instance: instance
  } do
    Bypass.down(bypass)
    conn = post(conn, "/v1/audio/speech", %{"model" => "m", "voice" => "v", "input" => "x"})
    assert conn.status == 502
    refute Druzhok.Inflight.busy?(instance.id)
  end
end
