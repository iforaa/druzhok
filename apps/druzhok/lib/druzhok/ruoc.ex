defmodule Druzhok.Ruoc do
  @moduledoc """
  The one module that knows ruoc-gateway's URLs and shapes.

  ruoc-gateway holds every bot's money: one account per bot, funded in its
  console. Druzhok creates the account, stores the key on the instance and
  proxies the bot's traffic with it. Balance, prices and admission live over
  there; this module only asks.

  Settings (dashboard rows); each is overridden by the app env of the same
  name, which `config/runtime.exs` fills from `RUOC_URL`, `RUOC_ADMIN_HOST`,
  `RUOC_ADMIN_TOKEN`, `RUOC_CATALOG_KEY`:

    * `ruoc_url`         — base for `/v1/*` and `/admin/*` (default loopback :8787)
    * `ruoc_admin_host`  — `Host` header on admin calls; the gateway serves
                           its admin surface only on that hostname
    * `ruoc_admin_token` — bearer for `/admin/*`
    * `ruoc_catalog_key` — a never-funded bot-style key for `GET /v1/models`
  """

  require Logger
  alias Druzhok.Ruoc.Client
  alias Druzhok.Settings

  @default_url "http://127.0.0.1:8787"
  @default_model "ruoc-flash"
  @cache_ttl_ms 60_000
  @cache_key {__MODULE__, :models}

  def url, do: setting("ruoc_url") || @default_url
  def admin_host, do: setting("ruoc_admin_host")
  def admin_token, do: setting("ruoc_admin_token")
  def catalog_key, do: setting("ruoc_catalog_key")

  # App env (from RUOC_* env vars or a test's put_env) wins over the settings
  # row; a blank in either place counts as unset.
  defp setting(key) do
    case Application.get_env(:druzhok, String.to_atom(key)) do
      v when is_binary(v) and v != "" -> v
      _ -> Settings.get(key)
    end
  end

  @doc "True when druzhok can provision accounts, i.e. the admin token is set."
  def configured?, do: admin_token() != nil

  def default_model, do: @default_model

  @doc "Where an operator looks at this account in the ruoc console."
  def console_url(account_id) do
    case admin_host() do
      nil -> nil
      host -> "https://#{host}/#/requests/#{account_id}"
    end
  end

  # --- Admin API -----------------------------------------------------------

  @doc """
  Create an account with one key. `{:ok, %{account_id, api_key}}`; the key
  is returned once by the gateway and stored on the instance by the caller.
  """
  def create_account(label, grant_rubles \\ nil) do
    body = %{"label" => label}
    body = if grant_rubles, do: Map.put(body, "grant_rubles", to_string(grant_rubles)), else: body

    case admin_post("/admin/accounts", body) do
      {:ok, 201, %{"account_id" => id, "api_key" => key}} ->
        {:ok, %{account_id: id, api_key: key}}

      other ->
        {:error, describe(other)}
    end
  end

  @doc "Suspend the account so its key stops working; history stays."
  def suspend(account_id) do
    case admin_post("/admin/accounts/#{account_id}/status", %{"status" => "suspended"}) do
      {:ok, 200, _} -> :ok
      other -> {:error, describe(other)}
    end
  end

  # --- Bot-facing API --------------------------------------------------------

  @doc "Balance for a bot key. `{:ok, %{balance_rub: \"12.5\", balance_nanorub: int}}`."
  def balance(api_key) do
    case Client.get("/v1/balance", api_key) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"balance_rub" => rub, "balance_nanorub" => nano}} ->
            {:ok, %{balance_rub: rub, balance_nanorub: nano}}

          _ ->
            {:error, "unexpected balance payload"}
        end

      {:ok, status, _headers, body} ->
        {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  The catalog: `[%{id, name, price: %{input, output}, capabilities}]`.
  Cached for 60 s; on failure the last good list is returned.
  """
  def models do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {fetched_at, list} when now - fetched_at < @cache_ttl_ms ->
        list

      stale ->
        case fetch_models() do
          {:ok, list} ->
            :persistent_term.put(@cache_key, {now, list})
            list

          {:error, reason} ->
            Logger.warning("ruoc models fetch failed: #{reason}")
            case stale do
              {_, list} -> list
              nil -> []
            end
        end
    end
  end

  def reset_cache, do: :persistent_term.erase(@cache_key)

  def find_model(id), do: Enum.find(models(), &(&1.id == id))

  @doc "Models whose upstream reads images (`capabilities.attachment`)."
  def vision_models, do: Enum.filter(models(), &(&1.capabilities["attachment"] == true))

  @doc "Label for a picker: `name (in/out RUB/M)`."
  def price_label(%{price: %{input: nil, output: nil}}), do: nil
  def price_label(%{price: %{input: i, output: o}}), do: "#{i || "?"}/#{o || "?"} ₽/M"

  defp fetch_models do
    case catalog_key() do
      nil ->
        {:error, "ruoc_catalog_key is not set"}

      key ->
        case Client.get("/v1/models", key) do
          {:ok, 200, _headers, body} ->
            case Jason.decode(body) do
              {:ok, %{"data" => data}} when is_list(data) -> {:ok, Enum.map(data, &to_model/1)}
              _ -> {:error, "unexpected models payload"}
            end

          {:ok, status, _headers, body} ->
            {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp to_model(m) do
    price = m["price"] || %{}

    %{
      id: m["id"],
      name: m["name"] || m["id"],
      price: %{input: price["input_rub_per_million"], output: price["output_rub_per_million"]},
      capabilities: m["capabilities"] || %{}
    }
  end

  defp admin_post(path, body) do
    case admin_token() do
      nil ->
        {:error, "ruoc_admin_token is not set"}

      token ->
        headers = if host = admin_host(), do: [{"host", host}], else: []

        case Client.post(path, token, Jason.encode!(body), headers: headers) do
          {:ok, status, _headers, resp} ->
            {:ok, status, decode(resp)}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> body
    end
  end

  defp describe({:error, reason}), do: reason
  defp describe({:ok, status, %{"error" => %{"message" => msg}}}), do: "HTTP #{status}: #{msg}"
  defp describe({:ok, status, body}), do: "HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}"
end
