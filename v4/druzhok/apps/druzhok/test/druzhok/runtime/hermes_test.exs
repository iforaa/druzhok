defmodule Druzhok.Runtime.HermesTest do
  use ExUnit.Case, async: true

  alias Druzhok.Runtime.Hermes

  @instance %{
    name: "alice",
    workspace: "/tmp/druzhok-hermes-test/alice/workspace",
    telegram_token: "111:ABCDEF",
    tenant_key: "dk-alice-token",
    model: "anthropic/claude-opus-4.6",
    owner_telegram_id: 42,
    allowed_telegram_ids: Jason.encode!(["100", "200"]),
    mention_only: false,
    trigger_name: nil,
    allowed_telegram_chats: nil,
    allow_all_telegram_users: false,
    timezone: "Europe/Amsterdam",
    id: 1
  }

  describe "env_vars/1" do
    test "flips inference provider to custom so hermes routes via OPENAI_BASE_URL" do
      env = Hermes.env_vars(@instance)
      assert env["HERMES_INFERENCE_PROVIDER"] == "custom"
    end

    test "sets telegram token and builds allowlist from owner + allowed ids" do
      env = Hermes.env_vars(@instance)
      assert env["TELEGRAM_BOT_TOKEN"] == "111:ABCDEF"

      allowed = env["TELEGRAM_ALLOWED_USERS"] |> String.split(",") |> Enum.sort()
      assert allowed == ["100", "200", "42"]
    end

    test "allowlist is empty string when no owner and no allowed ids" do
      inst = %{@instance | owner_telegram_id: nil, allowed_telegram_ids: nil}
      env = Hermes.env_vars(inst)
      assert env["TELEGRAM_ALLOWED_USERS"] == ""
    end

    test "passes tenant key as OPENROUTER_API_KEY so hermes sees a credentialled provider" do
      env = Hermes.env_vars(@instance)
      assert env["OPENROUTER_API_KEY"] == "dk-alice-token"
    end

    test "sets HERMES_HOME to /opt/data" do
      assert Hermes.env_vars(@instance)["HERMES_HOME"] == "/opt/data"
    end

    test "TELEGRAM_REQUIRE_MENTION reflects mention_only flag" do
      assert Hermes.env_vars(%{@instance | mention_only: true})["TELEGRAM_REQUIRE_MENTION"] == "true"
      assert Hermes.env_vars(%{@instance | mention_only: false})["TELEGRAM_REQUIRE_MENTION"] == "false"
    end

    test "TELEGRAM_MENTION_PATTERNS wraps trigger_name in a word-bounded regex" do
      env = Hermes.env_vars(Map.put(@instance, :trigger_name, "Вася"))
      assert env["TELEGRAM_MENTION_PATTERNS"] == Jason.encode!(["\\bВася\\b"])
    end

    test "TELEGRAM_MENTION_PATTERNS is empty when trigger_name is nil or blank" do
      assert Hermes.env_vars(Map.put(@instance, :trigger_name, nil))["TELEGRAM_MENTION_PATTERNS"] == ""
      assert Hermes.env_vars(Map.put(@instance, :trigger_name, ""))["TELEGRAM_MENTION_PATTERNS"] == ""
    end

    test "TELEGRAM_FREE_RESPONSE_CHATS is a comma-separated list from the JSON array field" do
      inst = Map.put(@instance, :allowed_telegram_chats, ~s(["-1002273542926","-12345"]))
      assert Hermes.env_vars(inst)["TELEGRAM_FREE_RESPONSE_CHATS"] == "-1002273542926,-12345"
    end

    test "TELEGRAM_ALLOW_ALL_USERS reflects the flag" do
      assert Hermes.env_vars(Map.put(@instance, :allow_all_telegram_users, true))["TELEGRAM_ALLOW_ALL_USERS"] == "true"
      assert Hermes.env_vars(Map.put(@instance, :allow_all_telegram_users, false))["TELEGRAM_ALLOW_ALL_USERS"] == "false"
    end

    test "does not duplicate keys from Runtime.base_env/1" do
      # OPENAI_BASE_URL / OPENAI_API_KEY / TZ are the shared slot — base_env provides them.
      env = Hermes.env_vars(@instance)
      refute Map.has_key?(env, "OPENAI_BASE_URL")
      refute Map.has_key?(env, "OPENAI_API_KEY")
      refute Map.has_key?(env, "TZ")
    end
  end

  describe "workspace_files/1" do
    test "returns a single create_only config.yaml entry" do
      [{path, content, mode}] = Hermes.workspace_files(@instance)
      assert path == "config.yaml"
      assert mode == :create_only
      assert content =~ "custom"
      assert content =~ @instance.model
      assert content =~ "platforms:\n    telegram:"
    end
  end

  describe "data_mount_path/0 and file_browser_root/1" do
    test "mount path is /opt/data" do
      assert Hermes.data_mount_path() == "/opt/data"
    end

    test "file_browser_root is the parent of instance.workspace" do
      assert Hermes.file_browser_root(@instance) == "/tmp/druzhok-hermes-test/alice"
    end

    test "file_browser_root handles missing workspace gracefully" do
      assert Hermes.file_browser_root(%{}) == ""
    end
  end

  describe "clear_sessions/1" do
    @tag :tmp_dir
    test "removes the sessions subtree", %{tmp_dir: tmp_dir} do
      sessions_dir = Path.join(tmp_dir, "sessions")
      File.mkdir_p!(sessions_dir)
      File.write!(Path.join(sessions_dir, "alice.jsonl"), "line")

      assert :ok = Hermes.clear_sessions(tmp_dir)
      refute File.exists?(sessions_dir)
    end
  end

  describe "read_allowed_users/1" do
    @tag :tmp_dir
    test "parses telegram-approved.json into a list of user ids", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "platforms", "pairing", "telegram-approved.json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"100" => %{}, "200" => %{}}))

      assert Hermes.read_allowed_users(tmp_dir) |> Enum.sort() == ["100", "200"]
    end

    test "returns [] when the approved file is missing" do
      assert Hermes.read_allowed_users("/nonexistent/path/that/does/not/exist") == []
    end
  end

  describe "supports_feature?/1" do
    test "owns :db_allowlist — allowlist lives in instance DB, rebuilt into env on restart" do
      assert Hermes.supports_feature?(:db_allowlist)
    end

    test "returns false for features hermes doesn't support" do
      refute Hermes.supports_feature?(:dreaming)
      refute Hermes.supports_feature?(:heartbeat)
      refute Hermes.supports_feature?(:fallback_models)
    end

    test "supports :group_chat_config — mention_only + trigger_name + allow_all + free_response_chats" do
      assert Hermes.supports_feature?(:group_chat_config)
    end
  end
end
