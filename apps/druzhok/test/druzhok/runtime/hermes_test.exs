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
    test "a builtin bot gets no MNEMOSYNE_ keys" do
      refute Hermes.env_vars(@instance)
             |> Map.keys()
             |> Enum.any?(&String.starts_with?(&1, "MNEMOSYNE_"))
    end

    test "a mnemosyne bot points the provider at the proxy with e5 prefixes and no LLM" do
      env = Hermes.env_vars(Map.put(@instance, :memory_provider, "mnemosyne"))

      assert env["MNEMOSYNE_DATA_DIR"] ==
               Path.join([Hermes.data_root(@instance), "mnemosyne", "data"])

      assert env["MNEMOSYNE_EMBEDDING_API_URL"] == Hermes.proxy_url()
      assert env["MNEMOSYNE_EMBEDDING_API_KEY"] == "dk-alice-token"
      assert env["MNEMOSYNE_EMBEDDING_MODEL"] == "ruoc-embed-gemini"
      assert env["MNEMOSYNE_EMBEDDING_DIM"] == "3072"
      assert env["MNEMOSYNE_EMBEDDING_QUERY_PREFIX"] == "query: "
      assert env["MNEMOSYNE_EMBEDDING_DOC_PREFIX"] == "passage: "
      assert env["MNEMOSYNE_LLM_ENABLED"] == "false"
      assert env["MNEMOSYNE_HOST_LLM_ENABLED"] == "false"
    end

    test "leaves model and provider to config.yaml" do
      env = Hermes.env_vars(@instance)

      for key <- ~w(HERMES_INFERENCE_PROVIDER HERMES_MODEL HERMES_QUIET),
          do: refute(Map.has_key?(env, key))

      assert env["MESSAGING_CWD"] == Path.join(Hermes.data_root(@instance), "workspace")
    end

    # Bots have no internet: an openrouter.ai call hangs until its timeout
    # (the video tool's catalog held every start for 20 s).
    test "anything hermes sends to openrouter goes to the proxy" do
      assert Hermes.env_vars(@instance)["OPENROUTER_BASE_URL"] == Hermes.proxy_url()
    end

    test "sets telegram token and builds allowlist from owner + allowed ids" do
      env = Hermes.env_vars(@instance)
      assert env["TELEGRAM_BOT_TOKEN"] == "111:ABCDEF"

      allowed = env["TELEGRAM_ALLOWED_USERS"] |> String.split(",") |> Enum.sort()
      assert allowed == ["100", "200", "42"]
    end

    test "pins Telegram fallback IPs inside the nftables 149.154.160.0/20 allow range" do
      ips = Hermes.env_vars(@instance)["TELEGRAM_FALLBACK_IPS"] |> String.split(",")
      assert ips != []

      for ip <- ips do
        {:ok, {149, 154, third, _}} = :inet.parse_ipv4strict_address(String.to_charlist(ip))
        assert third in 160..175, "#{ip} is outside the Telegram range bots may reach"
      end
    end

    test "a stopping bot lets a running turn finish, within the unit's stop timeout" do
      drain = String.to_integer(Hermes.env_vars(@instance)["HERMES_RESTART_DRAIN_TIMEOUT"])
      assert drain > 0
      # hermes resolve_systemd_timeout_stop_sec: max(60, max(drain, 30 + 10) + 30),
      # against hermes@.service's TimeoutStopSec (systemd default 90 s, unset in the unit).
      refute File.read!(Path.expand("../../../../../ops/hermes@.service", __DIR__)) =~
               "TimeoutStopSec"

      assert max(60, max(drain, 40) + 30) <= 90
    end

    test "every bot carries its loopback webhook port; only webhook mode gets URL and secret" do
      polling = Hermes.env_vars(Map.merge(@instance, %{id: 9, telegram_mode: "polling"}))
      assert polling["TELEGRAM_WEBHOOK_PORT"] == "20009"
      assert polling["TELEGRAM_WEBHOOK_HOST"] == "127.0.0.1"
      refute Map.has_key?(polling, "TELEGRAM_WEBHOOK_URL")
      refute Map.has_key?(polling, "TELEGRAM_WEBHOOK_SECRET")

      webhook =
        Hermes.env_vars(
          Map.merge(@instance, %{id: 9, telegram_mode: "webhook", telegram_webhook_secret: "abc"})
        )

      assert webhook["TELEGRAM_WEBHOOK_URL"] =~ ~r{^https://[^/]+/telegram/webhook/alice$}
      assert webhook["TELEGRAM_WEBHOOK_SECRET"] == "abc"
      assert webhook["TELEGRAM_WEBHOOK_PORT"] == "20009"
    end

    test "an id outside the port range gets no webhook vars, even in webhook mode" do
      env =
        Hermes.env_vars(
          Map.merge(@instance, %{
            id: 1000,
            telegram_mode: "webhook",
            telegram_webhook_secret: "abc"
          })
        )

      refute Enum.any?(Map.keys(env), &String.starts_with?(&1, "TELEGRAM_WEBHOOK_"))
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
      assert Hermes.env_vars(%{@instance | mention_only: true})["TELEGRAM_REQUIRE_MENTION"] ==
               "true"

      assert Hermes.env_vars(%{@instance | mention_only: false})["TELEGRAM_REQUIRE_MENTION"] ==
               "false"
    end

    test "TELEGRAM_MENTION_PATTERNS wraps trigger_name in a word-bounded regex" do
      env = Hermes.env_vars(Map.put(@instance, :trigger_name, "Вася"))
      assert env["TELEGRAM_MENTION_PATTERNS"] == Jason.encode!(["\\bВася\\b"])
    end

    test "TELEGRAM_MENTION_PATTERNS is empty when trigger_name is nil or blank" do
      assert Hermes.env_vars(Map.put(@instance, :trigger_name, nil))["TELEGRAM_MENTION_PATTERNS"] ==
               ""

      assert Hermes.env_vars(Map.put(@instance, :trigger_name, ""))["TELEGRAM_MENTION_PATTERNS"] ==
               ""
    end

    test "TELEGRAM_FREE_RESPONSE_CHATS is a comma-separated list from the JSON array field" do
      inst = Map.put(@instance, :allowed_telegram_chats, ~s(["-1002273542926","-12345"]))
      assert Hermes.env_vars(inst)["TELEGRAM_FREE_RESPONSE_CHATS"] == "-1002273542926,-12345"
    end

    test "TELEGRAM_ALLOW_ALL_USERS reflects the flag" do
      assert Hermes.env_vars(Map.put(@instance, :allow_all_telegram_users, true))[
               "TELEGRAM_ALLOW_ALL_USERS"
             ] == "true"

      assert Hermes.env_vars(Map.put(@instance, :allow_all_telegram_users, false))[
               "TELEGRAM_ALLOW_ALL_USERS"
             ] == "false"
    end

    test "does not duplicate keys from base_env/1" do
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
      assert config =~ "platforms:\n  telegram:"
      refute config =~ "messaging:"

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

  describe "vision model" do
    test "without image_model the bot's own model reads images" do
      yaml = Hermes.build_config_yaml(Map.merge(@instance, %{model: "ruoc-flash"}))
      refute yaml =~ "gemini-2.5-flash-lite"

      assert yaml =~
               "vision:\n    provider: custom\n    base_url: \"http://127.0.0.1:4000/v1\"\n    api_key: \"dk-alice-token\"\n    model: \"ruoc-flash\""
    end

    test "an explicit image_model wins" do
      yaml = Hermes.build_config_yaml(Map.merge(@instance, %{image_model: "ruoc-vision"}))
      assert yaml =~ ~s(model: "ruoc-vision")
    end
  end

  describe "compression reasoning" do
    @compression "  compression:\n    reasoning_effort: \"low\""

    test "the seed caps summary reasoning at low" do
      assert Hermes.build_config_yaml(@instance) =~ @compression
    end

    @tag :tmp_dir
    test "sync_config/2 writes it into an existing auxiliary block", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, "config.yaml"),
        "model: x\nauxiliary:\n  vision:\n    model: old\n"
      )

      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      yaml = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert yaml =~ @compression
      refute yaml =~ "model: old"
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

    test "switches the memory block to mnemosyne with the three tools, builtin flags still on", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"
      memory:
        provider: builtin
        memory_enabled: true
        user_profile_enabled: true
        memory_char_limit: 999
      """)

      inst = %{name: "b", model: "x", tenant_key: "k", memory_provider: "mnemosyne"}
      assert :ok = Hermes.sync_config(inst, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert content =~ ~r/^  provider: mnemosyne$/m
      assert content =~ ~r/^  memory_enabled: true$/m
      assert content =~ ~r/^  user_profile_enabled: true$/m

      assert content =~
               ~r/^  mnemosyne: \{tools: \[mnemosyne_remember, mnemosyne_recall, mnemosyne_forget\]\}$/m

      assert content =~ ~r/^  memory_char_limit: 999$/m

      assert YamlElixir.read_from_string!(content)["memory"]["mnemosyne"]["tools"] ==
               ~w(mnemosyne_remember mnemosyne_recall mnemosyne_forget)

      # Idempotent: a second sync leaves the memory block as it is (other
      # blocks have their own whitespace quirks, outside this test).
      memory_block = fn c -> Regex.run(~r/^memory:\n(?:[ \t]+\S[^\n]*\n)*/m, c) end
      assert :ok = Hermes.sync_config(inst, tmp_dir)

      assert memory_block.(File.read!(Path.join(tmp_dir, "config.yaml"))) ==
               memory_block.(content)
    end

    test "switching back to builtin drops the mnemosyne block hermes may have re-dumped as a mapping",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      memory:
        provider: mnemosyne
        memory_enabled: true
        user_profile_enabled: true
        mnemosyne:
          tools:
          - mnemosyne_remember
          - mnemosyne_recall
        memory_char_limit: 999
      """)

      assert :ok =
               Hermes.sync_config(
                 %{name: "b", model: "x", tenant_key: "k", memory_provider: "builtin"},
                 tmp_dir
               )

      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert content =~ ~r/^  provider: builtin$/m
      refute content =~ "mnemosyne"
      assert content =~ ~r/^  memory_char_limit: 999$/m
    end

    test "a re-dumped mnemosyne mapping is replaced, not doubled", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      memory:
        provider: mnemosyne
        mnemosyne:
          tools:
          - mnemosyne_remember
        memory_enabled: true
      """)

      assert :ok =
               Hermes.sync_config(
                 %{name: "b", model: "x", tenant_key: "k", memory_provider: "mnemosyne"},
                 tmp_dir
               )

      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert length(Regex.scan(~r/mnemosyne:/, content)) == 1

      assert YamlElixir.read_from_string!(content)["memory"]["mnemosyne"]["tools"] ==
               ~w(mnemosyne_remember mnemosyne_recall mnemosyne_forget)
    end

    test "a trailing mnemosyne mapping is dropped without eating the block's last newline", %{
      tmp_dir: tmp_dir
    } do
      # Hermes's own dumper puts unknown keys last, so this is the shape it
      # writes back; the next top-level key must survive both directions.
      dumped = """
      memory:
        provider: mnemosyne
        memory_enabled: true
        user_profile_enabled: true
        mnemosyne:
          tools:
          - mnemosyne_remember
      terminal:
        timeout: 30
      """

      for provider <- ["builtin", "mnemosyne"] do
        File.write!(Path.join(tmp_dir, "config.yaml"), dumped)

        assert :ok =
                 Hermes.sync_config(
                   %{name: "b", model: "x", tenant_key: "k", memory_provider: provider},
                   tmp_dir
                 )

        content = File.read!(Path.join(tmp_dir, "config.yaml"))

        assert %{"memory" => %{"provider" => ^provider}, "terminal" => %{"timeout" => 30}} =
                 YamlElixir.read_from_string!(content)
      end
    end

    test "a memory block at the end of the file stays one block across syncs", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"
      memory:
        provider: mnemosyne
        mnemosyne:
          tools:
          - mnemosyne_remember
      """)

      inst = %{name: "b", model: "x", tenant_key: "k", memory_provider: "mnemosyne"}
      assert :ok = Hermes.sync_config(inst, tmp_dir)
      assert :ok = Hermes.sync_config(inst, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert String.ends_with?(content, "\n")
      assert length(Regex.scan(~r/^  provider: mnemosyne$/m, content)) == 1
      assert YamlElixir.read_from_string!(content)["memory"]["provider"] == "mnemosyne"
    end

    test "AGENTS.md memory section is the builtin text", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")

      File.write!(
        Path.join([tmp_dir, "workspace", "AGENTS.md"]),
        "# Agent\n\n## Память\n\nhoncho stuff\n\n## Other\n"
      )

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
      File.write!(
        Path.join(tmp_dir, "config.yaml"),
        "gateway:\n  systemd_watchdog_seconds: 0\n  other: 1\n"
      )

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

  describe "sync_config/2 — telegram slash access + menu" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hermes-tg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    defp sync!(
           tmp_dir,
           yaml,
           instance \\ %{name: "b", model: "x", tenant_key: "k", operator_telegram_id: 4242}
         ) do
      File.write!(Path.join(tmp_dir, "config.yaml"), yaml)
      assert :ok = Hermes.sync_config(instance, tmp_dir)
      File.read!(Path.join(tmp_dir, "config.yaml"))
    end

    test "adds extra under the seeded telegram block: operator is admin, tenants get the user list",
         %{tmp_dir: tmp_dir} do
      content =
        sync!(tmp_dir, """
        model:
          default: "x"

        platforms:
          telegram:
            enabled: true
            observe_unmentioned_group_messages: false

        streaming:
          enabled: true
        """)

      assert content =~ """
             platforms:
               telegram:
                 extra:
                   allow_admin_from:
                     - "4242"
                   user_allowed_commands:
                     - start
                     - new
                     - compress
                     - status
                     - voice
                   group_allow_admin_from:
                     - "4242"
                   group_user_allowed_commands:
                     - start
                     - new
                     - compress
                     - status
                     - voice
                   command_menu:
                     priority_mode: replace
                     max_commands: 4
                     priority:
                       - new
                       - compress
                       - status
                       - voice
                   drop_pending_on_cold_boot: false
                 enabled: true
                 observe_unmentioned_group_messages: false

             streaming:
             """

      assert {:ok, %{"platforms" => %{"telegram" => %{"extra" => extra, "enabled" => true}}}} =
               YamlElixir.read_from_string(content)

      assert extra["allow_admin_from"] == ["4242"]

      assert extra["command_menu"] == %{
               "priority_mode" => "replace",
               "max_commands" => 4,
               "priority" => Hermes.menu_commands()
             }

      # Hermes's default drops every update sent while the bot was down.
      assert extra["drop_pending_on_cold_boot"] == false
    end

    test "rewrites its own keys and keeps what hermes wrote into extra", %{tmp_dir: tmp_dir} do
      content =
        sync!(tmp_dir, """
        platforms:
          telegram:
            enabled: true
            extra:
              dm_topics:
              - chat_id: 1
                topics:
                - name: x
                  thread_id: 7
              allow_admin_from:
              - '999'
              user_allowed_commands: [model, tools]
              command_menu: {max_commands: 60}
        """)

      assert {:ok, %{"platforms" => %{"telegram" => %{"extra" => extra}}}} =
               YamlElixir.read_from_string(content)

      assert extra["allow_admin_from"] == ["4242"]
      assert extra["user_allowed_commands"] == Hermes.user_commands()
      assert extra["command_menu"]["max_commands"] == 4

      assert extra["dm_topics"] == [
               %{"chat_id" => 1, "topics" => [%{"name" => "x", "thread_id" => 7}]}
             ]

      refute content =~ "999"
      refute content =~ "[model, tools]"
    end

    test "is idempotent", %{tmp_dir: tmp_dir} do
      once = sync!(tmp_dir, "platforms:\n  telegram:\n    enabled: true\n")
      twice = sync!(tmp_dir, once)
      assert YamlElixir.read_from_string!(once) == YamlElixir.read_from_string!(twice)
      assert length(Regex.scan(~r/^\s+allow_admin_from:/m, twice)) == 1
    end

    test "uses the sentinel id 0 when no operator is configured, so gating stays on", %{
      tmp_dir: tmp_dir
    } do
      content =
        sync!(tmp_dir, "platforms:\n  telegram:\n    enabled: true\n", %{
          name: "b",
          model: "x",
          tenant_key: "k"
        })

      assert {:ok, %{"platforms" => %{"telegram" => %{"extra" => extra}}}} =
               YamlElixir.read_from_string(content)

      assert extra["allow_admin_from"] == ["0"]
    end

    test "appends a platforms block when the file has none", %{tmp_dir: tmp_dir} do
      content = sync!(tmp_dir, "model:\n  default: \"x\"\n")

      assert {:ok,
              %{"platforms" => %{"telegram" => %{"extra" => %{"allow_admin_from" => ["4242"]}}}}} =
               YamlElixir.read_from_string(content)
    end
  end

  describe "sync_config/2 — cron + display notices" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "hermes-notices-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "adds cron.wrap_response: false and display.memory_notifications: off when absent", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)

      assert {:ok, cfg} =
               YamlElixir.read_from_string(File.read!(Path.join(tmp_dir, "config.yaml")))

      assert cfg["cron"] == %{"wrap_response" => false}
      assert cfg["display"]["memory_notifications"] == "off"
    end

    test "overrides the values inside existing blocks and keeps sibling keys", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      cron:
        wrap_response: true
        timezone: UTC
      display:
        tool_progress: all
        memory_notifications: verbose
      """)

      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)

      assert {:ok, cfg} =
               YamlElixir.read_from_string(File.read!(Path.join(tmp_dir, "config.yaml")))

      assert cfg["cron"] == %{"wrap_response" => false, "timezone" => "UTC"}
      assert cfg["display"] == %{"tool_progress" => "all", "memory_notifications" => "off"}
    end
  end

  describe "sync_config/2 — model facts" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hermes-facts-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    defp facts_sync(tmp_dir, yaml, facts) do
      if yaml, do: File.write!(Path.join(tmp_dir, "config.yaml"), yaml)
      instance = %{name: "b", model: "x", tenant_key: "k", model_facts: facts}
      assert :ok = Hermes.sync_config(instance, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      {:ok, cfg} = YamlElixir.read_from_string(content)
      {cfg, content}
    end

    test "a known model that reads images: its window, native photos, marked as seeing", %{
      tmp_dir: tmp_dir
    } do
      {cfg, _} =
        facts_sync(
          tmp_dir,
          "model:\n  default: \"x\"\n",
          {:ok, %{sees_images: true, context: 200_000}}
        )

      assert cfg["model"]["context_length"] == 200_000
      assert cfg["model"]["supports_vision"] == true
      assert cfg["model"]["default"] == "x"
      assert cfg["agent"]["image_input_mode"] == "native"
    end

    test "a known model without a window or vision: no window, auto photos, other agent keys kept",
         %{tmp_dir: tmp_dir} do
      yaml =
        "model:\n  default: \"x\"\n  context_length: 1000\n  supports_vision: true\nagent:\n  image_input_mode: native\n  gateway_timeout: 1800\n"

      {cfg, _} = facts_sync(tmp_dir, yaml, {:ok, %{sees_images: false, context: nil}})
      refute Map.has_key?(cfg["model"], "context_length")
      assert cfg["model"]["supports_vision"] == false
      assert cfg["agent"]["image_input_mode"] == "auto"
      assert cfg["agent"]["gateway_timeout"] == 1800
    end

    test "a model ruoc does not list loses the previous model's numbers", %{tmp_dir: tmp_dir} do
      yaml =
        "model:\n  default: \"x\"\n  context_length: 200000\n  supports_vision: true\nagent:\n  image_input_mode: native\n"

      {cfg, _} = facts_sync(tmp_dir, yaml, :unknown_model)
      refute Map.has_key?(cfg["model"], "context_length")
      refute Map.has_key?(cfg["model"], "supports_vision")
      assert cfg["agent"]["image_input_mode"] == "auto"
    end

    test "an empty catalogue leaves the model facts alone", %{tmp_dir: tmp_dir} do
      yaml =
        "model:\n  default: \"x\"\n  context_length: 200000\nagent:\n  image_input_mode: native\n"

      {cfg, _} = facts_sync(tmp_dir, yaml, :no_catalogue)
      assert cfg["model"]["context_length"] == 200_000
      assert cfg["agent"]["image_input_mode"] == "native"
    end

    test "a changed window between two syncs leaves no old line", %{tmp_dir: tmp_dir} do
      facts_sync(
        tmp_dir,
        "model:\n  default: \"x\"\n",
        {:ok, %{sees_images: true, context: 200_000}}
      )

      {cfg, content} = facts_sync(tmp_dir, nil, {:ok, %{sees_images: true, context: 131_072}})
      assert cfg["model"]["context_length"] == 131_072
      assert length(String.split(content, "context_length")) == 2
    end
  end

  describe "sync_config/2 — toolsets, skills, turn budget, terminal, dead keys" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "hermes-tuning-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    defp tune(tmp_dir, yaml) do
      if yaml, do: File.write!(Path.join(tmp_dir, "config.yaml"), yaml)
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      {:ok, cfg} = YamlElixir.read_from_string(content)
      {cfg, content}
    end

    defp manifest!(tmp_dir, names) do
      File.mkdir_p!(Path.join(tmp_dir, "skills"))

      File.write!(
        Path.join([tmp_dir, "skills", ".bundled_manifest"]),
        Enum.map_join(names, "\n", &"#{&1}:abc123") <> "\n"
      )
    end

    test "writes the turn budget and the disabled toolsets, replacing an older block list", %{
      tmp_dir: tmp_dir
    } do
      yaml =
        "model:\n  default: \"x\"\nagent:\n  disabled_toolsets:\n  - kanban\n  - browser\n  - delegation\n  gateway_timeout: 1800\n"

      {cfg, content} = tune(tmp_dir, yaml)
      assert cfg["agent"]["disabled_toolsets"] == ["browser", "computer_use", "connections"]
      assert cfg["agent"]["max_turns"] == 30
      assert cfg["agent"]["budget_warning_ratio"] == 0.75
      assert cfg["agent"]["run_budget_seconds"] == 300
      assert cfg["agent"]["gateway_timeout"] == 1800
      refute content =~ "kanban"
      refute content =~ "delegation"
    end

    test "disables only listed skills hermes bundled, never the bot's own", %{tmp_dir: tmp_dir} do
      manifest!(tmp_dir, ["claude-code", "notion", "obsidian", "codebase-inspection", "xlsx"])
      File.mkdir_p!(Path.join([tmp_dir, "skills", "my-own", "github"]))
      {cfg, _} = tune(tmp_dir, "model:\n  default: \"x\"\n")
      assert cfg["skills"]["disabled"] == ["claude-code", "notion"]
    end

    test "a skills dir without a manifest disables nothing, and an old list goes", %{
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join([tmp_dir, "skills", "my-own"]))

      {cfg, _} =
        tune(
          tmp_dir,
          "model:\n  default: \"x\"\nskills:\n  disabled: [codex]\n  external_dirs: [/x]\n"
        )

      assert cfg["skills"] == %{"external_dirs" => ["/x"]}
    end

    # Hermes copies its bundled skills in at gateway start, after this sync:
    # a fresh bot has no skills/ dir yet and no skill of its own either.
    test "a fresh bot with no skills dir gets the whole list", %{tmp_dir: tmp_dir} do
      {cfg, _} = tune(tmp_dir, "model:\n  default: \"x\"\n")
      assert "claude-code" in cfg["skills"]["disabled"]
      assert "google-workspace" in cfg["skills"]["disabled"]
      refute "codebase-inspection" in cfg["skills"]["disabled"]
    end

    test "an empty flow-mapping section becomes a block; a filled one is left alone", %{
      tmp_dir: tmp_dir
    } do
      {cfg, content} = tune(tmp_dir, "model:\n  default: \"x\"\nterminal: {}\n")
      assert cfg["terminal"] == %{"cwd" => Path.join(tmp_dir, "workspace")}
      assert length(String.split(content, "\nterminal:")) == 2

      {cfg, content} = tune(tmp_dir, "model:\n  default: \"x\"\nterminal: {backend: local}\n")
      assert cfg["terminal"] == %{"backend" => "local"}
      assert length(String.split(content, "\nterminal:")) == 2
    end

    test "a symlinked manifest is not read", %{tmp_dir: tmp_dir} do
      outside = Path.join(System.tmp_dir!(), "manifest-#{System.unique_integer([:positive])}")
      File.write!(outside, "claude-code:abc\n")
      on_exit(fn -> File.rm(outside) end)
      File.mkdir_p!(Path.join(tmp_dir, "skills"))
      File.ln_s!(outside, Path.join([tmp_dir, "skills", ".bundled_manifest"]))
      {cfg, _} = tune(tmp_dir, "model:\n  default: \"x\"\n")
      refute Map.has_key?(cfg, "skills")
    end

    test "sets terminal.cwd to the workspace and drops the dead messaging block", %{
      tmp_dir: tmp_dir
    } do
      yaml =
        "model:\n  default: \"x\"\nmessaging:\n  enabled_platforms:\n    telegram: [hermes-telegram]\nstreaming:\n  enabled: true\n"

      {cfg, _} = tune(tmp_dir, yaml)
      assert cfg["terminal"]["cwd"] == Path.join(tmp_dir, "workspace")
      refute Map.has_key?(cfg, "messaging")
      assert cfg["streaming"]["enabled"] == true
    end

    test "a header with a trailing comment is found, not duplicated", %{tmp_dir: tmp_dir} do
      {cfg, content} =
        tune(
          tmp_dir,
          "model: # the model\n  default: \"x\"\nterminal:   # shell\n  backend: local\n"
        )

      assert length(String.split(content, "\nterminal:")) == 2
      assert cfg["terminal"] == %{"backend" => "local", "cwd" => Path.join(tmp_dir, "workspace")}
      assert content =~ "model: # the model"
    end

    test "a comment between list items does not split an owned key", %{tmp_dir: tmp_dir} do
      yaml =
        "model:\n  default: \"x\"\nagent:\n  disabled_toolsets:\n  - browser\n  # why\n  - kanban\n  gateway_timeout: 1800\n"

      {cfg, content} = tune(tmp_dir, yaml)
      assert cfg["agent"]["disabled_toolsets"] == ["browser", "computer_use", "connections"]
      assert cfg["agent"]["gateway_timeout"] == 1800
      refute content =~ "kanban"
    end

    test "a second sync changes nothing", %{tmp_dir: tmp_dir} do
      manifest!(tmp_dir, ["codex", "notion"])

      {_, first} =
        tune(
          tmp_dir,
          "model:\n  default: \"x\"\nauxiliary:\n  title_generation:\n    enabled: false\n"
        )

      {_, second} = tune(tmp_dir, nil)
      assert first == second
    end

    test "strip_tuning_keys/1 removes what this change writes and keeps the photo keys", %{
      tmp_dir: tmp_dir
    } do
      manifest!(tmp_dir, ["codex"])

      File.write!(
        Path.join(tmp_dir, "config.yaml"),
        "model:\n  default: \"x\"\nagent:\n  gateway_timeout: 1800\n"
      )

      facts = {:ok, %{sees_images: true, context: 200_000}}

      :ok =
        Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k", model_facts: facts}, tmp_dir)

      {:ok, cfg} =
        tmp_dir
        |> Path.join("config.yaml")
        |> File.read!()
        |> Hermes.strip_tuning_keys()
        |> YamlElixir.read_from_string()

      refute Map.has_key?(cfg["model"], "context_length")
      assert cfg["model"]["supports_vision"] == true
      assert cfg["agent"] == %{"image_input_mode" => "native", "gateway_timeout" => 1800}
      refute Map.has_key?(cfg, "skills")
      refute Map.has_key?(cfg, "terminal")
    end
  end

  describe "sync_config/2 — auxiliary merge" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hermes-aux-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "rewrites only vision and compression; other aux tasks and keys stay", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"
      auxiliary:
        title_generation:
          model: "cheap-title"
          enabled: false
        vision:
          provider: auto
          model: "old"
          timeout: 30
        background_review:
          enabled: true
          extra_tools: [a]
        compression:
          reasoning_effort: "high"
          timeout: 90
      """)

      assert :ok =
               Hermes.sync_config(
                 %{name: "b", model: "x", tenant_key: "k", image_model: "seer"},
                 tmp_dir
               )

      {:ok, cfg} = YamlElixir.read_from_string(File.read!(Path.join(tmp_dir, "config.yaml")))
      aux = cfg["auxiliary"]
      assert aux["title_generation"] == %{"model" => "cheap-title", "enabled" => false}
      assert aux["background_review"] == %{"enabled" => true, "extra_tools" => ["a"]}

      assert aux["vision"] == %{
               "provider" => "custom",
               "base_url" => Hermes.proxy_url(),
               "api_key" => "k",
               "model" => "seer",
               "timeout" => 30
             }

      assert aux["compression"] == %{"reasoning_effort" => "low", "timeout" => 90}
    end
  end

  describe "sync_config/2 — symlinks" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hermes-links-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}.yaml")

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
        File.rm(outside)
      end)

      %{tmp_dir: tmp_dir, outside: outside}
    end

    test "a symlinked config.yaml is neither read nor written", %{
      tmp_dir: tmp_dir,
      outside: outside
    } do
      File.write!(outside, "model:\n  default: \"secret\"\n")
      File.ln_s!(outside, Path.join(tmp_dir, "config.yaml"))
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      assert File.read!(outside) == "model:\n  default: \"secret\"\n"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(tmp_dir, "config.yaml"))
    end
  end

  describe "sync_config/2 — stt silence trim" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hermes-stt-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "turns cloud_trim_silence off inside an existing stt block and keeps the provider", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      stt:
        enabled: true
        provider: openai
        openai:
          model: whisper-1
      tts:
        enabled: true
      """)

      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)

      assert {:ok, cfg} =
               YamlElixir.read_from_string(File.read!(Path.join(tmp_dir, "config.yaml")))

      assert cfg["stt"] == %{
               "enabled" => true,
               "provider" => "openai",
               "openai" => %{"model" => "whisper-1"},
               "cloud_trim_silence" => false
             }

      assert cfg["tts"] == %{"enabled" => true}
    end

    test "adds the stt block when absent and the seed template carries the key", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)

      assert {:ok, cfg} =
               YamlElixir.read_from_string(File.read!(Path.join(tmp_dir, "config.yaml")))

      assert cfg["stt"]["cloud_trim_silence"] == false
      assert {:ok, seed} = YamlElixir.read_from_string(Hermes.build_config_yaml(@instance))
      assert seed["stt"]["cloud_trim_silence"] == false
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
