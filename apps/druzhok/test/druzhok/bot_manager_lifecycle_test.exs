defmodule Druzhok.BotManagerLifecycleTest do
  # async: false — DRUZHOK_DATA_ROOT and real OS processes.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{BotManager, Instance, Repo, TokenPool}

  setup do
    ctx = with_tmp_data_root()
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
    test "inserts the row, seeds the workspace and starts the process", %{name: name, data_root: root} do
      assert {:ok, %{name: ^name, model: "z-ai/glm-5.3-flash"}} =
               BotManager.create(name, %{model: "z-ai/glm-5.3-flash", telegram_token: "1A", owner_telegram_id: 42})

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

    test "create on an existing name updates the model and keeps the row", %{name: name} do
      assert {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A"})
      first = Repo.get_by!(Instance, name: name)

      assert {:ok, %{model: "m2"}} = BotManager.create(name, %{model: "m2", telegram_token: "1B"})
      again = Repo.get_by!(Instance, name: name)
      assert again.id == first.id
      assert again.model == "m2"
      # Only model and active are touched on re-create.
      assert again.telegram_token == "1A"
      assert again.tenant_key == first.tenant_key
    end
  end

  describe "stop/1, start/1, restart/1" do
    setup %{name: name} do
      {:ok, _} = BotManager.create(name, %{model: "z-ai/glm-5.3-flash", telegram_token: "1A"})
      assert eventually(fn -> BotManager.status(name) == "active" end)
      :ok
    end

    test "stop marks inactive and kills the process", %{name: name} do
      assert :ok = BotManager.stop(name)
      refute Repo.get_by!(Instance, name: name).active
      assert BotManager.status(name) == "inactive"
    end

    test "start after stop brings it back and re-syncs config from the DB", %{name: name, data_root: root} do
      :ok = BotManager.stop(name)
      Repo.get_by!(Instance, name: name) |> Instance.changeset(%{model: "openai/gpt-5.4-nano"}) |> Repo.update!()

      assert {:ok, ^name} = BotManager.start(name)
      assert Repo.get_by!(Instance, name: name).active
      assert File.read!(Path.join([root, name, "config.yaml"])) =~ ~s(default: "openai/gpt-5.4-nano")
      assert eventually(fn -> BotManager.status(name) == "active" end)
    end

    test "start keeps hermes's own edits to config.yaml", %{name: name, data_root: root} do
      :ok = BotManager.stop(name)
      path = Path.join([root, name, "config.yaml"])
      File.write!(path, File.read!(path) <> "\ncustom_runtime_key: 42\n")

      assert {:ok, ^name} = BotManager.start(name)
      assert File.read!(path) =~ "custom_runtime_key: 42"
    end

    test "restart is stop then start", %{name: name} do
      assert {:ok, ^name} = BotManager.restart(name)
      assert Repo.get_by!(Instance, name: name).active
      assert eventually(fn -> BotManager.status(name) == "active" end)
    end

    test "start of an unknown name is an error" do
      assert {:error, :not_found} = BotManager.start("no-such-bot")
      assert :ok = BotManager.stop("no-such-bot")
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

      assert eventually(fn -> BotManager.status(name) == "active" end)

      assert {:ok, %{account_id: "acct-" <> _ = id, model: "ruoc-flash"}} = BotManager.migrate_to_ruoc(name)

      inst = Repo.get_by!(Instance, name: name)
      assert inst.ruoc_account_id == id
      assert inst.ruoc_api_key =~ "ruoc_key"
      assert inst.model == "ruoc-flash"
      assert inst.image_model == "ruoc-flash"
      assert [call | _] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts") |> Enum.reverse()
      assert call.params["label"] == "druzhok:#{name}"

      assert eventually(fn -> BotManager.status(name) == "active" end)
      assert File.read!(Path.join([root, name, "config.yaml"])) =~ ~s(default: "ruoc-flash")

      assert {:already_migrated, ^name} = BotManager.migrate_to_ruoc(name)
      assert {:error, :not_found} = BotManager.migrate_to_ruoc("no-such-bot")
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

      assert :ok = BotManager.delete(name)

      assert [%{path: path}] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts/:id/status")
      assert path == "/admin/accounts/#{id}/status"
      assert Repo.get_by(Instance, name: name) == nil
    end

    test "delete still succeeds when suspend fails", %{name: name, stub: stub} do
      {:ok, _} = BotManager.create(name, %{telegram_token: "1A"})
      Bypass.down(stub.bypass)
      assert :ok = BotManager.delete(name)
      assert Repo.get_by(Instance, name: name) == nil
    end
  end

  describe "delete/1" do
    test "wipes the data dir under the root, releases the token and drops the row", %{name: name, data_root: root} do
      pooled = pooled_token(name, "3POOLED")
      {:ok, _} = BotManager.create(name, %{model: "m"})
      dir = Path.join(root, name)
      assert File.dir?(dir)

      assert :ok = BotManager.delete(name)

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

      assert :ok = BotManager.delete(name)

      assert File.read!(Path.join(outside, "keep.txt")) == "precious"
      assert Repo.get_by(Instance, name: name) == nil
    end

    test "delete of an unknown name is a no-op" do
      assert :ok = BotManager.delete("no-such-bot")
    end
  end
end
