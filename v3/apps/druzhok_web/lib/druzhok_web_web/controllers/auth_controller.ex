defmodule DruzhokWebWeb.AuthController do
  use DruzhokWebWeb, :controller

  @max_attempts 5
  @window_ms 60_000

  def create_session(conn, %{"email" => email, "password" => password}) do
    case check_rate_limit(conn) do
      :rate_limited ->
        conn
        |> put_flash(:error, "Too many login attempts. Try again later.")
        |> redirect(to: "/login")

      :ok ->
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
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end

  defp check_rate_limit(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(:auth_rate_limit, ip) do
      [{^ip, count, first_at}] when now - first_at < @window_ms and count >= @max_attempts ->
        :rate_limited

      [{^ip, count, first_at}] when now - first_at < @window_ms ->
        :ets.insert(:auth_rate_limit, {ip, count + 1, first_at})
        :ok

      _ ->
        :ets.insert(:auth_rate_limit, {ip, 1, now})
        :ok
    end
  end
end
