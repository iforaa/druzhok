defmodule Druzhok.CLITest do
  # async: false — app env (RuocStub) and rows in the shared test DB.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Ecto.Query, only: [from: 2]
  alias Druzhok.{CLI, Instance, Repo, RuocStub}

  defp ago(s), do: DateTime.utc_now() |> DateTime.add(-s) |> DateTime.truncate(:second)

  defp account(id, ref, attrs \\ %{}) do
    Map.merge(
      %{"account_id" => id, "external_ref" => ref, "label" => "druzhok:#{ref}", "status" => "active",
        "plan" => "Старт", "created_at" => DateTime.to_iso8601(ago(7200))},
      attrs
    )
  end

  defp bot(name, attrs) do
    inst =
      Repo.insert!(
        struct(Instance, Map.merge(%{name: name, model: "m", workspace: "/tmp/#{name}/workspace", tenant_key: "dk-#{name}"}, attrs))
      )

    on_exit(fn -> Repo.delete_all(from(i in Instance, where: i.id == ^inst.id)) end)
    inst
  end

  defp serve_accounts(stub, list) do
    Bypass.stub(stub.bypass, "GET", "/partner/accounts", fn conn ->
      conn = RuocStub.record(stub, "GET /partner/accounts", conn)
      RuocStub.reply(conn, 200, list)
    end)
  end

  # main/1's exit status and everything it printed.
  defp run_cli(args) do
    parent = self()
    out = capture_io(fn -> capture_io(:stderr, fn -> send(parent, {:status, CLI.main(args)}) end) end)
    assert_received {:status, status}
    {status, out}
  end

  describe "ruoc_findings/2" do
    test "the four cases, and nothing for a matched bot" do
      n = System.unique_integer([:positive])
      ok = %Instance{name: "ok#{n}", owner_telegram_id: 5, ruoc_account_id: "a-ok"}
      missing = %Instance{name: "miss#{n}", ruoc_account_id: "a-gone"}
      suspended = %Instance{name: "susp#{n}", ruoc_account_id: "a-susp"}
      mismatch = %Instance{name: "mis#{n}", owner_telegram_id: 9, ruoc_account_id: "a-mis"}

      stuck = %Instance{name: "stuck#{n}", ruoc_account_id: "a-stuck", delete_requested: true,
                        delete_error: "ruoc suspend: HTTP 404", delete_failures: 3}

      accounts = [
        %{account_id: "a-ok", external_ref: "ok#{n}:5", status: "active"},
        %{account_id: "a-susp", external_ref: "susp#{n}:-", status: "suspended"},
        %{account_id: "a-mis", external_ref: "mis#{n}:8", status: "active"},
        %{account_id: "a-stuck", external_ref: "stuck#{n}:-", status: "active"},
        %{account_id: "a-orphan", external_ref: "gone:1", status: "active"},
        %{account_id: "a-old", external_ref: "old:1", status: "suspended"}
      ]

      findings = CLI.ruoc_findings(accounts, [ok, missing, suspended, mismatch, stuck])

      assert [{:orphan, %{account_id: "a-orphan"}}] = for({:orphan, _} = f <- findings, do: f)
      assert [{:missing, %{name: "miss" <> _}}] = for({:missing, _} = f <- findings, do: f)
      assert [{:suspended, %{name: "susp" <> _}, _}] = for({:suspended, _, _} = f <- findings, do: f)
      assert [{:ref_mismatch, %{name: "mis" <> _}, _, ref}] = for({:ref_mismatch, _, _, _} = f <- findings, do: f)
      assert ref == "mis#{n}:9"
      assert [{:stuck_delete, %{name: "stuck" <> _}}] = for({:stuck_delete, _} = f <- findings, do: f)
      assert length(findings) == 5
    end
  end

  describe "ruoc-check" do
    setup do
      %{stub: RuocStub.start()}
    end

    test "reports each case and exits 1; changes nothing", %{stub: stub} do
      n = System.unique_integer([:positive])
      bot("chk#{n}", %{owner_telegram_id: 3, ruoc_account_id: "a-#{n}"})
      bot("miss#{n}", %{ruoc_account_id: "a-miss#{n}"})
      bot("ref#{n}", %{ruoc_account_id: "a-ref#{n}"})
      bot("del#{n}", %{ruoc_account_id: "a-del#{n}", delete_requested: true, delete_error: "ruoc suspend: HTTP 404: no", delete_failures: 2})

      serve_accounts(stub, [
        account("a-#{n}", "chk#{n}:3"),
        account("a-ref#{n}", "ref#{n}:77"),
        account("a-del#{n}", "del#{n}:-"),
        account("a-orphan#{n}", "lost#{n}:1")
      ])

      {status, out} = run_cli(["ruoc-check"])
      assert status == 1
      assert out =~ "orphan: account a-orphan#{n}"
      assert out =~ "missing: bot miss#{n} has account a-miss#{n}"
      assert out =~ "ref mismatch: bot ref#{n} account a-ref#{n} has ref ref#{n}:77, expected ref#{n}:-"
      assert out =~ "stuck delete: bot del#{n} (2 attempts): ruoc suspend: HTTP 404: no"
      refute out =~ "bot chk#{n}"
      assert RuocStub.calls(stub, "POST /partner/accounts/:id/suspend") == []
      refute host_override?(hd(RuocStub.calls(stub, "GET /partner/accounts")), stub)
    end

    test "--suspend-orphans suspends only orphans older than an hour", %{stub: stub} do
      n = System.unique_integer([:positive])

      serve_accounts(stub, [
        account("a-old#{n}", "old#{n}:1"),
        account("a-new#{n}", "new#{n}:1", %{"created_at" => DateTime.to_iso8601(ago(600))})
      ])

      {status, out} = run_cli(["ruoc-check", "--suspend-orphans"])
      assert status == 1
      assert out =~ "suspended orphan a-old#{n}"
      assert out =~ "left orphan a-new#{n}"
      assert [%{path: path}] = RuocStub.calls(stub, "POST /partner/accounts/:id/suspend")
      assert path == "/partner/accounts/a-old#{n}/suspend"
    end

    test "a gateway failure is an error", %{stub: stub} do
      Bypass.down(stub.bypass)
      assert {1, _} = run_cli(["ruoc-check"])
    end
  end

  test "migrate-ruoc is gone" do
    assert {1, _} = run_cli(["migrate-ruoc", "x"])
  end

  defp host_override?(call, stub),
    do: List.keyfind(call.headers, "host", 0) not in [nil, {"host", "localhost:#{stub.bypass.port}"}]

  describe "bind-cabinet" do
    test "binds one bot and prints the outcome" do
      stub = RuocStub.start()

      Bypass.stub(stub.bypass, "PUT", "/partner/accounts/:id/telegram", fn conn ->
        conn = RuocStub.record(stub, "PUT /partner/accounts/:id/telegram", conn)
        RuocStub.reply(conn, 200, %{"bot_id" => 321, "mini_app_url" => "https://oldey.dev/tg/?bot=321"})
      end)

      tg = Bypass.open()
      Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{tg.port}")
      on_exit(fn -> Application.delete_env(:druzhok, :telegram_api_base) end)
      Bypass.stub(tg, "POST", "/:bot/:method", fn conn -> Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":true})) end)

      name = "cab#{System.unique_integer([:positive])}"
      bot(name, %{telegram_token: "321:x", owner_telegram_id: 9, ruoc_account_id: "acct-9"})

      assert {0, out} = run_cli(["bind-cabinet", name])
      assert out =~ "привязан, кнопка поставлена"
      assert {0, out} = run_cli(["bind-cabinet", name])
      assert out =~ "без изменений"
      assert length(RuocStub.calls(stub, "PUT /partner/accounts/:id/telegram")) == 1
      assert {1, _} = run_cli(["bind-cabinet", "no-such-bot"])
    end
  end
end
