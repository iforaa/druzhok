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
    |> then(fn c ->
      case Keyword.fetch(opts, :post) do
        {:ok, body} ->
          c
          |> put_req_header("content-type", "application/json")
          |> post(path, Jason.encode!(body))

        :error ->
          get(c, path)
      end
    end)
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

    assert api(build_conn(), "/app/api/files/nope").status == 404
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

  describe "POST /app/api/settings" do
    setup do
      %{stub: Druzhok.RuocStub.start()}
    end

    test "saves, answers the bot view with apply, and restarts nothing", %{conn: conn, inst: inst} do
      Repo.update!(Ecto.Changeset.change(inst, active: true))

      c =
        api(conn, "/app/api/settings",
          post: %{changes: %{"language" => "en", "timezone" => "Asia/Almaty"}}
        )

      assert c.status == 200
      bot = Jason.decode!(c.resp_body)["bot"]
      assert bot["settings"]["language"] == "en"
      assert bot["settings"]["timezone"] == "Asia/Almaty"
      assert bot["apply"] == %{"state" => "waiting", "error" => nil}

      row = Repo.get!(Instance, inst.id)
      assert {row.settings_seq, row.start_seq} == {1, inst.start_seq}
    end

    test "refusals in the envelope; nothing is written", %{conn: conn, inst: inst} do
      for {changes, type} <- [
            {%{"model" => "x"}, "unknown_setting"},
            {%{"telegram_token" => "x"}, "unknown_setting"},
            {%{"language" => "en", "timezone" => "Nowhere"}, "invalid_setting"},
            {%{"image_gen_model" => "ruoc-flux-pro"}, "images_off"}
          ] do
        c = api(build_conn(), "/app/api/settings", post: %{changes: changes})
        assert {c.status, error_type(c)} == {400, type}, inspect(changes)
      end

      c = api(conn, "/app/api/settings", post: %{other: 1})
      assert {c.status, error_type(c)} == {400, "invalid_setting"}
      assert Repo.get!(Instance, inst.id).language == inst.language
    end

    test "the same auth as every panel call", %{conn: conn, inst: inst} do
      body = [post: %{changes: %{"language" => "en"}}]
      assert api(conn, "/app/api/settings", [edge: nil] ++ body).status == 404
      c = api(build_conn(), "/app/api/settings", [user: 789] ++ body)
      assert {c.status, error_type(c)} == {403, "not_owner"}
      c = api(build_conn(), "/app/api/settings", [init: "auth_date=1&user=%7B%7D"] ++ body)
      assert {c.status, error_type(c)} == {401, "init_invalid"}
      Repo.update!(Ecto.Changeset.change(inst, cabinet_off: true))
      c = api(build_conn(), "/app/api/settings", body)
      assert {c.status, error_type(c)} == {403, "cabinet_off"}
      assert Repo.get!(Instance, inst.id).language == inst.language
    end

    test "GET /image-models passes ruoc's list through, 502 when it fails", %{
      conn: conn,
      stub: stub
    } do
      c = api(conn, "/app/api/image-models")
      assert c.status == 200

      assert [%{"id" => "ruoc-flux-klein", "default" => true, "rub_per_image" => "2"} | _] =
               Jason.decode!(c.resp_body)["models"]

      Bypass.down(stub.bypass)
      c = api(build_conn(), "/app/api/image-models")
      assert {c.status, error_type(c)} == {502, "catalogue_unavailable"}
    end
  end

  describe "POST /app/api/delete" do
    test "deletes the bot at once; the panel then has no bot", %{conn: conn, inst: inst} do
      c = api(conn, "/app/api/delete", post: %{})
      assert c.status == 200
      assert Jason.decode!(c.resp_body) == %{"deleted" => true}

      row = Repo.get!(Instance, inst.id)
      assert row.delete_requested
      refute row.active

      assert api(build_conn(), "/app/api/bot").status == 404
    end

    test "a panel opened over 10 minutes ago must be reopened first", %{conn: conn, inst: inst} do
      old = F.build(123, @token, 456, auth_date: System.system_time(:second) - 11 * 60)
      c = api(conn, "/app/api/delete", init: old, post: %{})
      assert {c.status, error_type(c)} == {401, "init_stale"}
      refute Repo.get!(Instance, inst.id).delete_requested

      # The same age still reads.
      assert api(build_conn(), "/app/api/bot", init: old).status == 200
    end

    test "not the owner: refused", %{conn: conn, inst: inst} do
      c = api(conn, "/app/api/delete", user: 789, post: %{})
      assert {c.status, error_type(c)} == {403, "not_owner"}
      refute Repo.get!(Instance, inst.id).delete_requested
    end
  end

  describe "skills" do
    setup %{dir: dir} do
      for {rel, body} <- [
            {"skills/notes/SKILL.md", "---\nname: daily\ndescription: Заметки\n---\nтело"},
            {"skills/cat/mine/SKILL.md", "---\nname: mine\n---\nтело"},
            {"skills/github/gh/SKILL.md", "---\nname: gh\ndescription: Гитхаб\n---\nтело"},
            {"skills/.bundled_manifest", "gh:abc\n"}
          ] do
        path = Path.join(dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, body)
      end

      :ok
    end

    test "GET /skills has both groups; `skills` keeps its meaning", %{conn: conn} do
      body = Jason.decode!(api(conn, "/app/api/skills").resp_body)
      assert Enum.map(body["skills"], & &1["name"]) == ["daily", "mine"]
      assert hd(body["skills"])["path"] == ["notes"]

      assert [%{"name" => "gh", "path" => ["github", "gh"], "description" => "Гитхаб"}] =
               body["system"]

      assert Jason.decode!(api(build_conn(), "/app/api/files").resp_body)["skills"] ==
               %{"own" => 2, "bundled" => 1}
    end

    test "both groups open; only own ones edit; a path outside both is 404", %{conn: conn} do
      own = Jason.decode!(api(conn, "/app/api/skills/notes").resp_body)
      assert own["editable"] == true and own["limit"] == 100_000 and is_binary(own["sha256"])

      nested = Jason.decode!(api(build_conn(), "/app/api/skills/cat/mine").resp_body)
      assert nested["editable"] == true

      system = api(build_conn(), "/app/api/skills/github/gh")
      assert system.status == 200
      assert Jason.decode!(system.resp_body)["editable"] == false

      assert api(build_conn(), "/app/api/skills/github/none").status == 404
      assert api(build_conn(), "/app/api/skills/none").status == 404
      assert api(build_conn(), "/app/api/skills/..%2Fetc").status == 404
    end
  end

  describe "GET /files/:kind" do
    test "a missing memory file is an empty page to fill in", %{conn: conn} do
      c = api(conn, "/app/api/files/memory")
      assert c.status == 200

      assert %{"text" => "", "sha256" => nil, "editable" => true, "limit" => 2200} =
               Jason.decode!(c.resp_body)

      assert get_resp_header(c, "cache-control") == ["no-store"]
      assert Jason.decode!(api(build_conn(), "/app/api/files/user").resp_body)["limit"] == 1375
    end

    test "SOUL.md has its hash; without one it is 404", %{conn: conn, dir: dir} do
      body = Jason.decode!(api(conn, "/app/api/files/soul").resp_body)
      assert body["editable"] == true and body["limit"] == 20_000
      assert body["sha256"] == :crypto.hash(:sha256, "# Вася") |> Base.encode16(case: :lower)

      File.rm!(Path.join(dir, "SOUL.md"))
      assert api(build_conn(), "/app/api/files/soul").status == 404
    end
  end

  # Records the hand-over file while it exists, and answers what the test set.
  defmodule Saver do
    def run(name, dir, path) do
      stat = File.stat!(path)

      send(
        Application.get_env(:druzhok, :panel_saver_test),
        {:saved, name, dir, path, File.read!(path), stat}
      )

      Application.get_env(
        :druzhok,
        :panel_saver_reply,
        {~s({"sha256":"#{String.duplicate("a", 64)}","modified_at":"2026-10-31T10:00:00Z"}\n), 0}
      )
    end

    def slow(_name, _dir, _path) do
      Process.sleep(:infinity)
    end
  end

  describe "saving" do
    setup do
      Application.put_env(:druzhok, :panel_saver, {Saver, :run})
      Application.put_env(:druzhok, :panel_saver_test, self())

      on_exit(fn ->
        for k <- [:panel_saver, :panel_saver_test, :panel_saver_reply, :panel_save_timeout_ms],
            do: Application.delete_env(:druzhok, k)
      end)

      :ok
    end

    defp reply_with(out, code \\ 0),
      do: Application.put_env(:druzhok, :panel_saver_reply, {out, code})

    defp hand_overs(dir) do
      dir |> Path.dirname() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, ".panel-save-"))
    end

    test "POST /files/:kind hands over the input and answers the hash", %{
      conn: conn,
      inst: inst,
      dir: dir
    } do
      c = api(conn, "/app/api/files/memory", post: %{text: "запись", base_sha256: nil})
      assert c.status == 200
      assert get_resp_header(c, "cache-control") == ["no-store"]

      assert Jason.decode!(c.resp_body) == %{
               "sha256" => String.duplicate("a", 64),
               "modified_at" => "2026-10-31T10:00:00Z"
             }

      name = inst.name
      assert_received {:saved, ^name, ^dir, path, job, stat}

      assert Jason.decode!(job) == %{
               "target" => ["memories", "MEMORY.md"],
               "kind" => "memory",
               "base_sha256" => nil,
               "text" => "запись",
               "limit" => 2200
             }

      # Next to the tenant dirs, the bot's own, readable by it alone.
      assert Path.dirname(path) == Path.dirname(Path.expand(dir))
      assert String.starts_with?(Path.basename(path), ".panel-save-")
      assert Bitwise.band(stat.mode, 0o777) == 0o400
      assert stat.uid == File.stat!(dir).uid
      assert hand_overs(dir) == [], "the hand-over file is removed after the run"
    end

    test "each route names its target and limit", %{conn: conn, dir: dir} do
      path = Path.join(dir, "skills/cat/mine/SKILL.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "---\nname: mine\n---\nтело")
      File.mkdir_p!(Path.join(dir, "skills/solo"))
      File.write!(Path.join(dir, "skills/solo/SKILL.md"), "---\nname: solo\n---\nтело")
      base = String.duplicate("b", 64)

      for {route, target, kind, limit} <- [
            {"files/soul", ["SOUL.md"], "soul", 20_000},
            {"files/user", ["memories", "USER.md"], "user", 1375},
            {"skills/solo", ["skills", "solo", "SKILL.md"], "skill", 100_000},
            {"skills/cat/mine", ["skills", "cat", "mine", "SKILL.md"], "skill", 100_000}
          ] do
        c = api(conn, "/app/api/" <> route, post: %{text: "t", base_sha256: base})
        assert c.status == 200, route
        assert_received {:saved, _, _, _, job, _}

        assert %{"target" => ^target, "kind" => ^kind, "limit" => ^limit, "base_sha256" => ^base} =
                 Jason.decode!(job)
      end
    end

    test "refused up front, running nothing", %{conn: conn, dir: dir} do
      for {route, body, status, type} <- [
            {"files/soul", %{text: 1}, 422, "invalid_text"},
            {"files/soul", %{}, 422, "invalid_text"},
            {"files/soul", %{text: "x", base_sha256: "nothex"}, 422, "invalid_text"},
            {"files/soul", %{text: "x", base_sha256: 5}, 422, "invalid_text"},
            {"files/soul", %{text: String.duplicate("x", 512 * 1024 + 1)}, 422, "too_long"},
            {"files/jobs", %{text: "x"}, 404, "not_found"},
            {"skills/none", %{text: "x"}, 404, "not_found"},
            {"skills/none/none", %{text: "x"}, 404, "not_found"}
          ] do
        c = api(conn, "/app/api/" <> route, post: body)
        assert {c.status, error_type(c)} == {status, type}, inspect({route, Map.keys(body)})
        assert get_resp_header(c, "cache-control") == ["no-store"]
      end

      refute_received {:saved, _, _, _, _, _}
      assert hand_overs(dir) == []

      big = api(conn, "/app/api/files/soul", post: %{text: String.duplicate("x", 512 * 1024 + 1)})
      assert Jason.decode!(big.resp_body)["error"]["limit"] == 20_000
    end

    test "a system skill is 404, running nothing", %{conn: conn, dir: dir} do
      File.mkdir_p!(Path.join(dir, "skills/github/gh"))
      File.write!(Path.join(dir, "skills/github/gh/SKILL.md"), "---\nname: gh\n---\nтело")
      File.write!(Path.join(dir, "skills/.bundled_manifest"), "gh:abc\n")

      c = api(conn, "/app/api/skills/github/gh", post: %{text: "x", base_sha256: nil})
      assert {c.status, error_type(c)} == {404, "not_found"}
      refute_received {:saved, _, _, _, _, _}
    end

    test "the script's answers map to the API's", %{conn: conn} do
      for {out, status, type, extra} <- [
            {~s({"error":"too_long","limit":2200}\n), 422, "too_long", %{"limit" => 2200}},
            {~s({"error":"invalid_text"}\n), 422, "invalid_text", %{}},
            {~s({"error":"empty_soul"}\n), 422, "empty_soul", %{}},
            {~s({"error":"invalid_skill"}\n), 422, "invalid_skill", %{}},
            {~s({"error":"blocked_entry","entry":"начало"}\n), 422, "blocked_entry",
             %{"entry" => "начало"}},
            {~s({"error":"file_changed"}\n), 409, "file_changed", %{}},
            {~s({"error":"save_failed"}\n), 500, "save_failed", %{}}
          ] do
        reply_with(out)
        c = api(conn, "/app/api/files/memory", post: %{text: "x", base_sha256: nil})
        assert {c.status, error_type(c)} == {status, type}, out
        assert Map.take(Jason.decode!(c.resp_body)["error"], Map.keys(extra)) == extra
      end
    end

    test "any other output is 500 save_failed", %{conn: conn, dir: dir} do
      good = ~s({"sha256":"#{String.duplicate("a", 64)}","modified_at":"2026-10-31T10:00:00Z"})

      for {out, code} <- [
            {"", 0},
            {"Traceback (most recent call last)\n", 1},
            {"not json\n", 0},
            {"[1,2]\n", 0},
            {"{}\n", 0},
            {"warning: something\n" <> good <> "\n", 0},
            {good <> "\n" <> good <> "\n", 0},
            {good <> "\n", 1},
            {~s({"sha256":"short","modified_at":"2026-10-31T10:00:00Z"}\n), 0},
            {~s({"sha256":"#{String.duplicate("a", 64)}","modified_at":"<script>"}\n), 0},
            {~s({"sha256":"#{String.duplicate("a", 64)}","modified_at":7}\n), 0},
            {~s({"error":"too_long"}\n), 0},
            {~s({"error":"too_long","limit":"много"}\n), 0},
            {~s({"error":"blocked_entry","entry":5}\n), 0},
            {~s({"error":"other"}\n), 0}
          ] do
        reply_with(out, code)
        c = api(conn, "/app/api/files/memory", post: %{text: "x", base_sha256: nil})
        assert {c.status, error_type(c)} == {500, "save_failed"}, out
        refute c.resp_body =~ "Traceback"
        assert hand_overs(dir) == []
      end
    end

    test "a failure's reason is logged as a plain word and never answered", %{
      conn: conn,
      inst: inst
    } do
      for {reason, shown} <- [
            {"PermissionError", "PermissionError"},
            {"evil\\nFAKE log line", "unknown"}
          ] do
        reply_with(~s({"error":"save_failed","reason":"#{reason}"}\n))

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            c = api(conn, "/app/api/files/memory", post: %{text: "x", base_sha256: nil})
            assert {c.status, error_type(c)} == {500, "save_failed"}
            refute c.resp_body =~ reason
          end)

        assert log =~ "the save for #{inst.name} failed: #{shown}"
        refute log =~ "FAKE"
      end
    end

    test "a blocked entry's start is cut to 60 characters", %{conn: conn} do
      reply_with(
        Jason.encode!(%{error: "blocked_entry", entry: String.duplicate("я", 500)}) <> "\n"
      )

      c = api(conn, "/app/api/files/memory", post: %{text: "x", base_sha256: nil})
      assert Jason.decode!(c.resp_body)["error"]["entry"] == String.duplicate("я", 60)
    end

    test "a run past the limit is save_failed, and the hand-over file goes", %{
      conn: conn,
      dir: dir
    } do
      Application.put_env(:druzhok, :panel_saver, {Saver, :slow})
      Application.put_env(:druzhok, :panel_save_timeout_ms, 50)
      c = api(conn, "/app/api/files/memory", post: %{text: "x", base_sha256: nil})
      assert {c.status, error_type(c)} == {500, "save_failed"}
      assert hand_overs(dir) == []
    end

    test "init data over an hour old is init_stale; it still reads", %{conn: conn} do
      old = F.build(123, @token, 456, auth_date: System.system_time(:second) - 61 * 60)
      c = api(conn, "/app/api/files/memory", init: old, post: %{text: "x", base_sha256: nil})
      assert {c.status, error_type(c)} == {401, "init_stale"}
      refute_received {:saved, _, _, _, _, _}
      assert api(build_conn(), "/app/api/files/memory", init: old).status == 200

      fresh = F.build(123, @token, 456, auth_date: System.system_time(:second) - 59 * 60)

      c =
        api(build_conn(), "/app/api/files/memory",
          init: fresh,
          post: %{text: "x", base_sha256: nil}
        )

      assert c.status == 200
    end

    test "the same auth as every panel call", %{conn: conn, inst: inst} do
      body = [post: %{text: "x", base_sha256: nil}]
      assert api(conn, "/app/api/files/memory", [edge: nil] ++ body).status == 404
      c = api(build_conn(), "/app/api/files/memory", [user: 789] ++ body)
      assert {c.status, error_type(c)} == {403, "not_owner"}
      c = api(build_conn(), "/app/api/skills/x", [user: 789] ++ body)
      assert {c.status, error_type(c)} == {403, "not_owner"}
      c = api(build_conn(), "/app/api/files/memory", [init: "auth_date=1&user=%7B%7D"] ++ body)
      assert {c.status, error_type(c)} == {401, "init_invalid"}
      Repo.update!(Ecto.Changeset.change(inst, cabinet_off: true))
      c = api(build_conn(), "/app/api/files/memory", body)
      assert {c.status, error_type(c)} == {403, "cabinet_off"}
      refute_received {:saved, _, _, _, _, _}
    end

    test "a save does not wake or restart the bot, or touch settings", %{conn: conn, inst: inst} do
      Repo.update!(Ecto.Changeset.change(inst, active: true, sleeping: true))
      before = Repo.get!(Instance, inst.id)

      assert api(conn, "/app/api/files/memory", post: %{text: "x", base_sha256: nil}).status ==
               200

      row = Repo.get!(Instance, inst.id)
      assert row.sleeping and row.active

      assert {row.settings_seq, row.start_seq, row.stop_seq} ==
               {before.settings_seq, before.start_seq, before.stop_seq}

      assert Druzhok.BotManager.status(inst.name) == "inactive"
    end
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
