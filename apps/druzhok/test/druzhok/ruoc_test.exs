defmodule Druzhok.RuocTest do
  # async: false — app env and settings rows.
  use ExUnit.Case, async: false

  alias Druzhok.{Ruoc, RuocStub}

  setup do
    %{stub: RuocStub.start()}
  end

  # The client's own Host (the URL's) is all that reaches the gateway.
  defp host_override?(call, stub),
    do: List.keyfind(call.headers, "host", 0) not in [nil, {"host", "localhost:#{stub.bypass.port}"}]

  describe "create_account/3" do
    test "posts label and ref with the partner token, no Host override, returns the key", %{stub: stub} do
      assert {:ok, %{account_id: "acct-" <> _, api_key: "ruoc_key" <> _}} =
               Ruoc.create_account("druzhok:bot1 tg:7", "bot1:7")

      [call] = RuocStub.calls(stub, "POST /partner/accounts")
      assert call.params == %{"label" => "druzhok:bot1 tg:7", "external_ref" => "bot1:7"}
      assert {"authorization", "Bearer " <> RuocStub.partner_token()} in call.headers
      refute host_override?(call, stub)
    end

    test "omits the invite when none given", %{stub: stub} do
      assert {:ok, _} = Ruoc.create_account("druzhok:bot2", "bot2:-")
      [call] = RuocStub.calls(stub, "POST /partner/accounts")
      refute Map.has_key?(call.params, "invite")
      refute Map.has_key?(call.params, "grant_rubles")
    end

    test "sends the invite code and maps the three refusals", %{stub: stub} do
      assert {:ok, _} = Ruoc.create_account("druzhok:kot", "kot:-", invite: "ABCD-EFGH")
      [call] = RuocStub.calls(stub, "POST /partner/accounts")
      assert call.params["invite"] == "ABCD-EFGH"

      for {type, reason} <- [{"invite_invalid", :invalid}, {"invite_spent", :spent}, {"invite_expired", :expired}] do
        Bypass.expect_once(stub.bypass, "POST", "/partner/accounts", fn conn ->
          RuocStub.reply(conn, 409, %{"error" => %{"type" => type, "message" => "no"}})
        end)

        assert {:error, {:invite, ^reason}} = Ruoc.create_account("druzhok:kot", "kot:-", invite: "ABCD-EFGH")
      end

      assert RuocStub.calls(stub, "POST /partner/accounts/:id/key") == []
    end

    test "409 account_exists reissues the key of that account", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "POST", "/partner/accounts", fn conn ->
        RuocStub.reply(conn, 409, %{"error" => %{"type" => "account_exists", "message" => "exists"}, "account_id" => "acct-old"})
      end)

      assert {:ok, %{account_id: "acct-old", api_key: "ruoc_rekey" <> _}} = Ruoc.create_account("druzhok:x", "x:-")
      [call] = RuocStub.calls(stub, "POST /partner/accounts/:id/key")
      assert call.path == "/partner/accounts/acct-old/key"
      assert {"authorization", "Bearer " <> RuocStub.partner_token()} in call.headers
    end

    test "the account id of a 409 may sit inside the error", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "POST", "/partner/accounts", fn conn ->
        RuocStub.reply(conn, 409, %{"error" => %{"type" => "invalid_request_error", "code" => "account_exists", "account_id" => "acct-in"}})
      end)

      assert {:ok, %{account_id: "acct-in"}} = Ruoc.create_account("druzhok:x", "x:-")
    end

    test "a failed reissue is an error", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "POST", "/partner/accounts", fn conn ->
        RuocStub.reply(conn, 409, %{"error" => %{"type" => "account_exists"}, "account_id" => "acct-old"})
      end)

      Bypass.expect_once(stub.bypass, "POST", "/partner/accounts/:id/key", fn conn ->
        RuocStub.reply(conn, 404, %{"error" => %{"type" => "not_found", "message" => "no such account"}})
      end)

      assert {:error, "HTTP 404: no such account"} = Ruoc.create_account("druzhok:x", "x:-")
    end

    test "a timeout is retried once with the same ref" do
      # A raw server: Bypass fails a test whose handler the client gave up on.
      # The first connection gets no answer; the second a 201.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      test = self()

      server =
        spawn(fn ->
          {:ok, first} = :gen_tcp.accept(listen)
          send(test, {:request, read_request(first)})
          {:ok, second} = :gen_tcp.accept(listen)
          send(test, {:request, read_request(second)})
          body = Jason.encode!(%{"account_id" => "acct-t", "api_key" => "ruoc_t"})

          :gen_tcp.send(
            second,
            "HTTP/1.1 201 Created\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body
          )

          receive do
            :done -> :gen_tcp.close(first)
          end
        end)

      Application.put_env(:druzhok, :ruoc_url, "http://127.0.0.1:#{port}")
      Application.put_env(:druzhok, :ruoc_partner_timeout_ms, 200)
      on_exit(fn -> Application.delete_env(:druzhok, :ruoc_partner_timeout_ms) end)

      assert {:ok, %{account_id: "acct-t", api_key: "ruoc_t"}} = Ruoc.create_account("druzhok:t tg:5", "t:5")
      assert_received {:request, first}
      assert_received {:request, second}
      assert first =~ ~s("external_ref":"t:5")
      assert request_body(first) == request_body(second)
      send(server, :done)
    end

    test "a second transport failure gives up", %{stub: stub} do
      Bypass.down(stub.bypass)
      assert {:error, msg} = Ruoc.create_account("x", "x:-")
      assert msg =~ "TransportError"
    end

    test "429 partner_quota is :ruoc_quota, logged for the operator", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "POST", "/partner/accounts", fn conn ->
        RuocStub.reply(conn, 429, %{"error" => %{"type" => "partner_quota", "message" => "limit"}})
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :ruoc_quota} = Ruoc.create_account("x", "x:-")
        end)

      assert log =~ "ruoc partner quota reached"
    end

    test "surfaces the gateway's error message", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "POST", "/partner/accounts", fn conn ->
        RuocStub.reply(conn, 401, %{"error" => %{"type" => "invalid_request_error", "message" => "invalid partner token"}})
      end)

      assert {:error, "HTTP 401: invalid partner token"} = Ruoc.create_account("x", "x:-")
    end

    test "fails without a partner token and without reaching the gateway", %{stub: stub} do
      RuocStub.unset(:ruoc_partner_token)
      refute Ruoc.configured?()
      assert {:error, "RUOC_PARTNER_TOKEN is not set"} = Ruoc.create_account("x", "x:-")
      assert RuocStub.calls(stub, "POST /partner/accounts") == []
    end

    test "the partner token never comes from the settings table", %{stub: _stub} do
      RuocStub.unset(:ruoc_partner_token)
      Druzhok.Settings.set("ruoc_partner_token", "ruoc_pk_from_settings")
      on_exit(fn -> Druzhok.Repo.get_by(Druzhok.Settings, key: "ruoc_partner_token") |> Druzhok.Repo.delete() end)
      refute Ruoc.configured?()
      assert Ruoc.partner_token() == nil
    end
  end

  test "suspend/1 posts to the partner suspend route", %{stub: stub} do
    assert :ok = Ruoc.suspend("acct-9")
    [call] = RuocStub.calls(stub, "POST /partner/accounts/:id/suspend")
    assert call.path == "/partner/accounts/acct-9/suspend"
    assert {"authorization", "Bearer " <> RuocStub.partner_token()} in call.headers
    refute host_override?(call, stub)

    Bypass.expect_once(stub.bypass, "POST", "/partner/accounts/:id/suspend", fn conn ->
      RuocStub.reply(conn, 404, %{"error" => %{"type" => "not_found", "message" => "no such account"}})
    end)

    assert {:error, "HTTP 404: no such account"} = Ruoc.suspend("acct-9")
  end

  test "delete_account_sites/1 uses the partner route and reports a refusal", %{stub: stub} do
    assert :ok = Ruoc.delete_account_sites("acct-9")
    [call] = RuocStub.calls(stub, "DELETE /partner/accounts/:id/sites")
    assert call.path == "/partner/accounts/acct-9/sites"
    assert {"authorization", "Bearer " <> RuocStub.partner_token()} in call.headers

    Bypass.expect_once(stub.bypass, "DELETE", "/partner/accounts/:id/sites", fn conn ->
      RuocStub.reply(conn, 404, %{"error" => %{"type" => "not_found", "message" => "no such account"}})
    end)

    assert {:error, "HTTP 404: no such account"} = Ruoc.delete_account_sites("acct-9")
  end

  test "a site upload with no free connection is an error, and chat traffic is unaffected", %{stub: stub} do
    # Accepts and never answers: each upload holds its connection until the timeout.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, backlog: 32])
    {:ok, port} = :inet.port(listen)
    Application.put_env(:druzhok, :ruoc_url, "http://127.0.0.1:#{port}")
    upload = fn -> Druzhok.Ruoc.Client.put_stream("/v1/sites/a", "k", "application/gzip", ["x"], receive_timeout: 7_000) end

    holders = for _ <- 1..8, do: Task.async(upload)
    Process.sleep(300)

    assert {:error, %RuntimeError{}} = upload.()

    Application.put_env(:druzhok, :ruoc_url, stub.base)
    assert {:ok, []} = Ruoc.sites("k")

    Enum.each(holders, &Task.shutdown(&1, :brutal_kill))
    :gen_tcp.close(listen)
  end

  test "sites/1 lists under the bot's key and reports a refusal", %{stub: stub} do
    Bypass.expect_once(stub.bypass, "GET", "/v1/sites", fn conn ->
      conn = RuocStub.record(stub, "GET /v1/sites", conn)
      RuocStub.reply(conn, 200, %{"sites" => [%{"name" => "a"}]})
    end)

    assert {:ok, [%{"name" => "a"}]} = Ruoc.sites("ruoc_bot")
    assert {"authorization", "Bearer ruoc_bot"} in hd(RuocStub.calls(stub, "GET /v1/sites")).headers

    Bypass.expect_once(stub.bypass, "GET", "/v1/sites", fn conn ->
      RuocStub.reply(conn, 401, %{"error" => %{"message" => "bad key"}})
    end)

    assert {:error, "HTTP 401: bad key"} = Ruoc.sites("ruoc_bot")
  end

  describe "list_accounts/1" do
    test "lists the partner's accounts with filters", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "GET", "/partner/accounts", fn conn ->
        conn = RuocStub.record(stub, "GET /partner/accounts", conn)

        RuocStub.reply(conn, 200, [
          %{"account_id" => "a1", "external_ref" => "bot:7", "label" => "druzhok:bot tg:7", "status" => "active",
            "plan" => "Старт", "created_at" => "2026-10-22T10:00:00Z"}
        ])
      end)

      assert {:ok, [%{account_id: "a1", external_ref: "bot:7", status: "active", plan: "Старт", created_at: ~U[2026-10-22 10:00:00Z]}]} =
               Ruoc.list_accounts(status: "active", ref: "bot:7")

      [call] = RuocStub.calls(stub, "GET /partner/accounts")
      assert URI.decode_query(call.query) == %{"status" => "active", "ref" => "bot:7"}
      assert {"authorization", "Bearer " <> RuocStub.partner_token()} in call.headers
      refute host_override?(call, stub)
    end

    test "a failure is an error", %{stub: stub} do
      Bypass.down(stub.bypass)
      assert {:error, _} = Ruoc.list_accounts()
    end
  end

  test "balance/1 uses the bot key", %{stub: stub} do
    assert {:ok, %{balance_rub: "12.50", balance_nanorub: 12_500_000_000}} = Ruoc.balance("ruoc_bot")

    Bypass.expect_once(stub.bypass, "GET", "/v1/balance", fn conn ->
      RuocStub.reply(conn, 200, %{"balance_nanorub" => 48_998_806_000, "balance_rub" => "48.998806 RUB"})
    end)

    assert {:ok, %{balance_rub: "49.00"}} = Ruoc.balance("ruoc_bot")

    Bypass.expect_once(stub.bypass, "GET", "/v1/balance", fn conn ->
      RuocStub.reply(conn, 200, %{"balance_nanorub" => -1_234_000_000, "balance_rub" => "-1.234 RUB"})
    end)

    assert {:ok, %{balance_rub: "-1.23"}} = Ruoc.balance("ruoc_bot")
    [call] = RuocStub.calls(stub, "GET /v1/balance")
    assert {"authorization", "Bearer ruoc_bot"} in call.headers

    Bypass.expect_once(stub.bypass, "GET", "/v1/balance", fn conn -> Plug.Conn.resp(conn, 403, "{}") end)
    assert {:error, "HTTP 403" <> _} = Ruoc.balance("ruoc_bot")
  end

  test "balance/1 carries the subscription when the account has one", %{stub: stub} do
    assert {:ok, %{subscription: nil}} = Ruoc.balance("ruoc_bot")

    Bypass.expect_once(stub.bypass, "GET", "/v1/balance", fn conn ->
      RuocStub.reply(conn, 200, %{
        "balance_nanorub" => 42_000_000_000,
        "balance_rub" => "42 RUB",
        "subscription" => %{
          "plan_id" => "p1", "plan_name" => "Старт", "credit_nanorub" => 50_000_000_000, "period_days" => 30,
          "status" => "active", "current_period_end" => "2026-10-05T12:00:00+05:00"
        }
      })
    end)

    assert {:ok, %{balance_rub: "42.00", subscription: sub}} = Ruoc.balance("ruoc_bot")
    assert sub == %{plan_name: "Старт", credit_rub: "50.00", period_days: 30, status: "active",
                    period_end: ~U[2026-10-05 07:00:00Z]}
  end

  describe "image_models/0" do
    test "lists the image catalogue in ruoc's order with prices, uncached", %{stub: stub} do
      assert {:ok,
              [
                %{id: "ruoc-flux-klein", name: "FLUX 2 Klein", description: "быстрая", rub_per_image: "2", default: true},
                %{id: "ruoc-flux-pro", name: "FLUX 2 Pro", rub_per_image: "5", default: false}
              ]} = Ruoc.image_models()

      assert {:ok, _} = Ruoc.image_models()
      [call, _] = RuocStub.calls(stub, "GET /v1/images/models")
      assert {"authorization", "Bearer " <> RuocStub.catalog_key()} in call.headers
    end

    test "surfaces a gateway failure instead of an empty list", %{stub: stub} do
      Bypass.down(stub.bypass)
      assert {:error, _} = Ruoc.image_models()
    end

    test "fails without a catalog key", %{stub: stub} do
      RuocStub.unset(:ruoc_catalog_key)
      assert {:error, "ruoc_catalog_key is not set"} = Ruoc.image_models()
      assert RuocStub.calls(stub, "GET /v1/images/models") == []
    end
  end

  describe "models/0" do
    test "maps the catalog with prices and caches it", %{stub: stub} do
      assert [%{id: "ruoc-flash", name: "GLM 5.3 Flash", price: %{input: "12", output: "38"}}, %{id: "ruoc-standard"}] =
               Ruoc.models()

      assert [%{id: "ruoc-flash"}] = Ruoc.vision_models()
      assert %{name: "GLM 5.3"} = Ruoc.find_model("ruoc-standard")

      Ruoc.models()
      [call] = RuocStub.calls(stub, "GET /v1/models")
      assert {"authorization", "Bearer " <> RuocStub.catalog_key()} in call.headers
    end

    test "keeps the last good list when the gateway fails", %{stub: stub} do
      assert length(Ruoc.models()) == 2
      Ruoc.reset_cache()
      Bypass.down(stub.bypass)
      assert Ruoc.models() == []

      Bypass.up(stub.bypass)
      Ruoc.reset_cache()
      assert length(Ruoc.models()) == 2
      # Expire the cache by hand and take the gateway down: the stale list survives.
      {_, list} = :persistent_term.get({Ruoc, :models})
      :persistent_term.put({Ruoc, :models}, {System.monotonic_time(:millisecond) - 120_000, list})
      Bypass.down(stub.bypass)
      assert length(Ruoc.models()) == 2
    end

    test "keeps the context limit", %{stub: _stub} do
      assert %{limits: %{context: 131_072, output: 32_768}} = Ruoc.find_model("ruoc-flash")
    end

    test "is empty without a catalog key", %{stub: stub} do
      RuocStub.unset(:ruoc_catalog_key)
      assert Ruoc.models() == []
      assert RuocStub.calls(stub, "GET /v1/models") == []
    end
  end

  test "default_model/0 is ruoc-flash", do: assert(Ruoc.default_model() == "ruoc-flash")

  describe "check_invite/1" do
    test "asks the partner surface and returns the status as an atom", %{stub: stub} do
      assert {:ok, :available} = Ruoc.check_invite("ABCD-EFGH")
      [call] = RuocStub.calls(stub, "GET /partner/invites/check")
      assert call.path == "/partner/invites/check"
      assert URI.decode_query(call.query) == %{"code" => "ABCD-EFGH"}
      assert {"authorization", "Bearer " <> RuocStub.partner_token()} in call.headers
      refute host_override?(call, stub)

      for status <- ["spent", "expired", "invalid"] do
        Bypass.expect_once(stub.bypass, "GET", "/partner/invites/check", fn conn ->
          RuocStub.reply(conn, 200, %{"status" => status})
        end)

        assert {:ok, String.to_atom(status)} == Ruoc.check_invite("x")
      end
    end

    test "an unknown status or a failure is an error", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "GET", "/partner/invites/check", fn conn ->
        RuocStub.reply(conn, 200, %{"status" => "weird"})
      end)

      assert {:error, _} = Ruoc.check_invite("x")
      Bypass.down(stub.bypass)
      assert {:error, _} = Ruoc.check_invite("x")
    end
  end

  test "referrals/1 uses the bot key and decodes the codes", %{stub: stub} do
    assert {:ok, [first, second]} = Ruoc.referrals("ruoc_bot")
    [call] = RuocStub.calls(stub, "GET /v1/referrals")
    assert {"authorization", "Bearer ruoc_bot"} in call.headers
    assert %{code: "AAAA-BBBB", status: "available", redeemed_at: nil, friend_rub: "0.00", you_rub: "20.00"} = first
    assert %{code: "CCCC-DDDD", status: "redeemed", redeemed_at: %DateTime{}} = second

    Bypass.expect_once(stub.bypass, "GET", "/v1/referrals", fn conn ->
      RuocStub.reply(conn, 503, %{"error" => %{"type" => "api_error", "message" => "referrals are not available"}})
    end)

    assert {:error, "HTTP 503: referrals are not available"} = Ruoc.referrals("ruoc_bot")
  end

  defp read_request(socket, acc \\ "") do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> data

    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, len] <- Regex.run(~r/content-length: (\d+)/i, head),
         true <- byte_size(body) >= String.to_integer(len) do
      acc
    else
      _ -> read_request(socket, acc)
    end
  end

  defp request_body(raw), do: raw |> String.split("\r\n\r\n", parts: 2) |> List.last()

  describe "model_facts/1" do
    test "a listed model, an unlisted one, and an empty catalogue", %{stub: stub} do
      Ruoc.reset_cache()
      assert length(Ruoc.models()) == 2
      assert {:ok, %{sees_images: true, context: 131_072}} = Ruoc.model_facts("ruoc-flash")
      assert {:ok, %{sees_images: false}} = Ruoc.model_facts("ruoc-standard")
      assert :unknown_model = Ruoc.model_facts("nope")

      # A failed first fetch caches an empty list: unknown, not "unlisted".
      Ruoc.reset_cache()
      Bypass.down(stub.bypass)
      assert Ruoc.models() == []
      assert :no_catalogue = Ruoc.model_facts("ruoc-flash")
    end
  end
end
