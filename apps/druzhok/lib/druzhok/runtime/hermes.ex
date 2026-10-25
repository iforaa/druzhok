defmodule Druzhok.Runtime.Hermes do
  @moduledoc """
  Env, config.yaml and workspace files for the Hermes agent (hermes-agent/ clone).

  One systemd unit (or dev process) per bot. `HERMES_HOME` is the tenant's
  data root on disk (`/data/tenants/<name>` in prod). All LLM traffic goes through druzhok's Elixir proxy via
  `OPENAI_BASE_URL` + `OPENAI_API_KEY`; hermes flips its inference provider
  to `"custom"` automatically when `OPENAI_BASE_URL` is set
  (see hermes_cli/main.py:915).

  The allowlist is env-var driven: druzhok writes `TELEGRAM_ALLOWED_USERS`
  at each start from `instance.owner_telegram_id +
  instance.allowed_telegram_ids`. Hermes's own pairing store under
  `<data_root>/platforms/pairing/telegram-approved.json` is left for the bot
  to manage — `ops/druzhok users` reads it, druzhok never writes it.

  `workspace/AGENTS.md` is seeded on first start and the druzhok-owned
  sections (`## Каждая сессия`, `## Память`, `## Стиль`, `## Публикация
  сайтов`) are rewritten on every start; everything else in it belongs to
  the bot.
  """

  require Logger
  alias Druzhok.{Instance, TenantFiles}

  # ruoc catalogue entry Mnemosyne embeds through, and its vector width.
  @embedding_model "ruoc-embed-gemini"
  @embedding_dim "3072"

  # Telegram API IPs the bot connects to. Without them hermes spends ~5 s on
  # every start trying DNS-over-HTTPS, which bots can't reach (no internet),
  # and then falls back to these same seeds (hermes SEED_FALLBACK_IPS,
  # plugins/platforms/telegram/telegram_network.py). Must stay inside the
  # Telegram CIDRs in ops/nftables-druzhok.nft.
  @telegram_fallback_ips "149.154.166.110,149.154.167.220"

  # Seconds a stopping bot lets a running chat turn finish before
  # interrupting it (hermes `agent.restart_drain_timeout`, default 0: a
  # deploy or BotManager.restart cut every running reply short and the user
  # got "send it again"). Hermes needs TimeoutStopSec >= max(60, max(drain,
  # cron_drain 30 + 10) + 30) = 70 s; hermes@.service has the 90 s default.
  @restart_drain_timeout "30"

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
  3. Запиши все файлы в `sites/<имя>/` внутри рабочей директории (workspace). Входная точка — `index.html`. Всего до ~50 MB на сайт, до ~100 файлов.
  4. Ответь пользователю одной кликабельной ссылкой: `$BOT_SITE_BASE_URL/<имя>/`.
  5. Удалить сайт: `rm -rf sites/<имя>/`.

  Файлы в `sites/<имя>/` публичны. Не клади туда секреты, токены, файлы, начинающиеся с точки.
  """

  def data_root(instance) do
    case Map.get(instance, :workspace) do
      ws when is_binary(ws) and ws != "" -> Path.dirname(ws)
      _ -> ""
    end
  end

  @doc "Hermes CLI binary (`HERMES_BIN`); bare `hermes` resolves via PATH."
  def bin, do: Application.get_env(:druzhok, :hermes_bin, "hermes")

  def env_vars(instance) do
    # base_env/1 already provides OPENAI_BASE_URL, OPENAI_API_KEY, TZ —
    # only add hermes-specific keys here.
    #
    # STT_OPENAI_BASE_URL routes voice transcription through the druzhok
    # proxy's /v1/audio/transcriptions endpoint instead of api.openai.com.
    # The provider choice (openai vs local/faster-whisper) lives in
    # config.yaml's `stt:` section — see build_config_yaml/1.
    #
    # The model and provider come from config.yaml's `model:` block only
    # (HERMES_MODEL / HERMES_INFERENCE_PROVIDER, and HERMES_QUIET, which the
    # gateway forces itself, are no longer set).
    tenant_key = Map.get(instance, :tenant_key, "") || ""
    proxy_url = proxy_url()

    %{
      "HERMES_HOME" => data_root(instance),
      # The bot's working directory; `terminal.cwd` in config.yaml is the
      # canonical setting since hermes 0.22 (sync_terminal_block/2). Kept with
      # the same value for one release, for rollback.
      "MESSAGING_CWD" => Path.join(data_root(instance), "workspace"),
      "TELEGRAM_BOT_TOKEN" => Map.get(instance, :telegram_token, "") || "",
      "TELEGRAM_FALLBACK_IPS" => @telegram_fallback_ips,
      "HERMES_RESTART_DRAIN_TIMEOUT" => @restart_drain_timeout,
      "TELEGRAM_ALLOWED_USERS" => build_allowlist(instance),
      "TELEGRAM_ALLOW_ALL_USERS" =>
        to_string(Map.get(instance, :allow_all_telegram_users, false)),
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
      "OPENROUTER_API_KEY" => tenant_key,
      # Anything hermes sends to "openrouter" goes to the proxy too. Bots have
      # no internet, and the video tool's catalog fetch to openrouter.ai hung
      # 2 × 10 s on every start (nftables drops), holding the first reply
      # behind hermes's turn warm-up; the proxy answers it 404 at once.
      "OPENROUTER_BASE_URL" => proxy_url,
      "STT_OPENAI_BASE_URL" => proxy_url,
      # Web search: firecrawl backend → druzhok /v2/search → perplexity/sonar
      "FIRECRAWL_API_URL" => proxy_url |> String.replace_suffix("/v1", ""),
      "FIRECRAWL_API_KEY" => tenant_key
    }
    |> Map.merge(mnemosyne_env(instance))
    |> Map.merge(webhook_env(instance))
  end

  # Telegram webhook relay (docs/superpowers/specs/2026-10-20-telegram-webhook-relay-design.md).
  # Hermes reads PORT and HOST only in webhook mode; every bot carries them so
  # druzhok-ctl has the nftables `uid . port` element in place before a bot is
  # switched. URL and SECRET are what switch hermes into webhook mode.
  defp webhook_env(instance) do
    alias Druzhok.Telegram.Webhook

    port_env =
      case Webhook.port(instance) do
        nil ->
          %{}

        port ->
          %{"TELEGRAM_WEBHOOK_PORT" => to_string(port), "TELEGRAM_WEBHOOK_HOST" => "127.0.0.1"}
      end

    if Webhook.webhook?(instance) and port_env != %{} do
      Map.merge(port_env, %{
        "TELEGRAM_WEBHOOK_URL" => Webhook.public_url(instance),
        "TELEGRAM_WEBHOOK_SECRET" => Map.get(instance, :telegram_webhook_secret) || ""
      })
    else
      port_env
    end
  end

  # Mnemosyne memory provider (docs/superpowers/specs/2026-09-06-mnemosyne-memory-design.md):
  # embeddings go to the proxy's /v1/embeddings with the tenant key, with the
  # e5-era query/passage prefixes (trailing space included; kept for gemini on
  # eval evidence, R@5 1.00 vs 0.99 without), and LLM consolidation stays
  # off. `MNEMOSYNE_DATA_DIR` keeps the SQLite bank inside the tenant dir; it
  # must be `<HERMES_HOME>/mnemosyne/data`, because the hermes plugin ignores
  # the variable and opens exactly that path, while the `mnemosyne` CLI (reindex,
  # doctor) opens `$MNEMOSYNE_DATA_DIR/mnemosyne.db` — any other value makes the
  # CLI operate on a different database than the bot.
  # Model and dimension name a ruoc catalogue entry; changing them means every
  # bot runs `mnemosyne reindex` after its next restart (until then Mnemosyne
  # falls back to keyword recall, nothing is lost). `ruoc-embed-gemini` is
  # google/gemini-embedding-001 via OpenRouter (R@5 1.00 on ops/embed-eval with
  # the prefixes, 0.99 without; since 2026-10-22, replacing e5-large, whose one
  # provider hung for tens of seconds).
  defp mnemosyne_env(instance) do
    if memory_provider(instance) == "mnemosyne" do
      %{
        "MNEMOSYNE_DATA_DIR" => Path.join([data_root(instance), "mnemosyne", "data"]),
        "MNEMOSYNE_EMBEDDING_API_URL" => proxy_url(),
        "MNEMOSYNE_EMBEDDING_API_KEY" => Map.get(instance, :tenant_key, "") || "",
        "MNEMOSYNE_EMBEDDING_MODEL" => @embedding_model,
        "MNEMOSYNE_EMBEDDING_DIM" => @embedding_dim,
        "MNEMOSYNE_EMBEDDING_QUERY_PREFIX" => "query: ",
        "MNEMOSYNE_EMBEDDING_DOC_PREFIX" => "passage: ",
        "MNEMOSYNE_LLM_ENABLED" => "false",
        "MNEMOSYNE_HOST_LLM_ENABLED" => "false"
      }
    else
      %{}
    end
  end

  defp memory_provider(instance) do
    case Map.get(instance, :memory_provider) do
      "mnemosyne" -> "mnemosyne"
      _ -> "builtin"
    end
  end

  def workspace_files(instance) do
    # :create_only — write on fresh data root only. Hermes persists runtime
    # state (telegram thread IDs, etc.) back into config.yaml at runtime, so
    # we must never overwrite it on restart. sync_config/2 (below) handles
    # targeted updates on every start.
    [
      {"config.yaml", build_config_yaml(instance), :create_only},
      {"workspace/AGENTS.md", default_agents_md(), :create_only}
    ]
  end

  # config.yaml and AGENTS.md are read whole; anything larger is left alone.
  @config_limit 1_048_576

  def sync_config(instance, data_root) do
    sync_agents_md(instance, data_root)

    # Patch druzhok-owned fields in config.yaml on every start so the
    # instance row stays the source of truth without clobbering hermes's
    # runtime writes (thread IDs etc). Read and written through TenantFiles:
    # the bot owns the file and could make it a symlink.
    model = Map.get(instance, :model) || Druzhok.Ruoc.default_model()
    vision_model = vision_model_for(instance, model)
    tenant_key = Map.get(instance, :tenant_key, "") || ""

    case TenantFiles.read_text(data_root, ["config.yaml"], @config_limit) do
      {:ok, %{text: content, truncated: false}} ->
        updated =
          content
          |> sync_model_default(model)
          |> sync_model_api_key()
          |> sync_auxiliary_block(vision_model, tenant_key)
          |> sync_group_sessions_per_user(instance)
          |> sync_memory_block(instance)
          |> sync_image_gen_block(instance)
          |> sync_quick_commands()
          |> sync_streaming_block()
          |> sync_plugins_enabled()
          |> sync_gateway_block()
          |> sync_telegram_extra(instance)
          |> sync_cron_block()
          |> sync_display_block()
          |> sync_stt_block()
          |> sync_model_facts(instance)
          |> sync_agent_block()
          |> sync_skills_block(bundled_skills(data_root))
          |> sync_terminal_block(data_root)
          |> drop_messaging_block()

        if updated != content, do: write_tenant_file(data_root, ["config.yaml"], updated)
        :ok

      _ ->
        :ok
    end
  end

  defp write_tenant_file(data_root, segments, content) do
    case TenantFiles.write(data_root, segments, content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Not writing #{Path.join(segments)} in #{data_root}: #{inspect(reason)}")
    end
  end

  # systemd Type=notify + WatchdogSec in ops/hermes@.service only work when
  # hermes opts in here; 0 (the default) means it never sends READY=1 and the
  # unit times out on start. 60s heartbeats vs WatchdogSec=120.
  @systemd_watchdog_seconds 60

  defp sync_gateway_block(content) do
    sync_yaml_block(content, "gateway",
      upsert:
        &upsert_indented_line(
          &1,
          "systemd_watchdog_seconds",
          to_string(@systemd_watchdog_seconds)
        ),
      default: "gateway:\n  systemd_watchdog_seconds: #{@systemd_watchdog_seconds}"
    )
  end

  # Hermes wraps cron deliveries in an English "Cronjob Response: <name>
  # (job_id: …) … To stop or manage this job…" envelope; the bot's own text
  # is all a tenant should see (hermes `cron.wrap_response`).
  defp sync_cron_block(content) do
    sync_yaml_block(content, "cron",
      upsert: &upsert_indented_line(&1, "wrap_response", "false"),
      default: "cron:\n  wrap_response: false"
    )
  end

  # No "💾 Self-improvement review: …" line in chat after the background
  # memory review (hermes `display.memory_notifications`); the review itself
  # still runs and writes.
  defp sync_display_block(content) do
    sync_yaml_block(content, "display",
      upsert: &upsert_indented_line(&1, "memory_notifications", "off"),
      default: "display:\n  memory_notifications: off"
    )
  end

  # What the bot's model can do, from ruoc's catalogue (`model_facts`, set by
  # BotManager.prepare_start/1 from Ruoc.model_facts/1):
  #
  # - `model.context_length`: hermes cannot probe the proxy for a window and
  #   falls back to its own table, 1M for "deepseek-flash", so it compressed
  #   only at 0.5 × 1M. ruoc's real limit (200K) makes it compress at 75 %.
  # - how a photo reaches the model (`agent.image_input_mode`). In `auto` the
  #   explicit `auxiliary.vision` block makes hermes describe every photo in a
  #   separate call and hand the bot 2-4 English sentences instead
  #   (agent/image_routing.py), even when the bot's model reads images;
  #   `native` sends the photo itself. Hermes also checks right before each
  #   call whether the model sees (agent/vision_message_prep.py); models.dev
  #   does not know ruoc's ids, so without `model.supports_vision` it turns
  #   every photo in the history back into a long description.
  #
  # A model ruoc does not list loses all three numbers (hermes falls back to
  # its own detection, `auto` describes photos); while the catalogue is empty
  # (`:no_catalogue`) the file is left as it is.
  defp sync_model_facts(content, instance) do
    case Map.get(instance, :model_facts) do
      {:ok, %{sees_images: sees?, context: context}} ->
        content
        |> put_block("model", [
          {"context_length", if(context, do: to_string(context), else: :delete)},
          {"supports_vision", to_string(sees?)}
        ])
        |> put_block("agent", [{"image_input_mode", if(sees?, do: "native", else: "auto")}])

      :unknown_model ->
        content
        |> put_block("model", [{"context_length", :delete}, {"supports_vision", :delete}])
        |> put_block("agent", [{"image_input_mode", "auto"}])

      _ ->
        content
    end
  end

  # Toolsets a bot can never use: no internet and no browser binary
  # (browser), no display (computer_use), no route to Nous's connector
  # gateway or an MCP server (connections). Hermes's global suppression list,
  # applied last (hermes_cli/tools_config.py:626): a block list, so toolsets
  # a later hermes adds are not lost silently. Delegation stays (operator).
  @disabled_toolsets ~w(browser computer_use connections)

  # One reply may take at most 30 tool iterations (hermes default: unlimited)
  # and 300 s; at 75 % the model is told once to wrap up, so it answers
  # instead of being cut off mid-task.
  @turn_budget [
    {"max_turns", "30"},
    {"budget_warning_ratio", "0.75"},
    {"run_budget_seconds", "300"}
  ]

  defp sync_agent_block(content) do
    put_block(
      content,
      "agent",
      @turn_budget ++ [{"disabled_toolsets", {:list, @disabled_toolsets}}]
    )
  end

  # Bundled skills that need a Mac, GitHub access, an external API or a
  # coding-agent CLI that is not installed; the skills index in every system
  # prompt lists them and some send the model after tools it lacks. Coding
  # itself stays (file, terminal and code-execution tools; codebase-inspection,
  # plan). google-workspace returns with a Google integration. Disabling is by
  # name (hermes `skills.disabled`), so only names in the bot's
  # skills/.bundled_manifest are written: a skill the bot made is not in it.
  @disabled_skills ~w(
    claude-code codex opencode computer-use merge-reconciler
    apple-notes apple-reminders findmy imessage
    github github-auth github-code-review github-issues github-issue-to-pr github-pr-workflow
    github-repo-management
    huggingface-hub serving-llms-vllm llama-cpp weights-and-biases evaluating-llms-harness
    sdlc-review openhue xurl himalaya comfyui touchdesigner-mcp
    airtable box google-workspace notion teams-meeting-pipeline
  )

  def disabled_skills, do: @disabled_skills

  defp sync_skills_block(content, bundled) do
    case Enum.filter(@disabled_skills, &MapSet.member?(bundled, &1)) do
      [] -> put_block(content, "skills", [{"disabled", :delete}])
      names -> put_block(content, "skills", [{"disabled", {:list, names}}])
    end
  end

  # Names of the skills hermes copied in (`name:hash` lines), read without
  # following a symlink; none when the manifest is missing or refused.
  defp bundled_skills(data_root) do
    case TenantFiles.read_text(data_root, ["skills", ".bundled_manifest"], 262_144) do
      {:ok, %{text: text}} ->
        for line <- String.split(text, "\n"),
            name = line |> String.split(":", parts: 2) |> hd() |> String.trim(),
            name != "",
            into: MapSet.new(),
            do: name

      _ ->
        MapSet.new()
    end
  end

  # The bot's working directory (`terminal.cwd`, canonical in hermes 0.22,
  # gateway/run.py:2152). MESSAGING_CWD in env_vars/1 carries the same value
  # for one more release, for rollback.
  defp sync_terminal_block(content, data_root) do
    put_block(content, "terminal", [{"cwd", ~s("#{Path.join(data_root, "workspace")}")}])
  end

  # `messaging.enabled_platforms` was written by druzhok's first seeds;
  # nothing in hermes 0.22 reads it (Telegram is on via platforms.telegram).
  defp drop_messaging_block(content),
    do: put_block(content, "messaging", [{"enabled_platforms", :delete}])

  @doc false
  # The keys `sync_config/2` writes for the config-tuning change, removed for
  # its rollback (spec 2026-10-25-hermes-config-tuning-design.md): the old
  # sync never removes them, so a plain revert would leave them in force.
  # `model.supports_vision` and `agent.image_input_mode` stay (live before it).
  def strip_tuning_keys(content) do
    content
    |> put_block("model", [{"context_length", :delete}])
    |> put_block(
      "agent",
      Enum.map(@turn_budget, fn {k, _} -> {k, :delete} end) ++ [{"disabled_toolsets", :delete}]
    )
    |> put_block("skills", [{"disabled", :delete}])
    |> put_block("terminal", [{"cwd", :delete}])
  end

  # Set druzhok-owned children of the top-level `name:` block. `owned` is
  # [{key, value}], value one of: a YAML scalar (a string written as is),
  # {:list, items} (a one-line flow list), {:merge, owned} (a nested block
  # whose other children are kept), :delete, or :keep (left untouched). Each
  # owned key is dropped with its whole body (blank lines, deeper lines,
  # hermes's same-indent `- item` lists) and rendered fresh at the top of the
  # block, so a changed value leaves nothing behind and a second run changes
  # nothing. A block left empty loses its header; a missing one is appended.
  defp put_block(content, name, owned) do
    lines = String.split(content, "\n")

    case yaml_block(lines, 0, name, 0, length(lines) - 1) do
      nil ->
        case put_children([], owned, 2) do
          [] ->
            content

          body ->
            String.trim_trailing(content) <>
              "\n\n" <> Enum.join([name <> ":" | body], "\n") <> "\n"
        end

      {idx, last} ->
        case put_children(Enum.slice(lines, (idx + 1)..last//1), owned, 2) do
          [] -> splice(lines, idx, last, [])
          body -> splice(lines, idx + 1, last, body)
        end
    end
  end

  defp put_children(body, owned, default_indent) do
    indent = child_indent(body, default_indent)

    {taken, rest} =
      Enum.reduce(owned, {%{}, body}, fn
        {_key, :keep}, acc ->
          acc

        {key, _}, {taken, lines} ->
          {child, lines} = take_child(lines, indent, key)
          {Map.put(taken, key, child), lines}
      end)

    rendered =
      Enum.flat_map(owned, fn {key, value} -> render_child(key, value, taken[key], indent) end)

    lines = rendered ++ rest
    if Enum.all?(lines, &(String.trim(&1) == "")), do: [], else: lines
  end

  defp render_child(_key, value, _old, _indent) when value in [:keep, :delete], do: []

  defp render_child(key, {:list, items}, _old, indent),
    do: [pad(indent) <> key <> ": [" <> Enum.join(items, ", ") <> "]"]

  defp render_child(key, {:merge, owned}, old, indent) do
    old_body =
      case old do
        [_header | body] -> body
        nil -> []
      end

    case put_children(old_body, owned, indent + 2) do
      [] -> []
      body -> [pad(indent) <> key <> ":" | body]
    end
  end

  defp render_child(key, value, _old, indent) when is_binary(value),
    do: [pad(indent) <> key <> ": " <> value]

  defp child_indent(body, default) do
    case Enum.find(body, fn l ->
           t = String.trim(l)
           t != "" and not String.starts_with?(t, "#")
         end) do
      nil -> default
      line -> indent_of(line)
    end
  end

  # `key:` at exactly `indent` and its body: blank lines, deeper lines, and
  # `- item` lines at the key's own indent. `{nil, lines}` when absent.
  defp take_child(lines, indent, key) do
    header = ~r/^ {#{indent}}#{Regex.escape(key)}:(\s|$)/

    case Enum.find_index(lines, &Regex.match?(header, &1)) do
      nil ->
        {nil, lines}

      i ->
        {before, [h | after_header]} = Enum.split(lines, i)

        {body, rest} =
          Enum.split_while(after_header, fn l ->
            String.trim(l) == "" or indent_of(l) > indent or
              (indent_of(l) == indent and String.starts_with?(String.trim_leading(l), "- "))
          end)

        {[h | body], before ++ rest}
    end
  end

  # Hermes trims silence from longer voice notes before a cloud STT upload
  # and re-encodes them to m4a (`stt.cloud_trim_silence`, default true). The
  # proxy's /v1/audio/transcriptions only carries wav/mp3/ogg to ruoc, so the
  # trimmed upload gets a 400 and the note is never transcribed. Telegram
  # voice notes are ogg/opus already; upload them as they are.
  defp sync_stt_block(content) do
    sync_yaml_block(content, "stt",
      upsert: &upsert_indented_line(&1, "cloud_trim_silence", "false"),
      default:
        "stt:\n  enabled: true\n  provider: \"openai\"\n  cloud_trim_silence: false\n  openai:\n    model: \"whisper-1\""
    )
  end

  # Slash-command access + Telegram command menu (upstream config keys, see
  # hermes gateway/slash_access.py and hermes_cli/commands.py — no fork patch).
  #
  # Tenants are "users" in hermes's terms: they may run @user_commands, and
  # everything else (/model, /tools, /config, /yolo, ...) replies "⛔ admin-only".
  # /help and /whoami are always allowed by hermes. The operator (Settings
  # `operator_telegram_id`) is the admin in DMs and groups; hermes only turns
  # the gate on when allow_admin_from is non-empty, so "0" stands in when no
  # operator is configured (no Telegram user has id 0).
  #
  # The menu Telegram shows on "/" is cut to exactly @menu_commands:
  # priority_mode=replace ranks them first, max_commands drops the rest.
  # `start` is the /start -> /new quick-command alias (sync_quick_commands/1);
  # hermes checks the typed name against the policy, so it must be listed.
  @user_commands ~w(start new compress status voice)
  @menu_commands ~w(new compress status voice)
  @telegram_extra_keys ~w(allow_admin_from user_allowed_commands group_allow_admin_from group_user_allowed_commands command_menu drop_pending_on_cold_boot)

  def user_commands, do: @user_commands
  def menu_commands, do: @menu_commands

  defp sync_telegram_extra(content, instance) do
    admin = operator_telegram_id(instance)

    owned = [
      {"allow_admin_from", [~s("#{admin}")]},
      {"user_allowed_commands", @user_commands},
      {"group_allow_admin_from", [~s("#{admin}")]},
      {"group_user_allowed_commands", @user_commands},
      {"command_menu",
       [
         {"priority_mode", "replace"},
         {"max_commands", to_string(length(@menu_commands))},
         {"priority", @menu_commands}
       ]},
      # Hermes's default (true) has Telegram discard every update sent while
      # the bot was down, on every restart. Keep them.
      {"drop_pending_on_cold_boot", "false"}
    ]

    lines = String.split(content, "\n")

    case yaml_block(lines, 0, "platforms", 0, length(lines) - 1) do
      nil ->
        String.trim_trailing(content) <>
          "\n\nplatforms:\n  telegram:\n    extra:\n" <> render_yaml(owned, 6, 2) <> "\n"

      {p_idx, p_end} ->
        case yaml_block(lines, nil, "telegram", p_idx + 1, p_end) do
          nil ->
            insert = ["  telegram:", "    extra:" | String.split(render_yaml(owned, 6, 2), "\n")]
            splice(lines, p_idx + 1, p_idx, insert)

          {t_idx, t_end} ->
            step = indent_of(Enum.at(lines, t_idx))

            case yaml_block(lines, nil, "extra", t_idx + 1, t_end) do
              nil ->
                insert = [
                  pad(2 * step) <> "extra:"
                  | String.split(render_yaml(owned, 3 * step, step), "\n")
                ]

                splice(lines, t_idx + 1, t_idx, insert)

              {e_idx, e_end} ->
                e_indent = indent_of(Enum.at(lines, e_idx))
                body = Enum.slice(lines, (e_idx + 1)..e_end//1)
                kept = drop_owned_keys(body, @telegram_extra_keys)
                rendered = String.split(render_yaml(owned, e_indent + step, step), "\n")
                splice(lines, e_idx + 1, e_end, rendered ++ kept)
            end
        end
    end
  end

  defp operator_telegram_id(instance) do
    case Map.get(instance, :operator_telegram_id) do
      id when is_integer(id) -> to_string(id)
      id when is_binary(id) and id != "" -> String.trim(id)
      _ -> "0"
    end
  end

  # {first_line_idx, last_body_idx} of `key:` at `indent` (nil = any indent > 0)
  # within lines[from..to]; the body is every following line that is blank or
  # indented deeper than the key.
  defp yaml_block(lines, indent, key, from, to) when from <= to do
    Enum.find_value(from..to, fn i ->
      line = Enum.at(lines, i)

      if yaml_key_line?(line, key, indent) do
        k = indent_of(line)

        last =
          Enum.reduce_while((i + 1)..to//1, i, fn j, acc ->
            l = Enum.at(lines, j)
            if String.trim(l) == "" or indent_of(l) > k, do: {:cont, j}, else: {:halt, acc}
          end)

        {i, trim_blank_tail(lines, i, last)}
      end
    end)
  end

  defp yaml_block(_lines, _indent, _key, _from, _to), do: nil

  defp yaml_key_line?(line, key, indent) do
    case Regex.run(~r/^([ \t]*)([A-Za-z0-9_]+):[ \t]*$/, line) do
      [_, ws, ^key] -> if indent == nil, do: byte_size(ws) > 0, else: byte_size(ws) == indent
      _ -> false
    end
  end

  defp trim_blank_tail(lines, first, last) do
    Enum.reduce_while(last..first//-1, first, fn j, _ ->
      if String.trim(Enum.at(lines, j)) == "", do: {:cont, first}, else: {:halt, j}
    end)
  end

  # Remove `key:` lines (and their nested bodies) for keys we own, keep the rest
  # (e.g. dm_topics hermes writes back at runtime).
  defp drop_owned_keys(body, keys) do
    Enum.reduce(body, {[], nil}, fn line, {acc, skipping} ->
      cond do
        # Nested body, or list items hermes's dumper puts at the key's own indent.
        skipping != nil and
            (String.trim(line) == "" or indent_of(line) > skipping or
               (indent_of(line) == skipping and
                  String.starts_with?(String.trim_leading(line), "- "))) ->
          {acc, skipping}

        Regex.run(~r/^([ \t]*)([A-Za-z0-9_]+):/, line) |> owned_key?(keys) ->
          {acc, indent_of(line)}

        true ->
          {[line | acc], nil}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp owned_key?([_, _ws, key], keys), do: key in keys
  defp owned_key?(_, _keys), do: false

  # Replace lines[from..to] with `insert` (to < from inserts before `from`).
  defp splice(lines, from, to, insert) do
    {head, _} = Enum.split(lines, from)
    tail = Enum.drop(lines, to + 1)
    Enum.join(head ++ insert ++ tail, "\n")
  end

  # Render [{key, scalar | [scalar] | [{key, _}]}] as YAML at `indent`, `step`
  # spaces per level; list items sit one step under their key.
  defp render_yaml(pairs, indent, step) do
    pairs
    |> Enum.flat_map(fn
      {key, [{_, _} | _] = nested} ->
        [
          pad(indent) <> key <> ":"
          | render_yaml(nested, indent + step, step) |> String.split("\n")
        ]

      {key, items} when is_list(items) ->
        [pad(indent) <> key <> ":" | Enum.map(items, &(pad(indent + step) <> "- " <> &1))]

      {key, scalar} ->
        [pad(indent) <> key <> ": " <> scalar]
    end)
    |> Enum.join("\n")
  end

  defp indent_of(line), do: byte_size(line) - byte_size(String.trim_leading(line, " "))
  defp pad(n), do: String.duplicate(" ", n)

  # Enable gateway streaming (progressive Telegram message edits). Existing bots
  # were seeded before the streaming block existed, so append it when absent.
  # New bots already get enabled: true from build_config_yaml/1.
  defp sync_streaming_block(content) do
    if Regex.match?(~r/^streaming:/m, content) do
      content
    else
      content <>
        "\nstreaming:\n  enabled: true\n  transport: edit\n  edit_interval: 0.6\n  buffer_threshold: 60\n"
    end
  end

  # Web search: hermes 0.17 moved web search into a bundled-but-disabled plugin
  # (`web/firecrawl`). The 0.16->0.17 config migration leaves `plugins.enabled: []`,
  # so web_search silently falls back to the browser. We ship FIRECRAWL_API_URL +
  # FIRECRAWL_API_KEY (env_vars/1) pointing at druzhok's /v2/search (perplexity),
  # so enabling the plugin is all that's needed. Idempotent; covers existing bots
  # (here) and new bots (build_config_yaml/1 seeds the same block).
  @web_search_plugin "web/firecrawl"
  defp sync_plugins_enabled(content) do
    cond do
      # Already enabled — no-op.
      Regex.match?(~r/^[ \t]*-[ \t]*#{Regex.escape(@web_search_plugin)}[ \t]*$/m, content) ->
        content

      # `plugins:` block with an empty inline list: `enabled: []` -> expand to a list.
      Regex.match?(~r/^[ \t]+enabled:[ \t]*\[\][ \t]*$/m, content) and
          Regex.match?(~r/^plugins:/m, content) ->
        Regex.replace(
          ~r/^([ \t]+)enabled:[ \t]*\[\][ \t]*$/m,
          content,
          "\\1enabled:\n\\1- #{@web_search_plugin}",
          global: false
        )

      # `plugins:` block with a populated `enabled:` list -> insert as first item.
      Regex.match?(~r/^plugins:/m, content) and
          Regex.match?(~r/^[ \t]+enabled:[ \t]*$/m, content) ->
        Regex.replace(
          ~r/^([ \t]+)enabled:[ \t]*\n/m,
          content,
          "\\1enabled:\n\\1- #{@web_search_plugin}\n",
          global: false
        )

      # No `plugins:` block at all -> append one.
      true ->
        content <> "\nplugins:\n  enabled:\n  - #{@web_search_plugin}\n"
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

  # Hermes 0.14 (#28660) gates env-var key fallbacks on authoritative hosts —
  # a `provider: custom` block pointing at our local proxy no longer auto-picks
  # up OPENROUTER_API_KEY. Explicitly set api_key with a ${VAR} template so
  # load_config()'s _expand_env_vars resolves it per-instance.
  #
  # Match only api_key WITHIN the top-level model: block (other blocks like
  # auxiliary.vision and custom_providers also have api_key lines).
  defp sync_model_api_key(content) do
    model_block_re = ~r/^model:\n((?:[ \t]+.*\n)+)/m

    case Regex.run(model_block_re, content, return: :index) do
      nil ->
        content

      [{_, _}, {body_start, body_len}] ->
        body = binary_part(content, body_start, body_len)

        if String.match?(body, ~r/^\s+api_key:\s/m) do
          content
        else
          new_body =
            Regex.replace(
              ~r/^(\s+base_url:[ \t]*.*\n)/m,
              body,
              "\\1  api_key: \"${OPENROUTER_API_KEY}\"\n",
              global: false
            )

          binary_part(content, 0, body_start) <>
            new_body <>
            binary_part(
              content,
              body_start + body_len,
              byte_size(content) - body_start - body_len
            )
        end
    end
  end

  # Since hermes 2026-04 (commit 976bad5b), config.yaml takes priority
  # over env vars for auxiliary task settings. Write the vision config
  # block so hermes routes vision calls through the druzhok proxy.
  # Images go through ruoc-gateway too; without an explicit vision model the
  # bot's own model reads them (the ruoc default has the attachment capability).
  defp vision_model_for(instance, model) do
    case Map.get(instance, :image_model) do
      v when v in [nil, ""] -> model
      vision -> vision
    end
  end

  # Compression summaries run on the bot's model. ruoc-flash (GLM) could not
  # turn reasoning off ("Reasoning is mandatory"), and at its default depth it
  # spent a whole 32k output cap thinking over a 60k-token history and returned
  # no summary, so the session could never compact. "low" kept it short; the
  # bots have since moved to DeepSeek and the value stays.
  @compression_block """
    compression:
      reasoning_effort: "low"
  """

  # Only `auxiliary.vision` and `auxiliary.compression` belong to druzhok;
  # their other keys and every other aux task (background_review,
  # title_generation, …) are kept. This used to replace the whole block.
  defp sync_auxiliary_block(content, vision_model, tenant_key) do
    put_block(content, "auxiliary", [
      {"vision",
       {:merge,
        [
          {"provider", "custom"},
          {"base_url", ~s("#{proxy_url()}")},
          {"api_key", ~s("#{tenant_key}")},
          {"model", ~s("#{vision_model}")}
        ]}},
      {"compression", {:merge, [{"reasoning_effort", ~s("low")}]}}
    ])
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

  # Druzhok owns `memory.provider` (builtin, or mnemosyne when the bot's
  # memory_provider says so); legacy MEMORY.md/USER.md memory stays on in
  # both cases (hermes runs one external provider alongside builtin).
  # Char-limit fields are left alone so user edits survive.
  #
  # The mnemosyne sub-block is written as a flow mapping on one line. Hermes
  # re-dumps config.yaml at runtime as a block mapping, so any existing
  # `mnemosyne:` key is dropped with its body first and re-added; otherwise
  # the one-line upsert would leave the old nested lines dangling.
  @mnemosyne_tools ~w(mnemosyne_remember mnemosyne_recall mnemosyne_forget)

  defp sync_memory_block(content, instance) do
    provider = memory_provider(instance)

    sync_yaml_block(content, "memory",
      upsert: fn body ->
        # The body ends in a newline the block regex captured; split off that
        # final "" before dropping keys, or a trailing mnemosyne mapping takes
        # it along and the next top-level key lands on the block's last line.
        {lines, tail} = body |> String.split("\n") |> Enum.split(-1)

        body =
          lines
          |> drop_owned_keys(["mnemosyne"])
          |> Kernel.++(tail)
          |> Enum.join("\n")
          |> upsert_indented_line("provider", provider)
          |> upsert_indented_line("memory_enabled", "true")
          |> upsert_indented_line("user_profile_enabled", "true")

        if provider == "mnemosyne", do: mnemosyne_line() <> "\n" <> body, else: body
      end,
      default: default_memory_block(provider)
    )
  end

  defp mnemosyne_line, do: "  mnemosyne: {tools: [#{Enum.join(@mnemosyne_tools, ", ")}]}"

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

  defp default_memory_block(provider) do
    mnemosyne = if provider == "mnemosyne", do: "\n" <> mnemosyne_line(), else: ""

    """
    memory:
      provider: #{provider}
      memory_enabled: true
      user_profile_enabled: true#{mnemosyne}
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

  def sync_agents_md(_instance, data_root) do
    segments = ["workspace", "AGENTS.md"]

    case TenantFiles.read_text(data_root, segments, @config_limit) do
      {:ok, %{text: content, truncated: false}} ->
        updated =
          content
          |> sync_section("Каждая сессия", @agents_md_session_section)
          |> sync_section("Память", memory_section())
          |> sync_section("Стиль", @agents_md_style_section)
          |> sync_section("Публикация сайтов", @agents_md_sites_section)

        if updated != content, do: write_tenant_file(data_root, segments, updated)
        :ok

      _ ->
        :ok
    end
  end

  # Replace one druzhok-owned `## <heading>` section (header + body, up to
  # the next `## ` or EOF) with `body`, appending it if absent. Druzhok owns
  # these sections so every restart picks up the latest wording: the session
  # section because the original lied that IDENTITY.md/USER.md were injected
  # into the system prompt (hermes only loads SOUL.md and memories), the
  # style section because it encodes loop-prevention tuned from observed bot
  # pathology, the sites section because paths changed across hosts.
  defp sync_section(content, heading, body) do
    body = String.trim_trailing(body)
    pattern = ~r/(?ms)^## #{Regex.escape(heading)}[ \t]*\n.*?\n+(?=^## |\z)/

    updated =
      if Regex.match?(pattern, content) do
        # Eat trailing newlines and re-emit a stable `\n\n` separator so the
        # rewrite is idempotent regardless of the original blank-line count.
        Regex.replace(pattern, content, body <> "\n\n", global: false)
      else
        String.trim_trailing(content) <> "\n\n" <> body
      end

    String.trim_trailing(updated) <> "\n"
  end

  # Seed for a fresh workspace: the druzhok-owned sections plus a few
  # starter rules the bot is free to edit.
  defp default_agents_md do
    [
      "# AGENTS.md — Персональный ассистент",
      @agents_md_session_section,
      memory_section(),
      """
      ## Безопасность

      - Приватные данные не утекают. Никогда.
      - Деструктивные команды — только с разрешения.
      - Сомневаешься — спроси.

      ## Групповые чаты

      Участвуй, но не доминируй. Отвечай когда упомянут или когда реально полезен.
      """,
      @agents_md_style_section,
      @agents_md_sites_section,
      "---\n\n_Этот файл — стартовая точка. Добавляй свои правила._"
    ]
    |> Enum.map_join("\n\n", &String.trim_trailing/1)
    |> Kernel.<>("\n")
  end

  defp memory_section do
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

  def clear_sessions(data_root) do
    data_root
    |> Path.join("sessions")
    |> File.rm_rf!()

    :ok
  end

  def read_allowed_users(data_root) do
    path = Path.join([data_root, "platforms", "pairing", "telegram-approved.json"])

    with {:ok, body} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      Map.keys(map)
    else
      _ -> []
    end
  end

  @doc "Base URL of druzhok's OpenAI-compatible proxy, as seen by bots and probes."
  def proxy_url do
    port = System.get_env("LLM_PROXY_PORT") || "4000"
    "http://127.0.0.1:#{port}/v1"
  end

  @doc "Env every bot gets: the proxy, its tenant key and its timezone."
  def base_env(instance) do
    %{
      "OPENAI_BASE_URL" => proxy_url(),
      "OPENAI_API_KEY" => Map.get(instance, :tenant_key, "") || "",
      "TZ" => Map.get(instance, :timezone, "UTC") || "UTC"
    }
  end

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
    model = Map.get(instance, :model) || Druzhok.Ruoc.default_model()
    vision_model = vision_model_for(instance, model)
    tenant_key = Map.get(instance, :tenant_key, "") || ""
    url = proxy_url()
    group_sessions_per_user = not Map.get(instance, :group_shared_memory, false)
    observe_unmentioned = Map.get(instance, :group_shared_memory, false)

    """
    # Generated by druzhok on first boot. Feel free to edit — druzhok will
    # NOT overwrite this file on restart (it only seeds it once).
    # sync_config/2 patches model + auxiliary on every start.
    model:
      default: "#{model}"
      provider: "custom"
      base_url: "#{url}"
      # Hermes 0.14 gates env-var fallbacks on authoritative hosts; localhost
      # proxy needs an explicit api_key. ${...} is expanded by load_config().
      api_key: "${OPENROUTER_API_KEY}"

    platforms:
      telegram:
        enabled: true
        observe_unmentioned_group_messages: #{observe_unmentioned}

    streaming:
      enabled: true
      transport: edit
      edit_interval: 0.6
      buffer_threshold: 60

    stt:
      enabled: true
      provider: "openai"
      cloud_trim_silence: false
      openai:
        # Ignored: the proxy sends audio to ruoc, which picks the model.
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
    #{@compression_block}
    memory:
      provider: builtin
      memory_enabled: true
      user_profile_enabled: true
      memory_char_limit: 2200
      user_char_limit: 1375

    quick_commands:
      start:
        type: alias
        target: new

    # Web search via druzhok /v2/search (perplexity/sonar). Hermes 0.17 gates
    # web search behind this bundled plugin; FIRECRAWL_API_URL/KEY are set in
    # env_vars/1. sync_plugins_enabled/1 keeps existing bots in sync.
    plugins:
      enabled:
      - web/firecrawl

    group_sessions_per_user: #{group_sessions_per_user}

    gateway:
      systemd_watchdog_seconds: #{@systemd_watchdog_seconds}
    """
  end
end
