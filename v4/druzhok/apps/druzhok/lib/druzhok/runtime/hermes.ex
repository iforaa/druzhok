defmodule Druzhok.Runtime.Hermes do
  @moduledoc """
  Runtime adapter for the Hermes agent (v4/hermes-agent).

  One container per bot. `HERMES_HOME=/opt/data` points at the tenant's data
  root on the host. All LLM traffic goes through druzhok's Elixir proxy via
  `OPENAI_BASE_URL` + `OPENAI_API_KEY`; hermes flips its inference provider
  to `"custom"` automatically when `OPENAI_BASE_URL` is set
  (see hermes_cli/main.py:915).

  The allowlist is env-var driven: druzhok writes `TELEGRAM_ALLOWED_USERS`
  at each container start from `instance.owner_telegram_id +
  instance.allowed_telegram_ids`. Hermes's own pairing store under
  `/opt/data/platforms/pairing/telegram-approved.json` is left for the bot
  to manage — we read it for the dashboard but don't write to it.
  """

  @behaviour Druzhok.Runtime

  require Logger
  alias Druzhok.{BotManager, Instance}

  @data_mount "/opt/data"
  @default_model "anthropic/claude-opus-4.6"
  @default_vision_model "google/gemini-2.5-flash-lite"

  @agents_md_session_section """
  ## Каждая сессия

  _Эта секция перезаписывается druzhok при каждом старте бота. Не правь руками._

  Перед любыми действиями:
  1. SOUL.md уже загружен в системный промпт — не читай заново
  2. Память пользователя уже подгружена в контекст — не лезь в файлы без нужды
  3. Читай файлы только если нужно обновить

  Не спрашивай разрешения. Просто делай.
  """

  @agents_md_style_section """
  ## Стиль

  _Эта секция перезаписывается druzhok при каждом старте бота. Не правь руками._

  - Простой вопрос → простой ответ. Один точный поиск лучше десяти.
  - Глубже только когда человек явно просит или цена ошибки реально высокая.
  - Получил достойный ответ — отвечай и останавливайся, не перепроверяй сам себя.
  - Один и тот же запрос дважды — никогда. Не нашёл — меняй стратегию или скажи "не знаю".
  - Человек добавил фото или контекст — отвечай на исходный вопрос, а не на новый.
  - Инструмент не сработал → не повторяй. Максимум 2 попытки, потом другой подход.
  - Кратко когда нужно, подробно когда важно.
  """

  @agents_md_sites_section """
  ## Публикация сайтов

  Если пользователь просит сделать лендинг, сайт, демо-страницу и т.п.:

  1. Проверь переменную окружения `BOT_SITE_BASE_URL`. Если пусто — хостинг не включён; сообщи пользователю и не пиши файлы.
  2. Выбери короткое имя сайта (`^[a-z0-9][a-z0-9-]*$`, до 50 символов).
  3. Запиши все файлы в `/opt/data/workspace/sites/<имя>/`. Входная точка — `index.html`. Всего до ~50 MB на сайт, до ~100 файлов.
  4. Ответь пользователю одной кликабельной ссылкой: `$BOT_SITE_BASE_URL/<имя>/`.
  5. Удалить сайт: `rm -rf /opt/data/workspace/sites/<имя>/`.

  Файлы в `sites/<имя>/` публичны. Не клади туда секреты, токены, файлы, начинающиеся с точки.
  """

  @impl true
  def docker_image, do: System.get_env("HERMES_IMAGE") || "hermes:latest"

  @impl true
  def gateway_command, do: ["gateway", "run"]

  @impl true
  def data_mount_path, do: @data_mount

  @impl true
  def file_browser_root(instance) do
    # Hermes writes at the mount root (cron/, sessions/, memories/, workspace/, ...).
    # Show the whole /opt/data equivalent to the operator, not just workspace/.
    case Map.get(instance, :workspace) do
      nil -> ""
      ws -> Path.dirname(ws)
    end
  end

  @impl true
  def env_vars(instance) do
    # base_env/1 already provides OPENAI_BASE_URL, OPENAI_API_KEY, TZ —
    # only add hermes-specific keys here.
    #
    # HOME points at a writable directory on the mounted data root. Without
    # it, hermes running as --user 1000:1000 hits `Path.home() == /` and
    # fails to mkdir `/.local` on boot (no /etc/passwd entry for uid 1000).
    # The hermes entrypoint creates `$HERMES_HOME/home` for exactly this
    # purpose — per-profile HOME for subprocesses (git, ssh, npm, …).
    #
    # STT_OPENAI_BASE_URL routes voice transcription through the druzhok
    # proxy's /v1/audio/transcriptions endpoint instead of api.openai.com.
    # The provider choice (openai vs local/faster-whisper) lives in
    # config.yaml's `stt:` section — see build_config_yaml/1.
    tenant_key = Map.get(instance, :tenant_key, "") || ""
    model = Map.get(instance, :model) || @default_model
    proxy_url = proxy_url()

    %{
      "HERMES_HOME" => @data_mount,
      "HERMES_QUIET" => "0",
      # Set MESSAGING_CWD so hermes's prompt_builder loads AGENTS.md
      # from the workspace, not from /root or /opt/hermes.
      "MESSAGING_CWD" => @data_mount <> "/workspace",
      "TELEGRAM_BOT_TOKEN" => Map.get(instance, :telegram_token, "") || "",
      "TELEGRAM_ALLOWED_USERS" => build_allowlist(instance),
      "TELEGRAM_ALLOW_ALL_USERS" => to_string(Map.get(instance, :allow_all_telegram_users, false)),
      # Group chat trigger gating. `require_mention` forces groups to need
      # an @mention / regex trigger / reply-to-bot. `mention_patterns` is
      # a JSON list of regexes hermes compiles with re.IGNORECASE.
      # `free_response_chats` are chat IDs where the bot always responds
      # even with require_mention on.
      # Auto-set home channel to the owner's DM so hermes doesn't nag
      # on first message. In Telegram, DM chat_id == user_id.
      "TELEGRAM_HOME_CHANNEL" => to_string(Map.get(instance, :owner_telegram_id, "") || ""),
      # Hermes native i18n (since 2026-05, commit c39168453). Catalogs
      # at locales/<lang>.yaml. Russian is supported.
      "HERMES_LANGUAGE" => Map.get(instance, :language, "ru") || "ru",
      # Native silent observer for shared-memory group bots (since 2026-05,
      # commits a9db0e2c7 + 4a91e3649). Env var takes priority over
      # platforms.telegram.observe_unmentioned_group_messages in config.yaml,
      # so this works for both fresh and existing data roots.
      "TELEGRAM_OBSERVE_UNMENTIONED_GROUP_MESSAGES" =>
        to_string(Map.get(instance, :group_shared_memory, false)),
      "TELEGRAM_REQUIRE_MENTION" => to_string(Map.get(instance, :mention_only, false)),
      "TELEGRAM_MENTION_PATTERNS" => build_mention_patterns(instance),
      "TELEGRAM_FREE_RESPONSE_CHATS" => build_free_response_chats(instance),
      # Druzhok website hosting: when enabled, the bot knows its public
      # base URL; otherwise this is empty and the agent refuses to
      # publish (see workspace/AGENTS.md "Публикация сайтов").
      "BOT_SITE_BASE_URL" => build_bot_site_base_url(instance),
      "HERMES_INFERENCE_PROVIDER" => "custom",
      "OPENROUTER_API_KEY" => tenant_key,
      "HERMES_MODEL" => model,
      "STT_OPENAI_BASE_URL" => proxy_url,
      # Web search: firecrawl backend → druzhok /v2/search → perplexity/sonar
      "FIRECRAWL_API_URL" => proxy_url |> String.replace_suffix("/v1", ""),
      "FIRECRAWL_API_KEY" => tenant_key,
      # Hermes now uses gosu for UID remapping (Dockerfile creates user
      # hermes with UID 10000). Pass HERMES_UID/GID so the entrypoint
      # remaps to the host user before dropping root.
      "HERMES_UID" => BotManager.host_uid() || "1000",
      "HERMES_GID" => BotManager.host_gid() || "1000"
    }
  end

  @impl true
  def workspace_files(instance) do
    # :create_only — write on fresh data root only. Hermes persists runtime
    # state (telegram thread IDs, etc.) back into config.yaml at runtime, so
    # we must never overwrite it on restart. sync_config/2 (below) handles
    # targeted updates on every start.
    [{"config.yaml", build_config_yaml(instance), :create_only}]
  end

  @impl true
  def sync_config(instance, data_root) do
    sync_agents_md(instance, data_root)
    sync_honcho_config(instance, data_root)

    # Patch dashboard-owned fields in config.yaml on every start so the
    # dashboard stays the source of truth without clobbering hermes's
    # runtime writes (thread IDs etc).
    config_path = Path.join(data_root, "config.yaml")
    model = Map.get(instance, :model) || @default_model
    vision_model = Map.get(instance, :image_model) || @default_vision_model
    tenant_key = Map.get(instance, :tenant_key, "") || ""

    case File.read(config_path) do
      {:ok, content} ->
        updated =
          content
          |> sync_model_default(model)
          |> sync_auxiliary_vision(vision_model, tenant_key)
          |> sync_group_sessions_per_user(instance)
          |> sync_memory_block(instance)
          |> sync_image_gen_block(instance)
          |> sync_quick_commands()

        if updated != content, do: File.write!(config_path, updated)
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp sync_model_default(content, model) do
    Regex.replace(
      ~r/^(\s*default:\s*).*$/m,
      content,
      ~s(\\1"#{model}"),
      global: false
    )
  end

  # Since hermes 2026-04 (commit 976bad5b), config.yaml takes priority
  # over env vars for auxiliary task settings. Write the vision config
  # block so hermes routes vision calls through the druzhok proxy.
  defp sync_auxiliary_vision(content, vision_model, tenant_key) do
    vision_block = """

    auxiliary:
      vision:
        provider: custom
        base_url: "#{proxy_url()}"
        api_key: "#{tenant_key}"
        model: "#{vision_model}"
    """
    |> String.trim_trailing()

    if String.contains?(content, "auxiliary:") do
      # Replace existing auxiliary block
      Regex.replace(
        ~r/^auxiliary:.*?(?=^\S|\z)/ms,
        content,
        String.trim_leading(vision_block) <> "\n"
      )
    else
      content <> "\n" <> vision_block <> "\n"
    end
  end

  defp sync_group_sessions_per_user(content, instance) do
    # User-facing toggle is `group_shared_memory`. Hermes's native config
    # uses the inverse — `group_sessions_per_user: false` means group
    # participants share one session (memory).
    shared = Map.get(instance, :group_shared_memory, false)
    upsert_yaml_line(content, "group_sessions_per_user", not shared)
  end


  defp upsert_yaml_line(content, key, value) do
    line = "#{key}: #{value}"
    pattern = ~r/^#{Regex.escape(key)}:.*$/m

    if Regex.match?(pattern, content) do
      Regex.replace(pattern, content, line)
    else
      String.trim_trailing(content) <> "\n\n" <> line <> "\n"
    end
  end

  @honcho_filename "honcho.json"
  # TODO: derive from `instance.owner_telegram_id` (or a future per-instance
  # `peer_name` field) once druzhok supports multiple operators. Hardcoded
  # for the single-operator deployment.
  @default_peer_name "igor"

  defp sync_honcho_config(instance, data_root) do
    case Map.get(instance, :memory_provider, "builtin") do
      "honcho" ->
        workspace = honcho_workspace(instance)
        token = ensure_honcho_token!(instance, workspace)
        json = Jason.encode!(honcho_config(instance.name, workspace, token), pretty: true)
        File.write!(Path.join(data_root, @honcho_filename), json)

      _ ->
        _ = File.rm(Path.join(data_root, @honcho_filename))
        :ok
    end
  end

  # The hermes honcho plugin special-cases 127.0.0.1 baseUrls: it ignores
  # the root-level apiKey and substitutes "local" UNLESS apiKey is inside a
  # hosts.<host> block (signals "user explicitly wants auth on local").
  # We nest under "hosts.hermes" because the default hermes profile resolves
  # to that host key.
  defp honcho_config(ai_peer, workspace, token) do
    %{
      "baseUrl" => "http://127.0.0.1:8000",
      "workspace" => workspace,
      "peerName" => @default_peer_name,
      # 1200 = doc-recommended cap on auto-injected memory block.
      "contextTokens" => 1200,
      "hosts" => %{
        "hermes" => %{
          "apiKey" => token,
          "aiPeer" => ai_peer,
          "recallMode" => "hybrid",
          "writeFrequency" => "async",
          "contextCadence" => 3,
          "dialecticCadence" => 5,
          # depth=1 returns thin output on cold peers (per docs).
          "dialecticDepth" => 2,
          "dialecticReasoningLevel" => "low"
        }
      }
    }
  end

  defp honcho_workspace(instance) do
    case Map.get(instance, :honcho_workspace) do
      blank when blank in [nil, ""] -> instance.name
      ws -> ws
    end
  end

  defp ensure_honcho_token!(instance, workspace) do
    case Map.get(instance, :honcho_token) do
      blank when blank in [nil, ""] ->
        {:ok, token} = Druzhok.HonchoJwt.mint_workspace_token(workspace)

        instance
        |> Instance.changeset(%{honcho_token: token})
        |> Druzhok.Repo.update!()

        token

      token ->
        token
    end
  end

  # Druzhok manages three sub-keys of `memory:` based on memory_provider:
  # provider, memory_enabled, user_profile_enabled. When provider == "honcho",
  # we explicitly disable the legacy MEMORY.md/USER.md path (and the `memory`
  # tool that depends on it) so the bot can only write through Honcho.
  # Char-limit fields are left alone so user edits survive.
  defp sync_memory_block(content, instance) do
    provider = Map.get(instance, :memory_provider, "builtin")
    legacy_enabled? = provider == "builtin"

    sync_yaml_block(content, "memory",
      upsert: fn body ->
        body
        |> upsert_indented_line("provider", provider)
        |> upsert_indented_line("memory_enabled", to_string(legacy_enabled?))
        |> upsert_indented_line("user_profile_enabled", to_string(legacy_enabled?))
      end,
      default: default_memory_block(provider, legacy_enabled?)
    )
  end

  # When image_gen is enabled, point hermes at the OpenAI plugin (which the
  # `openai>=2.x` SDK auto-routes through `OPENAI_BASE_URL` → druzhok proxy).
  # When disabled, blank the provider so hermes falls back to its built-in
  # FAL path (which short-circuits without `FAL_KEY` and just returns an
  # error to the agent).
  defp sync_image_gen_block(content, instance) do
    enabled? = Map.get(instance, :image_gen_enabled, false) == true
    provider = if enabled?, do: "openai", else: ""

    sync_yaml_block(content, "image_gen",
      upsert: &upsert_indented_line(&1, "provider", provider),
      default: if(enabled?, do: "image_gen:\n  provider: #{provider}", else: nil)
    )
  end

  # Splice an indented YAML block (`<name>:` + indented children) through
  # `upsert`. If the block is missing and `default` is non-nil, append it;
  # otherwise leave content untouched. Splices via offsets so `upsert`
  # returning the same body as input is a guaranteed no-op (and so the
  # `if updated != content` write-guard in sync_config/2 does the right
  # thing on every restart).
  defp sync_yaml_block(content, name, opts) do
    upsert = Keyword.fetch!(opts, :upsert)
    default = Keyword.get(opts, :default)
    block_pattern = ~r/(?m)^(#{Regex.escape(name)}:[ \t]*\n)((?:[ \t]+\S[^\n]*\n)*)/

    case Regex.run(block_pattern, content, return: :index) do
      [_, _header, {body_off, body_len}] when body_len > 0 ->
        body = binary_part(content, body_off, body_len)
        prefix = binary_part(content, 0, body_off)
        suffix_off = body_off + body_len
        suffix = binary_part(content, suffix_off, byte_size(content) - suffix_off)
        prefix <> upsert.(body) <> suffix

      _ when is_binary(default) ->
        String.trim_trailing(content) <> "\n\n" <> default <> "\n"

      _ ->
        content
    end
  end

  defp upsert_indented_line(body, key, value) do
    pattern = ~r/(?m)^([ \t]+)#{Regex.escape(key)}:[^\n]*$/

    if Regex.match?(pattern, body) do
      Regex.replace(pattern, body, "\\1#{key}: #{value}", global: false)
    else
      "  #{key}: #{value}\n" <> body
    end
  end

  defp default_memory_block(provider, legacy_enabled?) do
    """
    memory:
      provider: #{provider}
      memory_enabled: #{legacy_enabled?}
      user_profile_enabled: #{legacy_enabled?}
      memory_char_limit: 2200
      user_char_limit: 1375\
    """
  end

  # /start alias to /new so Telegram's first-interaction command doesn't
  # show "Unknown command".
  defp sync_quick_commands(content) do
    if content =~ ~r/^\s*quick_commands:/m do
      content
    else
      block = "quick_commands:\n  start:\n    type: alias\n    target: new"
      String.trim_trailing(content) <> "\n\n" <> block <> "\n"
    end
  end

  def sync_agents_md(instance, data_root) do
    agents_path = Path.join([data_root, "workspace", "AGENTS.md"])

    case File.read(agents_path) do
      {:ok, content} ->
        updated =
          content
          |> sync_session_section()
          |> sync_memory_section(instance)
          |> sync_style_section()
          |> ensure_sites_section()

        if updated != content, do: File.write!(agents_path, updated)
        :ok

      {:error, _} ->
        :ok
    end
  end

  # Replace the entire `## Память` section (header + body + trailing
  # newlines, up to the next `## ` or EOF) with the content matching the
  # bot's memory_provider. Druzhok owns this section because it's tightly
  # coupled to which memory tools the bot has.
  defp sync_memory_section(content, instance) do
    provider = Map.get(instance, :memory_provider, "builtin")
    new_section = memory_section(provider)
    # Eat trailing newlines so we can re-emit a stable `\n\n` separator —
    # makes the rewrite idempotent regardless of original blank-line count.
    pattern = ~r/(?ms)^## Память[ \t]*\n.*?\n+(?=^## |\z)/

    if Regex.match?(pattern, content) do
      Regex.replace(pattern, content, new_section <> "\n\n", global: false)
    else
      String.trim_trailing(content) <> "\n\n" <> new_section <> "\n"
    end
  end

  # Replace the entire `## Каждая сессия` section. Druzhok owns it because
  # the original wording lied that IDENTITY.md and USER.md were auto-loaded
  # into the system prompt — hermes only loads SOUL.md and memories/*.md;
  # workspace/IDENTITY.md and workspace/USER.md are never injected. Bots
  # acted on the lie by trying to read those files, finding empty templates,
  # and triggering investigation loops on cold start.
  defp sync_session_section(content) do
    body = String.trim_trailing(@agents_md_session_section)
    pattern = ~r/(?ms)^## Каждая сессия[ \t]*\n.*?\n+(?=^## |\z)/

    if Regex.match?(pattern, content) do
      Regex.replace(pattern, content, body <> "\n\n", global: false)
    else
      String.trim_trailing(content) <> "\n\n" <> body <> "\n"
    end
  end

  # Replace the entire `## Стиль` section. Druzhok owns it because we tune
  # research-depth / loop-prevention guidance from observed bot pathology
  # (sequential web_search storms, verification compulsion, query-truncation
  # loops) and want every restart to pick up the latest wording.
  defp sync_style_section(content) do
    body = String.trim_trailing(@agents_md_style_section)
    pattern = ~r/(?ms)^## Стиль[ \t]*\n.*?\n+(?=^## |\z)/

    if Regex.match?(pattern, content) do
      Regex.replace(pattern, content, body <> "\n\n", global: false)
    else
      String.trim_trailing(content) <> "\n\n" <> body <> "\n"
    end
  end

  defp ensure_sites_section(content) do
    if String.contains?(content, "## Публикация сайтов") do
      content
    else
      String.trim_trailing(content) <> "\n\n" <> @agents_md_sites_section
    end
  end

  defp memory_section("honcho") do
    """
    ## Память

    Ты используешь Honcho — внешнюю систему памяти с автоматическим извлечением фактов, поиском и синтезом.

    **Чтобы вспомнить факты о пользователе:**
    - `honcho_search` — семантический поиск по наблюдениям
    - `honcho_profile` — быстрая сводка ключевых фактов
    - `honcho_reasoning` — синтез ответа на вопрос о пользователе

    **Чтобы записать новый факт или исправить старый:** `honcho_conclude`. Просто опиши факт обычным текстом — Honcho сам разберётся как сохранить и связать с прошлыми наблюдениями.

    **НЕ используй** инструмент `memory` (MEMORY.md) — он отключён в этом боте. Все долгосрочные записи идут через Honcho.

    Файлы `memory/YYYY-MM-DD.md` — для рабочих заметок текущей сессии (логи, черновики). Долгосрочная память — только в Honcho.

    Память подгружается автоматически в начале каждого хода. Если нужно проверить что ты знаешь — спроси `honcho_profile` или `honcho_search`, не лезь в файлы.

    """
    |> String.trim_trailing()
  end

  defp memory_section(_other) do
    """
    ## Память

    Ты просыпаешься с чистого листа каждую сессию. Файлы — твоя преемственность:

    - **Ежедневные заметки:** `memory/YYYY-MM-DD.md` — сырой лог событий (через memory tools)
    - **Долгосрочная:** `MEMORY.md` — отобранные воспоминания (загружается автоматически)

    ### Записывай — никаких мысленных заметок!

    - Память ограничена — хочешь запомнить → **запиши в файл**
    - "Запомни это" → обнови ежедневный файл или MEMORY.md
    - Выучил урок → обнови AGENTS.md или TOOLS.md

    """
    |> String.trim_trailing()
  end

  @impl true
  def post_start(_instance), do: :ok

  @impl true
  def parse_log_rejection(_line), do: :ignore

  @impl true
  def clear_sessions(data_root) do
    data_root
    |> Path.join("sessions")
    |> File.rm_rf!()

    :ok
  end

  @impl true
  def read_allowed_users(data_root) do
    path = Path.join([data_root, "platforms", "pairing", "telegram-approved.json"])

    with {:ok, body} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      Map.keys(map)
    else
      _ -> []
    end
  end

  @impl true
  def add_allowed_user(_data_root, _user_id), do: :ok

  @impl true
  def remove_allowed_user(_data_root, _user_id), do: :ok

  @impl true
  def supports_feature?(:db_allowlist), do: true
  def supports_feature?(:pairing_code_approval), do: true
  def supports_feature?(:group_chat_config), do: true
  def supports_feature?(:website_hosting), do: true
  # Hermes manages these via its own config.yaml, not through druzhok env vars.
  # Hide the dashboard dropdowns to avoid confusion.
  def supports_feature?(:on_demand_model), do: false
  def supports_feature?(:audio_model), do: false
  def supports_feature?(:embedding_model), do: false
  def supports_feature?(_), do: false

  # --- Helpers ---

  defp build_allowlist(instance) do
    owner =
      case Map.get(instance, :owner_telegram_id) do
        nil -> []
        "" -> []
        id -> [to_string(id)]
      end

    extra = Instance.get_allowed_ids(instance)

    (owner ++ extra)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(",")
  end

  defp build_mention_patterns(instance) do
    case Map.get(instance, :trigger_name) do
      nil ->
        ""

      "" ->
        ""

      name ->
        # One regex per name; word-boundary + case-insensitive (the re.IGNORECASE
        # flag is applied by hermes when it compiles the pattern list).
        Jason.encode!(["\\b#{Regex.escape(name)}\\b"])
    end
  end

  defp build_bot_site_base_url(instance) do
    if Map.get(instance, :website_hosting_enabled, false) do
      "https://#{instance.name}.oldey.dev"
    else
      ""
    end
  end

  defp build_free_response_chats(instance) do
    case Map.get(instance, :allowed_telegram_chats) do
      nil ->
        ""

      "" ->
        ""

      json ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) ->
            list
            |> Enum.map(&to_string/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join(",")

          _ ->
            ""
        end
    end
  end

  def build_config_yaml(instance) do
    model = Map.get(instance, :model) || @default_model
    vision_model = Map.get(instance, :image_model) || @default_vision_model
    tenant_key = Map.get(instance, :tenant_key, "") || ""
    url = proxy_url()
    group_sessions_per_user = not Map.get(instance, :group_shared_memory, false)
    observe_unmentioned = Map.get(instance, :group_shared_memory, false)
    memory_provider = Map.get(instance, :memory_provider, "builtin")

    """
    # Generated by druzhok on first boot. Feel free to edit — druzhok will
    # NOT overwrite this file on restart (it only seeds it once).
    # sync_config/2 patches model + auxiliary on every start.
    model:
      default: "#{model}"
      provider: "custom"
      base_url: "#{url}"

    platforms:
      telegram:
        enabled: true
        observe_unmentioned_group_messages: #{observe_unmentioned}

    messaging:
      enabled_platforms:
        telegram: [hermes-telegram]

    stt:
      enabled: true
      provider: "openai"
      openai:
        model: "whisper-1"

    tts:
      enabled: true
      provider: "openai"
      openai:
        model: "gpt-4o-mini-tts"
        voice: "alloy"
        base_url: "#{url}"

    auxiliary:
      vision:
        provider: custom
        base_url: "#{url}"
        api_key: "#{tenant_key}"
        model: "#{vision_model}"

    memory:
      provider: #{memory_provider}
      memory_enabled: true
      user_profile_enabled: true
      memory_char_limit: 2200
      user_char_limit: 1375

    quick_commands:
      start:
        type: alias
        target: new

    group_sessions_per_user: #{group_sessions_per_user}
    """
  end

  defp proxy_url do
    proxy_host = Druzhok.Runtime.proxy_host()
    proxy_port = System.get_env("LLM_PROXY_PORT") || "4000"
    "http://#{proxy_host}:#{proxy_port}/v1"
  end
end
