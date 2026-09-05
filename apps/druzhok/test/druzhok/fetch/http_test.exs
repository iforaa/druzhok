defmodule Druzhok.Fetch.HTTPTest do
  use ExUnit.Case, async: true

  alias Druzhok.Fetch.HTTP

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  # Bypass listens on loopback, which the policy refuses; the transport tests
  # let it through and the policy has its own tests.
  defp get(url, opts \\ []), do: HTTP.get(url, Keyword.merge([allow_private: true], opts))

  test "reads a page with its final URL, status and content type", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "GET", "/page", fn conn ->
      assert Plug.Conn.get_req_header(conn, "host") == ["localhost:#{bypass.port}"]
      assert [ua] = Plug.Conn.get_req_header(conn, "user-agent")
      assert ua =~ "Druzhok"
      assert Plug.Conn.get_req_header(conn, "accept-language") == ["ru,en;q=0.8"]

      conn
      |> Plug.Conn.put_resp_content_type("text/html", "utf-8")
      |> Plug.Conn.resp(200, "<html><title>Hi</title><p>Привет</p></html>")
    end)

    assert {:ok, page} = get(base <> "/page")
    assert page.status == 200
    assert page.final_url == base <> "/page"
    assert page.content_type == "text/html"
    assert page.body =~ "Привет"
  end

  test "follows redirects, relative ones included, up to five hops", %{bypass: bypass, base: base} do
    Bypass.stub(bypass, "GET", "/a", fn conn -> redirect(conn, 301, "/b") end)
    Bypass.stub(bypass, "GET", "/b", fn conn -> redirect(conn, 302, base <> "/c?x=1") end)
    Bypass.stub(bypass, "GET", "/c", fn conn -> Plug.Conn.resp(conn, 200, "done") end)

    assert {:ok, %{status: 200, final_url: final, body: "done"}} = get(base <> "/a")
    assert final == base <> "/c?x=1"

    for i <- 1..7, do: Bypass.stub(bypass, "GET", "/hop#{i}", fn conn -> redirect(conn, 302, "/hop#{i + 1}") end)
    assert {:error, :unreachable} = get(base <> "/hop1")
  end

  # Every hop goes through the policy; the policy's own tests cover what it
  # refuses, this one shows a later hop is judged at all.
  test "a redirect to a URL the policy refuses is refused", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "GET", "/leave", fn conn -> redirect(conn, 302, "ftp://example.com/x") end)
    assert {:error, :bad_url} = get(base <> "/leave")

    Bypass.expect_once(bypass, "GET", "/leave2", fn conn -> redirect(conn, 302, "http://nope.example/") end)
    only_local = fn "localhost" -> {:ok, {127, 0, 0, 1}}; _ -> :error end
    assert {:error, :unreachable} = get(base <> "/leave2", resolver: only_local)
  end

  test "feeds are readable by content type", %{bypass: bypass, base: base} do
    for type <- ["application/rss+xml", "application/atom+xml", "application/xml", "text/xml"] do
      Bypass.expect_once(bypass, "GET", "/feed", fn conn ->
        conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.resp(200, "<rss/>")
      end)

      assert {:ok, %{content_type: ^type, body: "<rss/>"}} = get(base <> "/feed")
    end
  end

  test "a content type it cannot read is refused", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "GET", "/bin", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/octet-stream") |> Plug.Conn.resp(200, "0000")
    end)

    assert {:error, :unsupported_type} = get(base <> "/bin")
  end

  test "a body over the cap is refused", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "GET", "/big", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.resp(200, String.duplicate("x", 5 * 1024 * 1024 + 1))
    end)

    assert {:error, :too_large} = get(base <> "/big")
  end

  test "a declared size over the cap is refused before the body is read" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      :gen_tcp.recv(socket, 0, 1_000)
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 6000000\r\n\r\n<html>")
      Process.sleep(2_000)
      :gen_tcp.close(socket)
    end)

    started = System.monotonic_time(:millisecond)
    assert {:error, :too_large} = get("http://localhost:#{port}/big")
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "the charset parameter travels with the content type", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "GET", "/legacy", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html", "windows-1251")
      |> Plug.Conn.resp(200, "<p>x</p>")
    end)

    assert {:ok, %{content_type: "text/html", charset: "windows-1251"}} = get(base <> "/legacy")
  end

  test "a non-2xx final status is returned, not an error", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "GET", "/gone", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(404, "<p>nope</p>")
    end)

    assert {:ok, %{status: 404, body: ""}} = get(base <> "/gone")
  end

  test "a server that never answers times out at the deadline" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      send(parent, :accepted)
      Process.sleep(2_000)
      :gen_tcp.close(socket)
    end)

    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = get("http://localhost:#{port}/slow", deadline_ms: 300)
    assert_received :accepted
    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  test "a host that refuses the connection is unreachable", %{bypass: bypass, base: base} do
    Bypass.down(bypass)
    assert {:error, :unreachable} = get(base <> "/x")
  end

  defp redirect(conn, status, to) do
    conn |> Plug.Conn.put_resp_header("location", to) |> Plug.Conn.resp(status, "")
  end
end
