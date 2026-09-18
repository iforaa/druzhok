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
    # The dashboard itself lives on a subdomain too (PHX_HOST, e.g.
    # druzhok.oldey.dev) — never treat that host as a bot site.
    if host == DruzhokWebWeb.Endpoint.host() do
      conn
    else
      case Regex.run(@host_re, host) do
        [_, bot] -> serve(conn, bot)
        _ -> conn
      end
    end
  end

  defp serve(%Plug.Conn{method: method} = conn, _bot) when method not in ["GET", "HEAD"] do
    conn |> send_resp(405, "Method Not Allowed") |> halt()
  end

  defp serve(conn, bot) do
    case open_site_file(bot, conn.path_info) do
      {:ok, fd, file} ->
        conn
        |> put_resp_content_type(MIME.from_path(file))
        |> send_fd(fd)
        |> halt()

      :not_found ->
        not_found(conn)
    end
  end

  # The bot owns everything below its tenant dir, `workspace/` and `sites/`
  # included, and druzhok reads with CAP_DAC_READ_SEARCH: a symlink followed
  # here hands out any file on the host. So no component below the tenant dir
  # may be a symlink, and the bytes come from a descriptor we verified rather
  # than from a second lookup by name, which the bot could swap in between.
  @site_prefix ["workspace", "sites"]

  defp open_site_file(bot, segments) do
    tenant_dir = bot |> Druzhok.SiteLister.sites_dir() |> Path.dirname() |> Path.dirname()

    with :ok <- validate_segments(segments),
         {:ok, file, _stat} <- walk(tenant_dir, @site_prefix ++ segments),
         {:ok, fd} <- :file.open(file, [:read, :binary, :raw]) do
      # Re-walk now that the file is open: the descriptor is only trusted if
      # the symlink-free path still leads to the very inode it refers to.
      with {:ok, info} <- :file.read_file_info(fd),
           opened = File.Stat.from_record(info),
           {:ok, ^file, %File.Stat{inode: inode, major_device: dev}} <-
             walk(tenant_dir, @site_prefix ++ segments),
           true <- opened.type == :regular and opened.inode == inode and opened.major_device == dev do
        {:ok, fd, file}
      else
        _ ->
          :file.close(fd)
          :not_found
      end
    else
      _ -> :not_found
    end
  end

  # Descend from `dir` one component at a time with lstat. Every intermediate
  # must be a real directory and the target a real regular file; a directory
  # target resolves to its index.html.
  defp walk(dir, []), do: walk_leaf(Path.join(dir, "index.html"))

  defp walk(dir, [last]) do
    path = Path.join(dir, last)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, [])
      _ -> walk_leaf(path)
    end
  end

  defp walk(dir, [next | rest]) do
    path = Path.join(dir, next)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, rest)
      _ -> :not_found
    end
  end

  defp walk_leaf(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, path, stat}
      _ -> :not_found
    end
  end

  @chunk_bytes 64 * 1024

  defp send_fd(%Plug.Conn{method: "HEAD"} = conn, fd) do
    :file.close(fd)
    send_resp(conn, 200, "")
  end

  defp send_fd(conn, fd) do
    conn = send_chunked(conn, 200)

    try do
      pump(conn, fd)
    after
      :file.close(fd)
    end
  end

  defp pump(conn, fd) do
    with {:ok, data} <- :file.read(fd, @chunk_bytes),
         {:ok, conn} <- chunk(conn, data) do
      pump(conn, fd)
    else
      _ -> conn
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
