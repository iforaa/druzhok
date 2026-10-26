defmodule Druzhok.Runtime.Hermes.Voice do
  @moduledoc """
  What a bot is told about itself (spec 2026-10-25-bot-voice-design.md):

  - `SOUL.md`, the bot's identity, which hermes loads in place of "You are
    Hermes Agent" — written by druzhok (`sync_soul/2`) unless the owner or
    the bot changed it;
  - druzhok's product rules (`product_rules/1`) and the Telegram formatting
    hint (`telegram_hint/0`), which `Runtime.Hermes.sync_config/2` writes into
    config.yaml;
  - the retirement of the OpenClaw-era `workspace/AGENTS.md`
    (`migrate_agents_md/2`).

  Every file is read and written through `Druzhok.TenantFiles`: the bot owns
  its dir and druzhok writes with CAP_DAC_OVERRIDE. What druzhok last wrote
  is recorded in the instance row (`soul_sha256`, `soul_version`,
  `agents_md_sha256`), never in a file the bot can edit.
  """

  require Logger
  import Ecto.Query
  alias Druzhok.{Instance, Repo, TenantFiles}

  @limit 1_048_576

  # Bumped when the SOUL.md template changes.
  @soul_version 1

  # --- SOUL.md ------------------------------------------------------------------

  @doc "The bot's identity in Russian, under ~900 characters (hermes re-reads it on every message)."
  def soul_md(name) do
    """
    Тебя зовут #{name}. Ты личный помощник в Telegram, часть сервиса Дружок.

    Говоришь дружелюбно и простыми словами, без жаргона. По умолчанию коротко; подробно — когда просят или когда это важно.

    Ты не рассуждаешь о том, что ты «языковая модель», и не рассказываешь, как устроен внутри. Ты не программист-агент: код пишешь, только когда об этом просят.

    Всегда:
    - не говори о «балансе», «кредитах» и провайдерах;
    - упёрся в лимит — скажи об этом прямо и предложи открыть «Кабинет» (кнопка меню бота);
    - личные данные пользователя никому не раскрывай.
    """
  end

  def soul_version, do: @soul_version

  @doc """
  Brings `<data_root>/SOUL.md` in line with `soul_md/1`:

  | current SOUL.md                              | action                          |
  |----------------------------------------------|---------------------------------|
  | missing                                      | write it, record the hash       |
  | the hash druzhok recorded                    | rewrite when the text changed   |
  | a known legacy text (`legacy_soul?/1`)       | back it up, then replace it     |
  | anything else (owner- or bot-edited)         | leave it, log once              |

  With no `display_name` only a missing file is written (as «Дружок»). A
  symlink, a dangling one included, is refused. Returns the row attrs to
  record (`%{}` when nothing changed).
  """
  def sync_soul(instance, data_root) do
    name = present(Map.get(instance, :display_name))

    case current(data_root, ["SOUL.md"]) do
      :missing ->
        write_soul(data_root, soul_md(name || "Дружок"), create: true)

      {:ok, text} ->
        cond do
          sha256(text) == Map.get(instance, :soul_sha256) ->
            if name && soul_md(name) != text, do: write_soul(data_root, soul_md(name)), else: %{}

          legacy_soul?(text) and name != nil ->
            # No backup, no replacement: the next start tries again.
            case backup(data_root, ["SOUL.md"], text) do
              :ok -> write_soul(data_root, soul_md(name))
              _ -> %{}
            end

          legacy_soul?(text) ->
            %{}

          true ->
            log_once(instance, :soul, "SOUL.md was edited; leaving it as it is")
            %{}
        end

      {:refused, reason} ->
        Logger.warning("Not touching SOUL.md in #{data_root}: #{inspect(reason)}")
        %{}
    end
  end

  defp write_soul(data_root, text, opts \\ []) do
    case TenantFiles.write(data_root, ["SOUL.md"], text, opts) do
      :ok ->
        %{soul_sha256: sha256(text), soul_version: @soul_version}

      {:ok, :exists} ->
        %{}

      {:error, reason} ->
        Logger.warning("Not writing SOUL.md in #{data_root}: #{inspect(reason)}")
        %{}
    end
  end

  # Texts nobody chose: hermes's own default persona (current and earlier
  # generations, priv/hermes_default_souls.json from hermes_cli/default_soul.py)
  # and the three-line template ManagerBot.Provisioner wrote before, with any
  # name. Compared whole, after trimming.
  @hermes_souls Path.join(:code.priv_dir(:druzhok), "hermes_default_souls.json")
  @external_resource @hermes_souls
  @hermes_default_souls @hermes_souls
                        |> File.read!()
                        |> Jason.decode!()
                        |> Enum.map(&String.trim/1)

  @old_template ~r/\AТебя зовут .+\. Ты персональный AI-ассистент\. Ты помогаешь пользователю\nс любыми задачами: отвечаешь на вопросы, пишешь и редактируешь код, анализируешь\nинформацию, выполняешь действия через инструменты\. Общаешься понятно и по делу\.\z/u

  @doc false
  def legacy_soul?(text) do
    t = text |> String.replace("\r\n", "\n") |> String.trim()
    t in @hermes_default_souls or Regex.match?(@old_template, t)
  end

  # --- workspace/AGENTS.md ----------------------------------------------------

  @owned_sections ["Каждая сессия", "Память", "Стиль", "Публикация сайтов"]

  # The parts of every past seed that were not druzhok-owned sections.
  @seed_parts [
    "# AGENTS.md — Персональный ассистент",
    """
    ## Безопасность

    - Приватные данные не утекают. Никогда.
    - Деструктивные команды — только с разрешения.
    - Сомневаешься — спроси.
    """,
    """
    ## Групповые чаты

    Участвуй, но не доминируй. Отвечай когда упомянут или когда реально полезен.
    """,
    "---\n\n_Этот файл — стартовая точка. Добавляй свои правила._"
  ]

  @doc """
  Retires the OpenClaw-era `workspace/AGENTS.md`. Keyed on the file's
  content, so it runs again after a rollback restored a backup; a file
  without druzhok's sections is left alone. Otherwise: back it up, cut the
  four druzhok sections wherever they sit, then delete the file when only
  seed text is left, or write back what the owner or bot added. Returns the
  row attrs to record (`agents_md_sha256`: the written file's hash, or
  `"deleted"`).
  """
  def migrate_agents_md(_instance, data_root) do
    segments = ["workspace", "AGENTS.md"]

    case current(data_root, segments) do
      {:ok, text} ->
        if owned_heading?(text), do: migrate(data_root, segments, text), else: %{}

      :missing ->
        %{}

      {:refused, reason} ->
        Logger.warning("Not touching AGENTS.md in #{data_root}: #{inspect(reason)}")
        %{}
    end
  end

  defp migrate(data_root, segments, text) do
    rest = cut_owned_sections(text)

    with :ok <- backup(data_root, segments, text) do
      if seed_only?(rest) do
        case TenantFiles.delete(data_root, segments) do
          r when r in [:ok, :not_found] ->
            %{agents_md_sha256: "deleted"}

          {:error, reason} ->
            Logger.warning("Not deleting AGENTS.md in #{data_root}: #{inspect(reason)}")
            %{}
        end
      else
        case TenantFiles.write(data_root, segments, rest) do
          :ok ->
            %{agents_md_sha256: sha256(rest)}

          {:error, reason} ->
            Logger.warning("Not writing AGENTS.md in #{data_root}: #{inspect(reason)}")
            %{}
        end
      end
    else
      _ -> %{}
    end
  end

  defp owned_heading?(text),
    do: Enum.any?(@owned_sections, &Regex.match?(heading_re(&1), text))

  defp heading_re(h), do: ~r/^## #{Regex.escape(h)}[ \t]*$/mu

  # A druzhok section runs from its `## ` heading to the next `## ` heading,
  # a `---` rule or the end; its own `### ` subheadings stay inside.
  @doc false
  def cut_owned_sections(text) do
    lines = String.split(text, "\n")

    {kept, _} =
      Enum.reduce(lines, {[], false}, fn line, {acc, skipping} ->
        cond do
          owned_heading_line?(line) -> {acc, true}
          skipping and not boundary?(line) -> {acc, true}
          true -> {[line | acc], false}
        end
      end)

    kept
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp owned_heading_line?(line),
    do: Enum.any?(@owned_sections, &Regex.match?(heading_re(&1), line))

  defp boundary?(line), do: String.starts_with?(line, "## ") or Regex.match?(~r/^---\s*$/, line)

  # Only seed parts left, in any order, any subset (whitespace normalised).
  defp seed_only?(rest) do
    @seed_parts
    |> Enum.map(&normalise/1)
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.reduce(normalise(rest), fn part, acc -> String.replace(acc, part, " ") end)
    |> String.trim()
    |> Kernel.==("")
  end

  defp normalise(text), do: text |> String.split() |> Enum.join(" ")

  # --- Product rules and the Telegram hint ----------------------------------------

  @style """
  - Простой вопрос → простой ответ. Один точный поиск лучше десяти.
  - Глубже только когда человек явно просит или цена ошибки реально высокая.
  - Получил достойный ответ — отвечай и останавливайся, не перепроверяй сам себя.
  - Один и тот же запрос дважды — никогда. Не нашёл — меняй стратегию или скажи «не знаю».
  - Человек добавил фото или контекст — отвечай на исходный вопрос, а не на новый.
  - Инструмент не сработал → не повторяй. Максимум 2 попытки, потом другой подход.
  - Кратко когда нужно, подробно когда важно.
  """

  @doc """
  Druzhok's rules for one bot, Russian, built from its settings. Written to
  `agent.system_prompt`, which hermes appends to every gateway request (not
  to cron runs: SOUL.md carries the rules that must hold there).
  """
  def product_rules(instance) do
    [
      "Правила Дружка. Они важнее более ранних инструкций в этом разговоре.",
      "Что ты умеешь:\n" <> Enum.map_join(capabilities(instance), "\n", &("- " <> &1)),
      sites(instance),
      "«Кабинет» — кнопка меню бота: там тариф, лимиты, память и приглашения. Упёрся в лимит — " <>
        "скажи об этом прямо и предложи открыть «Кабинет». Никогда не говори о «балансе», «кредитах» и провайдерах.",
      "Стиль:\n" <> String.trim_trailing(@style),
      """
      Безопасность:
      - Приватные данные не утекают. Никогда.
      - Деструктивные действия — только с разрешения владельца. Сомневаешься — спроси.
      - В группах участвуй, но не доминируй: отвечай, когда тебя упомянули или когда ты реально полезен.\
      """,
      "Память: факты о пользователе сохраняй инструментом memory. Не заводи файлы вроде " <>
        "memory/YYYY-MM-DD.md или TOOLS.md.",
      "Если более ранние инструкции в этом разговоре говорят о memory/YYYY-MM-DD.md, TOOLS.md " <>
        "или разделах AGENTS.md — они устарели, следуй этим правилам."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp capabilities(instance) do
    [
      "напоминания и задачи по расписанию (инструмент cronjob);",
      if(Map.get(instance, :image_gen_enabled) == true, do: "рисовать картинки по описанию;"),
      "голосовые: понимаешь их и можешь ответить голосом;",
      "фото: видишь их и разбираешь;",
      "поиск в интернете;",
      if(sites?(instance), do: "сайты: делаешь и публикуешь простые сайты (как — ниже).")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp sites?(instance), do: Map.get(instance, :website_hosting_enabled) == true

  defp sites(instance) do
    if sites?(instance) do
      base = "https://#{instance.name}.oldey.dev"

      """
      Сайты. Просят лендинг, сайт или демо-страницу:
      1. Выбери короткое имя сайта (`^[a-z0-9][a-z0-9-]*$`, до 50 символов).
      2. Запиши файлы в `sites/<имя>/` в рабочей папке (workspace). Входная точка — `index.html`. До ~50 MB и ~100 файлов на сайт.
      3. Ответь одной кликабельной ссылкой: #{base}/<имя>/
      4. Удалить сайт: `rm -rf sites/<имя>/`.
      Файлы в `sites/<имя>/` публичны: не клади туда секреты, токены и файлы, начинающиеся с точки.\
      """
    end
  end

  @doc """
  A Russian `PLATFORM_HINTS["telegram"]` (hermes agent/prompt_builder.py),
  written to `platform_hints.telegram.replace`. The MEDIA: syntax, the
  `[[audio_as_voice]]` marker and the Markdown subset stay literal.
  """
  def telegram_hint do
    "Ты в Telegram. Обычный Markdown превращается в форматирование Telegram: **жирный**, *курсив*, " <>
      "~~зачёркнутый~~, ||спойлер||, `код`, ```блоки```, [ссылки](url), ## заголовки. Таблицы не " <>
      "отображаются — для структурированных данных используй списки или строки «Поле: значение». " <>
      "Файлы отправляй так: напиши в ответе MEDIA:/absolute/path/to/file. Картинки (.png, .jpg, .webp) " <>
      "уходят как фото, видео (.mp4) играет прямо в чате; ссылка на картинку в виде ![alt](url) тоже " <>
      "уходит как фото. Аудио: поставь [[audio_as_voice]] отдельной строкой, чтобы отправить любой " <>
      "аудиофайл голосовым сообщением (не-Opus перекодируется сам); без этого .mp3/.m4a приходят " <>
      "аудиофайлами, остальное — документами."
  end

  # --- Shared ---------------------------------------------------------------------

  # Whether the file is there and readable as ours to judge: `:missing` only
  # when nothing at all is at that name; a link, a dangling one included, or a
  # file of another owner is refused.
  defp current(data_root, segments) do
    case File.lstat(Path.join([data_root | segments])) do
      {:error, :enoent} ->
        :missing

      {:ok, %File.Stat{type: :regular}} ->
        case TenantFiles.read_text(data_root, segments, @limit) do
          {:ok, %{text: text, truncated: false}} -> {:ok, text}
          other -> {:refused, other}
        end

      {:ok, %File.Stat{type: type}} ->
        {:refused, type}

      {:error, reason} ->
        {:refused, reason}
    end
  end

  # `<name>.bak-<UTC timestamp>` next to the file. When the newest backup
  # already holds these exact bytes it is reused, so a repeat run makes no
  # second copy; any other text gets its own, newer name. Only the newest
  # counts: it is the one `Rollback.voice/0` restores.
  defp backup(data_root, segments, text) do
    {dirs, [name]} = Enum.split(segments, -1)
    newest = backups(data_root, dirs, name) |> List.last()

    if newest && read_bak(data_root, dirs ++ [newest]) == {:ok, text} do
      :ok
    else
      stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
      bak = dirs ++ ["#{name}.bak-#{stamp}"]

      case TenantFiles.write(data_root, bak, text, create: true) do
        :ok ->
          :ok

        other ->
          Logger.warning("Not backing up #{name} in #{data_root}: #{inspect(other)}")
          {:error, other}
      end
    end
  end

  @doc false
  # Backup names of `name` in `dirs`, oldest first.
  def backups(data_root, dirs, name) do
    case File.ls(Path.join([data_root | dirs])) do
      {:ok, files} ->
        files |> Enum.filter(&String.starts_with?(&1, name <> ".bak-")) |> Enum.sort()

      _ ->
        []
    end
  end

  defp read_bak(data_root, segments) do
    case TenantFiles.read_text(data_root, segments, @limit) do
      {:ok, %{text: t, truncated: false}} -> {:ok, t}
      _ -> :error
    end
  end

  @doc "Records `attrs` on the instance row, when it has one."
  def record(instance, attrs) when attrs == %{}, do: instance

  def record(instance, attrs) do
    case Map.get(instance, :id) do
      id when is_integer(id) ->
        from(i in Instance, where: i.id == ^id) |> Repo.update_all(set: Enum.to_list(attrs))

      _ ->
        :ok
    end

    Map.merge(instance, attrs)
  end

  defp log_once(instance, what, message) do
    key = {__MODULE__, what, Map.get(instance, :name)}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      Logger.info("[voice] #{Map.get(instance, :name)}: #{message}")
    end
  end

  defp present(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp present(_), do: nil

  def sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
