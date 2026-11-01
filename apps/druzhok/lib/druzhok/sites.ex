defmodule Druzhok.Sites do
  @moduledoc """
  A bot's published sites, which live in ruoc-gateway (`Druzhok.Ruoc`). The
  files stay in the bot's workspace; only hermes's `site_publish` sends them
  (`DruzhokWebWeb.SitesController`), and druzhok never reads them for this.
  """

  alias Druzhok.Ruoc

  @site_name ~r/\A[a-z0-9][a-z0-9-]{0,49}\z/

  @doc "Whether `name` is a site name the gateway could accept, safe in a URL path."
  def valid_name?(name), do: is_binary(name) and Regex.match?(@site_name, name)

  @doc """
  What the gateway serves for this bot: `{:ok, [%{name, url, files, bytes,
  published_at, disabled}]}` or `{:error, reason}`.
  """
  def published(%{ruoc_api_key: key}) when is_binary(key) and key != "" do
    with {:ok, sites} <- Ruoc.sites(key) do
      {:ok,
       Enum.map(sites, fn s ->
         %{
           name: s["name"],
           url: s["url"],
           files: s["files"],
           bytes: s["bytes"],
           published_at: s["published_at"],
           disabled: s["disabled"] == true
         }
       end)}
    end
  end

  def published(_inst), do: {:ok, []}

  @doc """
  Takes every published site down; the workspace files stay. Stops at the first
  refusal with `{:error, reason}`, and a repeat picks up what is left.
  """
  def unpublish_all(inst) do
    with {:ok, sites} <- published(inst) do
      Enum.reduce_while(sites, :ok, fn %{name: name}, :ok ->
        case unpublish(inst, name) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Takes one site down. One that is already gone is `:ok`."
  def unpublish(%{ruoc_api_key: key}, name) do
    case Ruoc.delete_site(key, name) do
      {:ok, status, _} when status in [200, 404] -> :ok
      {:ok, status, body} -> {:error, "HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}"}
      {:error, {:transport, reason}} -> {:error, inspect(reason)}
    end
  end
end
