defmodule DruzhokWebWeb.Plugs.BotSite do
  @moduledoc """
  Serves bot-published static sites for `<bot>.oldey.dev` subdomains.

  Caddy reverse-proxies `*.oldey.dev` bot subdomains to Phoenix instead of
  serving the files itself, because the `caddy` user cannot read into a bot's
  data dir (the hermes runtime `chmod 0700`s `HERMES_HOME` on every auth write).
  Phoenix runs as the data-dir owner, so it can always read the files.

  This plug runs BEFORE the dashboard router. On a bot subdomain it serves the
  requested file and `halt/1`s, so bot subdomains can only ever reach files
  under `<data_root>/<bot>/workspace/sites/` — never the dashboard, LiveView,
  or the `/v1/*` proxy routes. Any non-bot host (incl. the bare `oldey.dev`
  dashboard) passes through untouched.

  Sites live at `Druzhok.SiteLister.sites_dir/1`. The branded 404 page is the
  same "Nothing here yet" placeholder Caddy used to serve.
  """

  import Plug.Conn
  require Logger

  @host_re ~r/^([a-z0-9][a-z0-9-]+)\.oldey\.dev$/

  def init(opts), do: opts

  def call(%Plug.Conn{host: host} = conn, _opts) do
    case Regex.run(@host_re, host) do
      [_, bot] -> serve(conn, bot)
      _ -> conn
    end
  end

  defp serve(%Plug.Conn{method: method} = conn, _bot) when method not in ["GET", "HEAD"] do
    conn |> send_resp(405, "Method Not Allowed") |> halt()
  end

  defp serve(conn, bot) do
    root = Druzhok.SiteLister.sites_dir(bot)

    case resolve(root, conn.path_info) do
      {:ok, file} ->
        conn
        |> put_resp_content_type(MIME.from_path(file))
        |> send_file(200, file)
        |> halt()

      :not_found ->
        not_found(conn)
    end
  end

  # Map the request path to a concrete, readable file under `root`, or
  # `:not_found`. Guards against traversal, dotfiles/underscore files, and
  # symlink escape before touching disk-by-name.
  defp resolve(root, segments) do
    with :ok <- validate_segments(segments),
         candidate <- Path.expand(Path.join([root | segments])),
         true <- within_root?(root, candidate) do
      pick_file(candidate)
    else
      _ -> :not_found
    end
  end

  defp validate_segments(segments) do
    bad? =
      Enum.any?(segments, fn seg ->
        seg in ["", ".", ".."] or String.starts_with?(seg, ".") or
          String.starts_with?(seg, "_") or String.contains?(seg, "/") or
          String.contains?(seg, "\0")
      end)

    if bad?, do: :error, else: :ok
  end

  defp within_root?(root, candidate) do
    root = Path.expand(root)
    candidate == root or String.starts_with?(candidate, root <> "/")
  end

  defp pick_file(path) do
    cond do
      File.dir?(path) ->
        index = Path.join(path, "index.html")
        if File.regular?(index), do: {:ok, index}, else: :not_found

      File.regular?(path) ->
        {:ok, path}

      true ->
        :not_found
    end
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(404, not_found_body())
    |> halt()
  end

  defp not_found_body do
    path = Application.app_dir(:druzhok_web, "priv/default-page/index.html")

    case File.read(path) do
      {:ok, html} -> html
      _ -> "<!doctype html><meta charset=utf-8><title>druzhok</title><h1>Nothing here yet</h1>"
    end
  end
end
