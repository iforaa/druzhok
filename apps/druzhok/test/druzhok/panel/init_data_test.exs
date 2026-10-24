defmodule Druzhok.Panel.InitDataTest do
  use ExUnit.Case, async: true

  alias Druzhok.InitDataFixture, as: F
  alias Druzhok.Panel.InitData

  @bot 8_437_439_808
  @token "8437439808:AAtesttoken"
  @user 601_956

  defp verify(data, opts \\ []),
    do: InitData.verify(data, @bot, @token, Keyword.put_new(opts, :key, F.key()))

  test "genuine init data passes and names the user" do
    assert {:ok, %{user_id: @user}} = verify(F.build(@bot, @token, @user))
  end

  test "a valid token HMAC without Telegram's signature fails: a bot cannot mint it" do
    {_pub, other_priv} = :crypto.generate_key(:eddsa, :ed25519)
    assert {:error, :invalid} = verify(F.build(@bot, @token, @user, priv: other_priv))

    no_sig =
      F.build(@bot, @token, @user)
      |> URI.decode_query()
      |> Map.delete("signature")
      |> URI.encode_query()

    assert {:error, :invalid} = verify(no_sig)
  end

  test "a valid signature with the wrong token's HMAC fails" do
    assert {:error, :invalid} = verify(F.build(@bot, @token, @user, sign_token: "1:other"))
  end

  test "init data signed for another bot fails" do
    assert {:error, :invalid} = verify(F.build(@bot, @token, @user, sign_bot_id: 42))
  end

  test "a changed field fails" do
    data = F.build(@bot, @token, @user) |> String.replace("query_id=AAH", "query_id=AAX")
    assert {:error, :invalid} = verify(data)
  end

  test "a duplicated key fails, so an appended user cannot replace the signed one" do
    extra = "&user=" <> URI.encode_www_form(Jason.encode!(%{id: 1}))
    assert {:error, :invalid} = verify(F.build(@bot, @token, @user, raw_append: extra))
  end

  test "a padded signature passes, as ruoc accepts it" do
    data = F.build(@bot, @token, @user)
    %{"signature" => sig} = URI.decode_query(data)
    padded = String.replace(data, "signature=" <> sig, "signature=" <> sig <> "%3D%3D")
    # The HMAC covers `signature` as sent, so the padded form is re-hashed.
    fields = URI.decode_query(padded) |> Map.delete("hash")
    secret = :crypto.mac(:hmac, :sha256, "WebAppData", @token)

    check =
      fields |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)

    hash = :crypto.mac(:hmac, :sha256, secret, check) |> Base.encode16(case: :lower)
    assert {:ok, _} = verify(URI.encode_query(Map.put(fields, "hash", hash)))
  end

  test "stale and future auth_date" do
    now = System.system_time(:second)
    assert {:error, :stale} = verify(F.build(@bot, @token, @user, auth_date: now - 90_000))
    assert {:ok, _} = verify(F.build(@bot, @token, @user, auth_date: now - 3600))
    assert {:error, :stale} = verify(F.build(@bot, @token, @user, auth_date: now + 600))
    assert {:ok, _} = verify(F.build(@bot, @token, @user, auth_date: now + 30))

    assert {:error, :stale} =
             verify(F.build(@bot, @token, @user, auth_date: now - 120), max_age: 60)
  end

  test "garbage" do
    assert {:error, :invalid} = verify("")
    assert {:error, :invalid} = verify("a=b")
    assert {:error, :invalid} = InitData.verify(F.build(@bot, @token, @user), @bot, nil)
    assert {:error, :invalid} = InitData.verify("%zz", @bot, @token)
  end

  test "Telegram's production key is the one in ruoc" do
    assert byte_size(InitData.prod_key()) == 32
  end
end
