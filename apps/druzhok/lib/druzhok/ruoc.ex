defmodule Druzhok.Ruoc do
  @moduledoc """
  The one module that knows ruoc-gateway's URLs and shapes.

  ruoc-gateway holds every bot's money: one account per bot, funded in its
  console. Druzhok creates the account, stores the key on the instance and
  proxies the bot's traffic with it. Balance, prices and admission live over
  there; this module only asks.

  Account calls go to the gateway's `/partner/*` routes with druzhok's
  partner token, which reaches only the accounts druzhok made (partner access
  spec, ruoc-gateway `docs/superpowers/specs/2026-10-22-partner-access-design.md`).

    * `ruoc_url`           — base for `/v1/*` and `/partner/*` (default loopback
                             :8787); app env from `RUOC_URL`, else the settings row
    * `ruoc_partner_token` — bearer for `/partner/*`; app env from
                             `RUOC_PARTNER_TOKEN` only, never the settings table
    * `ruoc_catalog_key`   — a never-funded bot-style key for `GET /v1/models`;
                             app env from `RUOC_CATALOG_KEY`, else the settings row

  The old `ruoc_admin_token` / `ruoc_admin_host` settings rows are left in
  place for a rollback to the previous druzhok; nothing here reads them.
  """

  require Logger
  alias Druzhok.Ruoc.Client
  alias Druzhok.Settings

  @default_url "http://127.0.0.1:8787"
  @default_model "ruoc-flash"
  @cache_ttl_ms 60_000
  @cache_key {__MODULE__, :models}
  @refresh_key {__MODULE__, :models_refresh}
  @partner_timeout_ms 15_000
  @support_unread_timeout_ms 5_000

  def url, do: setting("ruoc_url") || @default_url
  def catalog_key, do: setting("ruoc_catalog_key")

  @doc "The partner token, from `RUOC_PARTNER_TOKEN` (via app env) only."
  def partner_token do
    case Application.get_env(:druzhok, :ruoc_partner_token) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  # App env (from RUOC_* env vars or a test's put_env) wins over the settings
  # row; a blank in either place counts as unset.
  defp setting(key) do
    case Application.get_env(:druzhok, String.to_atom(key)) do
      v when is_binary(v) and v != "" -> v
      _ -> Settings.get(key)
    end
  end

  @doc "True when druzhok can provision accounts, i.e. the partner token is set."
  def configured?, do: partner_token() != nil

  def default_model, do: @default_model

  # --- Partner API -----------------------------------------------------------

  @doc """
  Create the account for `ref` with one key. `{:ok, %{account_id, api_key}}`;
  the key is returned once by the gateway and stored on the instance by the
  caller.

  `ref` is the partner reference (`BotManager.external_ref/2`): at most one
  active account holds it, so a repeat is answered 409 `account_exists` and
  the key is reissued (`POST /partner/accounts/{id}/key`) instead, and a lost
  reply is retried once with the same ref. `invite` is a code the gateway
  redeems in the same commit; a refusal is
  `{:error, {:invite, :invalid | :spent | :expired}}` and no account exists.
  Past the partner's daily limit: `{:error, :ruoc_quota}`.
  """
  def create_account(label, ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    body =
      %{"label" => label, "external_ref" => ref}
      |> put_present("invite", opts[:invite])

    case partner_post_retry("/partner/accounts", body) do
      {:ok, 201, %{"account_id" => id, "api_key" => key}} ->
        {:ok, %{account_id: id, api_key: key}}

      {:ok, 409, %{} = resp} ->
        case error_type(resp) do
          "account_exists" ->
            reissue_key(resp)

          "invite_" <> reason when reason in ["invalid", "spent", "expired"] ->
            {:error, {:invite, invite_reason(reason)}}

          _ ->
            {:error, describe({:ok, 409, resp})}
        end

      {:ok, 429, %{} = resp} = other ->
        if error_type(resp) == "partner_quota" do
          Logger.error("ruoc partner quota reached")
          {:error, :ruoc_quota}
        else
          {:error, describe(other)}
        end

      other ->
        {:error, describe(other)}
    end
  end

  # The account was made by an earlier attempt whose reply was lost: a new key
  # for it, which revokes the one nobody received.
  defp reissue_key(resp) do
    case resp["account_id"] || get_in(resp, ["error", "account_id"]) do
      id when is_binary(id) and id != "" ->
        case partner_post("/partner/accounts/#{URI.encode(id)}/key", %{}) do
          {:ok, 200, %{"api_key" => key}} -> {:ok, %{account_id: id, api_key: key}}
          other -> {:error, describe(other)}
        end

      _ ->
        {:error, describe({:ok, 409, resp})}
    end
  end

  @refusals ~w(account_exists partner_quota invite_invalid invite_spent invite_expired)

  # The refusal's name is the error's type, or its `code` beside a generic
  # type (the gateway's `writeErrorCode`).
  defp error_type(%{"error" => %{} = err}),
    do: Enum.find([err["type"], err["code"]], &(&1 in @refusals))

  defp error_type(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, to_string(value))

  defp invite_reason("invalid"), do: :invalid
  defp invite_reason("spent"), do: :spent
  defp invite_reason("expired"), do: :expired

  @doc """
  Whether `code` would be accepted right now, without spending it:
  `{:ok, :available | :spent | :expired | :invalid}`. The gateway is the
  authority at creation; this is only so a person is refused before naming
  their bot rather than after the Telegram step.
  """
  def check_invite(code) do
    # A person is waiting on this one in the superbot's poll loop, so it gets a
    # short leash rather than the client's two-minute default.
    case partner_get("/partner/invites/check?code=" <> URI.encode_www_form(code),
           receive_timeout: 10_000
         ) do
      {:ok, 200, %{"status" => status}}
      when status in ["available", "spent", "expired", "invalid"] ->
        {:ok, invite_status(status)}

      other ->
        {:error, describe(other)}
    end
  end

  defp invite_status("available"), do: :available
  defp invite_status("spent"), do: :spent
  defp invite_status("expired"), do: :expired
  defp invite_status("invalid"), do: :invalid

  @doc "Suspend the account so its key stops working; history stays. Already suspended is `:ok`."
  def suspend(account_id) do
    case partner_post("/partner/accounts/#{URI.encode(account_id)}/suspend", %{}) do
      {:ok, 200, _} -> :ok
      other -> {:error, describe(other)}
    end
  end

  @doc """
  Removes every site of an account and frees its slug
  (`DELETE /partner/accounts/{id}/sites`). Works on a suspended account, which
  its own key cannot do, and removing nothing is `:ok`.
  """
  def delete_account_sites(account_id) do
    with {:ok, token} <- require_token(),
         {:ok, 200, _} <-
           Client.delete("/partner/accounts/#{URI.encode(account_id)}/sites", token,
             receive_timeout: partner_timeout()
           )
           |> partner_reply() do
      :ok
    else
      other -> {:error, describe(other)}
    end
  end

  @doc """
  This partner's accounts with unread support replies
  (`GET /partner/support/unread`): `{:ok, [%{"account_id", "unread", "latest_at"}]}`,
  or `{:error, reason}` when the gateway is down, refuses, or does not have the
  route yet. Answers within 5 s, because a minute's poll calls it.
  """
  def support_unread do
    case partner_get("/partner/support/unread", receive_timeout: @support_unread_timeout_ms) do
      {:ok, 200, %{"accounts" => list}} when is_list(list) ->
        {:ok, list}

      {:ok, 200, other} ->
        {:error, "unexpected unread payload: #{inspect(other) |> String.slice(0, 200)}"}

      other ->
        {:error, describe(other)}
    end
  end

  @doc """
  Binds an account to its Telegram bot and owner for ruoc's bot cabinet
  (`PUT /partner/accounts/{id}/telegram`): `{:ok, mini_app_url}`, the address
  the owner's menu button opens. Idempotent; ruoc logs only a change.
  """
  def bind_telegram(account_id, bot_id, owner_telegram_id)
      when is_binary(account_id) and is_integer(bot_id) and is_integer(owner_telegram_id) do
    body = %{bot_id: bot_id, owner_telegram_id: owner_telegram_id}

    case partner_put("/partner/accounts/#{URI.encode(account_id)}/telegram", body) do
      {:ok, 200, %{"mini_app_url" => url}} when is_binary(url) and url != "" -> {:ok, url}
      other -> {:error, describe(other)}
    end
  end

  @doc """
  The partner's own accounts: `{:ok, [%{account_id, external_ref, label,
  status, plan, created_at}]}`, `created_at` a `DateTime` or nil. Options
  `status` and `ref` filter on the gateway.
  """
  def list_accounts(opts \\ []) do
    query =
      [status: opts[:status], ref: opts[:ref]]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
      |> URI.encode_query()

    path = if query == "", do: "/partner/accounts", else: "/partner/accounts?" <> query

    case partner_get(path, receive_timeout: @partner_timeout_ms) do
      {:ok, 200, list} when is_list(list) ->
        {:ok, Enum.map(list, &to_account/1)}

      {:ok, 200, %{"accounts" => list}} when is_list(list) ->
        {:ok, Enum.map(list, &to_account/1)}

      {:ok, 200, other} ->
        {:error, "unexpected accounts payload: #{inspect(other) |> String.slice(0, 200)}"}

      other ->
        {:error, describe(other)}
    end
  end

  defp to_account(a) do
    created_at =
      case DateTime.from_iso8601(a["created_at"] || "") do
        {:ok, dt, _} -> DateTime.truncate(dt, :second)
        _ -> nil
      end

    %{
      account_id: a["account_id"],
      external_ref: a["external_ref"],
      label: a["label"],
      status: a["status"],
      plan: a["plan"],
      created_at: created_at
    }
  end

  # --- Bot-facing API --------------------------------------------------------

  @doc """
  Balance for a bot key. `{:ok, %{balance_rub: "12.50", balance_nanorub: int, subscription: sub | nil}}` —
  `balance_rub` is a plain two-decimal string (the gateway sends "12.5 RUB"), and
  `subscription` is `%{plan_name, credit_rub, period_days, status, period_end}` when
  the account is on a plan.
  """
  def balance(api_key) do
    case Client.get("/v1/balance", api_key) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"balance_nanorub" => nano} = payload} when is_integer(nano) ->
            {:ok,
             %{
               balance_rub: format_rub(nano),
               balance_nanorub: nano,
               subscription: subscription(payload["subscription"])
             }}

          _ ->
            {:error, "unexpected balance payload"}
        end

      {:ok, status, _headers, body} ->
        {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp subscription(%{"plan_name" => name, "status" => status} = sub) do
    period_end =
      case DateTime.from_iso8601(sub["current_period_end"] || "") do
        {:ok, dt, _} -> DateTime.truncate(dt, :second)
        _ -> nil
      end

    %{
      plan_name: name,
      credit_rub: format_rub(sub["credit_nanorub"] || 0),
      period_days: sub["period_days"],
      status: status,
      period_end: period_end
    }
  end

  defp subscription(_), do: nil

  @doc """
  The referral codes on a bot's account, oldest first:
  `%{code, status, redeemed_at, friend_rub, you_rub}`. `code` is nil when the
  gateway reports it underivable (its secret changed). `status` is one of
  available | redeemed | revoked | expired | underivable.
  """
  def referrals(api_key) do
    case Client.get("/v1/referrals", api_key) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"codes" => codes}} when is_list(codes) -> {:ok, Enum.map(codes, &to_referral/1)}
          _ -> {:error, "unexpected referrals payload"}
        end

      {:ok, status, _headers, body} ->
        {:error, describe({:ok, status, decode(body)})}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp to_referral(c) do
    redeemed_at =
      case DateTime.from_iso8601(c["redeemed_at"] || "") do
        {:ok, dt, _} -> DateTime.truncate(dt, :second)
        _ -> nil
      end

    %{
      code: c["code"],
      status: c["status"],
      redeemed_at: redeemed_at,
      friend_rub: format_rub(c["friend_gets_nanorub"] || 0),
      you_rub: format_rub(c["you_get_nanorub"] || 0)
    }
  end

  # Nanorubles to a two-decimal string, rounding half up, without floats.
  defp format_rub(nano) do
    kopecks = div(abs(nano) + 5_000_000, 10_000_000)
    sign = if nano < 0, do: "-", else: ""

    "#{sign}#{div(kopecks, 100)}.#{kopecks |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc """
  What this bot key has published (`GET /v1/sites`): `{:ok, [%{"name", "url",
  "files", "bytes", "published_at", "disabled"}]}`.
  """
  def sites(api_key) do
    case Client.get("/v1/sites", api_key, receive_timeout: partner_timeout())
         |> partner_reply() do
      {:ok, 200, %{"sites" => sites}} when is_list(sites) -> {:ok, sites}
      other -> {:error, describe(other)}
    end
  end

  @doc "`DELETE /v1/sites/{site}`, as the caller decides what its answer means: `{:ok, status, body}`."
  def delete_site(api_key, site) do
    Client.delete("/v1/sites/#{URI.encode(site)}", api_key, receive_timeout: partner_timeout())
    |> partner_reply()
  end

  @doc """
  The catalogue as last fetched, without waiting on ruoc: `[]` before the
  first fetch. A missing or expired cache starts one fetch in the background
  (at most one a minute), for callers that must answer now, like the panel.
  """
  def cached_models do
    now = System.monotonic_time(:millisecond)
    cached = :persistent_term.get(@cache_key, nil)

    with {fetched_at, _} when now - fetched_at < @cache_ttl_ms <- cached do
      :ok
    else
      _ ->
        case :persistent_term.get(@refresh_key, nil) do
          at when is_integer(at) and now - at < @cache_ttl_ms ->
            :ok

          _ ->
            :persistent_term.put(@refresh_key, now)
            Task.start(fn -> models() end)
        end
    end

    case cached do
      {_, list} -> list
      nil -> []
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
            # Keep serving the last good list (or nothing) and do not retry
            # before the TTL: every model picker would otherwise hit the
            # gateway again.
            list =
              case stale do
                {_, list} -> list
                nil -> []
              end

            :persistent_term.put(@cache_key, {now, list})
            list
        end
    end
  end

  def reset_cache do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@refresh_key)
  end

  def find_model(id), do: Enum.find(models(), &(&1.id == id))

  @doc "Models whose upstream reads images (`capabilities.attachment`)."
  def vision_models, do: Enum.filter(models(), &(&1.capabilities["attachment"] == true))

  @doc """
  What a bot's config needs to know about `model`, from the cached catalogue
  without waiting on ruoc: `{:ok, %{sees_images: bool, context: int | nil}}`;
  `:unknown_model` when the catalogue is loaded but does not list it; or
  `:no_catalogue` while the cached list is empty (never fetched, or the first
  fetch failed).
  """
  def model_facts(model) do
    case cached_models() do
      [] ->
        :no_catalogue

      list ->
        case Enum.find(list, &(&1.id == model)) do
          nil ->
            :unknown_model

          m ->
            {:ok, %{sees_images: m.capabilities["attachment"] == true, context: m.limits.context}}
        end
    end
  end

  @doc """
  The ruoc id a legacy OpenRouter model becomes at migration. Known ids pass
  through; the two GLMs map to their ruoc entries; anything else falls to
  the default.
  """
  def remap_model(nil), do: default_model()

  def remap_model(id) do
    cond do
      find_model(id) -> id
      id == "z-ai/glm-5.3-flash" -> "ruoc-flash"
      id == "z-ai/glm-5.3" -> "ruoc-standard"
      true -> default_model()
    end
  end

  @doc """
  The image catalogue, in ruoc's order: `[%{id, name, description,
  rub_per_image, default}]`. Not cached: it is read when a picker opens, and
  a failure is an answer the caller shows ("list unavailable"), not an
  empty picker.
  """
  def image_models do
    case catalog_key() do
      nil ->
        {:error, "ruoc_catalog_key is not set"}

      key ->
        case Client.get("/v1/images/models", key) do
          {:ok, 200, _headers, body} ->
            case Jason.decode(body) do
              {:ok, %{"models" => list}} when is_list(list) ->
                {:ok, Enum.map(list, &to_image_model/1)}

              _ ->
                {:error, "unexpected image models payload"}
            end

          {:ok, status, _headers, body} ->
            {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp to_image_model(m) do
    %{
      id: m["id"],
      name: m["name"] || m["id"],
      description: m["description"] || "",
      rub_per_image: m["rub_per_image"],
      default: m["default"] == true
    }
  end

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
      capabilities: m["capabilities"] || %{},
      limits: %{
        context: positive_int(get_in(m, ["limit", "context"])),
        output: positive_int(get_in(m, ["limit", "output"]))
      }
    }
  end

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_), do: nil

  # A create is safe to send twice (the ref), so a transport error or a
  # timeout gets one more try before it is given up.
  defp partner_post_retry(path, body) do
    case partner_post(path, body) do
      {:error, {:transport, _}} -> partner_post(path, body)
      other -> other
    end
  end

  defp partner_post(path, body) do
    with {:ok, token} <- require_token() do
      Client.post(path, token, Jason.encode!(body), receive_timeout: partner_timeout())
      |> partner_reply()
    end
  end

  defp partner_put(path, body) do
    with {:ok, token} <- require_token() do
      Client.put(path, token, Jason.encode!(body), receive_timeout: partner_timeout())
      |> partner_reply()
    end
  end

  defp partner_get(path, opts) do
    with {:ok, token} <- require_token() do
      Client.get(path, token, Keyword.put_new(opts, :receive_timeout, partner_timeout()))
      |> partner_reply()
    end
  end

  defp partner_reply({:ok, status, _headers, resp}), do: {:ok, status, decode(resp)}
  defp partner_reply({:error, reason}), do: {:error, {:transport, reason}}

  defp require_token do
    case partner_token() do
      nil -> {:error, "RUOC_PARTNER_TOKEN is not set"}
      token -> {:ok, token}
    end
  end

  defp partner_timeout,
    do: Application.get_env(:druzhok, :ruoc_partner_timeout_ms, @partner_timeout_ms)

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> body
    end
  end

  defp describe({:error, {:transport, reason}}), do: inspect(reason)
  defp describe({:error, reason}), do: reason
  defp describe({:ok, status, %{"error" => %{"message" => msg}}}), do: "HTTP #{status}: #{msg}"

  defp describe({:ok, status, body}),
    do: "HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}"
end
