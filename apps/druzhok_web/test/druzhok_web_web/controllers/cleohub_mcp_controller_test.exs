defmodule DruzhokWebWeb.CleohubMcpControllerTest do
  # RuocProxyCase: async: false, a ruoc stub, one bot with a tenant key.
  use DruzhokWebWeb.RuocProxyCase

  alias Druzhok.{Instance, Repo, Settings}
  alias Druzhok.Cleohub.AvatarLimit

  defmodule FakeGetMe do
    def get_me(_token), do: {:ok, %{"first_name" => "Cleo", "username" => "cleo_superbot"}}
  end

  # A 2×2 PNG, so ffmpeg has a real picture to convert.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP8yjGPgYGBiQEMABPFAZ8Rl76UAAAAAElFTkSuQmCC"
       )

  @token "4242TOKEN"
  @owner 777

  setup %{instance: instance} do
    instance =
      instance
      |> Ecto.Changeset.change(telegram_token: @token, owner_telegram_id: @owner, display_name: "Вася")
      |> Repo.update!()

    tg = Bypass.open()
    site = Bypass.open()
    origin = "http://localhost:#{site.port}"

    prev =
      for k <- [:telegram_api_base, :ruoc_site_url, :panel_get_me], into: %{},
          do: {k, Application.get_env(:druzhok, k)}

    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{tg.port}")
    Application.put_env(:druzhok, :ruoc_site_url, origin)
    Application.put_env(:druzhok, :panel_get_me, {FakeGetMe, :get_me})
    Druzhok.Ruoc.reset_plans_cache(origin)
    AvatarLimit.reset()

    on_exit(fn ->
      for {k, v} <- prev,
          do: if(v, do: Application.put_env(:druzhok, k, v), else: Application.delete_env(:druzhok, k))

      Druzhok.Ruoc.reset_plans_cache(origin)
      AvatarLimit.reset()
    end)

    %{instance: instance, tg: tg, site: site}
  end

  defp rpc(conn, method, params \\ nil, id \\ 1) do
    body = %{jsonrpc: "2.0", id: id, method: method}
    body = if params, do: Map.put(body, :params, params), else: body

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post("/mcp/cleohub", Jason.encode!(body))
  end

  defp call_tool(conn, name, args \\ %{}) do
    resp = conn |> rpc("tools/call", %{name: name, arguments: args}) |> json_response(200)
    resp["result"]
  end

  defp text(%{"content" => [%{"type" => "text", "text" => text}]}), do: text

  describe "auth and transport" do
    test "no tenant key or a wrong one is 401" do
      conn = build_conn() |> put_req_header("content-type", "application/json")
      assert post(conn, "/mcp/cleohub", ~s({"jsonrpc":"2.0","id":1,"method":"ping"})).status == 401

      conn = put_req_header(conn, "authorization", "Bearer dk-nope")
      assert post(conn, "/mcp/cleohub", ~s({"jsonrpc":"2.0","id":1,"method":"ping"})).status == 401
    end

    test "GET and DELETE are 405, so the client opens no stream", %{conn: conn} do
      assert get(conn, "/mcp/cleohub").status == 405
      assert delete(conn, "/mcp/cleohub").status == 405
    end

    test "initialize answers with serverInfo and echoes a known version", %{conn: conn} do
      resp =
        conn
        |> rpc("initialize", %{
          protocolVersion: "2025-06-18",
          capabilities: %{},
          clientInfo: %{name: "hermes", version: "0.22"}
        })
        |> json_response(200)

      assert resp == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{
                 "protocolVersion" => "2025-06-18",
                 "capabilities" => %{"tools" => %{}},
                 "serverInfo" => %{"name" => "cleohub", "version" => "1"}
               }
             }

      resp = conn |> rpc("initialize", %{protocolVersion: "2099-01-01", capabilities: %{}}) |> json_response(200)
      assert resp["result"]["protocolVersion"] == "2025-11-25"
    end

    test "mcp 2.0's server/discover probe is -32601, unknown methods too", %{conn: conn} do
      assert %{"error" => %{"code" => -32601}, "id" => 7} =
               conn |> rpc("server/discover", %{}, 7) |> json_response(200)

      assert %{"error" => %{"code" => -32601}} = conn |> rpc("resources/list") |> json_response(200)
    end

    test "a notification is 202 with no body; ping is an empty result", %{conn: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp/cleohub", ~s({"jsonrpc":"2.0","method":"notifications/initialized"}))

      assert resp.status == 202 and resp.resp_body == ""
      assert %{"result" => %{}} = conn |> rpc("ping") |> json_response(200)
    end

    test "a batch or a non-JSON-RPC body is -32600", %{conn: conn} do
      conn = put_req_header(conn, "content-type", "application/json")
      assert %{"error" => %{"code" => -32600}} = conn |> post("/mcp/cleohub", "[]") |> json_response(200)
      assert %{"error" => %{"code" => -32600}} = conn |> post("/mcp/cleohub", ~s({"a":1})) |> json_response(200)
    end

    test "tools/list: six tools, each with an object inputSchema", %{conn: conn} do
      %{"result" => %{"tools" => tools}} = conn |> rpc("tools/list", %{}) |> json_response(200)

      assert Enum.map(tools, & &1["name"]) ==
               ~w(cleohub_account cleohub_plans cleohub_help cleohub_notices cleohub_invite cleohub_set_avatar)

      for t <- tools do
        assert is_binary(t["description"]) and t["description"] != ""
        assert %{"type" => "object", "properties" => %{}, "required" => required} = t["inputSchema"]
        assert is_list(required)
      end

      avatar = List.last(tools)
      assert avatar["inputSchema"]["required"] == ["description"]
    end

    test "an unknown tool or non-object arguments are -32602", %{conn: conn} do
      assert %{"error" => %{"code" => -32602}} =
               conn |> rpc("tools/call", %{name: "nope", arguments: %{}}) |> json_response(200)

      assert %{"error" => %{"code" => -32602}} =
               conn |> rpc("tools/call", %{name: "cleohub_help", arguments: [1]}) |> json_response(200)

      assert %{"error" => %{"code" => -32602}} = conn |> rpc("tools/call", %{}) |> json_response(200)
    end
  end

  describe "cleohub_account" do
    test "plan, windows and trial; never the balance", %{conn: conn, stub: stub} do
      Bypass.expect_once(stub.bypass, "GET", "/v1/balance", fn c ->
        Druzhok.RuocStub.record(stub, "GET /v1/balance", c)
        |> Druzhok.RuocStub.reply(200, %{
          "balance_nanorub" => 123_456_000_000,
          "subscription" => %{"plan_name" => "Лайт", "status" => "active", "credit_nanorub" => 0,
                               "current_period_end" => "2026-12-01T00:00:00Z"},
          "limits" => %{
            "plan_name" => "Лайт",
            "session" => %{"used_percent" => 40, "resets_at" => "2026-11-14T18:00:00Z"},
            "weekly" => %{"used_percent" => 100, "resets_at" => "2026-11-17T00:00:00Z"},
            "overflow" => false,
            "spent" => "weekly"
          }
        })
      end)

      result = call_tool(conn, "cleohub_account")
      text = text(result)

      assert result["isError"] == false
      assert text =~ "Тариф: «Лайт» (действует), оплачен до 01.12.2026"
      assert text =~ "Лимит на 5 часов: израсходовано 40 %, обновится 14.11.2026 18:00"
      assert text =~ "Лимит на неделю: израсходовано 100 %"
      assert text =~ "Сейчас лимит на неделю исчерпан."
      refute text =~ "123"
      refute Jason.encode!(result) =~ "123"
      assert result["structuredContent"]["plan"] == "Лайт"
      assert result["structuredContent"]["session"] == %{"used_percent" => 40, "resets_at" => "2026-11-14T18:00:00Z"}

      [call] = Druzhok.RuocStub.calls(stub, "GET /v1/balance")
      assert {"authorization", "Bearer " <> bot_key()} in call.headers
    end

    test "a gateway failure is a tool error, not a protocol one", %{conn: conn, stub: stub} do
      Bypass.expect_once(stub.bypass, "GET", "/v1/balance", fn c -> Plug.Conn.resp(c, 500, "{}") end)
      result = call_tool(conn, "cleohub_account")
      assert result["isError"] == true
      assert text(result) =~ "Не удалось узнать тариф"
    end
  end

  describe "cleohub_plans" do
    defp plans_json(site) do
      Bypass.expect_once(site, "GET", "/plans.json", fn c ->
        Druzhok.RuocStub.reply(c, 200, [
          %{"name" => "Лайт", "description" => "для начала", "price_nanorub" => 290_000_000_000,
            "period_days" => 30, "is_default" => true},
          %{"name" => "Про", "description" => "", "price_nanorub" => 990_500_000_000, "period_days" => 30}
        ])
      end)
    end

    defp on_plan(stub, name) do
      Bypass.stub(stub.bypass, "GET", "/v1/balance", fn c ->
        Druzhok.RuocStub.reply(c, 200, %{
          "balance_nanorub" => 1,
          "subscription" => %{"plan_name" => name, "status" => "active"}
        })
      end)
    end

    test "lists the plans with prices and marks the current one", %{conn: conn, stub: stub, site: site} do
      plans_json(site)
      on_plan(stub, "Лайт")

      result = call_tool(conn, "cleohub_plans")
      text = text(result)
      assert text =~ "- «Лайт»: 290 ₽ / 30 дн. (ваш тариф) — для начала"
      assert text =~ "- «Про»: 990,50 ₽ / 30 дн."
      assert text =~ "«Кабинет» → Тариф"
      refute text =~ "Ваш тариф:"
      assert [%{"current" => true, "price_rub" => "290"}, %{"current" => false}] = result["structuredContent"]["plans"]

      # Cached: the site is asked once (Bypass fails a second call).
      assert text(call_tool(conn, "cleohub_plans")) == text
    end

    test "a plan not on offer is named, nothing marked", %{conn: conn, stub: stub, site: site} do
      plans_json(site)
      on_plan(stub, "Партнёрский")

      result = call_tool(conn, "cleohub_plans")
      assert text(result) =~ "Ваш тариф: «Партнёрский»."
      refute text(result) =~ "(ваш тариф)"
      assert Enum.all?(result["structuredContent"]["plans"], &(&1["current"] == false))
    end

    test "no plans.json is a tool error", %{conn: conn, site: site} do
      Bypass.down(site)
      result = call_tool(conn, "cleohub_plans")
      assert result["isError"] == true
    end
  end

  describe "cleohub_help" do
    test "Russian, with the pictures section only when pictures are on", %{conn: conn, instance: inst} do
      off = text(call_tool(conn, "cleohub_help"))
      assert off =~ "# Что я умею"
      assert off =~ "Картинки сейчас не рисую"
      refute off =~ "Рисую картинки"
      refute off =~ "<!--"

      inst |> Ecto.Changeset.change(image_gen_enabled: true) |> Repo.update!()
      on = text(call_tool(conn, "cleohub_help"))
      assert on =~ "Рисую картинки по описанию"
      refute on =~ "Картинки сейчас не рисую"
      refute on =~ "<!--"
    end

    test "English for an English bot", %{conn: conn, instance: inst} do
      inst |> Ecto.Changeset.change(language: "en") |> Repo.update!()
      assert text(call_tool(conn, "cleohub_help")) =~ "# What I can do"
    end
  end

  describe "cleohub_notices" do
    test "the operator's notice, or none", %{conn: conn} do
      assert text(call_tool(conn, "cleohub_notices")) =~ "Сейчас уведомлений нет"

      {:ok, _} = Settings.set("cleohub_notice", "  Картинки не рисуются до 18:00, чиним.\n")
      result = call_tool(conn, "cleohub_notices")
      assert text(result) == "Картинки не рисуются до 18:00, чиним."
      assert result["structuredContent"] == %{"notice" => "Картинки не рисуются до 18:00, чиним."}
    end
  end

  describe "cleohub_invite" do
    setup do
      {:ok, _} = Settings.set("manager_bot_token", "mgr#{System.unique_integer([:positive])}")
      :ok
    end

    test "the first free link with the cabinet's wording", %{conn: conn} do
      result = call_tool(conn, "cleohub_invite")
      text = text(result)
      assert text =~ "Ссылка для друга: https://t.me/cleo_superbot?start=ref_AAAA-BBBB"
      assert text =~ "Поделиться: https://t.me/share/url?url="
      assert text =~ "Вам — 20,00 ₽"
      refute text =~ "ругу —"
      assert result["structuredContent"]["link"] == "https://t.me/cleo_superbot?start=ref_AAAA-BBBB"
    end

    test "no free code says so", %{conn: conn, stub: stub} do
      Bypass.expect_once(stub.bypass, "GET", "/v1/referrals", fn c ->
        Druzhok.RuocStub.reply(c, 200, %{"codes" => [%{"code" => "X", "status" => "redeemed"}]})
      end)

      assert text(call_tool(conn, "cleohub_invite")) == "Свободных приглашений сейчас нет."
    end
  end

  describe "cleohub_set_avatar" do
    defp watch_telegram(tg, method) do
      parent = self()

      Bypass.stub(tg, "POST", "/bot#{@token}/#{method}", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c, length: 5_000_000)
        send(parent, {method, Plug.Conn.get_req_header(c, "content-type"), body})

        result = if method == "setMyProfilePhoto", do: true, else: %{"message_id" => 1}
        Plug.Conn.resp(c, 200, Jason.encode!(%{ok: true, result: result}))
      end)
    end

    defp count_images(stub) do
      parent = self()

      Bypass.stub(stub.bypass, "POST", "/v1/images", fn c ->
        send(parent, :image_request)
        Druzhok.RuocStub.reply(c, 402, %{"error" => %{"type" => "insufficient_quota"}})
      end)
    end

    test "starts at once; success sets the photo and sends it to the owner", %{conn: conn, stub: stub, tg: tg} do
      Bypass.stub(stub.bypass, "POST", "/v1/images", fn c ->
        Druzhok.RuocStub.reply(c, 200, %{"image" => %{"b64" => Base.encode64(@png)}})
      end)

      watch_telegram(tg, "setMyProfilePhoto")
      watch_telegram(tg, "sendPhoto")

      result = call_tool(conn, "cleohub_set_avatar", %{description: "рыжий кот в очках"})
      assert result["isError"] == false
      assert text(result) =~ "Рисую"

      assert_receive {"setMyProfilePhoto", _, _}, 5_000
      assert_receive {"sendPhoto", ["multipart/form-data" <> _], body}, 5_000
      assert body =~ ~s(name="chat_id"\r\n\r\n#{@owner})
      assert body =~ "Готово — новая аватарка"
      assert body =~ <<0xFF, 0xD8, 0xFF>>
    end

    test "a failure tells the owner why", %{conn: conn, stub: stub, tg: tg} do
      count_images(stub)
      watch_telegram(tg, "sendMessage")

      assert call_tool(conn, "cleohub_set_avatar", %{description: "кот"})["isError"] == false
      assert_receive {"sendMessage", _, body}, 5_000

      assert Jason.decode!(body) == %{
               "chat_id" => @owner,
               "text" => "Не получилось сменить аватарку: лимит тарифа исчерпан, подробности в «Кабинете»"
             }
    end

    test "the 4th call of the day is refused without drawing", %{conn: conn, stub: stub, tg: tg} do
      count_images(stub)
      watch_telegram(tg, "sendMessage")

      for _ <- 1..3 do
        assert call_tool(conn, "cleohub_set_avatar", %{description: "кот"})["isError"] == false
        assert_receive :image_request, 5_000
        assert_receive {"sendMessage", _, _}, 5_000
      end

      result = call_tool(conn, "cleohub_set_avatar", %{description: "кот"})
      assert result["isError"] == true
      assert text(result) == "Лимит: 3 смены аватарки в день. Попробуйте завтра."
      refute_receive :image_request, 300
    end

    test "the day's count is per bot and per UTC day; a new day is not wiped by a late old one" do
      assert AvatarLimit.take(1, ~D[2026-11-14]) == :ok
      for _ <- 1..3, do: assert(AvatarLimit.take(2, ~D[2026-11-15]) == :ok)
      assert AvatarLimit.take(2, ~D[2026-11-15]) == :limit
      # A call still carrying yesterday's date keeps today's counts.
      assert AvatarLimit.take(1, ~D[2026-11-14]) == :ok
      assert AvatarLimit.take(2, ~D[2026-11-15]) == :limit
    end

    test "an empty or too long description is a tool error that costs nothing", %{conn: conn, stub: stub} do
      count_images(stub)

      assert call_tool(conn, "cleohub_set_avatar", %{description: "  "})["isError"] == true
      assert call_tool(conn, "cleohub_set_avatar", %{})["isError"] == true

      long = call_tool(conn, "cleohub_set_avatar", %{description: String.duplicate("к", 301)})
      assert long["isError"] == true and text(long) =~ "300"

      refute_receive :image_request, 200
      # None of them counted towards the day's three.
      for _ <- 1..3, do: assert(AvatarLimit.take(Repo.get_by!(Instance, tenant_key: get_key(conn)).id) == :ok)
    end
  end

  defp get_key(conn) do
    ["Bearer " <> key] = Plug.Conn.get_req_header(conn, "authorization")
    key
  end
end
