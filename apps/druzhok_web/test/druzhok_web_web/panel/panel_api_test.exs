defmodule DruzhokWebWeb.PanelApiTest do
  use DruzhokWebWeb.ConnCase

  alias Druzhok.{Instance, Repo}
  alias Druzhok.InitDataFixture, as: F

  @edge "edge-secret"
  @token "123:secret"

  setup do
    root = Path.join(System.tmp_dir!(), "panelapi-#{System.unique_integer([:positive])}")
    prev = System.get_env("DRUZHOK_DATA_ROOT")
    System.put_env("DRUZHOK_DATA_ROOT", root)
    Application.put_env(:druzhok, :edge_secret, @edge)
    Application.put_env(:druzhok, :telegram_init_key, F.key())
    Application.put_env(:druzhok, :panel_lister, {Druzhok.FakeFind, :list})

    on_exit(fn ->
      if prev,
        do: System.put_env("DRUZHOK_DATA_ROOT", prev),
        else: System.delete_env("DRUZHOK_DATA_ROOT")

      for k <- [:edge_secret, :telegram_init_key, :panel_lister],
          do: Application.delete_env(:druzhok, k)

      File.rm_rf!(root)
    end)

    n = System.unique_integer([:positive])

    inst =
      Repo.insert!(%Instance{
        name: "panel#{n}",
        model: "m",
        workspace: Path.join([root, "panel#{n}", "workspace"]),
        telegram_token: @token,
        owner_telegram_id: 456,
        active: false
      })

    dir = Path.join(root, inst.name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SOUL.md"), "# Вася")
    %{inst: inst, dir: dir}
  end

  defp api(conn, path, opts \\ []) do
    init = Keyword.get(opts, :init, F.build(123, @token, Keyword.get(opts, :user, 456)))

    conn
    |> then(
      &if(e = Keyword.get(opts, :edge, @edge),
        do: put_req_header(&1, "x-druzhok-edge", e),
        else: &1
      )
    )
    |> put_req_header("authorization", "tma " <> init)
    |> put_req_header("x-telegram-bot", Keyword.get(opts, :bot, "123"))
    |> put_req_header(
      "x-forwarded-for",
      Keyword.get(opts, :ip, "203.0.113.#{System.unique_integer([:positive]) |> rem(250)}")
    )
    |> get(path)
  end

  defp error_type(conn), do: Jason.decode!(conn.resp_body)["error"]["type"]

  test "the owner gets the bot view and a Markdown file", %{conn: conn} do
    conn1 = api(conn, "/app/api/bot")
    assert conn1.status == 200
    assert get_resp_header(conn1, "cache-control") == ["no-store"]
    body = Jason.decode!(conn1.resp_body)
    assert body["bot_id"] == 123 and body["state"] == "stopped"
    refute conn1.resp_body =~ @token

    conn2 = api(build_conn(), "/app/api/files/soul")
    assert Jason.decode!(conn2.resp_body)["text"] == "# Вася"

    assert api(build_conn(), "/app/api/files/memory").status == 404
    assert api(build_conn(), "/app/api/files").status == 200
    assert api(build_conn(), "/app/api/jobs").status == 200
    assert api(build_conn(), "/app/api/skills").status == 200
    assert api(build_conn(), "/app/api/site").status == 200
    assert api(build_conn(), "/app/api/skills/nope").status == 404

    # No ruoc key: the invites cannot load, and say so.
    conn3 = api(build_conn(), "/app/api/invites")
    assert conn3.status == 502 and error_type(conn3) == "invites_unavailable"
  end

  defp real_asset do
    static = Path.join([Application.app_dir(:druzhok_web, "priv"), "static", "app"])
    html = File.read!(Path.join(static, "index.html"))

    [ref | _] =
      Regex.scan(~r{/app/(assets/[^"]+)}, html, capture: :all_but_first) |> List.flatten()

    "/app/" <> ref
  end

  defp page(path, edge) do
    conn = if edge, do: put_req_header(build_conn(), "x-druzhok-edge", edge), else: build_conn()
    get(conn, path).status
  end

  test "no edge header, a wrong one, or none configured: 404 for API, page and bundle", %{
    conn: conn
  } do
    asset = real_asset()
    assert page(asset, @edge) == 200 and page("/app/", @edge) == 200

    assert api(conn, "/app/api/bot", edge: nil).status == 404
    assert api(build_conn(), "/app/api/bot", edge: "wrong").status == 404

    for edge <- [nil, "wrong"], path <- ["/app/", asset] do
      assert page(path, edge) == 404, "#{path} with #{inspect(edge)}"
    end

    Application.delete_env(:druzhok, :edge_secret)
    assert api(build_conn(), "/app/api/bot").status == 404
    assert page("/app/", @edge) == 404
    assert page(asset, @edge) == 404
  end

  test "refusals use ruoc's error envelope", %{conn: conn, inst: inst} do
    c = api(conn, "/app/api/bot", user: 789)
    assert {c.status, error_type(c)} == {403, "not_owner"}

    c = api(build_conn(), "/app/api/bot", bot: "999")
    assert {c.status, error_type(c)} == {404, "not_found"}

    c = api(build_conn(), "/app/api/bot", init: "auth_date=1&user=%7B%7D")
    assert {c.status, error_type(c)} == {401, "init_invalid"}

    stale = F.build(123, @token, 456, auth_date: System.system_time(:second) - 100_000)
    c = api(build_conn(), "/app/api/bot", init: stale)
    assert {c.status, error_type(c)} == {401, "init_stale"}

    # Signed by a bot that knows its token but not Telegram's key.
    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    c = api(build_conn(), "/app/api/bot", init: F.build(123, @token, 456, priv: priv))
    assert {c.status, error_type(c)} == {401, "init_invalid"}

    Repo.update!(Ecto.Changeset.change(inst, cabinet_off: true))
    c = api(build_conn(), "/app/api/bot")
    assert {c.status, error_type(c)} == {403, "cabinet_off"}

    Repo.update!(Ecto.Changeset.change(inst, cabinet_off: false, delete_requested: true))
    c = api(build_conn(), "/app/api/bot")
    assert {c.status, error_type(c)} == {404, "not_found"}
  end

  test "61 requests a minute from one address are refused", %{conn: conn} do
    statuses = for _ <- 1..61, do: api(conn, "/app/api/bot", ip: "198.51.100.7").status
    assert Enum.count(statuses, &(&1 == 200)) == 60
    c = api(build_conn(), "/app/api/bot", ip: "198.51.100.7")
    assert {c.status, error_type(c)} == {429, "rate_limit_error"}
  end

  test "the page carries the Mini App policy" do
    conn = build_conn() |> put_req_header("x-druzhok-edge", @edge) |> get("/app/")
    assert conn.status == 200
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors https://web.telegram.org"
    assert csp =~ "connect-src 'self' https://oldey.dev"
    assert csp =~ "script-src 'self' https://telegram.org"
    assert conn.resp_body =~ "/app/assets/"
  end

  test "the committed page references bundle files that are committed" do
    static = Path.join([Application.app_dir(:druzhok_web, "priv"), "static", "app"])
    html = File.read!(Path.join(static, "index.html"))
    refs = Regex.scan(~r{/app/(assets/[^"]+)}, html, capture: :all_but_first) |> List.flatten()
    assert refs != []
    for ref <- refs, do: assert(File.regular?(Path.join(static, ref)), "#{ref} missing")

    [asset | _] = refs
    conn = build_conn() |> put_req_header("x-druzhok-edge", @edge) |> get("/app/" <> asset)
    assert conn.status == 200

    assert build_conn()
           |> put_req_header("x-druzhok-edge", @edge)
           |> get("/app/assets/..%2Findex.html")
           |> Map.get(:status) == 404
  end
end
