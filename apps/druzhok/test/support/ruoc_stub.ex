defmodule Druzhok.RuocStub do
  @moduledoc """
  A fake ruoc-gateway on Bypass: partner account provisioning, key reissue,
  suspend and listing, balance and the model catalog. Points `Druzhok.Ruoc` at it for the test and clears
  the model cache and settings on exit.

  Configuration goes through app env, not settings rows, so the stub works
  the same inside a web test's SQL sandbox and in a core test without one.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @partner_token "ruoc_pk_test0000000000000000000000000000"
  @catalog_key "ruoc_catalog0000000000000000000000000000"

  def partner_token, do: @partner_token
  def catalog_key, do: @catalog_key

  @doc "Start the stub and configure `Druzhok.Ruoc` to use it."
  def start(opts \\ []) do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    env = %{ruoc_url: base, ruoc_partner_token: @partner_token, ruoc_catalog_key: @catalog_key}
    prev = Map.new(env, fn {k, _} -> {k, Application.get_env(:druzhok, k)} end)
    for {k, v} <- env, do: Application.put_env(:druzhok, k, v)
    Druzhok.Ruoc.reset_cache()

    on_exit(fn ->
      for {k, v} <- prev do
        if v, do: Application.put_env(:druzhok, k, v), else: Application.delete_env(:druzhok, k)
      end

      Druzhok.Ruoc.reset_cache()
    end)

    {:ok, calls} = Agent.start(fn -> [] end)
    on_exit(fn -> Agent.stop(calls) end)
    stub = %{bypass: bypass, base: base, calls: calls}

    if Keyword.get(opts, :routes, true), do: default_routes(stub)
    stub
  end

  def default_routes(%{bypass: bypass} = stub) do
    Bypass.stub(bypass, "POST", "/partner/accounts", fn conn ->
      conn = record(stub, "POST /partner/accounts", conn)
      n = System.unique_integer([:positive])
      reply(conn, 201, %{"account_id" => "acct-#{n}", "api_key" => "ruoc_key#{n}"})
    end)

    Bypass.stub(bypass, "POST", "/partner/accounts/:id/key", fn conn ->
      conn = record(stub, "POST /partner/accounts/:id/key", conn)
      reply(conn, 200, %{"api_key" => "ruoc_rekey#{System.unique_integer([:positive])}"})
    end)

    Bypass.stub(bypass, "POST", "/partner/accounts/:id/suspend", fn conn ->
      conn = record(stub, "POST /partner/accounts/:id/suspend", conn)
      reply(conn, 200, %{"status" => "suspended"})
    end)

    Bypass.stub(bypass, "GET", "/partner/accounts", fn conn ->
      conn = record(stub, "GET /partner/accounts", conn)
      reply(conn, 200, [])
    end)

    Bypass.stub(bypass, "GET", "/v1/balance", fn conn ->
      conn = record(stub, "GET /v1/balance", conn)
      reply(conn, 200, %{"balance_nanorub" => 12_500_000_000, "balance_rub" => "12.5 RUB", "grants" => [], "models" => []})
    end)

    Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
      conn = record(stub, "GET /v1/models", conn)
      reply(conn, 200, %{"object" => "list", "data" => models()})
    end)

    Bypass.stub(bypass, "POST", "/v1/fetch", fn conn ->
      conn = record(stub, "POST /v1/fetch", conn)
      url = conn |> read_recorded(stub, "POST /v1/fetch") |> Map.get("url", "")
      reply(conn, 200, %{"request_id" => "req_fetch", "url" => url, "final_url" => url, "title" => "Example Domain",
        "markdown" => "# Example Domain\n\nThis domain is for use in illustrative examples.", "status_code" => 200})
    end)

    Bypass.stub(bypass, "GET", "/v1/images/models", fn conn ->
      conn = record(stub, "GET /v1/images/models", conn)
      reply(conn, 200, %{"models" => image_models()})
    end)

    Bypass.stub(bypass, "GET", "/partner/invites/check", fn conn ->
      conn = record(stub, "GET /partner/invites/check", conn)
      reply(conn, 200, %{"status" => "available"})
    end)

    Bypass.stub(bypass, "GET", "/v1/referrals", fn conn ->
      conn = record(stub, "GET /v1/referrals", conn)
      reply(conn, 200, %{"codes" => referral_codes()})
    end)
  end

  def referral_codes do
    [
      %{"code" => "AAAA-BBBB", "status" => "available", "friend_gets_nanorub" => 0, "you_get_nanorub" => 20_000_000_000},
      %{"code" => "CCCC-DDDD", "status" => "redeemed", "redeemed_at" => "2026-10-05T09:00:00Z",
        "friend_gets_nanorub" => 0, "you_get_nanorub" => 20_000_000_000}
    ]
  end

  def image_models do
    [
      %{"id" => "ruoc-flux-klein", "name" => "FLUX 2 Klein", "description" => "быстрая", "rub_per_image" => "2", "default" => true},
      %{"id" => "ruoc-flux-pro", "name" => "FLUX 2 Pro", "description" => "", "rub_per_image" => "5", "default" => false}
    ]
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

  @doc "Unset one ruoc setting for the rest of the test."
  def unset(key) when key in [:ruoc_partner_token, :ruoc_catalog_key] do
    Application.put_env(:druzhok, key, "")
  end

  @doc "Recorded calls to `route`: `[%{headers, params, path}]`, oldest first."
  def calls(%{calls: calls}, route) do
    calls |> Agent.get(& &1) |> Enum.reverse() |> Enum.filter(&(&1.route == route))
  end

  defp read_recorded(_conn, stub, route) do
    case calls(stub, route) do
      [] -> %{}
      list -> List.last(list).params
    end
  end

  @doc "Record a call to `route` from a test's own handler (as the default routes do)."
  def record(%{calls: calls}, route, conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    params = if raw == "", do: %{}, else: Jason.decode!(raw)
    Agent.update(calls, &[%{route: route, params: params, headers: conn.req_headers, path: conn.request_path, query: conn.query_string} | &1])
    conn
  end

  def reply(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
