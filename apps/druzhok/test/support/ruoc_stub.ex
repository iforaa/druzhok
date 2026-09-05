defmodule Druzhok.RuocStub do
  @moduledoc """
  A fake ruoc-gateway on Bypass: admin account provisioning, status, balance
  and the model catalog. Points `Druzhok.Ruoc` at it for the test and clears
  the model cache and settings on exit.

  Core tests run outside a sandbox, so settings rows are removed in on_exit.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  alias Druzhok.{Repo, Settings}

  @admin_token "test-admin-token"
  @catalog_key "ruoc_catalog0000000000000000000000000000"

  def admin_token, do: @admin_token
  def catalog_key, do: @catalog_key

  @doc "Start the stub and configure `Druzhok.Ruoc` to use it."
  def start(opts \\ []) do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    prev_url = Application.get_env(:druzhok, :ruoc_url)
    Application.put_env(:druzhok, :ruoc_url, base)
    Settings.set("ruoc_admin_token", @admin_token)
    Settings.set("ruoc_admin_host", "admin.test")
    Settings.set("ruoc_catalog_key", @catalog_key)
    Druzhok.Ruoc.reset_cache()

    on_exit(fn ->
      if prev_url, do: Application.put_env(:druzhok, :ruoc_url, prev_url), else: Application.delete_env(:druzhok, :ruoc_url)
      for key <- Settings.ruoc_keys(), s = Repo.get_by(Settings, key: key), do: Repo.delete(s)
      Druzhok.Ruoc.reset_cache()
    end)

    {:ok, calls} = Agent.start(fn -> [] end)
    on_exit(fn -> Agent.stop(calls) end)
    stub = %{bypass: bypass, base: base, calls: calls}

    if Keyword.get(opts, :routes, true), do: default_routes(stub)
    stub
  end

  def default_routes(%{bypass: bypass} = stub) do
    Bypass.stub(bypass, "POST", "/admin/accounts", fn conn ->
      conn = record(stub, "POST /admin/accounts", conn)
      n = System.unique_integer([:positive])
      reply(conn, 201, %{"account_id" => "acct-#{n}", "api_key" => "ruoc_key#{n}"})
    end)

    Bypass.stub(bypass, "POST", "/admin/accounts/:id/status", fn conn ->
      conn = record(stub, "POST /admin/accounts/:id/status", conn)
      reply(conn, 200, %{"status" => "suspended"})
    end)

    Bypass.stub(bypass, "GET", "/v1/balance", fn conn ->
      conn = record(stub, "GET /v1/balance", conn)
      reply(conn, 200, %{"balance_nanorub" => 12_500_000_000, "balance_rub" => "12.5", "grants" => [], "models" => []})
    end)

    Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
      conn = record(stub, "GET /v1/models", conn)
      reply(conn, 200, %{"object" => "list", "data" => models()})
    end)
  end

  def models do
    [
      %{
        "id" => "ruoc-flash",
        "name" => "GLM 5.3 Flash",
        "limit" => %{"context" => 131_072, "output" => 32_768},
        "capabilities" => %{"tools" => true, "attachment" => true},
        "price" => %{"input_rub_per_million" => "12", "output_rub_per_million" => "38"}
      },
      %{
        "id" => "ruoc-standard",
        "name" => "GLM 5.3",
        "limit" => %{"context" => 131_072, "output" => 32_768},
        "capabilities" => %{"tools" => true, "attachment" => false},
        "price" => %{"input_rub_per_million" => "210", "output_rub_per_million" => "660"}
      }
    ]
  end

  @doc "Recorded calls to `route`: `[%{headers, params, path}]`, oldest first."
  def calls(%{calls: calls}, route) do
    calls |> Agent.get(& &1) |> Enum.reverse() |> Enum.filter(&(&1.route == route))
  end

  defp record(%{calls: calls}, route, conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    params = if raw == "", do: %{}, else: Jason.decode!(raw)
    Agent.update(calls, &[%{route: route, params: params, headers: conn.req_headers, path: conn.request_path} | &1])
    conn
  end

  def reply(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
