defmodule Druzhok.Runtime.Hermes.LocaleTest do
  use ExUnit.Case, async: true

  alias Druzhok.Runtime.Hermes.Locale

  setup do
    tmp = Path.join(System.tmp_dir!(), "hermes-locale-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp parse!(text), do: YamlElixir.read_from_string!(text)

  describe "render/2" do
    test "every override comes back as written, with the bot's name put in" do
      for lang <- Locale.languages() do
        parsed = parse!(Locale.render(lang, "Кот Вася"))

        expected =
          Map.new(Locale.overrides(lang), fn {k, v} ->
            {k, String.replace(v, "%{bot_name}", "Кот Вася")}
          end)

        assert parsed == expected
      end
    end

    test "a hostile name still parses, and braces cannot reach str.format" do
      for name <- [
            ~s(Bot "q" \\ x),
            "{x}",
            "}{",
            "* star",
            "[list",
            "- dash",
            "a: b",
            "# hash",
            "Ёж\n2"
          ] do
        parsed = parse!(Locale.render("ru", name))
        title = parsed["gateway.progress.task_card_title"]
        refute title =~ "{"
        refute title =~ "}"
        assert String.ends_with?(title, " работает")
      end
    end

    test "characters YAML forbids are dropped from the name" do
      text = Locale.render("ru", "a\x7Fb\u0090c￾d")
      refute text =~ ~r/[\x{7F}\x{90}\x{FFFE}]/u
      assert parse!(text)["gateway.progress.task_card_title"] =~ "abcd"
    end

    test "no name falls back to Дружок" do
      assert parse!(Locale.render("ru", nil))["gateway.start.greeting"] =~ "Я Дружок."
      assert parse!(Locale.render("ru", "  "))["gateway.start.greeting"] =~ "Я Дружок."
    end

    test "starts with the marker line" do
      assert Locale.render("en", "x") =~ ~r/\A# druzhok-owned: /
    end
  end

  describe "sync/2 and remove/1" do
    test "writes both languages, and leaves an unchanged file alone", %{tmp: tmp} do
      assert :ok = Locale.sync(%{display_name: "Вася"}, tmp)
      path = Path.join([tmp, "locales", "ru.yaml"])
      assert File.read!(path) == Locale.render("ru", "Вася")
      assert File.read!(Path.join([tmp, "locales", "en.yaml"])) == Locale.render("en", "Вася")

      File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
      assert :ok = Locale.sync(%{display_name: "Вася"}, tmp)
      assert File.stat!(path).mtime == {{2000, 1, 1}, {0, 0, 0}}

      assert :ok = Locale.sync(%{display_name: "Петя"}, tmp)
      assert File.read!(path) =~ "Петя"
    end

    test "refuses a symlinked locales dir", %{tmp: tmp} do
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(outside)
      tenant = Path.join(tmp, "tenant")
      File.mkdir_p!(tenant)
      File.ln_s!(outside, Path.join(tenant, "locales"))

      assert :ok = Locale.sync(%{display_name: "x"}, tenant)
      assert File.ls!(outside) == []
    end

    test "remove/1 deletes only druzhok's files", %{tmp: tmp} do
      assert :ok = Locale.sync(%{display_name: "x"}, tmp)
      File.write!(Path.join([tmp, "locales", "en.yaml"]), "gateway:\n  help:\n    header: mine\n")

      assert :ok = Locale.remove(tmp)
      refute File.exists?(Path.join([tmp, "locales", "ru.yaml"]))
      assert File.read!(Path.join([tmp, "locales", "en.yaml"])) =~ "mine"
    end
  end

  # Against hermes's own catalogs in the local clone (hermes-agent/, gitignored):
  # skipped where it is absent. The update-hermes skill runs it on every new tag.
  describe "audit against hermes's catalog" do
    @catalogs Path.expand("../../../../../../hermes-agent/locales", __DIR__)
    @roots ["gateway.", "explainer.", "approval.", "platform.telegram."]
    @slash ~w(new stop voice help start whoami) |> Enum.map(&"slash.#{&1}.description")
    @leak ~r/Hermes|hermes |config\.yaml|doctor|\/login|\/model|\/retry|\/compress|\/reset|\/resume|\/commands|\/busy|\/approve|провайдер|TTS|state\.db/u

    defp catalog(lang) do
      path = Path.join(@catalogs, lang <> ".yaml")
      if File.exists?(path), do: path |> YamlElixir.read_from_file!() |> flatten(""), else: nil
    end

    defp flatten(map, prefix) when is_map(map) do
      Enum.reduce(map, %{}, fn {k, v}, acc ->
        key = if prefix == "", do: to_string(k), else: prefix <> "." <> to_string(k)
        Map.merge(acc, flatten(v, key))
      end)
    end

    defp flatten(v, key) when is_binary(v), do: %{key => v}
    defp flatten(_, _), do: %{}

    defp placeholders(text) do
      text
      |> String.replace(["{{", "}}"], "")
      |> then(&Regex.scan(~r/\{([A-Za-z_][A-Za-z0-9_]*)[^{}]*\}/, &1, capture: :all_but_first))
      |> List.flatten()
      |> MapSet.new()
    end

    defp reviewed do
      Path.join([:code.priv_dir(:druzhok), "hermes_locale", "reviewed.txt"])
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(fn line ->
        [key, reason] = String.split(line, "\t", parts: 2)
        {key, reason}
      end)
    end

    defp covered_by(key, reviewed) do
      Enum.find(reviewed, fn {pattern, _} ->
        if String.ends_with?(pattern, "*"),
          do: String.starts_with?(key, String.trim_trailing(pattern, "*")),
          else: key == pattern
      end)
    end

    for lang <- ~w(ru en) do
      @lang lang

      test "#{lang}: every override exists in hermes's catalog, with no new placeholders" do
        case catalog(@lang) do
          nil ->
            :ok

          bundled ->
            rendered = parse!(Locale.render(@lang, "Name"))

            for {key, text} <- rendered do
              assert Map.has_key?(bundled, key), "#{key} is not in hermes's #{@lang}.yaml"

              extra = MapSet.difference(placeholders(text), placeholders(bundled[key]))
              assert MapSet.size(extra) == 0, "#{key} adds #{inspect(MapSet.to_list(extra))}"
            end
        end
      end

      test "#{lang}: no override says Hermes, a config key, a CLI command or a denied command" do
        for {key, text} <- Locale.overrides(@lang) do
          refute text =~ @leak, "#{key}: #{text}"
        end
      end
    end

    test "every key under the audited roots is overridden or reviewed" do
      case catalog("ru") do
        nil ->
          :ok

        bundled ->
          overridden = Locale.overrides("ru")
          reviewed = reviewed()

          missing =
            for key <- Map.keys(bundled),
                Enum.any?(@roots, &String.starts_with?(key, &1)) or key in @slash,
                not Map.has_key?(overridden, key),
                covered_by(key, reviewed) == nil,
                do: key

          assert missing == [],
                 "neither overridden nor in reviewed.txt: #{inspect(Enum.sort(missing))}"

          for key <- @slash, do: assert(Map.has_key?(overridden, key))
      end
    end

    test "nothing marked clean still leaks" do
      case catalog("ru") do
        nil ->
          :ok

        bundled ->
          reviewed = reviewed()
          overridden = Locale.overrides("ru")

          leaks =
            for {key, text} <- bundled,
                not Map.has_key?(overridden, key),
                match?({_, "clean" <> _}, covered_by(key, reviewed)),
                text =~ @leak,
                do: key

          assert leaks == []
      end
    end

    test "ru and en override the same keys" do
      assert Map.keys(Locale.overrides("ru")) |> Enum.sort() ==
               Map.keys(Locale.overrides("en")) |> Enum.sort()
    end
  end
end
