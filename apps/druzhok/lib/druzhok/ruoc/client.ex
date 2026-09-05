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

  def get(path, api_key, opts \\ []) do
    headers = [{"authorization", "Bearer #{api_key}"}] ++ Keyword.get(opts, :headers, [])

    Finch.build(:get, Druzhok.Ruoc.url() <> path, headers)
    |> run(opts)
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

    case Finch.request(request, Druzhok.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} -> {:ok, status, headers, body}
      {:error, reason} -> {:error, reason}
    end
  end
end
