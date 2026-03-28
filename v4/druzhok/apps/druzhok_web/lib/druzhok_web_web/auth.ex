defmodule DruzhokWebWeb.Auth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)

    if user_id do
      case Druzhok.Repo.get(Druzhok.User, user_id) do
        nil ->
          conn |> clear_session() |> redirect(to: "/login") |> halt()
        user ->
          assign(conn, :current_user, user)
      end
    else
      conn |> redirect(to: "/login") |> halt()
    end
  end

  def require_admin(conn, _opts) do
    if conn.assigns[:current_user] && conn.assigns.current_user.role == "admin" do
      conn
    else
      conn |> put_flash(:error, "Admin access required") |> redirect(to: "/") |> halt()
    end
  end
end
