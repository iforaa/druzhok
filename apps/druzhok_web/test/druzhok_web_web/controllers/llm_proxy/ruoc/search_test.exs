defmodule DruzhokWebWeb.LlmProxy.Ruoc.SearchTest do
  use DruzhokWebWeb.RuocProxyCase

  @results [
    %{"title" => "Нанорубль", "url" => "https://ru.wikipedia.org/x", "content" => "Одна миллиардная.", "score" => 0.9},
    %{"title" => "Second", "url" => "https://b", "content" => "b", "score" => 0.5, "published_date" => "2026-01-01"}
  ]

  test "maps Firecrawl query/limit to ruoc search and results back to Firecrawl shape",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/search", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> bot_key()]
      assert Jason.decode!(raw) == %{"query" => "что такое нанорубль", "max_results" => 3}
      gateway_reply(req, 200, %{"query" => "что такое нанорубль", "results" => @results, "request_id" => "req_q"}, "req_q")
    end)

    conn = post(conn, "/v2/search", %{"query" => "что такое нанорубль", "limit" => 3})

    assert json_response(conn, 200) == %{
             "success" => true,
             "data" => %{
               "web" => [
                 %{"title" => "Нанорубль", "url" => "https://ru.wikipedia.org/x", "description" => "Одна миллиардная.", "position" => 1},
                 %{"title" => "Second", "url" => "https://b", "description" => "b", "position" => 2}
               ]
             }
           }

    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_q"]
    assert [log] = usage_logs(instance)
    assert log.request_type == "search"
    assert log.provider == "ruoc"
    assert log.prompt_preview == "что такое нанорубль"
    assert log.response_preview == "Нанорубль | Second"
    assert log.cost_cents == 0
  end

  test "clamps limit to the gateway's 10 and defaults to 5", %{conn: conn, bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/search", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      send(self(), {:max, Jason.decode!(raw)["max_results"]})
      gateway_reply(req, 200, %{"results" => []})
    end)

    assert post(conn, "/v2/search", %{"query" => "q", "limit" => 20}).status == 200
    assert post(conn, "/v2/search", %{"query" => "q"}).status == 200
  end

  test "empty query is a 400 before any upstream call", %{conn: conn} do
    conn = post(conn, "/v2/search", %{"query" => ""})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["success"] == false
  end

  test "gateway errors keep their status in the Firecrawl error shape", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/search", fn req ->
      gateway_error(req, 402, "insufficient_quota", "account balance is too low")
    end)

    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert conn.status == 402
    assert Jason.decode!(conn.resp_body) == %{"success" => false, "error" => "account balance is too low"}
  end

  test "502 when the gateway is down", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert conn.status == 502
    assert Jason.decode!(conn.resp_body) == %{"success" => false, "error" => "search provider unavailable"}
  end

  test "/v2/scrape is still not served, so hermes falls back to its browser", %{conn: conn} do
    assert post(conn, "/v2/scrape", %{"url" => "https://x"}).status == 404
  end
end
