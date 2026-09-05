defmodule Druzhok.FetchTest do
  # async: false — shares the one worker process.
  use ExUnit.Case, async: false

  alias Druzhok.Fetch

  @fixtures Path.expand("../fixtures/fetch", __DIR__)

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  defp fetch(url), do: Fetch.fetch(url, allow_private: true)

  defp serve(bypass, path, type, body, status \\ 200) do
    Bypass.stub(bypass, "GET", path, fn conn ->
      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.resp(status, body)
    end)
  end

  @tag :fetch_worker
  test "an HTML page becomes a titled markdown page with its size and status", %{bypass: bypass, base: base} do
    serve(bypass, "/bike", "text/html", File.read!(Path.join(@fixtures, "article.html")))

    assert {:ok, page} = fetch(base <> "/bike")
    assert page.title =~ "Как выбрать велосипед"
    assert page.markdown =~ "## Рама и посадка"
    assert page.final_url == base <> "/bike"
    assert page.status_code == 200
    assert page.bytes > 1000
  end

  @tag :fetch_worker
  test "a PDF is read by content type, whatever the URL says", %{bypass: bypass, base: base} do
    serve(bypass, "/download", "application/pdf", File.read!(Path.join(@fixtures, "report.pdf")))
    assert {:ok, %{title: "Quarterly Report Q3", markdown: md}} = fetch(base <> "/download")
    assert md =~ "Revenue grew"
  end

  @tag :fetch_worker
  test "a page with almost no text is no_text, not a sale", %{bypass: bypass, base: base} do
    serve(bypass, "/shell", "text/html", ~s(<html><head><title>App</title></head><body><div id="root"></div><script src="/b.js"></script></body></html>))
    assert {:error, :no_text, %{status_code: 200}} = fetch(base <> "/shell")
  end

  test "a non-2xx page is no_text with its status and no extraction", %{bypass: bypass, base: base} do
    serve(bypass, "/gone", "text/html", "<p>" <> String.duplicate("nope ", 100) <> "</p>", 404)
    assert {:error, :no_text, %{status_code: 404}} = fetch(base <> "/gone")
  end

  test "transport and policy errors pass through with their code", %{bypass: bypass, base: base} do
    serve(bypass, "/zip", "application/zip", "PK")
    assert {:error, :unsupported_type, %{}} = fetch(base <> "/zip")
    assert {:error, :bad_url, %{}} = fetch("ftp://x/")
    assert {:error, :unsafe_url, %{}} = Fetch.fetch("http://127.0.0.1/", [])
    Bypass.down(bypass)
    assert {:error, :unreachable, %{}} = fetch(base <> "/x")
  end
end
