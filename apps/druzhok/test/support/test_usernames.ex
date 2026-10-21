defmodule Druzhok.TestUsernames do
  @moduledoc "The getMe stand-in for `Druzhok.Telegram.Addressed`: `%{token => username}` in app env."
  def lookup(token), do: Map.get(Application.get_env(:druzhok, :test_usernames, %{}), token)
end
