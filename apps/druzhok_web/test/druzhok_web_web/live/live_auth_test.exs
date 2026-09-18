defmodule DruzhokWebWeb.LiveAuthTest do
  @moduledoc """
  Live navigation happens over the already-open websocket and never runs the
  router's plug pipelines. Two things keep it out of the protected LiveViews:
  separate `live_session`s (crossing one forces a full page load, which the
  plugs guard) and the `LiveAuth` on_mount hooks (for navigation inside one).
  """
  use DruzhokWebWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # A refused live navigation comes back as a redirect to the full URL: the
  # browser reloads the page. Follow it the way the browser would.
  defp reload(conn, view, path) do
    assert {:error, {:redirect, %{to: url}}} = live_redirect(view, to: path)
    assert URI.parse(url).path == path
    get(conn, path)
  end

  describe "live navigation from the public login page" do
    for path <- ["/", "/instances/some-bot", "/usage", "/errors", "/settings"] do
      test "an anonymous visitor cannot reach #{path}", %{conn: conn} do
        {:ok, view, _html} = live(conn, "/login")

        assert conn |> reload(view, unquote(path)) |> redirected_to() == "/login"
      end
    end
  end

  describe "live navigation from the dashboard" do
    for path <- ["/usage", "/errors", "/settings"] do
      test "a non-admin cannot reach #{path}", %{conn: conn} do
        %{conn: conn} = log_in_user(conn)
        {:ok, view, _html} = live(conn, "/")

        assert conn |> reload(view, unquote(path)) |> redirected_to() == "/"
      end
    end

    test "an admin reaches the admin pages", %{conn: conn} do
      %{conn: conn, user: user} = log_in_user(conn)
      {:ok, _admin} = user |> Ecto.Changeset.change(role: "admin") |> Druzhok.Repo.update()
      {:ok, view, _html} = live(conn, "/")

      assert conn |> reload(view, "/usage") |> html_response(200)
      assert {:ok, _usage, _html} = live(conn, "/usage")
    end
  end

  describe "on_mount hooks, navigating inside one live_session" do
    test "a session whose user was deleted is sent to login", %{conn: conn} do
      %{conn: conn, user: user} = log_in_user(conn)
      {:ok, view, _html} = live(conn, "/")

      Druzhok.Repo.delete!(user)

      assert {:error, {:redirect, %{to: "/login"}}} = live_redirect(view, to: "/instances/some-bot")
    end

    test "an admin demoted mid-session loses the admin pages", %{conn: conn} do
      %{conn: conn, user: user} = log_in_user(conn)
      {:ok, admin} = user |> Ecto.Changeset.change(role: "admin") |> Druzhok.Repo.update()
      {:ok, view, _html} = live(conn, "/usage")

      {:ok, _} = admin |> Ecto.Changeset.change(role: "user") |> Druzhok.Repo.update()

      assert {:error, {:redirect, %{to: "/"}}} = live_redirect(view, to: "/errors")
    end
  end
end
