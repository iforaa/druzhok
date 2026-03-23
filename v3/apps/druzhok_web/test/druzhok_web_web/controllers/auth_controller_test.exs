defmodule DruzhokWebWeb.AuthControllerTest do
  use DruzhokWebWeb.ConnCase

  test "rate limits login attempts after 5 failures", %{conn: conn} do
    for _ <- 1..5 do
      post(conn, "/auth/session", %{email: "bad", password: "bad"})
    end

    conn = post(conn, "/auth/session", %{email: "bad", password: "bad"})
    assert redirected_to(conn) =~ "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many"
  end
end
