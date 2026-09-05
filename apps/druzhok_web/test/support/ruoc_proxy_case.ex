defmodule DruzhokWebWeb.RuocProxyCase do
  @moduledoc """
  Case template for the ruoc path of the LLM proxy: a `Druzhok.RuocStub` as
  the gateway, one migrated instance (ruoc key set), and a conn carrying its
  tenant key. Tests add `Bypass.expect_once(stub.bypass, ...)` for the
  endpoint under test.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use DruzhokWebWeb.ConnCase, async: false
      import DruzhokWebWeb.ProxyCase, only: [create_instance: 1, authed: 2, usage_logs: 1]
      import DruzhokWebWeb.UpstreamStub
      import DruzhokWebWeb.RuocProxyCase

      setup :ruoc_proxy_setup
    end
  end

  @bot_key "ruoc_botkey00000000000000000000000000000"

  def bot_key, do: @bot_key

  def ruoc_proxy_setup(_context) do
    stub = Druzhok.RuocStub.start()
    instance = DruzhokWebWeb.ProxyCase.create_instance(%{model: "ruoc-flash", ruoc_account_id: "acct-1", ruoc_api_key: @bot_key})
    conn = DruzhokWebWeb.ProxyCase.authed(Phoenix.ConnTest.build_conn(), instance)
    %{stub: stub, bypass: stub.bypass, instance: instance, conn: conn}
  end

  @doc "A gateway reply with the request id header; `body` is a map or a string."
  def gateway_reply(conn, status, body, request_id \\ "req_abc") do
    payload = if is_binary(body), do: body, else: Jason.encode!(body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("x-ruoc-request-id", request_id)
    |> Plug.Conn.resp(status, payload)
  end

  def gateway_error(conn, status, type, message) do
    gateway_reply(conn, status, %{"error" => %{"type" => type, "message" => message}})
  end
end
