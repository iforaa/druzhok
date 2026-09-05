defmodule DruzhokWebWeb.LlmProxy.SearchTest do
  use DruzhokWebWeb.ProxyCase

  @results [
    %{"title" => "Нанорубль", "url" => "https://ru.wikipedia.org/x", "description" => "Одна миллиардная рубля."},
    %{"title" => "Second", "url" => "https://b.example", "snippet" => "uses snippet key"}
  ]

  # Error paths answer with send_resp and no content-type header, so
  # json_response/2 refuses them; decode by hand.
  defp firecrawl_error(conn, status) do
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end

  defp expect_search(bypass, content, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{"prompt_tokens" => 50, "completion_tokens" => 80, "cost" => 0.008})

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion(content, usage: usage, model: "perplexity/sonar")))
    end)
  end

  test "asks perplexity/sonar for a JSON array and returns the Firecrawl shape",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer test-or-key"]
      assert sent["model"] == "perplexity/sonar"
      assert sent["usage"] == %{"include" => true}
      [system, user] = sent["messages"]
      assert system["role"] == "system"
      assert system["content"] =~ "web search API"
      assert user["content"] =~ "что такое нанорубль"
      assert user["content"] =~ "up to 2 results"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion(Jason.encode!(@results), model: "perplexity/sonar")))
    end)

    conn = post(conn, "/v2/search", %{"query" => "что такое нанорубль", "limit" => 2})

    assert %{"success" => true, "data" => %{"web" => web}} = json_response(conn, 200)

    assert web == [
             %{"title" => "Нанорубль", "url" => "https://ru.wikipedia.org/x", "description" => "Одна миллиардная рубля.", "position" => 1},
             %{"title" => "Second", "url" => "https://b.example", "description" => "uses snippet key", "position" => 2}
           ]
  end

  test "accepts results wrapped in {results: [...]} or {web: [...]}", %{conn: conn, bypass: bypass} do
    for key <- ["results", "web"] do
      expect_search(bypass, Jason.encode!(%{key => @results}))
      conn = post(conn, "/v2/search", %{"query" => "q"})
      assert length(json_response(conn, 200)["data"]["web"]) == 2
    end
  end

  test "digs a JSON array out of surrounding prose", %{conn: conn, bypass: bypass} do
    expect_search(bypass, "Here you go:\n" <> Jason.encode!(@results) <> "\nHope this helps.")
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert length(json_response(conn, 200)["data"]["web"]) == 2
  end

  test "returns an empty list when the model answers with no array", %{conn: conn, bypass: bypass} do
    expect_search(bypass, "I could not find anything.")
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert json_response(conn, 200)["data"]["web"] == []
  end

  test "fills missing title/url with empty strings", %{conn: conn, bypass: bypass} do
    expect_search(bypass, Jason.encode!([%{"snippet" => "only a snippet"}]))
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert json_response(conn, 200)["data"]["web"] == [%{"title" => "", "url" => "", "description" => "only a snippet", "position" => 1}]
  end

  test "truncates to limit and clamps limit to 1..20 (default 5)", %{conn: conn, bypass: bypass} do
    many = Enum.map(1..30, &%{"title" => "t#{&1}", "url" => "u#{&1}", "description" => "d"})
    expect_search(bypass, Jason.encode!(many))

    for {given, expected} <- [{1, 1}, {"3", 3}, {20, 20}, {25, 5}, {0, 5}, {"x", 5}, {nil, 5}] do
      body = if given, do: %{"query" => "q", "limit" => given}, else: %{"query" => "q"}
      conn = post(conn, "/v2/search", body)
      assert length(json_response(conn, 200)["data"]["web"]) == expected, "limit #{inspect(given)}"
    end
  end

  test "400 on an empty query", %{conn: conn} do
    conn = post(conn, "/v2/search", %{"query" => ""})
    assert firecrawl_error(conn, 400) == %{"success" => false, "error" => "query is required"}
  end

  test "meters as request_type search with the query as preview",
       %{conn: conn, bypass: bypass, instance: instance} do
    expect_search(bypass, Jason.encode!(@results), usage: %{"prompt_tokens" => 50, "completion_tokens" => 80, "cost" => 0.011})
    post(conn, "/v2/search", %{"query" => "нанорубль"})

    assert [log] = usage_logs(instance)
    assert log.request_type == "search"
    assert log.model == "perplexity/sonar"
    assert log.total_tokens == 130
    assert log.cost_cents == 1
    assert log.prompt_preview == "нанорубль"
    assert spent_today(instance) == 1
  end

  test "relays upstream failures in the Firecrawl error shape", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> Plug.Conn.resp(req, 503, "nope") end)
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert firecrawl_error(conn, 503) == %{"success" => false, "error" => "upstream error"}
  end

  test "502 in the Firecrawl shape when the upstream body is not JSON", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> Plug.Conn.resp(req, 200, "<html>") end)
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert firecrawl_error(conn, 502) == %{"success" => false, "error" => "invalid upstream response"}
  end

  test "502 in the Firecrawl shape when the upstream is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert firecrawl_error(conn, 502) == %{"success" => false, "error" => "search provider unavailable"}
  end

  test "429 in the Firecrawl shape when the budget is spent" do
    instance = create_instance(%{daily_budget_cents: 5})
    Druzhok.Budget.deduct(instance.id, 5)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert firecrawl_error(conn, 429) == %{"success" => false, "error" => "Token budget exceeded"}
  end
end
