defmodule Druzhok.BotManagerTest do
  # async: false — mutates the DRUZHOK_DATA_ROOT env var.
  use ExUnit.Case, async: false

  alias Druzhok.BotManager

  describe "safe_to_wipe?/1" do
    setup do
      prev = System.get_env("DRUZHOK_DATA_ROOT")
      System.put_env("DRUZHOK_DATA_ROOT", "/tmp/druzhok-test-root")
      on_exit(fn ->
        if prev, do: System.put_env("DRUZHOK_DATA_ROOT", prev),
                else: System.delete_env("DRUZHOK_DATA_ROOT")
      end)
      :ok
    end

    test "allows a path strictly under the data root" do
      assert BotManager.safe_to_wipe?("/tmp/druzhok-test-root/somebot")
      assert BotManager.safe_to_wipe?("/tmp/druzhok-test-root/somebot/")
    end

    test "refuses the data root itself" do
      refute BotManager.safe_to_wipe?("/tmp/druzhok-test-root")
    end

    test "refuses paths outside the data root" do
      refute BotManager.safe_to_wipe?("/etc")
      refute BotManager.safe_to_wipe?("/tmp/other")
    end

    test "refuses nil, empty, and root" do
      refute BotManager.safe_to_wipe?(nil)
      refute BotManager.safe_to_wipe?("")
      refute BotManager.safe_to_wipe?("/")
    end

    test "refuses a sibling that merely shares the prefix string" do
      # "/tmp/druzhok-test-root-evil" must NOT be treated as inside the root.
      refute BotManager.safe_to_wipe?("/tmp/druzhok-test-root-evil/x")
    end
  end

  describe "prepare_start/1 and the tuning rollback" do
    setup do
      %{data_root: root} = Druzhok.BotFixtures.with_tmp_data_root()
      name = "tune#{System.unique_integer([:positive])}"
      inst = %Druzhok.Instance{name: name, workspace: Path.join([root, name, "workspace"]), model: "x", tenant_key: "k"}
      File.mkdir_p!(inst.workspace)
      outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(outside) end)
      %{inst: inst, home: Path.join(root, name), outside: outside}
    end

    test "a dangling config.yaml symlink is refused, not followed", %{inst: inst, home: home, outside: outside} do
      File.ln_s!(outside, Path.join(home, "config.yaml"))
      assert_raise RuntimeError, ~r/config.yaml.*not_regular/, fn -> BotManager.prepare_start(inst) end
      refute File.exists?(outside)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(home, "config.yaml"))
    end

    test "seeds config.yaml with the tuning keys, and Rollback.tuning/0 removes them", %{inst: inst, home: home} do
      BotManager.prepare_start(inst)
      {:ok, cfg} = YamlElixir.read_from_string(File.read!(Path.join(home, "config.yaml")))
      assert cfg["agent"]["max_turns"] == 30
      assert cfg["terminal"]["cwd"] == inst.workspace

      row = Druzhok.Repo.insert!(%{inst | telegram_token: "rollback-#{inst.name}"})
      on_exit(fn -> Druzhok.Repo.delete(row) end)

      assert {_, :ok} = List.keyfind(Druzhok.Runtime.Hermes.Rollback.tuning(), inst.name, 0)
      {:ok, cfg} = YamlElixir.read_from_string(File.read!(Path.join(home, "config.yaml")))
      refute Map.has_key?(cfg["agent"] || %{}, "max_turns")
      refute Map.has_key?(cfg, "terminal")
      assert {_, :unchanged} = List.keyfind(Druzhok.Runtime.Hermes.Rollback.tuning(), inst.name, 0)
    end
  end
end
