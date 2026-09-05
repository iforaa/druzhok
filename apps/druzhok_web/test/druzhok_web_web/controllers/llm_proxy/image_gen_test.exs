defmodule DruzhokWebWeb.LlmProxy.ImageGenTest do
  use DruzhokWebWeb.ProxyCase

  @png_b64 Base.encode64("\x89PNG-fake")

  defp image_reply(model, usage \\ %{"prompt_tokens" => 20, "completion_tokens" => 0, "cost" => 0.014}) do
    %{
      "id" => "gen-img",
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => "",
            "images" => [%{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> @png_b64}}]
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => usage
    }
  end

  test "ignores the client's model, uses the catalog default, asks for image modality only",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer test-or-key"]
      assert sent["model"] == "black-forest-labs/flux.2-klein-4b"
      assert sent["modalities"] == ["image"]
      assert sent["messages"] == [%{"role" => "user", "content" => "a red fox"}]
      assert sent["usage"] == %{"include" => true}
      Plug.Conn.resp(req, 200, Jason.encode!(image_reply("black-forest-labs/flux.2-klein-4b")))
    end)

    conn = post(conn, "/v1/images/generations", %{"model" => "dall-e-3", "prompt" => "a red fox"})

    assert %{"created" => created, "data" => [%{"b64_json" => b64}]} = json_response(conn, 200)
    assert is_integer(created)
    assert b64 == @png_b64
  end

  test "uses the instance's image_gen_model and adds text modality for google models", %{bypass: bypass} do
    instance = create_instance(%{image_gen_model: "google/gemini-2.5-flash-image"})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["model"] == "google/gemini-2.5-flash-image"
      assert sent["modalities"] == ["image", "text"]
      Plug.Conn.resp(req, 200, Jason.encode!(image_reply("google/gemini-2.5-flash-image")))
    end)

    assert post(conn, "/v1/images/generations", %{"prompt" => "x"}).status == 200
  end

  test "meters as request_type image_gen using the reported cost", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(image_reply("black-forest-labs/flux.2-klein-4b", %{"prompt_tokens" => 20, "completion_tokens" => 0, "cost" => 0.034})))
    end)

    post(conn, "/v1/images/generations", %{"prompt" => "x"})

    assert [log] = usage_logs(instance)
    assert log.request_type == "image_gen"
    assert log.model == "black-forest-labs/flux.2-klein-4b"
    assert log.cost_cents == 3
    assert log.total_tokens == 0
    assert spent_today(instance) == 3
  end

  test "tolerates leading whitespace in the upstream body", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, "\n\n  " <> Jason.encode!(image_reply("black-forest-labs/flux.2-klein-4b")))
    end)

    assert [%{"b64_json" => _}] = json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 200)["data"]
  end

  test "returns an empty data list when the reply carries no images or non-data URLs", %{conn: conn, bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("no image for you")))
    end)

    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 200)["data"] == []

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn req ->
      reply = put_in(image_reply("m"), ["choices", Access.at(0), "message", "images"], [%{"image_url" => %{"url" => "https://cdn/x.png"}}])
      Plug.Conn.resp(req, 200, Jason.encode!(reply))
    end)

    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 200)["data"] == []
  end

  test "relays upstream errors", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> Plug.Conn.resp(req, 402, ~s({"error":"pay"})) end)
    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 402) == %{"error" => "pay"}
  end

  test "502 when unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/images/generations", %{"prompt" => "x"})
    assert json_response(conn, 502)["error"]["message"] == "Image generation provider unavailable"
  end

  test "429 on spent budget" do
    instance = create_instance(%{daily_budget_cents: 1})
    Druzhok.Budget.deduct(instance.id, 1)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)
    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 429)["error"]["type"] == "budget_exceeded"
  end
end
