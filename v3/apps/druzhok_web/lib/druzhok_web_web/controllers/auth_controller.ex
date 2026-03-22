defmodule DruzhokWebWeb.AuthController do
  use DruzhokWebWeb, :controller

  def create_session(conn, %{"email" => email, "password" => password}) do
    case Druzhok.User.authenticate(email, password) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> redirect(to: "/")
      {:error, _} ->
        conn
        |> redirect(to: "/login")
    end
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end
end
