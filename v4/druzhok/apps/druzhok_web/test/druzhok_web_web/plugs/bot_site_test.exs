defmodule DruzhokWebWeb.Plugs.BotSiteTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias DruzhokWebWeb.Plugs.BotSite

  @opts BotSite.init([])

  setup do
    root = Path.join(System.tmp_dir!(), "botsite-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = System.get_env("DRUZHOK_DATA_ROOT")
    System.put_env("DRUZHOK_DATA_ROOT", root)

    on_exit(fn ->
      if prev, do: System.put_env("DRUZHOK_DATA_ROOT", prev), else: System.delete_env("DRUZHOK_DATA_ROOT")
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp write_site(root, bot, rel, body) do
    path = Path.join([root, bot, "workspace", "sites", rel])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp call(host, path) do
    conn(:get, path) |> Map.put(:host, host) |> BotSite.call(@opts)
  end

  describe "host matching" do
    test "bare dashboard host passes through untouched" do
      conn = call("oldey.dev", "/")
      refute conn.halted
      assert conn.state == :unset
    end

    test "non-oldey host passes through untouched" do
      conn = call("example.com", "/")
      refute conn.halted
      assert conn.state == :unset
    end

    test "bot subdomain is handled and halted", %{root: root} do
      write_site(root, "igorhermes", "wc2026-bracket/index.html", "<h1>bracket</h1>")
      conn = call("igorhermes.oldey.dev", "/wc2026-bracket/")
      assert conn.halted
    end
  end

  describe "serving files" do
    test "serves a file with correct content-type", %{root: root} do
      write_site(root, "igorhermes", "wc2026-bracket/index.html", "<h1>bracket</h1>")
      conn = call("igorhermes.oldey.dev", "/wc2026-bracket/index.html")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    end

    test "serves index.html for a directory request", %{root: root} do
      write_site(root, "igorhermes", "wc2026-bracket/index.html", "<h1>bracket</h1>")
      conn = call("igorhermes.oldey.dev", "/wc2026-bracket/")
      assert conn.status == 200
    end

    test "serves index.html at the subdomain root", %{root: root} do
      write_site(root, "igorhermes", "index.html", "<h1>home</h1>")
      conn = call("igorhermes.oldey.dev", "/")
      assert conn.status == 200
    end

    test "css gets a css content-type", %{root: root} do
      write_site(root, "igorhermes", "site/style.css", "body{}")
      conn = call("igorhermes.oldey.dev", "/site/style.css")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/css"
    end
  end

  describe "not found" do
    test "unknown bot -> branded 404" do
      conn = call("nobody.oldey.dev", "/whatever/")
      assert conn.status == 404
      assert conn.resp_body =~ "Nothing here yet"
    end

    test "missing file -> branded 404", %{root: root} do
      write_site(root, "igorhermes", "exists/index.html", "x")
      conn = call("igorhermes.oldey.dev", "/missing/")
      assert conn.status == 404
      assert conn.resp_body =~ "Nothing here yet"
    end

    test "directory without index.html -> 404", %{root: root} do
      File.mkdir_p!(Path.join([root, "igorhermes", "workspace", "sites", "empty"]))
      conn = call("igorhermes.oldey.dev", "/empty/")
      assert conn.status == 404
    end
  end

  describe "path traversal safety" do
    test "rejects .. segments and never escapes the root", %{root: root} do
      # secret outside the bot's sites dir (in workspace/, above sites/)
      write_site(root, "igorhermes", "site/index.html", "x")
      File.write!(Path.join([root, "igorhermes", "workspace", "secret.txt"]), "TOPSECRET")

      for path <- ["/../secret.txt", "/site/../../secret.txt", "/%2e%2e/secret.txt", "/..%2f..%2fsecret.txt"] do
        conn = call("igorhermes.oldey.dev", path)
        refute conn.resp_body == "TOPSECRET"
        assert conn.status in [404, 400]
      end
    end

    test "absolute-path-looking request does not escape", %{root: root} do
      write_site(root, "igorhermes", "site/index.html", "x")
      conn = call("igorhermes.oldey.dev", "/etc/passwd")
      assert conn.status == 404
    end
  end

  describe "hidden files" do
    test "dotfiles are hidden", %{root: root} do
      write_site(root, "igorhermes", ".env", "SECRET=1")
      conn = call("igorhermes.oldey.dev", "/.env")
      assert conn.status == 404
    end

    test "underscore files are hidden", %{root: root} do
      write_site(root, "igorhermes", "_private.txt", "x")
      conn = call("igorhermes.oldey.dev", "/_private.txt")
      assert conn.status == 404
    end
  end

  describe "methods" do
    test "non-GET on a bot subdomain is rejected with 405", %{root: root} do
      write_site(root, "igorhermes", "site/index.html", "x")
      conn = conn(:post, "/site/") |> Map.put(:host, "igorhermes.oldey.dev") |> BotSite.call(@opts)
      assert conn.status == 405
    end
  end
end
