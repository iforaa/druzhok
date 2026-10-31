defmodule DruzhokWebWeb.Plugs.PanelAuth do
  @moduledoc """
  Authenticates a bot panel API request (bot panel spec, "Authentication"),
  after `Plugs.Edge`: rate limit per client IP, Telegram's init data (Ed25519
  signature and bot-token HMAC, `Druzhok.Panel.InitData`), freshness, the
  bot's owner, the cabinet not switched off. Assigns `:instance`.

  Errors use ruoc's envelope, `{"error": {"type", "message"}}`, so the page's
  shared `api.ts` reads both APIs the same way.
  """

  import Plug.Conn
  alias Druzhok.Panel
  alias Druzhok.Panel.InitData

  @per_minute 60

  def init(opts), do: opts

  def call(conn, _opts) do
    with :ok <- limit(conn),
         {:ok, init_data, bot_id} <- credentials(conn),
         {:ok, inst} <- bot(bot_id),
         {:ok, who} <- verify(init_data, bot_id, inst),
         :ok <- owner(inst, who),
         :ok <- cabinet_on(inst) do
      conn |> assign(:instance, inst) |> assign(:auth_date, who.auth_date)
    else
      {:error, status, type, message} -> error(conn, status, type, message)
    end
  end

  @doc "Sends an error in ruoc's envelope; `extra` goes beside its type and message."
  def error(conn, status, type, message, extra \\ %{}) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(
      status,
      Jason.encode!(%{error: Map.merge(extra, %{type: type, message: message})})
    )
    |> halt()
  end

  # The last X-Forwarded-For hop is Caddy's view of the client; Plugs.Edge
  # has proven the request came through Caddy.
  defp limit(conn) do
    ip =
      case get_req_header(conn, "x-forwarded-for") do
        [xff | _] -> xff |> String.split(",") |> List.last() |> String.trim()
        [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
      end

    if DruzhokWebWeb.Panel.Limiter.allow?(ip, @per_minute),
      do: :ok,
      else: {:error, 429, "rate_limit_error", "too many requests; try again shortly"}
  end

  defp credentials(conn) do
    with ["tma " <> init_data] <- get_req_header(conn, "authorization"),
         [bot] <- get_req_header(conn, "x-telegram-bot"),
         bot = String.trim(bot),
         true <- Regex.match?(~r/^\d{1,20}$/, bot),
         {bot_id, ""} <- Integer.parse(bot) do
      {:ok, init_data, bot_id}
    else
      _ -> invalid()
    end
  end

  defp bot(bot_id) do
    case Panel.find_bot(bot_id) do
      nil -> {:error, 404, "not_found", "this bot has no panel"}
      inst -> {:ok, inst}
    end
  end

  defp verify(init_data, bot_id, inst) do
    opts =
      [max_age: Application.get_env(:druzhok, :panel_init_max_age, 24 * 60 * 60)] ++
        case Application.get_env(:druzhok, :telegram_init_key) do
          key when is_binary(key) -> [key: key]
          nil -> []
        end

    case InitData.verify(init_data, bot_id, inst.telegram_token, opts) do
      {:ok, who} -> {:ok, who}
      {:error, :stale} -> {:error, 401, "init_stale", "close the panel and open it again"}
      {:error, :invalid} -> invalid()
    end
  end

  defp invalid, do: {:error, 401, "init_invalid", "open the panel from the bot"}

  defp owner(%{owner_telegram_id: owner}, %{user_id: owner}) when is_integer(owner), do: :ok

  defp owner(_inst, _who),
    do: {:error, 403, "not_owner", "only the bot's owner can open its panel"}

  defp cabinet_on(%{cabinet_off: true}),
    do: {:error, 403, "cabinet_off", "the panel is switched off for this bot"}

  defp cabinet_on(_inst), do: :ok
end
