defmodule DruzhokWebWeb.DashboardLiveTest do
  use DruzhokWebWeb.ConnCase
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    %{conn: conn, user: user} = log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "renders dashboard for authenticated user", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Druzhok"
    assert html =~ "No instances yet"
  end

  test "unauthenticated user is redirected to login", %{} do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/")
  end

  test "tab switching to files works", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    # Tab switching only applies when an instance is selected,
    # but the event handler should not crash regardless
    html = render_click(view, "tab", %{"tab" => "files"})
    assert is_binary(html)
  end

  test "tab switching to security works", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "tab", %{"tab" => "security"})
    assert is_binary(html)
  end

  test "tab switching to logs works", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    # Switch to files first, then back to logs
    render_click(view, "tab", %{"tab" => "files"})
    html = render_click(view, "tab", %{"tab" => "logs"})
    assert is_binary(html)
  end

  test "invalid tab name does not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "tab", %{"tab" => "nonexistent"})
    # Should still render without crashing
    assert is_binary(html)
  end

  test "toggle_create shows create form", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute html =~ "Instance name"

    html = render_click(view, "toggle_create")
    assert html =~ "Instance name"
  end

  test "create with empty name shows error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_submit(view, "create", %{"name" => "", "token" => "", "model" => ""})
    assert html =~ "Name and token required"
  end
end
