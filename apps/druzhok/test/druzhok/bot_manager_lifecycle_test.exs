defmodule Druzhok.BotManagerLifecycleTest do
  # async: false — DRUZHOK_DATA_ROOT and real OS processes.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
  alias Druzhok.{BotManager, Instance, Repo, TokenPool}

  setup do
    ctx = with_tmp_data_root()
    start_lifecycle()
    name = "lc#{System.unique_integer([:positive])}"
    cleanup_instance(name)
    Map.put(ctx, :name, name)
  end

  # Token strings are unique per test so an aborted earlier run cannot collide
  # on the tokens.token unique index (core tests run outside a sandbox).
  defp pooled_token(name, prefix) do
    {:ok, pooled} = TokenPool.add("#{prefix}#{name}", "#{name}_bot")
    on_exit(fn -> Repo.delete(pooled) end)
    pooled
  end

  describe "create/2" do
    test "inserts the row stopped; the start request seeds the workspace and starts the process",
         %{name: name, data_root: root} do
      assert {:ok, %{name: ^name, model: "z-ai/glm-5.3-flash"}} =
               BotManager.create(name, %{model: "z-ai/glm-5.3-flash", telegram_token: "1A", owner_telegram_id: 42})

      refute Repo.get_by!(Instance, name: name).active
      assert {:ok, ^name} = BotManager.start(name, wait: true)

      inst = Repo.get_by!(Instance, name: name)
      assert inst.active
      assert inst.telegram_token == "1A"
      assert inst.owner_telegram_id == 42
      assert String.starts_with?(inst.tenant_key, "dk-#{name}-")
      assert inst.workspace == Path.join([root, name, "workspace"])

      assert File.exists?(Path.join([root, name, "config.yaml"]))
      assert File.exists?(Path.join([root, name, "workspace", "AGENTS.md"]))
      assert File.read!(Path.join([root, name, "config.yaml"])) =~ ~s(default: "z-ai/glm-5.3-flash")

      assert eventually(fn -> BotManager.status(name) == "active" end)
      assert eventually(fn -> BotManager.logs(name, 5) =~ "TELEGRAM_BOT_TOKEN=1A" end)
      assert %{mem_bytes: _, cpu_usec: _} = BotManager.stats(name)
      assert {out, 0} = BotManager.exec(name, ["sh", "-c", "echo $OPENAI_API_KEY"])
      assert String.trim(out) == inst.tenant_key
    end

    test "takes a token from the pool when none is given", %{name: name} do
      pooled = pooled_token(name, "2POOLED")

      assert {:ok, _} = BotManager.create(name, %{model: "z-ai/glm-5.3-flash"})
      inst = Repo.get_by!(Instance, name: name)
      assert inst.telegram_token == pooled.token
      assert Repo.reload!(pooled).instance_id == inst.id
    end

    test "fails cleanly when the pool is empty", %{name: name} do
      assert {:error, "No Telegram tokens available in pool"} = BotManager.create(name, %{model: "m"})
      assert Repo.get_by(Instance, name: name) == nil
    end

    test "create on a taken name is refused and leaves the row alone", %{name: name} do
      assert {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A"})
      first = Repo.get_by!(Instance, name: name)

      assert {:error, :name_taken} = BotManager.create(name, %{model: "m2", telegram_token: "1B"})
      again = Repo.get_by!(Instance, name: name)
      assert again.model == "m"
      assert again.telegram_token == "1A"
      assert again.updated_at == first.updated_at
    end

    test "a new bot is polling without a public host and webhook with one", %{name: name} do
      assert {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A"})
      assert Repo.get_by!(Instance, name: name).telegram_mode == "polling"

      Application.put_env(:druzhok, :public_host, "druzhok.test")
      on_exit(fn -> Application.delete_env(:druzhok, :public_host) end)
      other = name <> "w"
      cleanup_instance(other)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = BotManager.create(other, %{model: "m", telegram_token: "1B"})
        end)

      inst = Repo.get_by!(Instance, name: other)

      # The shared test DB's ids may be past the relay's port range; then the
      # bot stays on polling and says why.
      if Druzhok.Telegram.Webhook.port(inst) do
        assert inst.telegram_mode == "webhook"
        assert is_binary(inst.telegram_webhook_secret)
      else
        assert inst.telegram_mode == "polling"
        assert log =~ "stays on polling: {:error, {:id_out_of_range"
      end
    end
  end

  describe "stop/1, start/1, restart/1" do
    setup %{name: name} do
      {:ok, _} = BotManager.create(name, %{model: "z-ai/glm-5.3-flash", telegram_token: "1A"})
      assert {:ok, _} = BotManager.start(name, wait: true)
      :ok
    end

    test "stop marks inactive and kills the process", %{name: name} do
      assert :ok = BotManager.stop(name, wait: true)
      refute Repo.get_by!(Instance, name: name).active
      assert BotManager.status(name) == "inactive"
    end

    test "start after stop brings it back and re-syncs config from the DB", %{name: name, data_root: root} do
      :ok = BotManager.stop(name, wait: true)
      Repo.get_by!(Instance, name: name) |> Instance.changeset(%{model: "openai/gpt-5.4-nano"}) |> Repo.update!()

      assert {:ok, ^name} = BotManager.start(name, wait: true)
      assert Repo.get_by!(Instance, name: name).active
      assert File.read!(Path.join([root, name, "config.yaml"])) =~ ~s(default: "openai/gpt-5.4-nano")
      assert eventually(fn -> BotManager.status(name) == "active" end)
    end

    test "start makes the operator from Settings the slash-command admin", %{name: name, data_root: root} do
      Druzhok.Settings.set("operator_telegram_id", "777001")
      on_exit(fn -> Repo.get_by(Druzhok.Settings, key: "operator_telegram_id") |> Repo.delete() end)
      assert {:ok, ^name} = BotManager.start(name, wait: true)
      content = File.read!(Path.join([root, name, "config.yaml"]))
      assert content =~ ~r/^      allow_admin_from:\n        - "777001"$/m
      assert content =~ ~r/^      user_allowed_commands:\n        - start\n        - new$/m
    end

    test "start keeps hermes's own edits to config.yaml", %{name: name, data_root: root} do
      :ok = BotManager.stop(name, wait: true)
      path = Path.join([root, name, "config.yaml"])
      File.write!(path, File.read!(path) <> "\ncustom_runtime_key: 42\n")

      assert {:ok, ^name} = BotManager.start(name, wait: true)
      assert File.read!(path) =~ "custom_runtime_key: 42"
    end

    test "restart is a fresh start of the running bot", %{name: name} do
      %{start_seq: seq} = Repo.get_by!(Instance, name: name)

      assert {:ok, ^name} = BotManager.restart(name, wait: true)
      inst = Repo.get_by!(Instance, name: name)
      assert inst.active
      assert inst.applied_seq == seq + 1
      assert BotManager.status(name) == "active"
    end

    test "start of an unknown name is an error" do
      assert {:error, :not_found} = BotManager.start("no-such-bot")
      assert :ok = BotManager.stop("no-such-bot")
    end

    test "a waiter for a start is not failed by an older start's failure", %{name: name} do
      inst = Repo.get_by!(Instance, name: name)
      Repo.update_all(Ecto.Query.from(i in Instance, where: i.id == ^inst.id), set: [failed_seq: inst.start_seq])
      assert {:ok, ^name} = BotManager.restart(name, wait: true)
    end
  end

  describe "ruoc" do
    setup do
      %{stub: Druzhok.RuocStub.start()}
    end

    test "migrate_to_ruoc creates the account, remaps models, restarts, and is idempotent",
         %{name: name, data_root: root, stub: stub} do
      {:ok, _} = BotManager.create(name, %{model: "z-ai/glm-5.3-flash", telegram_token: "1A", image_model: "google/gemini-2.5-flash-lite"})
      # create/2 provisioned already (ruoc is configured); undo that to test a legacy bot.
      Repo.get_by!(Instance, name: name)
      |> Instance.changeset(%{ruoc_account_id: nil, ruoc_api_key: nil, model: "z-ai/glm-5.3-flash", image_model: "google/gemini-2.5-flash-lite"})
      |> Repo.update!()

      assert {:ok, _} = BotManager.start(name, wait: true)

      assert {:ok, %{account_id: "acct-" <> _ = id, model: "ruoc-flash"}} = BotManager.migrate_to_ruoc(name)

      inst = Repo.get_by!(Instance, name: name)
      assert inst.ruoc_account_id == id
      assert inst.ruoc_api_key =~ "ruoc_key"
      assert inst.model == "ruoc-flash"
      assert inst.image_model == "ruoc-flash"
      assert [call | _] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts") |> Enum.reverse()
      assert call.params["label"] == "druzhok:#{name}"
      # Migration funds nothing; the owner already has a balance to move.
      refute Map.has_key?(call.params, "grant_rubles")

      # The restart is a request; the controller re-syncs config.yaml.
      assert eventually(fn -> File.read!(Path.join([root, name, "config.yaml"])) =~ ~s(default: "ruoc-flash") end, 200)
      assert eventually(fn -> BotManager.status(name) == "active" end)

      assert {:already_migrated, ^name} = BotManager.migrate_to_ruoc(name)
      assert {:error, :not_found} = BotManager.migrate_to_ruoc("no-such-bot")
    end

    test "create leaves funding to ruoc's default plan: no grant_rubles", %{name: name, stub: stub} do
      {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A"})
      assert [%{params: params}] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts")
      refute Map.has_key?(params, "grant_rubles")
      refute Map.has_key?(params, "plan")
    end

    test "migrate_to_ruoc leaves the row alone when the gateway refuses", %{name: name, stub: stub} do
      {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A"})
      Repo.get_by!(Instance, name: name) |> Instance.changeset(%{ruoc_account_id: nil, ruoc_api_key: nil}) |> Repo.update!()

      Bypass.expect_once(stub.bypass, "POST", "/admin/accounts", fn conn ->
        Druzhok.RuocStub.reply(conn, 500, %{"error" => %{"type" => "api_error", "message" => "internal error"}})
      end)

      assert {:error, "HTTP 500: internal error"} = BotManager.migrate_to_ruoc(name)
      assert Repo.get_by!(Instance, name: name).ruoc_api_key == nil
    end

    test "create provisions a ruoc account when the gateway is configured", %{name: name, stub: stub} do
      assert {:ok, %{model: "ruoc-flash"}} = BotManager.create(name, %{telegram_token: "1A"})
      assert {:ok, _} = BotManager.start(name, wait: true)
      inst = Repo.get_by!(Instance, name: name)
      assert inst.ruoc_account_id =~ "acct-"
      assert inst.ruoc_api_key =~ "ruoc_key"
      assert [%{params: %{"label" => label}}] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts")
      assert label == "druzhok:#{name}"
      assert {out, 0} = BotManager.exec(name, ["sh", "-c", "echo $OPENAI_API_KEY"])
      # The bot still talks to druzhok with its tenant key; the ruoc key stays server-side.
      assert String.trim(out) == inst.tenant_key
    end

    test "the ruoc label carries the owner's telegram id when known", %{name: name, stub: stub} do
      assert {:ok, _} = BotManager.create(name, %{telegram_token: "1A", owner_telegram_id: 4242})
      assert [%{params: %{"label" => label}}] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts")
      assert label == "druzhok:#{name} tg:4242"
      assert BotManager.ruoc_label("x", nil) == "druzhok:x"
    end

    test "create keeps a legacy model id out of a ruoc bot", %{name: name} do
      assert {:ok, %{model: "ruoc-standard"}} = BotManager.create(name, %{model: "z-ai/glm-5.3", telegram_token: "1A"})
      assert {:ok, %{model: "ruoc-flash"}} = BotManager.create(name <> "b", %{model: "anthropic/claude-sonnet-4-6", telegram_token: "1B"})
      cleanup_instance(name <> "b")
    end

    test "create leaves no row when account creation fails", %{name: name, stub: stub} do
      Bypass.down(stub.bypass)
      assert {:error, "ruoc-gateway account creation failed: " <> _} = BotManager.create(name, %{telegram_token: "1A"})
      assert Repo.get_by(Instance, name: name) == nil
    end

    test "create skips provisioning when ruoc is not configured", %{name: name, stub: stub} do
      Druzhok.RuocStub.unset(:ruoc_admin_token)
      assert {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A"})
      assert Repo.get_by!(Instance, name: name).ruoc_api_key == nil
      assert Druzhok.RuocStub.calls(stub, "POST /admin/accounts") == []
    end

    test "delete suspends the ruoc account", %{name: name, stub: stub} do
      {:ok, _} = BotManager.create(name, %{telegram_token: "1A"})
      id = Repo.get_by!(Instance, name: name).ruoc_account_id

      assert :ok = BotManager.delete(name, wait: true)

      assert [%{path: path}] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts/:id/status")
      assert path == "/admin/accounts/#{id}/status"
      assert Repo.get_by(Instance, name: name) == nil
    end

    test "delete still succeeds when suspend fails", %{name: name, stub: stub} do
      {:ok, _} = BotManager.create(name, %{telegram_token: "1A"})
      Bypass.down(stub.bypass)
      assert :ok = BotManager.delete(name, wait: true)
      assert Repo.get_by(Instance, name: name) == nil
    end

    test "create sends the invite to ruoc and admits the owner", %{name: name, stub: stub} do
      owner = System.unique_integer([:positive]) + 20_000_000
      on_exit(fn -> Repo.delete_all(from(a in "admissions", where: a.telegram_id == ^owner)) end)
      refute Druzhok.Admissions.admitted?(owner)

      {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A", owner_telegram_id: owner, invite: "ABCD-EFGH"})

      assert [%{params: params}] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts")
      assert params["invite"] == "ABCD-EFGH"
      assert Druzhok.Admissions.admitted?(owner)
      assert %{invite_hint: "ABCD"} = Repo.one(from(a in "admissions", where: a.telegram_id == ^owner, select: %{invite_hint: a.invite_hint}))
    end

    test "a refused invite leaves no row and no admission", %{name: name, stub: stub} do
      owner = System.unique_integer([:positive]) + 20_000_000

      Bypass.expect_once(stub.bypass, "POST", "/admin/accounts", fn conn ->
        Druzhok.RuocStub.reply(conn, 409, %{"error" => %{"type" => "invite_spent", "message" => "used"}})
      end)

      assert {:error, {:invite, :spent}} =
               BotManager.create(name, %{model: "m", telegram_token: "1A", owner_telegram_id: owner, invite: "ABCD-EFGH"})

      assert Repo.get_by(Instance, name: name) == nil
      refute Druzhok.Admissions.admitted?(owner)
    end

    test "create without a code still admits the owner", %{name: name} do
      owner = System.unique_integer([:positive]) + 20_000_000
      on_exit(fn -> Repo.delete_all(from(a in "admissions", where: a.telegram_id == ^owner)) end)
      {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A", owner_telegram_id: owner})
      assert Druzhok.Admissions.admitted?(owner)
    end
  end

  describe "delete/1" do
    test "wipes the data dir under the root, releases the token and drops the row", %{name: name, data_root: root} do
      pooled = pooled_token(name, "3POOLED")
      {:ok, _} = BotManager.create(name, %{model: "m"})
      dir = Path.join(root, name)
      assert File.dir?(dir)

      assert :ok = BotManager.delete(name, wait: true)

      refute File.exists?(dir)
      assert Repo.get_by(Instance, name: name) == nil
      assert Repo.reload!(pooled).instance_id == nil
      assert BotManager.status(name) == "inactive"
    end

    test "refuses to wipe a workspace outside the data root", %{name: name} do
      outside = Path.join(System.tmp_dir!(), "outside-#{name}")
      File.mkdir_p!(Path.join(outside, "workspace"))
      File.write!(Path.join(outside, "keep.txt"), "precious")
      on_exit(fn -> File.rm_rf!(outside) end)

      %Instance{}
      |> Instance.changeset(%{name: name, model: "m", workspace: Path.join(outside, "workspace"), tenant_key: "dk-x"})
      |> Repo.insert!()

      assert :ok = BotManager.delete(name, wait: true)

      assert File.read!(Path.join(outside, "keep.txt")) == "precious"
      assert Repo.get_by(Instance, name: name) == nil
    end

    test "delete of an unknown name is a no-op" do
      assert :ok = BotManager.delete("no-such-bot")
    end
  end
end
