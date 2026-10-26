defmodule Druzhok.Runtime.Hermes.VoiceTest do
  # async: false — the rollback test walks every instance row.
  use ExUnit.Case, async: false

  alias Druzhok.Runtime.Hermes
  alias Druzhok.Runtime.Hermes.{Rollback, Voice}

  @hermes_default "You are Hermes Agent, built by Nous Research. Be direct: match the length of your reply to the weight of the ask — a one-line question gets a one-line answer, and finished work gets a short report of what changed, what's verified, and what's left, never a replay of the process. No filler (\"Great question,\" \"I'd be happy to\"), no restating the request back, no re-summarizing what you already said, no narrating tool calls the user can see. Plain claims over adjectives; when unsure, say so plainly. Agree because it's right, not because the user said it. Depth is earned — give it when the user asks for detail, teaches, or the stakes demand it, not by default."

  defp old_template(name) do
    String.trim("""
    Тебя зовут #{name}. Ты персональный AI-ассистент. Ты помогаешь пользователю
    с любыми задачами: отвечаешь на вопросы, пишешь и редактируешь код, анализируешь
    информацию, выполняешь действия через инструменты. Общаешься понятно и по делу.
    """)
  end

  # The seed as prod bots have it: druzhok's sections spliced in, the footer
  # eaten by the old section sync.
  @spliced_seed """
  # AGENTS.md — Персональный ассистент

  ## Каждая сессия

  _Эта секция перезаписывается druzhok при каждом старте бота. Не правь руками._

  Не спрашивай разрешения. Просто делай.

  ## Память

  - **Ежедневные заметки:** `memory/YYYY-MM-DD.md`

  ### Записывай — никаких мысленных заметок!

  - Выучил урок → обнови AGENTS.md или TOOLS.md

  ## Безопасность

  - Приватные данные не утекают. Никогда.
  - Деструктивные команды — только с разрешения.
  - Сомневаешься — спроси.

  ## Групповые чаты

  Участвуй, но не доминируй. Отвечай когда упомянут или когда реально полезен.

  ## Стиль

  - Простой вопрос → простой ответ.

  ## Публикация сайтов

  1. Проверь переменную окружения `BOT_SITE_BASE_URL`.
  """

  setup do
    root = Path.join(System.tmp_dir!(), "voice-#{System.unique_integer([:positive])}")
    home = Path.join(root, "bot")
    File.mkdir_p!(Path.join(home, "workspace"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{home: home}
  end

  defp soul(home), do: File.read!(Path.join(home, "SOUL.md"))
  defp put_soul(home, text), do: File.write!(Path.join(home, "SOUL.md"), text)
  defp agents(home), do: Path.join([home, "workspace", "AGENTS.md"])

  defp baks(dir, name),
    do: dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, name <> ".bak-"))

  describe "sync_soul/2" do
    test "a missing SOUL.md is written with the name and its hash returned", %{home: home} do
      attrs = Voice.sync_soul(%{display_name: "Вася"}, home)
      assert soul(home) =~ "Тебя зовут Вася."
      assert attrs == %{soul_sha256: Voice.sha256(soul(home)), soul_version: Voice.soul_version()}
    end

    test "with no name, a missing SOUL.md is «Дружок»; the slug is never the name", %{home: home} do
      Voice.sync_soul(%{name: "vasya_8b05", display_name: nil}, home)
      assert soul(home) =~ "Тебя зовут Дружок."
      refute soul(home) =~ "vasya"
    end

    test "druzhok's own text is rewritten when the name changes, and left when it does not", %{
      home: home
    } do
      %{soul_sha256: sha} = Voice.sync_soul(%{display_name: "Вася"}, home)
      assert Voice.sync_soul(%{display_name: "Вася", soul_sha256: sha}, home) == %{}

      %{soul_sha256: sha2} = Voice.sync_soul(%{display_name: "Василий", soul_sha256: sha}, home)
      assert soul(home) =~ "Тебя зовут Василий."
      assert sha2 == Voice.sha256(soul(home))
      assert baks(home, "SOUL.md") == []
    end

    for {label, text} <- [
          {"hermes's default", @hermes_default},
          {"the old template, one name", "OLD:Джарвис"},
          {"the old template, another name", "OLD:Medical Assistant"}
        ] do
      test "a legacy text is backed up once and replaced: #{label}", %{home: home} do
        legacy =
          case unquote(text) do
            "OLD:" <> name -> old_template(name)
            t -> t
          end

        put_soul(home, legacy)
        assert %{soul_sha256: sha} = Voice.sync_soul(%{display_name: "Вася"}, home)
        assert soul(home) =~ "Тебя зовут Вася."
        assert [bak] = baks(home, "SOUL.md")
        assert File.read!(Path.join(home, bak)) == legacy

        # Idempotent: a second run changes nothing and makes no second copy.
        assert Voice.sync_soul(%{display_name: "Вася", soul_sha256: sha}, home) == %{}
        assert length(baks(home, "SOUL.md")) == 1
      end
    end

    test "a legacy text is not replaced when its backup cannot be written", %{home: home} do
      put_soul(home, @hermes_default)
      # No staging dir can be made: every TenantFiles write fails.
      File.write!(Path.join(Path.dirname(home), ".druzhok-staging"), "")
      assert Voice.sync_soul(%{display_name: "Вася"}, home) == %{}
      assert soul(home) == @hermes_default
    end

    test "a legacy text is kept while the name is unknown", %{home: home} do
      put_soul(home, @hermes_default)
      assert Voice.sync_soul(%{display_name: nil}, home) == %{}
      assert soul(home) == @hermes_default
    end

    test "an edited SOUL.md is left alone", %{home: home} do
      put_soul(home, "Ты — кот Вася. Мурлычешь.")

      assert Voice.sync_soul(%{name: "edited", display_name: "Вася", soul_sha256: "other"}, home) ==
               %{}

      assert soul(home) == "Ты — кот Вася. Мурлычешь."
    end

    test "a symlink and a dangling symlink are refused, never followed", %{home: home} do
      target = Path.join(Path.dirname(home), "outside.md")
      File.write!(target, "host file")
      File.ln_s!(target, Path.join(home, "SOUL.md"))
      assert Voice.sync_soul(%{display_name: "Вася"}, home) == %{}
      assert File.read!(target) == "host file"

      File.rm!(Path.join(home, "SOUL.md"))
      dangling = Path.join(Path.dirname(home), "nowhere.md")
      File.ln_s!(dangling, Path.join(home, "SOUL.md"))
      assert Voice.sync_soul(%{display_name: "Вася"}, home) == %{}
      refute File.exists?(dangling)
    end

    test "the persona stays short (hermes re-reads it on every message)" do
      assert String.length(Voice.soul_md("Медицинский Ассистент")) < 900
    end
  end

  describe "product_rules/1 and the config keys" do
    test "capability lines follow the settings" do
      plain = Voice.product_rules(%{name: "b"})
      refute plain =~ "картинки"
      refute plain =~ "Сайты"

      full =
        Voice.product_rules(%{name: "b", image_gen_enabled: true, website_hosting_enabled: true})

      assert full =~ "рисовать картинки"
      assert full =~ "https://b.oldey.dev/<имя>/"
      assert full =~ "«Кабинет»"
      assert full =~ "устарели"
    end

    defp sync(home, inst) do
      :ok = Hermes.sync_config(Map.merge(%{name: "b", model: "x", tenant_key: "k"}, inst), home)
      File.read!(Path.join(home, "config.yaml"))
    end

    test "agent.system_prompt and the Telegram hint are one double-quoted line each, idempotent",
         %{home: home} do
      File.write!(Path.join(home, "config.yaml"), "model:\n  default: \"x\"\n")
      first = sync(home, %{})
      assert [_] = Regex.scan(~r/^  system_prompt: ".*"$/m, first)
      assert [_] = Regex.scan(~r/^    replace: ".*"$/m, first)

      cfg = YamlElixir.read_from_string!(first)
      assert cfg["agent"]["system_prompt"] == Voice.product_rules(%{name: "b"})
      assert cfg["platform_hints"]["telegram"]["replace"] == Voice.telegram_hint()
      assert cfg["platform_hints"]["telegram"]["replace"] =~ "MEDIA:/absolute/path/to/file"
      assert cfg["platform_hints"]["telegram"]["replace"] =~ "[[audio_as_voice]]"

      assert sync(home, %{}) == first
    end

    test "a changed prompt leaves no old lines behind", %{home: home} do
      File.write!(Path.join(home, "config.yaml"), "model:\n  default: \"x\"\n")
      sync(home, %{})
      changed = sync(home, %{image_gen_enabled: true})
      assert [_] = Regex.scan(~r/system_prompt:/, changed)
      assert YamlElixir.read_from_string!(changed)["agent"]["system_prompt"] =~ "картинки"
    end

    test "a block-scalar prompt hermes re-dumped, followed by other agent keys, is cleaned up", %{
      home: home
    } do
      File.write!(Path.join(home, "config.yaml"), """
      model:
        default: "x"
      agent:
        system_prompt: |-
          old rules

          second paragraph
        gateway_timeout: 1800
      display:
        personality: kawaii
        memory_notifications: off
      platform_hints:
        telegram:
          append: keep me
      """)

      content = sync(home, %{})
      cfg = YamlElixir.read_from_string!(content)
      assert [_] = Regex.scan(~r/system_prompt:/, content)
      refute content =~ "old rules"
      refute content =~ "second paragraph"
      assert cfg["agent"]["gateway_timeout"] == 1800
      assert cfg["agent"]["system_prompt"] == Voice.product_rules(%{name: "b"})
      refute Map.has_key?(cfg["display"], "personality")
      assert cfg["platform_hints"]["telegram"]["append"] == "keep me"
      assert [_] = Regex.scan(~r/^agent:/m, content)

      # Rollback's strip takes only what druzhok wrote.
      stripped = YamlElixir.read_from_string!(Hermes.strip_voice_keys(content))
      assert stripped["platform_hints"]["telegram"] == %{"append" => "keep me"}
      refute Map.has_key?(stripped["agent"], "system_prompt")
    end
  end

  describe "migrate_agents_md/2" do
    test "a seed with druzhok's sections spliced in is deleted, its backup kept", %{home: home} do
      File.write!(
        agents(home),
        @spliced_seed <>
          "\n---\n\n_Этот файл — стартовая точка. Добавляй свои правила._\n\n## Стиль\n\n- x\n"
      )

      assert Voice.migrate_agents_md(%{}, home) == %{agents_md_sha256: "deleted"}
      refute File.exists?(agents(home))
      assert [bak] = baks(Path.join(home, "workspace"), "AGENTS.md")
      assert File.read!(Path.join([home, "workspace", bak])) =~ "## Каждая сессия"
    end

    test "an owner's own section stays byte for byte; only druzhok's four go", %{home: home} do
      own = "## Мои правила\n\n- Называй меня Игорь.\n  - и на «ты».\n"
      File.write!(agents(home), @spliced_seed <> "\n" <> own)

      %{agents_md_sha256: sha} = Voice.migrate_agents_md(%{}, home)
      rest = File.read!(agents(home))
      assert sha == Voice.sha256(rest)
      assert rest =~ own
      assert rest =~ "## Безопасность"

      for h <- [
            "## Каждая сессия",
            "## Память",
            "### Записывай",
            "## Стиль",
            "## Публикация сайтов"
          ],
          do: refute(rest =~ h)
    end

    test "a file without druzhok's headings is left alone", %{home: home} do
      File.write!(agents(home), "# Мой проект\n\n## Сборка\n\nmake\n")
      assert Voice.migrate_agents_md(%{}, home) == %{}
      assert File.read!(agents(home)) == "# Мой проект\n\n## Сборка\n\nmake\n"
      assert baks(Path.join(home, "workspace"), "AGENTS.md") == []
    end

    test "a second migration of different text keeps both backups", %{home: home} do
      ws = Path.join(home, "workspace")
      File.write!(agents(home), @spliced_seed <> "\n## Своё\n\nа\n")
      Voice.migrate_agents_md(%{}, home)
      # Same bytes again (a rollback restored the backup): no new copy.
      File.write!(agents(home), @spliced_seed <> "\n## Своё\n\nа\n")
      Voice.migrate_agents_md(%{}, home)
      assert length(baks(ws, "AGENTS.md")) == 1

      Process.sleep(1100)
      File.write!(agents(home), @spliced_seed <> "\n## Своё\n\nа\n\n## Новое\n\nб\n")
      Voice.migrate_agents_md(%{}, home)
      assert [_, newest] = Voice.backups(home, ["workspace"], "AGENTS.md")
      assert File.read!(Path.join(ws, newest)) =~ "## Новое"

      # Back to the first text: an older backup holds it, but only the newest
      # counts, so it is copied again as the newest.
      Process.sleep(1100)
      File.write!(agents(home), @spliced_seed <> "\n## Своё\n\nа\n")
      Voice.migrate_agents_md(%{}, home)
      assert [_, _, newest] = Voice.backups(home, ["workspace"], "AGENTS.md")
      refute File.read!(Path.join(ws, newest)) =~ "## Новое"
    end

    test "a missing AGENTS.md is a no-op", %{home: home} do
      assert Voice.migrate_agents_md(%{}, home) == %{}
    end
  end

  describe "Rollback.voice/0" do
    setup %{home: home} do
      root = Path.dirname(home)
      name = "voice#{System.unique_integer([:positive])}"
      bot = Path.join(root, name)
      File.mkdir_p!(Path.join(bot, "workspace"))

      inst =
        Druzhok.Repo.insert!(%Druzhok.Instance{
          name: name,
          model: "x",
          tenant_key: "k",
          telegram_token: "voice-#{name}",
          workspace: Path.join(bot, "workspace"),
          display_name: "Вася"
        })

      on_exit(fn -> Druzhok.Repo.delete(inst) end)
      %{inst: inst, bot: bot}
    end

    defp start(inst, bot) do
      :ok = Hermes.sync_config(Druzhok.Repo.reload!(inst), bot)
      Druzhok.Repo.reload!(inst)
    end

    test "migrate → rollback → migrate ends migrated; edits after the migration are kept", %{
      inst: inst,
      bot: bot
    } do
      File.write!(Path.join(bot, "config.yaml"), "model:\n  default: \"x\"\n")
      File.write!(Path.join(bot, "SOUL.md"), @hermes_default)
      File.write!(agents(bot), @spliced_seed)

      row = start(inst, bot)
      assert row.agents_md_sha256 == "deleted"
      assert row.soul_sha256 == Voice.sha256(soul(bot))

      assert %{config: :ok, soul: :ok, agents_md: :ok} =
               Rollback.voice() |> List.keyfind(inst.name, 0) |> elem(1)

      assert soul(bot) == @hermes_default
      assert File.read!(agents(bot)) == @spliced_seed
      cfg = YamlElixir.read_from_string!(File.read!(Path.join(bot, "config.yaml")))
      refute Map.has_key?(cfg["agent"] || %{}, "system_prompt")
      refute Map.has_key?(cfg["platform_hints"] || %{}, "telegram")

      row = start(inst, bot)
      assert soul(bot) =~ "Тебя зовут Вася."
      refute File.exists?(agents(bot))

      # The owner edits the persona; a rollback now keeps the edit.
      File.write!(Path.join(bot, "SOUL.md"), "моё")
      assert %{soul: :edited} = Rollback.voice() |> List.keyfind(row.name, 0) |> elem(1)
      assert soul(bot) == "моё"
    end
  end
end
