defmodule Druzhok.RuocTest do
  # async: false — app env and settings rows.
  use ExUnit.Case, async: false

  alias Druzhok.{Ruoc, RuocStub}

  setup do
    %{stub: RuocStub.start()}
  end

  describe "create_account/2" do
    test "posts label and grant with the admin token and Host header, returns the key", %{stub: stub} do
      assert {:ok, %{account_id: "acct-" <> _, api_key: "ruoc_key" <> _}} =
               Ruoc.create_account("druzhok:bot1", "5")

      [call] = RuocStub.calls(stub, "POST /admin/accounts")
      assert call.params == %{"label" => "druzhok:bot1", "grant_rubles" => "5"}
      assert {"authorization", "Bearer " <> RuocStub.admin_token()} in call.headers
      assert {"host", "admin.test"} in call.headers
    end

    test "omits grant_rubles when none given", %{stub: stub} do
      assert {:ok, _} = Ruoc.create_account("druzhok:bot2")
      [call] = RuocStub.calls(stub, "POST /admin/accounts")
      refute Map.has_key?(call.params, "grant_rubles")
    end

    test "surfaces the gateway's error message", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "POST", "/admin/accounts", fn conn ->
        RuocStub.reply(conn, 401, %{"error" => %{"type" => "invalid_request_error", "message" => "invalid admin token"}})
      end)

      assert {:error, "HTTP 401: invalid admin token"} = Ruoc.create_account("x")
    end

    test "fails without an admin token and without reaching the gateway", %{stub: stub} do
      RuocStub.unset(:ruoc_admin_token)
      refute Ruoc.configured?()
      assert {:error, "ruoc_admin_token is not set"} = Ruoc.create_account("x")
      assert RuocStub.calls(stub, "POST /admin/accounts") == []
    end

    test "network failure is an error, not a crash", %{stub: stub} do
      Bypass.down(stub.bypass)
      assert {:error, msg} = Ruoc.create_account("x")
      assert msg =~ "TransportError"
    end
  end

  test "suspend/1 posts the status change", %{stub: stub} do
    assert :ok = Ruoc.suspend("acct-9")
    [call] = RuocStub.calls(stub, "POST /admin/accounts/:id/status")
    assert call.path == "/admin/accounts/acct-9/status"
    assert call.params == %{"status" => "suspended"}
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

  describe "new_bot_grant_rubles/0" do
    setup do
      on_exit(fn -> Druzhok.Settings.set("new_bot_grant_rubles", "") end)
    end

    test "defaults to 50 and reads the setting; 0 disables, garbage falls back" do
      assert Ruoc.new_bot_grant_rubles() == 50
      Druzhok.Settings.set("new_bot_grant_rubles", "120")
      assert Ruoc.new_bot_grant_rubles() == 120
      Druzhok.Settings.set("new_bot_grant_rubles", "0")
      assert Ruoc.new_bot_grant_rubles() == 0
      Druzhok.Settings.set("new_bot_grant_rubles", "lots")
      assert Ruoc.new_bot_grant_rubles() == 50
    end
  end

  describe "models/0" do
    test "maps the catalog with prices and caches it", %{stub: stub} do
      assert [%{id: "ruoc-flash", name: "GLM 5.3 Flash", price: %{input: "12", output: "38"}}, %{id: "ruoc-standard"}] =
               Ruoc.models()

      assert [%{id: "ruoc-flash"}] = Ruoc.vision_models()
      assert %{name: "GLM 5.3"} = Ruoc.find_model("ruoc-standard")
      assert Ruoc.price_label(Ruoc.find_model("ruoc-flash")) == "12/38 ₽/M"

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

    test "is empty without a catalog key", %{stub: stub} do
      RuocStub.unset(:ruoc_catalog_key)
      assert Ruoc.models() == []
      assert RuocStub.calls(stub, "GET /v1/models") == []
    end
  end

  test "console_url/1 needs the admin host" do
    assert Ruoc.console_url("acct-1") == "https://admin.test/#/requests/acct-1"
    RuocStub.unset(:ruoc_admin_host)
    assert Ruoc.console_url("acct-1") == nil
  end

  test "default_model/0 is ruoc-flash", do: assert(Ruoc.default_model() == "ruoc-flash")
end
