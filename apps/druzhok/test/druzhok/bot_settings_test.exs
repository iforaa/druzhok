defmodule Druzhok.BotSettingsTest do
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import ExUnit.CaptureIO
  alias Druzhok.{BotSettings, CLI, Instance, Repo, Settings}

  defp reload(inst), do: Repo.get!(Instance, inst.id)

  describe "turning website hosting off" do
    setup do
      stub = Druzhok.RuocStub.start()
      inst = relay_instance(%{active: true, website_hosting_enabled: true, ruoc_api_key: "ruoc_bot"})

      Bypass.stub(stub.bypass, "GET", "/v1/sites", fn conn ->
        conn = Druzhok.RuocStub.record(stub, "GET /v1/sites", conn)
        Druzhok.RuocStub.reply(conn, 200, %{"sites" => [%{"name" => "a"}, %{"name" => "b"}]})
      end)

      %{stub: stub, inst: inst}
    end

    defp deleted(stub), do: Druzhok.RuocStub.calls(stub, "DELETE /v1/sites/:site")

    test "takes every published site down under the bot's own key", %{stub: stub, inst: inst} do
      assert {:ok, row, true} =
               BotSettings.update(inst.name, %{website_hosting_enabled: false}, restart: :when_quiet)

      refute row.website_hosting_enabled
      assert deleted(stub) |> Enum.map(& &1.path) |> Enum.uniq() == ["/v1/sites/a", "/v1/sites/b"]
      assert {"authorization", "Bearer ruoc_bot"} in hd(deleted(stub)).headers
    end

    test "the operator's `set` does the same, then restarts", %{stub: stub, inst: inst} do
      assert {:ok, _, true} = BotSettings.update(inst.name, %{website_hosting_enabled: false})
      assert length(deleted(stub)) >= 2
      assert reload(inst).start_seq == inst.start_seq + 1
    end

    test "a site already gone counts as down", %{stub: stub, inst: inst} do
      Bypass.stub(stub.bypass, "DELETE", "/v1/sites/:site", fn conn ->
        Druzhok.RuocStub.reply(conn, 404, %{"error" => "not_found"})
      end)

      assert {:ok, _, _} = BotSettings.update(inst.name, %{website_hosting_enabled: false})
    end

    test "if the gateway refuses, nothing is saved and no restart is asked", %{stub: stub, inst: inst} do
      Bypass.stub(stub.bypass, "DELETE", "/v1/sites/:site", fn conn ->
        Druzhok.RuocStub.reply(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, {:unpublish_failed, reason}} =
               BotSettings.update(inst.name, %{website_hosting_enabled: false, mention_only: true})

      assert reason =~ "HTTP 500"
      row = reload(inst)
      assert row.website_hosting_enabled
      refute row.mention_only
      assert row.start_seq == inst.start_seq
    end

    test "a refusal under the panel's quiet path leaves nothing for the controller to apply", %{stub: stub, inst: inst} do
      Bypass.stub(stub.bypass, "DELETE", "/v1/sites/:site", fn conn ->
        Druzhok.RuocStub.reply(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, {:unpublish_failed, _}} =
               BotSettings.update(inst.name, %{website_hosting_enabled: false}, restart: :when_quiet)

      row = reload(inst)
      assert row.website_hosting_enabled
      assert row.settings_seq == inst.settings_seq
      assert row.settings_saved_at == inst.settings_saved_at
      assert Druzhok.Panel.Settings.apply_state(row) == "applied"
    end

    test "the row still says on during the first pass, and a site landing behind it is swept", %{stub: stub, inst: inst} do
      test = self()
      {:ok, lists} = Agent.start_link(fn -> 0 end)

      Bypass.stub(stub.bypass, "GET", "/v1/sites", fn conn ->
        send(test, {:listed, reload(inst).website_hosting_enabled})

        sites =
          if Agent.get_and_update(lists, &{&1, &1 + 1}) == 0,
            do: [%{"name" => "a"}],
            else: [%{"name" => "late"}]

        Druzhok.RuocStub.reply(conn, 200, %{"sites" => sites})
      end)

      assert {:ok, row, _} = BotSettings.update(inst.name, %{website_hosting_enabled: false})
      refute row.website_hosting_enabled
      assert_received {:listed, true}
      assert_received {:listed, false}
      assert Enum.map(deleted(stub), & &1.path) == ["/v1/sites/a", "/v1/sites/late"]
    end

    test "a failed sweep keeps the saved off and is logged", %{stub: stub, inst: inst} do
      {:ok, lists} = Agent.start_link(fn -> 0 end)

      Bypass.stub(stub.bypass, "GET", "/v1/sites", fn conn ->
        if Agent.get_and_update(lists, &{&1, &1 + 1}) == 0,
          do: Druzhok.RuocStub.reply(conn, 200, %{"sites" => []}),
          else: Druzhok.RuocStub.reply(conn, 500, %{"error" => "boom"})
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _, _} = BotSettings.update(inst.name, %{website_hosting_enabled: false})
        end)

      refute reload(inst).website_hosting_enabled
      assert log =~ "a late site may be up"
    end

    test "a change that will not save takes no site down", %{stub: stub, inst: inst} do
      assert {:error, %Ecto.Changeset{}} =
               BotSettings.update(inst.name, %{website_hosting_enabled: false, timezone: 12})

      assert Druzhok.RuocStub.calls(stub, "GET /v1/sites") == []
      assert reload(inst).website_hosting_enabled
    end

    test "sites gone before the refusal stay gone, and a retry finishes the job", %{stub: stub, inst: inst} do
      {:ok, ok?} = Agent.start_link(fn -> false end)

      Bypass.stub(stub.bypass, "DELETE", "/v1/sites/:site", fn conn ->
        conn = Druzhok.RuocStub.record(stub, "DELETE /v1/sites/:site", conn)

        if conn.request_path == "/v1/sites/a" or Agent.get(ok?, & &1),
          do: Druzhok.RuocStub.reply(conn, 200, %{}),
          else: Druzhok.RuocStub.reply(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, {:unpublish_failed, _}} = BotSettings.update(inst.name, %{website_hosting_enabled: false})
      assert Enum.map(deleted(stub), & &1.path) == ["/v1/sites/a", "/v1/sites/b"]
      assert reload(inst).website_hosting_enabled

      Agent.update(ok?, fn _ -> true end)
      assert {:ok, _, _} = BotSettings.update(inst.name, %{website_hosting_enabled: false})
      refute reload(inst).website_hosting_enabled
    end

    test "if the gateway cannot list, nothing is saved", %{stub: stub, inst: inst} do
      Bypass.down(stub.bypass)

      assert {:error, {:unpublish_failed, _}} =
               BotSettings.update(inst.name, %{website_hosting_enabled: false}, restart: :when_quiet)

      Bypass.up(stub.bypass)
      assert reload(inst).website_hosting_enabled
    end

    test "turning it on publishes nothing", %{stub: stub} do
      off = relay_instance(%{active: true, website_hosting_enabled: false, ruoc_api_key: "ruoc_bot"})
      assert {:ok, row, _} = BotSettings.update(off.name, %{website_hosting_enabled: true})
      assert row.website_hosting_enabled
      assert Druzhok.RuocStub.calls(stub, "GET /v1/sites") == []
      assert deleted(stub) == []
    end

    test "a bot with no ruoc key has nothing to take down", %{stub: stub} do
      bare = relay_instance(%{active: true, website_hosting_enabled: true})
      assert {:ok, _, _} = BotSettings.update(bare.name, %{website_hosting_enabled: false})
      assert Druzhok.RuocStub.calls(stub, "GET /v1/sites") == []
    end

    test "the panel and the CLI name the failure", %{stub: stub, inst: inst} do
      Bypass.stub(stub.bypass, "DELETE", "/v1/sites/:site", fn conn ->
        Druzhok.RuocStub.reply(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, 502, "unpublish_failed", _} =
               Druzhok.Panel.Settings.save(reload(inst), %{"website_hosting_enabled" => false})

      err =
        capture_io(:stderr, fn ->
          assert 1 == CLI.main(["set", inst.name, "website_hosting_enabled=false"])
        end)

      assert err =~ "could not take all the sites down"
    end
  end

  describe "update/3 with restart: :when_quiet" do
    test "never restarts or wakes, in any state; a restart field bumps settings_seq" do
      for attrs <- [%{active: true}, %{active: true, sleeping: true}, %{active: false}] do
        inst = relay_instance(Map.merge(%{mention_only: false}, attrs))

        assert {:ok, row, true} =
                 BotSettings.update(inst.name, %{mention_only: true}, restart: :when_quiet)

        assert row.mention_only
        assert row.settings_seq == 1
        assert row.settings_saved_at
        assert reload(inst).start_seq == inst.start_seq
        assert reload(inst).active == inst.active
      end
    end

    test "a live-only or unchanged change leaves settings_seq" do
      inst = relay_instance(%{active: true, mention_only: true})

      assert {:ok, row, false} =
               BotSettings.update(
                 inst.name,
                 %{image_gen_model: "m", mention_only: true},
                 restart: :when_quiet
               )

      assert row.settings_seq == 0
      assert row.start_seq == inst.start_seq
    end
  end

  describe "update/2" do
    test "a restart field restarts a running bot" do
      inst = relay_instance(%{active: true, mention_only: false})
      assert {:ok, _, true} = BotSettings.update(inst.name, %{"mention_only" => "true"})
      row = reload(inst)
      assert row.mention_only
      assert row.start_seq == inst.start_seq + 1
    end

    test "a stopped bot is not started, an unchanged value and a live field restart nothing" do
      stopped = relay_instance(%{active: false})
      assert {:ok, _, false} = BotSettings.update(stopped.name, %{trigger_name: "Вася"})
      refute reload(stopped).active
      assert reload(stopped).start_seq == 0

      running = relay_instance(%{active: true, mention_only: true})

      assert {:ok, _, false} =
               BotSettings.update(running.name, %{mention_only: true, sleep_enabled: true})

      assert reload(running).sleep_enabled
      assert reload(running).start_seq == 0
    end

    test "strings are parsed by field type, blank is nil" do
      inst = relay_instance(%{trigger_name: "x", owner_telegram_id: 1})

      assert {:ok, _, _} =
               BotSettings.update(inst.name, %{
                 "trigger_name" => " ",
                 "owner_telegram_id" => "42",
                 "image_gen_enabled" => "on"
               })

      row = reload(inst)
      assert row.trigger_name == nil
      assert row.owner_telegram_id == 42
      assert row.image_gen_enabled
    end

    test "unknown fields, bad values and unknown bots are refused" do
      inst = relay_instance()

      assert {:error, {:unknown_field, "api_key"}} =
               BotSettings.update(inst.name, %{"api_key" => "x"})

      assert {:error, {:not_boolean, :mention_only, "maybe"}} =
               BotSettings.update(inst.name, %{"mention_only" => "maybe"})

      assert {:error, {:unknown_memory_provider, "x"}} =
               BotSettings.update(inst.name, %{"memory_provider" => "x"})

      assert {:error, :not_found} = BotSettings.update("nobody", %{mention_only: true})
    end
  end

  describe "CLI" do
    test "show masks the token" do
      inst = relay_instance(%{telegram_token: "123456:ABCDEFGHIJ"})
      out = capture_io(fn -> assert CLI.main(["show", inst.name]) == 0 end)
      assert out =~ ~r/telegram_token\s+\*\*\*\*GHIJ/
      refute out =~ "ABCDEF"
    end

    test "set saves, reads '-' from stdin and reports errors with status 1" do
      inst = relay_instance()

      assert capture_io("sekret-token\n", fn ->
               assert CLI.main(["set", inst.name, "telegram_token=-", "sleep_enabled=true"]) == 0
             end) =~ "saved"

      assert reload(inst).telegram_token == "sekret-token"
      assert reload(inst).sleep_enabled

      err = capture_io(:stderr, fn -> assert CLI.main(["set", inst.name, "nope=1"]) == 1 end)
      assert err =~ "unknown field nope"

      assert capture_io(:stderr, fn -> assert CLI.main(["set", inst.name, "novalue"]) == 1 end) =~
               "key=value"

      assert capture_io(:stderr, fn -> assert CLI.main(["show", "nobody"]) == 1 end) =~
               "no such bot"

      assert capture_io(:stderr, fn -> assert CLI.main(["frobnicate"]) == 1 end) =~
               "unknown command"
    end

    test "global settings: secrets masked, unknown keys refused" do
      on_exit(fn ->
        import Ecto.Query

        Repo.delete_all(
          from(s in Settings, where: s.key in ["fetch_secret", "sleep_idle_minutes"])
        )
      end)

      Settings.set("fetch_secret", "abcdefghijklmn")
      Settings.set("sleep_idle_minutes", "30")
      out = capture_io(fn -> assert CLI.main(["settings"]) == 0 end)
      assert out =~ ~r/fetch_secret\s+\*\*\*\*klmn/
      assert out =~ ~r/sleep_idle_minutes\s+30/

      assert capture_io(fn ->
               assert CLI.main(["settings", "set", "sleep_idle_minutes=45"]) == 0
             end) =~ "saved"

      assert Settings.get("sleep_idle_minutes") == "45"

      assert capture_io(:stderr, fn -> assert CLI.main(["settings", "set", "bogus=1"]) == 1 end) =~
               "unknown setting bogus"
    end

    test "approve <bot> <id> allows the id and sends the welcome" do
      bypass = Bypass.open()
      Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:druzhok, :telegram_api_base) end)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/bot123abc/sendMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, Jason.decode!(body)})
        Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":{}}))
      end)

      inst = relay_instance(%{active: false, telegram_token: "123abc", welcome_message: "привет"})

      assert capture_io(fn -> assert CLI.main(["approve", inst.name, "777"]) == 0 end) =~
               "approved"

      assert "777" in Instance.get_allowed_ids(reload(inst))
      assert_receive {:sent, %{"chat_id" => chat, "text" => "привет"}}
      assert to_string(chat) == "777"
    end

    test "help lists the commands" do
      assert capture_io(fn -> assert CLI.main(["help"]) == 0 end) =~ "set <bot> key=value"
    end
  end
end
