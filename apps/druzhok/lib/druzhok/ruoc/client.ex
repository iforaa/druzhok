defmodule Druzhok.Ruoc.Client do
  @moduledoc "HTTP to ruoc-gateway over `Druzhok.Finch`. Bearer per call; no retries."

  @receive_timeout 120_000

  @doc "POST JSON. Returns `{:ok, status, headers, body}` or `{:error, reason}`."
  def post(path, api_key, body, opts \\ []) do
    headers =
      [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}] ++
        Keyword.get(opts, :headers, [])

    Finch.build(:post, Druzhok.Ruoc.url() <> path, headers, body)
    |> run(opts)
  end

  @doc "PUT JSON, as `post/4`."
  def put(path, api_key, body, opts \\ []) do
    headers =
      [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}] ++
        Keyword.get(opts, :headers, [])

    Finch.build(:put, Druzhok.Ruoc.url() <> path, headers, body)
    |> run(opts)
  end

  def get(path, api_key, opts \\ []) do
    headers = [{"authorization", "Bearer #{api_key}"}] ++ Keyword.get(opts, :headers, [])

    Finch.build(:get, Druzhok.Ruoc.url() <> path, headers)
    |> run(opts)
  end

  def delete(path, api_key, opts \\ []) do
    headers = [{"authorization", "Bearer #{api_key}"}] ++ Keyword.get(opts, :headers, [])

    Finch.build(:delete, Druzhok.Ruoc.url() <> path, headers)
    |> run(opts)
  end

  @doc """
  PUT with a body read from `chunks` as it is sent, so nothing is held but the
  chunk in hand (site uploads). The enumerable runs in the calling process. If
  it raises or throws, the connection is closed without the final chunk, so the
  gateway sees a broken upload rather than a short one, and the raise goes on to
  the caller. A slow upload holds a connection for minutes, so these have their
  own small pool: a bot cannot use them to starve the chat traffic.
  """
  def put_stream(path, api_key, content_type, chunks, opts \\ []) do
    headers = [{"authorization", "Bearer #{api_key}"}, {"content-type", content_type}]

    Finch.build(:put, Druzhok.Ruoc.url() <> path, headers, {:stream, chunks})
    |> run(Keyword.put(opts, :finch, Druzhok.UploadFinch))
  end

  @doc "A Finch request for the caller to stream itself (chat SSE)."
  def build(method, path, api_key, body, extra_headers \\ []) do
    headers =
      [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}] ++ extra_headers

    Finch.build(method, Druzhok.Ruoc.url() <> path, headers, body)
  end

  def receive_timeout, do: @receive_timeout

  defp run(request, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @receive_timeout)

    case Finch.request(request, Keyword.get(opts, :finch, Druzhok.Finch), receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} -> {:ok, status, headers, body}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # Finch raises this for no free connection within its pool timeout. Anything
    # else raised here is a put_stream body's own, for its caller.
    e in RuntimeError -> {:error, e}
  catch
    # The pool is gone.
    :exit, reason -> {:error, reason}
  end
end
