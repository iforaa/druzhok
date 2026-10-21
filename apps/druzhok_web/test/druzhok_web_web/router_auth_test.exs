defmodule DruzhokWebWeb.RouterAuthTest do
  use DruzhokWebWeb.ConnCase, async: false

  @routes [
    "/v1/chat/completions",
    "/v1/embeddings",
    "/v1/images/generations",
    "/v1/audio/transcriptions",
    "/v1/audio/speech",
    "/v1/responses",
    "/v2/search"
  ]

  for route <- @routes do
    test "POST #{route} without key is 401", %{conn: conn} do
      conn = post(conn, unquote(route), %{})
      assert conn.status == 401
      assert %{"error" => %{"type" => "authentication_error"}} = Jason.decode!(conn.resp_body)
    end

    test "POST #{route} with bogus key is 401", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer nope") |> post(unquote(route), %{})
      assert conn.status == 401
    end
  end

  test "no browser routes are left", %{conn: conn} do
    for path <- ["/", "/login", "/settings", "/instances/x"] do
      assert get(build_conn(), path).status == 404
    end

    assert conn
  end
end
