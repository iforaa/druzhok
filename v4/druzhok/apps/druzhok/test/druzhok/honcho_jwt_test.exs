defmodule Druzhok.HonchoJwtTest do
  use ExUnit.Case, async: false

  alias Druzhok.HonchoJwt

  @secret "test-secret-not-real-32-bytes-long"

  setup do
    prev = System.get_env("HONCHO_JWT_SECRET")
    System.put_env("HONCHO_JWT_SECRET", @secret)

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("HONCHO_JWT_SECRET")
        v -> System.put_env("HONCHO_JWT_SECRET", v)
      end
    end)

    :ok
  end

  test "mints a JWT-shaped token" do
    {:ok, token} = HonchoJwt.mint_workspace_token("vasya")
    assert is_binary(token)
    assert String.match?(token, ~r/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/)
  end

  test "claims contain workspace name" do
    {:ok, token} = HonchoJwt.mint_workspace_token("vasya")
    [_h, payload, _s] = String.split(token, ".")
    decoded = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert decoded["w"] == "vasya"
  end

  test "different workspaces produce different tokens" do
    {:ok, t1} = HonchoJwt.mint_workspace_token("vasya")
    {:ok, t2} = HonchoJwt.mint_workspace_token("vilya")
    assert t1 != t2
  end

  test "raises on missing secret" do
    System.delete_env("HONCHO_JWT_SECRET")

    assert_raise RuntimeError, ~r/HONCHO_JWT_SECRET/, fn ->
      HonchoJwt.mint_workspace_token("vasya")
    end
  end

  test "rejects empty workspace name" do
    assert_raise FunctionClauseError, fn ->
      HonchoJwt.mint_workspace_token("")
    end
  end
end
