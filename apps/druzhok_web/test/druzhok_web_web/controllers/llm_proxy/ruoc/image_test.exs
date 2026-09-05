defmodule DruzhokWebWeb.LlmProxy.Ruoc.ImageTest do
  use DruzhokWebWeb.RuocProxyCase

  @png_b64 Base.encode64("\x89PNG-fake")

  defp image_reply(model) do
    %{"request_id" => "req_img", "model" => model, "image" => %{"b64" => @png_b64, "mime" => "image/png"}}
  end

  test "forwards the prompt with the bot's key, ignores the client's model, answers in OpenAI shape",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> bot_key()]
      assert sent == %{"prompt" => "a red fox"}
      gateway_reply(req, 200, image_reply("ruoc-flux-klein"), "req_img")
    end)

    conn = post(conn, "/v1/images/generations", %{"model" => "dall-e-3", "prompt" => "a red fox"})

    assert %{"created" => created, "data" => [%{"b64_json" => @png_b64}]} = json_response(conn, 200)
    assert is_integer(created)
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_img"]
  end

  test "names the bot's image_gen_model when one is set", %{bypass: bypass} do
    instance = create_instance(%{image_gen_model: "ruoc-flux-pro"})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw) == %{"prompt" => "x", "model" => "ruoc-flux-pro"}
      gateway_reply(req, 200, image_reply("ruoc-flux-pro"))
    end)

    assert post(conn, "/v1/images/generations", %{"prompt" => "x"}).status == 200
  end

  test "meters as image_gen with provider ruoc, the model ruoc used and no cost",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/images", fn req -> gateway_reply(req, 200, image_reply("ruoc-flux-klein")) end)

    post(conn, "/v1/images/generations", %{"prompt" => "a red fox"})

    assert [log] = usage_logs(instance)
    assert log.request_type == "image_gen"
    assert log.provider == "ruoc"
    assert log.model == "ruoc-flux-klein"
    assert log.cost_cents == 0
    assert log.total_tokens == 0
    assert log.prompt_preview == "a red fox"
  end

  test "an empty balance becomes a 402 whose message is the localized notice", %{bypass: bypass} do
    instance = create_instance(%{language: "ru"})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
      gateway_error(req, 402, "insufficient_quota", "account balance is too low for an image")
    end)

    assert %{"error" => %{"message" => msg, "type" => "insufficient_quota"}} =
             json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 402)

    assert msg == DruzhokWebWeb.LlmProxy.BalanceNotice.text(instance)
    assert usage_logs(instance) == []
  end

  test "an unknown model is relayed as ruoc's 400", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
      gateway_error(req, 400, "invalid_request_error", "unknown image model")
    end)

    assert %{"error" => %{"message" => "unknown image model"}} =
             json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 400)
  end

  test "502 when the gateway fails or is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
      gateway_error(req, 502, "api_error", "the image provider could not be reached")
    end)

    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 502)["error"]["message"] ==
             "the image provider could not be reached"

    Bypass.down(bypass)
    conn = post(conn, "/v1/images/generations", %{"prompt" => "x"})
    assert json_response(conn, 502)["error"]["message"] == "Image generation provider unavailable"
  end
end
