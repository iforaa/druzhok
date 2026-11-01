defmodule DruzhokWebWeb.SitesController do
  @moduledoc """
  `PUT` and `DELETE /v2/sites/:site`: hermes's `site_publish` and `site_delete`,
  forwarded to ruoc-gateway under the bot's `ruoc_api_key`. The gateway's status
  and JSON pass through. Of its own druzhok adds 403 `sites_off`, and 502
  `gateway_unavailable` when there is no answer to pass on; it answers `bad_name`,
  `bad_archive`, `too_large` and 408 `upload_incomplete` (an upload that stopped)
  in the gateway's words, without asking it.

  A `PUT` body is up to 50 MB and this box has 4 GB, so it is read one chunk at a
  time as the gateway takes it, and never held. It is cut at `@max_body_bytes`.
  An upload that is cut or broken closes the gateway connection without the final
  chunk, so a short archive can never look complete.
  """

  use DruzhokWebWeb, :controller
  require Logger

  alias Druzhok.{Instance, Repo, Ruoc, Sites}

  # The gateway's own limit on the body (`siteMaxBody`). The site's 50 MB it checks
  # itself while unpacking, so anything under this is its to decide.
  @max_body_bytes 60 * 1024 * 1024
  @chunk_bytes 64 * 1024
  @read_timeout_ms 15_000
  # All of one upload, for a slow link to the gateway.
  @upload_timeout_ms 600_000
  # Unpacking happens after the last byte, before the answer.
  @reply_timeout_ms 120_000

  @conn_key {__MODULE__, :conn}

  def publish(conn, %{"site" => site}) do
    inst = conn.assigns.instance

    cond do
      inst.website_hosting_enabled != true -> refuse(conn, 403, "sites_off")
      not Sites.valid_name?(site) -> refuse(conn, 400, "bad_name")
      not gzip?(conn) -> refuse(conn, 400, "bad_archive")
      too_long?(conn) -> refuse(conn, 413, "too_large")
      true -> forward(conn, inst, site)
    end
  end

  def unpublish(conn, %{"site" => site}) do
    if Sites.valid_name?(site) do
      inst = conn.assigns.instance

      case Ruoc.delete_site(inst.ruoc_api_key, site) do
        {:ok, status, %{} = body} -> conn |> put_status(status) |> json(body)
        other -> unavailable(conn, inst, site, other)
      end
    else
      refuse(conn, 400, "bad_name")
    end
  end

  defp forward(conn, inst, site) do
    started = System.monotonic_time(:millisecond)
    path = "/v1/sites/" <> site

    Process.put(@conn_key, conn)
    result = upload(path, inst.ruoc_api_key, started + @upload_timeout_ms)

    # read_body returns a new conn each time; replying on the old one would lose
    # what Bandit knows about the body.
    conn = Process.delete(@conn_key)
    Logger.info("[sites] #{inst.name} PUT #{site}: #{outcome(result)} #{elapsed(started)}ms")

    case result do
      {:ok, status, _headers, body} -> pass_through(conn, inst, site, status, body)
      {:abort, :too_large} -> refuse(conn, 413, "too_large")
      {:abort, _} -> refuse(conn, 408, "upload_incomplete")
      {:error, _} = error -> no_answer(conn, inst, site, error)
    end
  end

  defp upload(path, key, deadline) do
    Ruoc.Client.put_stream(path, key, "application/gzip", body_chunks(deadline),
      receive_timeout: @reply_timeout_ms
    )
  catch
    :throw, {:abort, why} -> {:abort, why}
  end

  # Runs inside Finch, in this process, one chunk per send. A Bandit error while
  # reading (the client left, a malformed body) goes through Finch, which closes
  # the gateway connection, and on to Bandit, which knows how to end the request.
  defp body_chunks(deadline) do
    Stream.unfold({:more, 0}, fn
      :done ->
        nil

      {:more, sent} ->
        if System.monotonic_time(:millisecond) > deadline, do: throw({:abort, :timeout})

        case read_chunk() do
          {:more, data} -> {data, {:more, counted(sent, data)}}
          {:ok, data} -> {data, counted(sent, data) && :done}
          {:error, why} -> throw({:abort, why})
        end
    end)
    |> Stream.reject(&(&1 == ""))
  end

  defp read_chunk do
    opts = [length: @chunk_bytes, read_length: @chunk_bytes, read_timeout: read_timeout_ms()]

    case read_body(Process.get(@conn_key), opts) do
      {:more, data, conn} ->
        Process.put(@conn_key, conn)
        {:more, data}

      {:ok, data, conn} ->
        Process.put(@conn_key, conn)
        {:ok, data}

      {:error, why} ->
        {:error, why}
    end
  rescue
    # Bandit raises a stalled read rather than returning it, and Phoenix would
    # answer it in a shape the contract does not have.
    e ->
      if Plug.Exception.status(e) == 408,
        do: {:error, :timeout},
        else: reraise(e, __STACKTRACE__)
  end

  defp counted(sent, data) do
    sent = sent + byte_size(data)
    if sent > max_body_bytes(), do: throw({:abort, :too_large})
    sent
  end

  # Hosting went off while this was uploading. BotSettings has already listed the
  # sites, possibly before this one existed, so it goes down here; the same for a
  # bot deleted meanwhile.
  defp pass_through(conn, inst, site, status, body) when status in 200..299 do
    if publishing_allowed?(inst) do
      relay(conn, inst, site, status, body)
    else
      take_down(inst, site)
      refuse(conn, 403, "sites_off")
    end
  end

  defp pass_through(conn, inst, site, status, body), do: relay(conn, inst, site, status, body)

  # The reply can be lost after the gateway committed, so no answer is not proof
  # that nothing landed.
  defp no_answer(conn, inst, site, why) do
    unless publishing_allowed?(inst), do: take_down(inst, site)
    unavailable(conn, inst, site, why)
  end

  defp publishing_allowed?(inst),
    do: match?(%Instance{website_hosting_enabled: true, delete_requested: false}, Repo.get(Instance, inst.id))

  defp take_down(inst, site) do
    with {:error, reason} <- Sites.unpublish(inst, site) do
      Logger.error("[sites] #{inst.name}: #{site} may stay up after hosting off: #{reason}")
    end
  end

  defp relay(conn, inst, site, status, body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> conn |> put_status(status) |> json(decoded)
      _ -> unavailable(conn, inst, site, {:ok, status, :not_json})
    end
  end

  defp unavailable(conn, inst, site, why) do
    Logger.error("[sites] #{inst.name} #{site}: no usable gateway answer: #{inspect(why)}")
    refuse(conn, 502, "gateway_unavailable")
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})

  # Anything else may already have been eaten by Plug.Parsers, which reads a JSON
  # or form body before the route runs and leaves `application/gzip` alone.
  defp gzip?(conn) do
    case get_req_header(conn, "content-type") do
      [value] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase() == "application/gzip"
      _ -> false
    end
  end

  defp too_long?(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n > max_body_bytes()
    else
      _ -> false
    end
  end

  defp read_timeout_ms,
    do: Application.get_env(:druzhok_web, :site_read_timeout_ms, @read_timeout_ms)

  defp max_body_bytes,
    do: Application.get_env(:druzhok_web, :site_max_body_bytes, @max_body_bytes)

  defp outcome({:ok, status, _, _}), do: status
  defp outcome({:abort, why}), do: why
  defp outcome({:error, _}), do: "gateway error"

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
