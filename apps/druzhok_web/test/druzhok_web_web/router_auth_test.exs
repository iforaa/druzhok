defmodule DruzhokWebWeb.RouterAuthTest do
  use DruzhokWebWeb.ConnCase, async: false

  @routes [
    "/v1/chat/completions",
    "/v1/embeddings",
    "/v1/images/generations",
    "/v1/audio/transcriptions",
    "/v1/audio/speech",
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

  test "the site routes need a tenant key" do
    gzip = put_req_header(build_conn(), "content-type", "application/gzip")

    assert put(gzip, "/v2/sites/cv", "").status == 401
    assert delete(build_conn(), "/v2/sites/cv").status == 401

    assert gzip
           |> put_req_header("authorization", "Bearer nope")
           |> put("/v2/sites/cv", "")
           |> Map.get(:status) == 401
  end

  test "the removed OpenRouter passthrough stays removed" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer nope")
      |> post("/v1/responses", %{})

    assert conn.status == 404
  end

  test "no browser routes are left", %{conn: conn} do
    for path <- ["/", "/login", "/settings", "/instances/x"] do
      assert get(build_conn(), path).status == 404
    end

    assert conn
  end
end
