defmodule Druzhok.TestUsernames do
  @moduledoc "The getMe stand-in for `Druzhok.Telegram.Addressed`: `%{token => username}` in app env."
  def lookup(token), do: Map.get(Application.get_env(:druzhok, :test_usernames, %{}), token)

  @doc "The getMe stand-in for `Druzhok.Panel.profile/1`: `%{token => getMe result}` in app env."
  def get_me(token) do
    case Map.get(Application.get_env(:druzhok, :test_profiles, %{}), token) do
      nil -> {:error, :not_found}
      me -> {:ok, me}
    end
  end
end
