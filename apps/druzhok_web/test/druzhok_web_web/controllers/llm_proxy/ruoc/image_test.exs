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

  test "passes the requested size on", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw) == %{"prompt" => "x", "size" => "1536x1024"}
      gateway_reply(req, 200, image_reply("ruoc-flux-klein"))
    end)

    assert post(conn, "/v1/images/generations", %{"prompt" => "x", "size" => "1536x1024"}).status == 200
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

  test "a spent window is a 402 with the notice, and tells the owner", %{conn: conn, bypass: bypass, instance: instance} do
    watch_cabinet()
    Bypass.expect_once(bypass, "POST", "/v1/images", &usage_limit/1)

    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 402) ==
             %{"error" => %{"message" => DruzhokWebWeb.LlmProxy.BalanceNotice.text(instance), "type" => "insufficient_quota"}}

    assert_owner_told(instance)
  end

  test "a 402 does not tell the owner, as before", %{conn: conn, bypass: bypass} do
    watch_cabinet()
    Bypass.expect_once(bypass, "POST", "/v1/images", fn req -> gateway_error(req, 402, "insufficient_quota", "no") end)

    assert post(conn, "/v1/images/generations", %{"prompt" => "x"}).status == 402
    refute_owner_told()
  end

  test "an ordinary 429 is relayed and tells nobody", %{conn: conn, bypass: bypass} do
    watch_cabinet()
    Bypass.expect_once(bypass, "POST", "/v1/images", fn req -> gateway_error(req, 429, "rate_limit_error", "slow down") end)

    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 429) ==
             %{"error" => %{"type" => "rate_limit_error", "message" => "slow down"}}

    refute_owner_told()
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

  describe "catalogue" do
    test "passes the account's catalogue through verbatim with its own key", %{bypass: bypass} do
      instance = create_instance(%{image_gen_enabled: true})
      conn = authed(build_conn(), instance)
      body = ~s({"models": [{"id":"draw","edits":false},{"id":"editor","edits":true,"max_reference_images":4,"extra":{"quality":"high"}}],"version":2})

      Bypass.expect_once(bypass, "GET", "/v1/images/models", fn req ->
        assert get_req_header(req, "authorization") == ["Bearer " <> instance.ruoc_api_key]
        gateway_reply(req, 200, body, "req_catalogue")
      end)

      result = get(conn, "/v1/images/models")
      assert response(result, 200) == body
      assert json_response(result, 200)["models"] |> Enum.at(1) |> Map.get("edits")
      assert get_resp_header(result, "x-ruoc-request-id") == ["req_catalogue"]
      assert usage_logs(instance) == []
    end

    test "an empty catalogue stays empty", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/images/models", fn req ->
        gateway_reply(req, 200, %{"models" => []})
      end)

      assert json_response(get(conn, "/v1/images/models"), 200) == %{"models" => []}
    end

    test "retains a gateway error status and OpenAI error body without plan remapping",
         %{conn: conn, bypass: bypass, instance: instance} do
      body = %{"error" => %{"message" => "catalogue is rate limited", "type" => "usage_limit_reached", "retry_after" => 30}}
      Bypass.expect_once(bypass, "GET", "/v1/images/models", fn req ->
        gateway_reply(req, 429, body, "req_catalogue_error")
      end)

      result = get(conn, "/v1/images/models")
      assert json_response(result, 429) == body
      assert get_resp_header(result, "x-ruoc-request-id") == ["req_catalogue_error"]
      assert usage_logs(instance) == []
    end

    test "wraps a non-JSON gateway error in the OpenAI envelope", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/images/models", fn req ->
        req |> put_resp_content_type("text/html") |> resp(503, "<html>unavailable</html>")
      end)

      assert json_response(get(conn, "/v1/images/models"), 503) ==
               %{"error" => %{"message" => "Image catalogue unavailable", "type" => "api_error"}}
    end

    test "a transport failure is 502", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)
      assert json_response(get(conn, "/v1/images/models"), 502)["error"]["type"] == "api_error"
    end

    test "missing, invalid and deleted tenant credentials are refused", %{stub: stub} do
      assert json_response(get(build_conn(), "/v1/images/models"), 401)["error"]["type"] == "authentication_error"
      bogus = put_req_header(build_conn(), "authorization", "Bearer invalid")
      assert get(bogus, "/v1/images/models").status == 401

      deleted =
        create_instance(%{})
        |> Ecto.Changeset.change(delete_requested: true)
        |> Druzhok.Repo.update!()
      assert get(authed(build_conn(), deleted), "/v1/images/models").status == 401
      assert Druzhok.RuocStub.calls(stub, "GET /v1/images/models") == []
    end

    test "a missing ruoc key has the same refusal as edits", %{stub: stub} do
      instance = create_instance(%{ruoc_api_key: nil})
      conn = authed(build_conn(), instance)
      catalogue = json_response(get(conn, "/v1/images/models"), 503)
      assert catalogue == json_response(post(conn, "/v1/images/edits", %{}), 503)
      assert catalogue["error"]["type"] == "api_error"
      assert Druzhok.RuocStub.calls(stub, "GET /v1/images/models") == []
    end

    test "pictures off follows edits' existing proxy access policy", %{bypass: bypass} do
      instance = create_instance(%{image_gen_enabled: false, group_images_enabled: false})
      conn = authed(build_conn(), instance)
      Bypass.expect_once(bypass, "GET", "/v1/images/models", fn req ->
        gateway_reply(req, 200, %{"models" => []})
      end)

      assert get(conn, "/v1/images/models").status == 200
      # Edits passes auth too, then validates input; the proxy has no pictures switch gate.
      assert json_response(post(conn, "/v1/images/edits", %{}), 400)["error"]["message"] ==
               "an edit needs at least one image"
    end
  end

  describe "edits" do
    @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "fake-jpeg">>

    defp upload(bytes, type \\ "application/octet-stream") do
      path = Path.join(System.tmp_dir!(), "edit-#{System.unique_integer([:positive])}")
      File.write!(path, bytes)
      on_exit(fn -> File.rm(path) end)
      %Plug.Upload{path: path, filename: "image.jpg", content_type: type}
    end

    # Read with the bot's own key: the list that account is offered.
    defp catalogue(bypass, models, key \\ bot_key()) do
      Bypass.stub(bypass, "GET", "/v1/images/models", fn req ->
        assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> key]
        Plug.Conn.resp(req, 200, Jason.encode!(%{"models" => models}))
      end)
    end

    @models [
      %{"id" => "ruoc-flux-klein", "default" => true},
      %{"id" => "ruoc-seedream-flash", "edits" => true},
      %{"id" => "ruoc-nano-banana", "edits" => true}
    ]

    test "sends the photo as a data URI to the first model that edits, answers in OpenAI shape",
         %{conn: conn, bypass: bypass, instance: instance} do
      catalogue(bypass, @models)

      Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)

        assert Jason.decode!(raw) == %{
                 "prompt" => "same face, short bob",
                 "model" => "ruoc-seedream-flash",
                 "images" => ["data:image/jpeg;base64," <> Base.encode64(@jpeg)]
               }

        gateway_reply(req, 200, image_reply("ruoc-seedream-flash"), "req_edit")
      end)

      conn = post(conn, "/v1/images/edits", %{"model" => "gpt-image-2", "prompt" => "same face, short bob", "image" => upload(@jpeg)})

      assert %{"data" => [%{"b64_json" => @png_b64}]} = json_response(conn, 200)
      assert get_resp_header(conn, "x-ruoc-request-id") == ["req_edit"]
      assert [%{request_type: "image_gen", model: "ruoc-seedream-flash"}] = usage_logs(instance)
    end

    test "keeps the bot's own model when it edits, and sends every picture in order", %{bypass: bypass} do
      instance = create_instance(%{image_gen_model: "ruoc-nano-banana"})
      conn = authed(Phoenix.ConnTest.build_conn(), instance)
      catalogue(bypass, @models, instance.ruoc_api_key)
      png = <<0x89, "PNG", "fake-png">>

      Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)
        sent = Jason.decode!(raw)
        assert sent["model"] == "ruoc-nano-banana"

        assert sent["images"] == [
                 "data:image/jpeg;base64," <> Base.encode64(@jpeg),
                 "data:image/png;base64," <> Base.encode64(png)
               ]

        gateway_reply(req, 200, image_reply("ruoc-nano-banana"))
      end)

      assert post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => [upload(@jpeg), upload(png)]}).status == 200
    end

    test "passes the requested size on, and leaves it out when none is sent", %{conn: conn, bypass: bypass} do
      catalogue(bypass, @models)
      parent = self()

      Bypass.expect(bypass, "POST", "/v1/images", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)
        send(parent, {:size, Map.fetch(Jason.decode!(raw), "size")})
        gateway_reply(req, 200, image_reply("ruoc-seedream-flash"))
      end)

      assert post(conn, "/v1/images/edits", %{"prompt" => "x", "size" => "1024x1536", "image" => upload(@jpeg)}).status == 200
      assert_received {:size, {:ok, "1024x1536"}}

      assert post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => upload(@jpeg)}).status == 200
      assert_received {:size, :error}
    end

    test "a bot model that cannot edit is swapped for one that can", %{bypass: bypass} do
      instance = create_instance(%{image_gen_model: "ruoc-flux-klein"})
      conn = authed(Phoenix.ConnTest.build_conn(), instance)
      catalogue(bypass, @models, instance.ruoc_api_key)

      Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)
        assert Jason.decode!(raw)["model"] == "ruoc-seedream-flash"
        gateway_reply(req, 200, image_reply("ruoc-seedream-flash"))
      end)

      assert post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => upload(@jpeg)}).status == 200
    end

    test "if the catalogue cannot be read, the bot's model goes as is", %{bypass: bypass} do
      instance = create_instance(%{image_gen_model: "ruoc-flux-klein"})
      conn = authed(Phoenix.ConnTest.build_conn(), instance)

      Bypass.stub(bypass, "GET", "/v1/images/models", fn req -> Plug.Conn.resp(req, 500, "boom") end)

      Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)
        assert Jason.decode!(raw)["model"] == "ruoc-flux-klein"
        gateway_error(req, 400, "invalid_request_error", "this image model does not take reference images")
      end)

      assert %{"error" => %{"message" => "this image model does not take reference images"}} =
               json_response(post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => upload(@jpeg)}), 400)
    end

    test "no model that edits is a 400 that tells the bot to draw from text", %{conn: conn, bypass: bypass} do
      catalogue(bypass, [%{"id" => "ruoc-flux-klein", "default" => true}])

      assert %{"error" => %{"message" => msg}} =
               json_response(post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => upload(@jpeg)}), 400)

      assert msg =~ "text description"
    end

    test "the declared type is used when the bytes are not recognised", %{conn: conn, bypass: bypass} do
      catalogue(bypass, @models)

      Bypass.expect_once(bypass, "POST", "/v1/images", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)
        assert ["data:image/heic;base64," <> _] = Jason.decode!(raw)["images"]
        gateway_reply(req, 200, image_reply("ruoc-seedream-flash"))
      end)

      assert post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => upload("heic-bytes", "image/heic")}).status == 200
    end

    test "no picture, a mask, or a non-file image is a 400 and nothing is sent", %{conn: conn} do
      assert json_response(post(conn, "/v1/images/edits", %{"prompt" => "x"}), 400)["error"]["message"] ==
               "an edit needs at least one image"

      assert json_response(post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => upload(@jpeg), "mask" => upload(@jpeg)}), 400)["error"]["message"] ==
               "masks are not supported"

      assert json_response(post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => "not a file"}), 400)["error"]["message"] ==
               "image must be a file"
    end

    test "a spent window is a 402 with the notice, as for generation", %{conn: conn, bypass: bypass, instance: instance} do
      watch_cabinet()
      catalogue(bypass, @models)
      Bypass.expect_once(bypass, "POST", "/v1/images", &usage_limit/1)

      assert json_response(post(conn, "/v1/images/edits", %{"prompt" => "x", "image" => upload(@jpeg)}), 402)["error"]["message"] ==
               DruzhokWebWeb.LlmProxy.BalanceNotice.text(instance)

      assert_owner_told(instance)
    end
  end
end
