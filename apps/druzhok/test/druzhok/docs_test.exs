defmodule Druzhok.DocsTest do
  use ExUnit.Case, async: false

  alias Druzhok.Docs

  @wrapper Path.expand("../../../../ops/docs-convert", __DIR__)

  test "filters belong to their target only" do
    assert Docs.valid_filter?("pdf", nil)
    assert Docs.valid_filter?("pdf", "writer_pdf_Export")
    assert Docs.valid_filter?("xlsx", "Calc MS Excel 2007 XML")
    refute Docs.valid_filter?("pdf", "Calc MS Excel 2007 XML")
    refute Docs.valid_filter?("pdf", "writer_pdf_Export:{\"PageRange\":\"1\"}")
    assert Docs.valid_filter?("csv", "Text - txt - csv (StarCalc)")
    refute Docs.valid_filter?("docx", "Text - txt - csv (StarCalc)")
  end

  # ops/docs-convert repeats the lists: root's copy must refuse what druzhok refuses.
  test "the wrapper's targets, filters and inputs are druzhok's" do
    text = File.read!(@wrapper)

    wrapper_filters =
      Regex.scan(~r/^\s+(\w+)\)\s+filters='([^']*)';;$/m, text)
      |> Map.new(fn [_, to, list] -> {to, String.split(list, "|")} end)

    assert wrapper_filters == Docs.filters()
    assert Map.keys(wrapper_filters) |> Enum.sort() == Enum.sort(Docs.targets())

    [_, inputs] = Regex.run(~r/\^input\\\.\(([a-z|]+)\)\$/, text)
    assert String.split(inputs, "|") |> Enum.sort() == Enum.sort(Docs.inputs())
  end

  describe "with a real soffice (Runner.Local)" do
    @describetag :soffice

    setup do
      root = Path.join(System.tmp_dir!(), "druzhok-docs-real-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      prev = Application.get_env(:druzhok, :docs)
      Application.put_env(:druzhok, :docs, runner: Docs.Runner.Local, jobs_root: root, min_free_mb: 1)

      on_exit(fn ->
        if prev, do: Application.put_env(:druzhok, :docs, prev), else: Application.delete_env(:druzhok, :docs)
        File.rm_rf!(root)
      end)

      %{root: root}
    end

    @tag timeout: 180_000
    test "converts an HTML page to PDF and keeps its Cyrillic text", %{root: root} do
      src = Path.join(root, "page.html")
      File.write!(src, "<html><body><p>Проверка конвертера</p></body></html>")

      assert {:ok, pdf} =
               Docs.convert(%{id: -1, name: "local"}, src, "html", "pdf", nil, fn out -> File.read!(out) end)

      assert "%PDF" <> _ = pdf
      assert File.ls!(root) == ["page.html"]
    end
  end
end
