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

  alias Druzhok.{BotManager, Instance}

  @data_mount "/opt/data"
  @default_model "anthropic/claude-opus-4.6"
  @default_vision_model "google/gemini-2.5-flash-lite"

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
      "TELEGRAM_BOT_TOKEN" => Map.get(instance, :telegram_token, "") || "",
      "TELEGRAM_ALLOWED_USERS" => build_allowlist(instance),
      "TELEGRAM_ALLOW_ALL_USERS" => to_string(Map.get(instance, :allow_all_telegram_users, false)),
      # Group chat trigger gating. `require_mention` forces groups to need
      # an @mention / regex trigger / reply-to-bot. `mention_patterns` is
      # a JSON list of regexes hermes compiles with re.IGNORECASE.
      # `free_response_chats` are chat IDs where the bot always responds
      # even with require_mention on.
      "TELEGRAM_REQUIRE_MENTION" => to_string(Map.get(instance, :mention_only, false)),
      "TELEGRAM_MENTION_PATTERNS" => build_mention_patterns(instance),
      "TELEGRAM_FREE_RESPONSE_CHATS" => build_free_response_chats(instance),
      # Druzhok patch: enables thread_id collapse + silent observer for
      # group chats (see gateway/platforms/telegram.py patches).
      "TELEGRAM_GROUP_SHARED_MEMORY" => to_string(Map.get(instance, :group_shared_memory, false)),
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
    value = Map.get(instance, :group_sessions_per_user, true)
    line = "group_sessions_per_user: #{value}"

    if Regex.match?(~r/^group_sessions_per_user:.*$/m, content) do
      Regex.replace(~r/^group_sessions_per_user:.*$/m, content, line)
    else
      String.trim_trailing(content) <> "\n\n" <> line <> "\n"
    end
  end

  def sync_agents_md(_instance, data_root) do
    agents_path = Path.join([data_root, "workspace", "AGENTS.md"])

    case File.read(agents_path) do
      {:ok, content} ->
        if String.contains?(content, "## Публикация сайтов") do
          :ok
        else
          updated = String.trim_trailing(content) <> "\n\n" <> @agents_md_sites_section
          File.write!(agents_path, updated)
          :ok
        end

      {:error, _} ->
        :ok
    end
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
    group_sessions_per_user = Map.get(instance, :group_sessions_per_user, true)

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

    group_sessions_per_user: #{group_sessions_per_user}
    """
  end

  defp proxy_url do
    proxy_host = Druzhok.Runtime.proxy_host()
    proxy_port = System.get_env("LLM_PROXY_PORT") || "4000"
    "http://#{proxy_host}:#{proxy_port}/v1"
  end
end
