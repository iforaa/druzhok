defmodule Druzhok.InitDataFixture do
  @moduledoc """
  Init data as Telegram would hand it to a Mini App, signed with a test
  Ed25519 key (`key/0`, configured as `:telegram_init_key` where a test needs
  the panel to accept it) and the bot's token.
  """

  @doc "The test key pair, `{public, private}`, stable for the BEAM's life."
  def keys do
    case :persistent_term.get({__MODULE__, :keys}, nil) do
      nil ->
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
        :persistent_term.put({__MODULE__, :keys}, {pub, priv})
        {pub, priv}

      keys ->
        keys
    end
  end

  def key, do: elem(keys(), 0)

  @doc """
  Signed init data for `bot_id`/`token` and user `user_id`. Options:
  `:auth_date`, `:extra` (more `{k, v}` pairs, signed), `:sign_bot_id`,
  `:sign_token`, `:priv` (to sign with something else), `:raw_append`
  (appended after signing).
  """
  def build(bot_id, token, user_id, opts \\ []) do
    auth_date = Keyword.get(opts, :auth_date, System.system_time(:second))

    fields =
      [
        {"auth_date", Integer.to_string(auth_date)},
        {"query_id", "AAH#{user_id}"},
        {"user", Jason.encode!(%{id: user_id, first_name: "Igor"})}
      ] ++ Keyword.get(opts, :extra, [])

    priv = Keyword.get(opts, :priv, elem(keys(), 1))
    sign_bot = Keyword.get(opts, :sign_bot_id, bot_id)

    msg = "#{sign_bot}:WebAppData\n" <> check(fields)
    sig = :crypto.sign(:eddsa, :none, msg, [priv, :ed25519]) |> Base.url_encode64(padding: false)
    fields = fields ++ [{"signature", sig}]

    secret = :crypto.mac(:hmac, :sha256, "WebAppData", Keyword.get(opts, :sign_token, token))
    hash = :crypto.mac(:hmac, :sha256, secret, check(fields)) |> Base.encode16(case: :lower)

    URI.encode_query(fields ++ [{"hash", hash}], :www_form) <> Keyword.get(opts, :raw_append, "")
  end

  defp check(fields) do
    fields |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end
end
