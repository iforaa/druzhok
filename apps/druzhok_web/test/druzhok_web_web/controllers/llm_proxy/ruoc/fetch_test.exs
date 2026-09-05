defmodule DruzhokWebWeb.LlmProxy.Ruoc.FetchTest do
  use DruzhokWebWeb.RuocProxyCase

  defp page_reply(url) do
    %{"request_id" => "req_pg", "url" => url, "final_url" => url <> "/", "title" => "Example Domain",
      "markdown" => "# Example Domain\n\nThis domain is for use in illustrative examples.", "status_code" => 200}
  end

  test "forwards the url with the bot's key and answers in Firecrawl's scrape shape",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/fetch", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> bot_key()]
      assert Jason.decode!(raw) == %{"url" => "https://example.com"}
      gateway_reply(req, 200, page_reply("https://example.com"), "req_pg")
    end)

    conn = post(conn, "/v2/scrape", %{"url" => "https://example.com", "formats" => ["markdown", "html"]})

    assert %{"success" => true, "data" => data} = json_response(conn, 200)
    assert data["markdown"] =~ "# Example Domain"
    assert data["metadata"] == %{"title" => "Example Domain", "sourceURL" => "https://example.com/", "statusCode" => 200, "url" => "https://example.com"}
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_pg"]
  end

  test "meters as fetch with the url and title as previews, no tokens, no cost",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/fetch", fn req -> gateway_reply(req, 200, page_reply("https://example.com")) end)
    post(conn, "/v2/scrape", %{"url" => "https://example.com"})

    assert [log] = usage_logs(instance)
    assert log.request_type == "fetch"
    assert log.provider == "ruoc"
    assert log.model == "ruoc-fetch"
    assert log.total_tokens == 0 and log.cost_cents == 0
    assert log.prompt_preview == "https://example.com"
    assert log.response_preview == "Example Domain"
  end

  test "an empty balance keeps the 402 and carries the localized notice", %{bypass: bypass} do
    instance = create_instance(%{language: "ru"})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)
    Bypass.expect_once(bypass, "POST", "/v1/fetch", fn req -> gateway_error(req, 402, "insufficient_quota", "account balance is too low for a page fetch") end)

    conn = post(conn, "/v2/scrape", %{"url" => "https://example.com"})
    assert %{"success" => false, "error" => msg} = json_response(conn, 402)
    assert msg == DruzhokWebWeb.LlmProxy.BalanceNotice.text(instance)
    assert usage_logs(instance) == []
  end

  test "other gateway refusals keep their status and message", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/fetch", fn req ->
      gateway_reply(req, 422, %{"error" => %{"type" => "invalid_request_error", "message" => "the page has no extractable text", "status_code" => 404}})
    end)

    conn = post(conn, "/v2/scrape", %{"url" => "https://example.com/missing"})
    assert %{"success" => false, "error" => "the page has no extractable text"} = json_response(conn, 422)
  end

  test "a gateway that cannot be reached is a 502", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v2/scrape", %{"url" => "https://example.com"})
    assert %{"success" => false, "error" => "fetch provider unavailable"} = json_response(conn, 502)
  end

  test "a request without a url is refused before the gateway", %{conn: conn, bypass: bypass} do
    Bypass.stub(bypass, "POST", "/v1/fetch", fn _ -> flunk("must not reach ruoc") end)
    assert %{"success" => false} = json_response(post(conn, "/v2/scrape", %{"formats" => ["markdown"]}), 400)
    assert %{"success" => false} = json_response(post(conn, "/v2/scrape", %{"url" => ""}), 400)
  end
end
