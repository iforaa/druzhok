defmodule Druzhok.Panel.InitData do
  @moduledoc """
  Checks the init data Telegram hands a Mini App (bot panel spec
  `docs/superpowers/specs/2026-10-24-bot-panel-design.md`, "Authentication").

  Two signatures, both required:

  - Telegram's Ed25519 `signature` (the third-party scheme, as ruoc-gateway's
    `telegram_init.go`). Only Telegram holds that key, so a bot, which holds
    its own token, cannot mint init data for its owner.
  - The bot-token HMAC `hash` (the first-party scheme), which binds the data
    to this bot's current token.

  The pairs are split once into a single-valued map: a key that occurs twice
  is refused, and every signed string and every value read comes from that
  map, so what is checked is what is used.
  """

  @prod_key "e7bf03a2fa4602af4580703d88dda5bb59f32ed8b02a56c187fe7d34caed242d"
  # Telegram allows clocks to differ a little; more than this ahead is refused.
  @future_skew_s 60

  @doc "Telegram's production Ed25519 public key (raw 32 bytes)."
  def prod_key, do: Base.decode16!(@prod_key, case: :lower)

  @doc """
  `{:ok, %{user_id: id, auth_date: unix}}`, `{:error, :invalid}` or
  `{:error, :stale}`.

  Options: `:key` (Ed25519 public key, default Telegram's production key),
  `:max_age` seconds (default 24 h), `:now` unix seconds.
  """
  def verify(init_data, bot_id, token, opts \\ [])

  def verify(init_data, bot_id, token, opts)
      when is_binary(init_data) and init_data != "" and is_integer(bot_id) and bot_id > 0 and
             is_binary(token) and token != "" do
    key = Keyword.get(opts, :key, prod_key())
    max_age = Keyword.get(opts, :max_age, 24 * 60 * 60)
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, fields} <- parse(init_data),
         %{"signature" => sig_text, "hash" => hash, "auth_date" => auth_text, "user" => user_text} <-
           fields,
         {:ok, sig} <- Base.url_decode64(String.trim_trailing(sig_text, "="), padding: false),
         64 <- byte_size(sig),
         true <- ed25519_ok?(fields, bot_id, sig, key),
         true <- hmac_ok?(fields, hash, token),
         {auth_date, ""} when auth_date > 0 <- Integer.parse(auth_text),
         {:ok, %{"id" => user_id}} when is_integer(user_id) and user_id > 0 <-
           Jason.decode(user_text) do
      # Too old, or from the future (a clock off by more than the skew):
      # either way, reopening the panel gets fresh data.
      if now - auth_date > max_age or auth_date > now + @future_skew_s,
        do: {:error, :stale},
        else: {:ok, %{user_id: user_id, auth_date: auth_date}}
    else
      _ -> {:error, :invalid}
    end
  end

  def verify(_init_data, _bot_id, _token, _opts), do: {:error, :invalid}

  # application/x-www-form-urlencoded, as Go's url.ParseQuery reads it.
  defp parse(init_data) do
    init_data
    |> String.split("&", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
      {k, v} =
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end

      with {:ok, k} <- decode(k),
           {:ok, v} <- decode(v),
           false <- Map.has_key?(acc, k) do
        {:cont, {:ok, Map.put(acc, k, v)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp decode(s) do
    {:ok, URI.decode_www_form(s)}
  rescue
    ArgumentError -> :error
  end

  defp ed25519_ok?(fields, bot_id, sig, key) do
    msg = "#{bot_id}:WebAppData\n" <> check_string(fields, ["hash", "signature"])
    :crypto.verify(:eddsa, :none, msg, sig, [key, :ed25519])
  end

  defp hmac_ok?(fields, hash, token) do
    secret = :crypto.mac(:hmac, :sha256, "WebAppData", token)
    want = :crypto.mac(:hmac, :sha256, secret, check_string(fields, ["hash"]))
    got = String.downcase(hash)
    want = Base.encode16(want, case: :lower)
    byte_size(got) == byte_size(want) and :crypto.hash_equals(got, want)
  end

  defp check_string(fields, skip) do
    fields
    |> Enum.reject(fn {k, _} -> k in skip end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end
end
