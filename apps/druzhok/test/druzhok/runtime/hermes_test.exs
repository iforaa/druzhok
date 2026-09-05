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

    test "HERMES_HOME and MESSAGING_CWD derive from instance.workspace" do
      env = Hermes.env_vars(%{workspace: "/data/tenants/b/workspace", tenant_key: "k"})
      assert env["HERMES_HOME"] == "/data/tenants/b"
      assert env["MESSAGING_CWD"] == "/data/tenants/b/workspace"
      refute Map.has_key?(env, "HERMES_UID")
      refute Map.has_key?(env, "HERMES_GID")
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
    test "seeds config.yaml and workspace/AGENTS.md, both create_only" do
      [{"config.yaml", config, :create_only}, {"workspace/AGENTS.md", agents, :create_only}] =
        Hermes.workspace_files(@instance)

      assert config =~ "custom"
      assert config =~ @instance.model
      assert config =~ "platforms:\n    telegram:"

      for heading <- ["## Каждая сессия", "## Память", "## Стиль", "## Публикация сайтов"],
          do: assert(agents =~ heading)

      refute agents =~ "/opt/data"
    end
  end

  describe "data_root/1" do
    test "is the parent of instance.workspace" do
      inst = %{workspace: "/data/tenants/b/workspace"}
      assert Hermes.data_root(inst) == "/data/tenants/b"
    end

    test "handle missing workspace gracefully" do
      assert Hermes.data_root(%{}) == ""
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

  describe "vision model" do
    test "legacy bot falls back to the OpenRouter vision default" do
      yaml = Hermes.build_config_yaml(@instance)
      assert yaml =~ ~s(model: "google/gemini-2.5-flash-lite")
    end

    test "migrated bot without image_model uses its own model for vision" do
      yaml = Hermes.build_config_yaml(Map.merge(@instance, %{model: "ruoc-flash", ruoc_api_key: "ruoc_x"}))
      refute yaml =~ "gemini-2.5-flash-lite"
      assert yaml =~ "vision:\n    provider: custom\n    base_url: \"http://127.0.0.1:4000/v1\"\n    api_key: \"dk-alice-token\"\n    model: \"ruoc-flash\""
    end

    test "an explicit image_model wins on both paths" do
      yaml = Hermes.build_config_yaml(Map.merge(@instance, %{ruoc_api_key: "ruoc_x", image_model: "ruoc-vision"}))
      assert yaml =~ ~s(model: "ruoc-vision")
    end
  end

  describe "sync_config/2 — memory block" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hermes-mem-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "forces builtin provider and legacy memory on, keeps char limits", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"
      memory:
        provider: honcho
        memory_enabled: false
        user_profile_enabled: false
        memory_char_limit: 999
      """)

      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert content =~ ~r/^  provider: builtin$/m
      assert content =~ ~r/^  memory_enabled: true$/m
      assert content =~ ~r/^  user_profile_enabled: true$/m
      assert content =~ ~r/^  memory_char_limit: 999$/m
    end

    test "removes a stale honcho.json", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")
      File.write!(Path.join(tmp_dir, "honcho.json"), "{}")
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      refute File.exists?(Path.join(tmp_dir, "honcho.json"))
    end

    test "AGENTS.md memory section is the builtin text", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")
      File.write!(Path.join([tmp_dir, "workspace", "AGENTS.md"]), "# Agent\n\n## Память\n\nhoncho stuff\n\n## Other\n")
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      agents = File.read!(Path.join([tmp_dir, "workspace", "AGENTS.md"]))
      refute agents =~ "honcho"
      assert agents =~ "## Память"
      assert agents =~ "## Other"
    end
  end

  describe "sync_config/2 — gateway systemd watchdog" do
    @tag :tmp_dir
    test "adds gateway.systemd_watchdog_seconds when missing", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert content =~ ~r/^gateway:\n  systemd_watchdog_seconds: 60$/m
    end

    @tag :tmp_dir
    test "overwrites an existing value", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "gateway:\n  systemd_watchdog_seconds: 0\n  other: 1\n")
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert content =~ ~r/^  systemd_watchdog_seconds: 60$/m
      assert content =~ ~r/^  other: 1$/m
    end
  end

  describe "sync_config/2 — group_sessions_per_user" do
    @tag :tmp_dir
    test "appends the key when absent", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")

      inst = Map.put(@instance, :group_shared_memory, true)
      assert :ok = Hermes.sync_config(inst, tmp_dir)

      yaml = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert yaml =~ ~r/^group_sessions_per_user: false$/m
    end

    @tag :tmp_dir
    test "overwrites an existing value rather than duplicating", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"

      group_sessions_per_user: true
      """)

      inst = Map.put(@instance, :group_shared_memory, true)
      assert :ok = Hermes.sync_config(inst, tmp_dir)

      yaml = File.read!(Path.join(tmp_dir, "config.yaml"))
      matches = Regex.scan(~r/^group_sessions_per_user:/m, yaml)
      assert length(matches) == 1
      assert yaml =~ ~r/^group_sessions_per_user: false$/m
    end
  end

  describe "build_config_yaml/1" do
    test "emits group_sessions_per_user: false when group_shared_memory is on" do
      inst = Map.put(@instance, :group_shared_memory, true)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_sessions_per_user: false$/m
    end

    test "emits group_sessions_per_user: true when group_shared_memory is off" do
      inst = Map.put(@instance, :group_shared_memory, false)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_sessions_per_user: true$/m
    end

    test "defaults to true when key missing on the instance map" do
      inst = Map.delete(@instance, :group_shared_memory)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_sessions_per_user: true$/m
    end
  end

  describe "env_vars/1 — BOT_SITE_BASE_URL" do
    test "emits URL when hosting is enabled" do
      inst = Map.merge(@instance, %{website_hosting_enabled: true, name: "alice"})
      assert Hermes.env_vars(inst)["BOT_SITE_BASE_URL"] == "https://alice.oldey.dev"
    end

    test "emits empty string when hosting is disabled" do
      inst = Map.put(@instance, :website_hosting_enabled, false)
      assert Hermes.env_vars(inst)["BOT_SITE_BASE_URL"] == ""
    end

    test "defaults to empty string when key missing on instance map" do
      inst = Map.delete(@instance, :website_hosting_enabled)
      assert Hermes.env_vars(inst)["BOT_SITE_BASE_URL"] == ""
    end
  end

  describe "sync_agents_md/2" do
    @tag :tmp_dir
    test "appends the sites section when absent", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS.md\n\nExisting content.\n")

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      content = File.read!(Path.join(workspace, "AGENTS.md"))
      assert content =~ "## Публикация сайтов"
      assert content =~ "BOT_SITE_BASE_URL"
    end

    @tag :tmp_dir
    test "rewrites a stale sites section (old Docker path)", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)

      File.write!(
        Path.join(workspace, "AGENTS.md"),
        "# AGENTS.md\n\n## Публикация сайтов\n\nПиши в `/opt/data/workspace/sites/`.\n\n## Своё\n\nне трогать\n"
      )

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)
      content = File.read!(Path.join(workspace, "AGENTS.md"))
      refute content =~ "/opt/data"
      assert content =~ "`sites/<имя>/`"
      assert content =~ "## Своё\n\nне трогать"
    end

    @tag :tmp_dir
    test "is idempotent when section already present", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS.md\n\nExisting content.\n")

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)
      first = File.read!(Path.join(workspace, "AGENTS.md"))

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)
      second = File.read!(Path.join(workspace, "AGENTS.md"))

      assert first == second
    end

    @tag :tmp_dir
    test "is a no-op when AGENTS.md does not exist", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      refute File.exists?(Path.join(workspace, "AGENTS.md"))
    end

    @tag :tmp_dir
    test "memory section: builtin variant when memory_provider=builtin",
         %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)

      File.write!(Path.join(workspace, "AGENTS.md"), """
      # AGENTS.md

      ## Память

      _to be replaced_

      ## Other

      keep
      """)

      inst = Map.put(@instance, :memory_provider, "builtin")
      assert :ok = Hermes.sync_agents_md(inst, tmp_dir)

      content = File.read!(Path.join(workspace, "AGENTS.md"))
      assert content =~ "MEMORY.md"
      assert content =~ "memory/YYYY-MM-DD.md"
      refute content =~ "honcho_conclude"
      assert content =~ "## Other"
    end

    @tag :tmp_dir
    test "memory section: appends if missing entirely",
         %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS.md\n\nNo memory section yet.\n")

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      content = File.read!(Path.join(workspace, "AGENTS.md"))
      assert content =~ "## Память"
      assert content =~ "MEMORY.md"
    end

    @tag :tmp_dir
    test "style section: replaces stale wording on existing bots",
         %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)

      File.write!(Path.join(workspace, "AGENTS.md"), """
      # AGENTS.md

      ## Стиль

      - Кратко когда нужно, подробно когда важно
      - Не используй инструменты для простых ответов
      - Инструмент не сработал → не повторяй. Максимум 2 попытки.

      ## Other

      keep
      """)

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      content = File.read!(Path.join(workspace, "AGENTS.md"))
      assert content =~ "Один точный поиск лучше десяти"
      assert content =~ "Один и тот же запрос дважды — никогда"
      refute content =~ "Не используй инструменты для простых ответов"
      assert content =~ "## Other"
      assert content =~ "keep"
    end

    @tag :tmp_dir
    test "style section: appends when missing entirely", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS.md\n\nNo style section yet.\n")

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      content = File.read!(Path.join(workspace, "AGENTS.md"))
      assert content =~ "## Стиль"
      assert content =~ "Один точный поиск лучше десяти"
    end

    @tag :tmp_dir
    test "session section: replaces stale 'IDENTITY.md, USER.md уже загружены' lie",
         %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)

      File.write!(Path.join(workspace, "AGENTS.md"), """
      # AGENTS.md

      ## Каждая сессия

      Перед любыми действиями:
      1. SOUL.md, IDENTITY.md, USER.md уже загружены — **не читай их заново**
      2. `MEMORY.md` уже в контексте — используй `memory_recall` для поиска по памяти
      3. Читай файлы только если нужно обновить

      ## Прочее

      keep
      """)

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      content = File.read!(Path.join(workspace, "AGENTS.md"))
      assert content =~ "SOUL.md уже загружен в системный промпт"
      refute content =~ "IDENTITY.md, USER.md уже загружены"
      refute content =~ "memory_recall"
      assert content =~ "## Прочее"
      assert content =~ "keep"
    end

    @tag :tmp_dir
    test "session section: appends when missing entirely", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS.md\n\nNo session section yet.\n")

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      content = File.read!(Path.join(workspace, "AGENTS.md"))
      assert content =~ "## Каждая сессия"
      assert content =~ "SOUL.md уже загружен"
    end

    @tag :tmp_dir
    test "style section: idempotent across two syncs", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS.md\n\nbody\n")

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)
      first = File.read!(Path.join(workspace, "AGENTS.md"))

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)
      second = File.read!(Path.join(workspace, "AGENTS.md"))

      assert first == second
    end
  end

end
