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
               Ruoc.create_account("druzhok:bot1", grant_rubles: "5")

      [call] = RuocStub.calls(stub, "POST /admin/accounts")
      assert call.params == %{"label" => "druzhok:bot1", "grant_rubles" => "5"}
      assert {"authorization", "Bearer " <> RuocStub.admin_token()} in call.headers
      assert {"host", "admin.test"} in call.headers
    end

    test "omits grant_rubles and invite when none given", %{stub: stub} do
      assert {:ok, _} = Ruoc.create_account("druzhok:bot2")
      [call] = RuocStub.calls(stub, "POST /admin/accounts")
      refute Map.has_key?(call.params, "grant_rubles")
      refute Map.has_key?(call.params, "invite")
    end

    test "sends the invite code and maps the three refusals", %{stub: stub} do
      assert {:ok, _} = Ruoc.create_account("druzhok:kot", invite: "ABCD-EFGH")
      [call] = RuocStub.calls(stub, "POST /admin/accounts")
      assert call.params["invite"] == "ABCD-EFGH"

      for {type, reason} <- [{"invite_invalid", :invalid}, {"invite_spent", :spent}, {"invite_expired", :expired}] do
        Bypass.expect_once(stub.bypass, "POST", "/admin/accounts", fn conn ->
          RuocStub.reply(conn, 409, %{"error" => %{"type" => type, "message" => "no"}})
        end)

        assert {:error, {:invite, ^reason}} = Ruoc.create_account("druzhok:kot", invite: "ABCD-EFGH")
      end
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

    test "is empty without a catalog key", %{stub: stub} do
      RuocStub.unset(:ruoc_catalog_key)
      assert Ruoc.models() == []
      assert RuocStub.calls(stub, "GET /v1/models") == []
    end
  end

  test "default_model/0 is ruoc-flash", do: assert(Ruoc.default_model() == "ruoc-flash")

  describe "check_invite/1" do
    test "asks the admin surface and returns the status as an atom", %{stub: stub} do
      assert {:ok, :available} = Ruoc.check_invite("ABCD-EFGH")
      [call] = RuocStub.calls(stub, "GET /admin/invites/check")
      assert call.path == "/admin/invites/check"
      assert {"host", "admin.test"} in call.headers

      for status <- ["spent", "expired", "invalid"] do
        Bypass.expect_once(stub.bypass, "GET", "/admin/invites/check", fn conn ->
          RuocStub.reply(conn, 200, %{"status" => status})
        end)

        assert {:ok, String.to_atom(status)} == Ruoc.check_invite("x")
      end
    end

    test "an unknown status or a failure is an error", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "GET", "/admin/invites/check", fn conn ->
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
end
