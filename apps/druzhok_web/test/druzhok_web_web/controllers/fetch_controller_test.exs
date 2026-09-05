defmodule DruzhokWebWeb.FetchControllerTest do
  use DruzhokWebWeb.ConnCase, async: false

  alias DruzhokWebWeb.FetchStub

  @secret "fetch-secret-for-tests"

  setup do
    FetchStub.start()
    Druzhok.Settings.set("fetch_secret", @secret)
    :ok
  end

  defp call(conn, url, secret \\ @secret) do
    conn
    |> put_req_header("authorization", "Bearer " <> secret)
    |> post("/internal/fetch", %{"url" => url})
  end

  test "returns the page for ruoc with the shared secret", %{conn: conn} do
    FetchStub.reply("https://example.com/a", {:ok, %{final_url: "https://example.com/a/", title: "A", markdown: "# A\n\ntext", status_code: 200, bytes: 512}})

    conn = call(conn, "https://example.com/a")
    assert json_response(conn, 200) == %{"final_url" => "https://example.com/a/", "title" => "A", "markdown" => "# A\n\ntext", "status_code" => 200, "bytes" => 512}
    assert FetchStub.calls() == ["https://example.com/a"]
  end

  test "refuses a missing, wrong or unset secret without fetching", %{conn: conn} do
    assert call(conn, "https://example.com/a", "nope").status == 401
    assert post(conn, "/internal/fetch", %{"url" => "https://example.com/a"}).status == 401

    Druzhok.Repo.delete_all(Druzhok.Settings)
    assert call(conn, "https://example.com/a").status == 401
    assert FetchStub.calls() == []
  end

  test "maps every fetch verdict to its status and code" do
    cases = [
      {:bad_url, 400}, {:unsafe_url, 400}, {:unsupported_type, 400},
      {:timeout, 504}, {:unreachable, 502}, {:too_large, 502}, {:worker_down, 502}, {:extract_failed, 502}
    ]

    for {code, status} <- cases do
      url = "https://example.com/#{code}"
      FetchStub.reply(url, {:error, code, %{}})
      conn = call(build_conn(), url)
      assert conn.status == status, "#{code}: got #{conn.status}"
      assert json_response(conn, status) == %{"error" => to_string(code)}
    end

    FetchStub.reply("https://example.com/empty", {:error, :no_text, %{status_code: 404}})
    conn = call(build_conn(), "https://example.com/empty")
    assert json_response(conn, 422) == %{"error" => "no_text", "status_code" => 404}
  end

  test "a body without a url is a bad_url", %{conn: conn} do
    conn = conn |> put_req_header("authorization", "Bearer " <> @secret) |> post("/internal/fetch", %{})
    assert json_response(conn, 400) == %{"error" => "bad_url"}
    assert FetchStub.calls() == []
  end
end
