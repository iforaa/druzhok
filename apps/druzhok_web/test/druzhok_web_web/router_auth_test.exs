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

  for path <- ["/usage", "/errors", "/settings"] do
    test "GET #{path} as non-admin redirects to /", %{conn: conn} do
      %{conn: conn} = log_in_user(conn, %{email: "u#{System.unique_integer([:positive])}@x.test"})
      conn = get(conn, unquote(path))
      assert redirected_to(conn) == "/"
    end
  end
end
