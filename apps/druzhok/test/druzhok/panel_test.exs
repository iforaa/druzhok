defmodule Druzhok.PanelTest do
  # async: false — DRUZHOK_DATA_ROOT, app env and shared instance rows.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
  alias Druzhok.Panel
  alias Druzhok.Panel.Lister

  setup do
    root = Path.join(System.tmp_dir!(), "panel-#{System.unique_integer([:positive])}")
    outside = root <> "-outside"
    File.mkdir_p!(outside)
    prev = System.get_env("DRUZHOK_DATA_ROOT")
    System.put_env("DRUZHOK_DATA_ROOT", root)
    Application.put_env(:druzhok, :panel_lister, {Druzhok.FakeFind, :list})

    on_exit(fn ->
      if prev,
        do: System.put_env("DRUZHOK_DATA_ROOT", prev),
        else: System.delete_env("DRUZHOK_DATA_ROOT")

      Application.delete_env(:druzhok, :panel_lister)
      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    inst =
      relay_instance(%{
        telegram_token: "123:secret",
        owner_telegram_id: 456,
        active: false,
        website_hosting_enabled: true,
        allowed_telegram_ids: Jason.encode!(["456", "789"]),
        allowed_telegram_chats: Jason.encode!(["-100", "-200", "-300"]),
        ruoc_api_key: "rk-secret",
        tenant_key: "tk-secret"
      })

    dir = Path.join(root, inst.name)
    File.mkdir_p!(dir)
    %{inst: inst, dir: dir, outside: outside}
  end

  defp put(dir, rel, body) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  test "find_bot finds the live bot by its token's id, never a deleted one", %{inst: inst} do
    assert Panel.find_bot(123).id == inst.id
    assert Panel.find_bot(999) == nil

    Druzhok.Repo.update_all(from(i in Druzhok.Instance, where: i.id == ^inst.id),
      set: [delete_requested: true]
    )

    assert Panel.find_bot(123) == nil
  end

  test "the bot view carries no secret, account id or owner id", %{inst: inst, dir: dir} do
    put(
      dir,
      "platforms/pairing/telegram-approved.json",
      Jason.encode!(%{"789" => %{}, "1001" => %{}})
    )

    view = Panel.bot(inst)
    json = Jason.encode!(view)

    for secret <- ["123:secret", "rk-secret", "tk-secret", "456"] do
      refute json =~ secret, "#{secret} leaked"
    end

    assert view.state == "stopped"
    # owner 456, row 789, paired 789 and 1001: three people.
    assert view.access == %{allow_all_users: false, allowed_users: 3, free_response_chats: 3}
    assert view.billing_url == "https://oldey.dev"
  end

  test "the bot view names the bot as Telegram does", %{inst: inst} do
    token = "named:#{System.unique_integer([:positive])}"

    Application.put_env(:druzhok, :test_profiles, %{
      token => %{"first_name" => "Кот Вася", "username" => "DruzhokVasaBot"}
    })

    on_exit(fn -> Application.delete_env(:druzhok, :test_profiles) end)

    view = Panel.bot(%{inst | telegram_token: token})
    assert view.title == "Кот Вася"
    assert view.username == "DruzhokVasaBot"
    assert Panel.profile(nil) == nil
  end

  test "the bot's Telegram name is remembered for its SOUL.md, and filled in at boot", %{
    inst: inst
  } do
    token = "voice:#{System.unique_integer([:positive])}"
    other = "voice2:#{System.unique_integer([:positive])}"

    Application.put_env(:druzhok, :test_profiles, %{
      token => %{"first_name" => "Кот Вася"},
      other => %{"first_name" => "Жора"}
    })

    on_exit(fn -> Application.delete_env(:druzhok, :test_profiles) end)

    inst = Druzhok.Repo.update!(Ecto.Changeset.change(inst, telegram_token: token))
    Panel.bot(inst)
    assert Druzhok.Repo.reload!(inst).display_name == "Кот Вася"

    nameless = relay_instance(%{telegram_token: other})
    Panel.backfill_display_names()
    assert Druzhok.Repo.reload!(nameless).display_name == "Жора"
  end

  test "an expired profile is kept when Telegram fails, and the failure is not retried at once" do
    token = "expired:#{System.unique_integer([:positive])}"
    key = {Panel, :profile, :crypto.hash(:sha256, token)}
    old = %{title: "Кот Вася", username: "DruzhokVasaBot"}
    on_exit(fn -> :persistent_term.erase(key) end)

    # Two hours old, and Telegram knows nothing about the token now.
    :persistent_term.put(key, {System.monotonic_time(:second) - 7200, old})
    assert Panel.profile(token) == old
    assert {:failed, _, ^old} = :persistent_term.get(key)

    # Within the minute the failure is remembered: no new ask, even once
    # Telegram would answer.
    Application.put_env(:druzhok, :test_profiles, %{token => %{"first_name" => "Новое имя"}})
    on_exit(fn -> Application.delete_env(:druzhok, :test_profiles) end)
    assert Panel.profile(token) == old

    # A never-known bot gets nil, remembered the same way.
    unknown = "unknown:#{System.unique_integer([:positive])}"
    on_exit(fn -> :persistent_term.erase({Panel, :profile, :crypto.hash(:sha256, unknown)}) end)
    assert Panel.profile(unknown) == nil

    assert {:failed, _, nil} =
             :persistent_term.get({Panel, :profile, :crypto.hash(:sha256, unknown)})
  end

  test "the model shows ruoc's catalogue name as last fetched, never waiting on ruoc", %{
    inst: inst
  } do
    _stub = Druzhok.RuocStub.start()
    [%{"id" => id, "name" => name} | _] = Druzhok.RuocStub.models()

    # Nothing fetched yet: the id, and a fetch starts in the background.
    assert Panel.bot(%{inst | model: id}).settings.model_name == id
    Druzhok.Ruoc.models()
    assert Panel.bot(%{inst | model: id}).settings.model_name == name
    assert Panel.bot(%{inst | model: "nope/x"}).settings.model_name == "nope/x"
  end

  test "support_url only takes an https address" do
    on_exit(fn ->
      Druzhok.Repo.delete_all(from(s in Druzhok.Settings, where: s.key == "support_url"))
    end)

    assert Panel.support_url() == nil
    Druzhok.Settings.set("support_url", "javascript:alert(1)")
    assert Panel.support_url() == nil
    Druzhok.Settings.set("support_url", " https://t.me/druzhok_help ")
    assert Panel.support_url() == "https://t.me/druzhok_help"
  end

  test "invites: available codes as superbot links, redeemed ones counted", %{inst: inst} do
    stub = Druzhok.RuocStub.start()

    Bypass.stub(stub.bypass, "GET", "/v1/referrals", fn conn ->
      Druzhok.RuocStub.reply(conn, 200, %{
        "codes" => [
          %{
            "code" => "ABC123",
            "status" => "available",
            "you_get_nanorub" => 50_000_000_000,
            "friend_gets_nanorub" => 0
          },
          %{"code" => nil, "status" => "redeemed", "redeemed_at" => "2026-10-01T00:00:00Z"}
        ]
      })
    end)

    Application.put_env(:druzhok, :test_profiles, %{
      "mgr:token" => %{"first_name" => "Дружок", "username" => "druzhok_bot"}
    })

    Druzhok.Settings.set("manager_bot_token", "mgr:token")

    on_exit(fn ->
      Application.delete_env(:druzhok, :test_profiles)
      Druzhok.Repo.delete_all(from(s in Druzhok.Settings, where: s.key == "manager_bot_token"))
    end)

    assert {:ok, %{links: [link], used: 1}} = Panel.invites(inst)
    assert link.link == "https://t.me/druzhok_bot?start=ref_ABC123"
    assert link.you_rub == "50.00"
    assert link.share_url =~ "https://t.me/share/url?"
    assert URI.decode_query(URI.parse(link.share_url).query)["url"] == link.link

    assert Panel.invites(%{inst | ruoc_api_key: nil}) == :error
  end

  test "the state table" do
    assert Panel.state("active", true) == "awake"
    assert Panel.state("sleeping", true) == "asleep"
    for s <- ~w(activating waking restarting), do: assert(Panel.state(s, true) == "starting")
    for s <- ~w(stopping deleting), do: assert(Panel.state(s, true) == "stopped")
    assert Panel.state("inactive", false) == "stopped"
    assert Panel.state("failed", false) == "stopped"
    assert Panel.state("inactive", true) == "error"
    assert Panel.state("failed", true) == "error"
    assert Panel.state("unknown", false) == "error"
  end

  test "files: the fixed Markdown files, never through a symlink", %{
    inst: inst,
    dir: dir,
    outside: outside
  } do
    put(dir, "SOUL.md", "# Кот Вася")
    put(dir, "memories/USER.md", "Игорь")
    File.write!(Path.join(outside, "secret"), "x")
    File.mkdir_p!(Path.join(dir, "memories"))
    File.ln_s!(Path.join(outside, "secret"), Path.join(dir, "memories/MEMORY.md"))

    assert {:ok, %{text: "# Кот Вася"}} = Panel.file(inst, "soul")
    assert {:ok, %{text: "", unreadable: true, editable: false}} = Panel.file(inst, "memory")
    assert :not_found = Panel.file(inst, "../config")

    index = Panel.files(inst)
    assert index.soul.size == byte_size("# Кот Вася")
    assert index.memory == nil
    assert index.user.size == byte_size("Игорь")
  end

  test "jobs: shown as hermes shows them", %{inst: inst, dir: dir} do
    jobs = [
      %{
        "id" => "a1",
        "name" => "",
        "prompt" => "Утренняя сводка",
        "schedule" => %{"expr" => "0 9 * * *"}
      },
      %{
        "id" => "b2",
        "name" => "Отчёт",
        "schedule_display" => "every 1h",
        "enabled" => false,
        "state" => "scheduled",
        "paused_at" => "2026-10-24T10:00:00Z"
      },
      %{
        "id" => "c3",
        "script" => String.duplicate("s", 80),
        "enabled" => true,
        "state" => "paused"
      },
      %{"id" => "d4", "name" => "Готово", "state" => "completed", "enabled" => false}
    ]

    put(dir, "cron/jobs.json", Jason.encode!(%{"jobs" => jobs}))
    %{jobs: [a, b, c, d]} = Panel.jobs(inst)
    assert {a.name, a.schedule, a.state} == {"Утренняя сводка", "0 9 * * *", "scheduled"}
    assert {b.name, b.schedule, b.state} == {"Отчёт", "every 1h", "paused"}
    assert {String.length(c.name), c.schedule, c.state} == {50, "?", "scheduled"}
    assert d.state == "completed"
    refute Map.has_key?(a, :deliver)

    put(dir, "cron/jobs.json", Jason.encode!(jobs))
    assert %{jobs: [_, _, _, _]} = Panel.jobs(inst)

    odd = %{"name" => %{}, "prompt" => ["x"], "schedule" => %{"expr" => %{}}}
    put(dir, "cron/jobs.json", Jason.encode!(%{"jobs" => [odd]}))
    assert %{jobs: [%{name: "cron job", prompt: "", schedule: "?"}]} = Panel.jobs(inst)

    put(dir, "cron/jobs.json", "{nope")
    assert %{jobs: [], error: "unreadable"} = Panel.jobs(inst)
  end

  test "job state follows effective_job_state" do
    assert Panel.job_state(%{"enabled" => false}) == "paused"
    assert Panel.job_state(%{"enabled" => false, "state" => "scheduled"}) == "scheduled"

    assert Panel.job_state(%{"enabled" => false, "state" => "scheduled", "paused_at" => "x"}) ==
             "paused"

    assert Panel.job_state(%{"enabled" => true, "paused_at" => "x"}) == "scheduled"
    assert Panel.job_state(%{"state" => "error", "enabled" => true}) == "error"
    assert Panel.job_state(%{}) == "scheduled"
  end

  test "skills: own and system ones, both layouts, own ones editable", %{
    inst: inst,
    dir: dir,
    outside: outside
  } do
    # The front-matter name differs from the directory's: listed by name, opened by path.
    put(
      dir,
      "skills/notes/SKILL.md",
      "---\nname: daily-notes\ndescription: \"Заметки\"\n---\nтело"
    )

    put(
      dir,
      "skills/productivity/planner/SKILL.md",
      "---\nname: planner\ndescription: План\n---\n"
    )

    put(dir, "skills/productivity/todo/SKILL.md", "---\nname: todo-list\n---\nсистемный")
    put(dir, "skills/github/gh/SKILL.md", "---\nname: gh\ndescription: Гитхаб\n---\n")
    put(dir, "skills/.bundled_manifest", "todo-list:abc\ngh:def\ndeleted-one:000\n")
    File.mkdir_p!(Path.join(outside, "evil"))
    File.write!(Path.join([outside, "evil", "SKILL.md"]), "---\nname: evil\n---\n")
    File.ln_s!(Path.join(outside, "evil"), Path.join(dir, "skills/evil"))

    skills = Panel.skills(inst)

    assert Enum.map(skills.own, &{&1.category, &1.name, &1.path}) == [
             {nil, "daily-notes", ["notes"]},
             {"productivity", "planner", ["productivity", "planner"]}
           ]

    assert Enum.map(skills.system, &{&1.category, &1.name, &1.path}) == [
             {"github", "gh", ["github", "gh"]},
             {"productivity", "todo-list", ["productivity", "todo"]}
           ]

    assert hd(skills.own).description == "Заметки"
    assert hd(skills.system).description == "Гитхаб"
    assert Panel.files(inst).skills == %{own: 2, bundled: 2}

    assert {:ok, %{text: text, editable: true, limit: 100_000, sha256: sha}} =
             Panel.skill(inst, ["notes"])

    assert text =~ "тело"
    assert sha == :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    assert {:ok, %{editable: true}} = Panel.skill(inst, ["productivity", "planner"])

    # A system skill opens and cannot be edited.
    assert {:ok, %{text: "---\nname: todo-list\n---\nсистемный", editable: false, limit: nil}} =
             Panel.skill(inst, ["productivity", "todo"])

    assert :not_found = Panel.skill(inst, ["evil"])
    assert :not_found = Panel.skill(inst, [".."])
    assert :not_found = Panel.skill(inst, ["productivity", "nope"])

    assert {:ok, %{kind: "skill", target: ["skills", "notes", "SKILL.md"], limit: 100_000}} =
             Panel.edit_target(inst, {:skill, ["notes"]})

    assert :not_found = Panel.edit_target(inst, {:skill, ["productivity", "todo"]})
    assert :not_found = Panel.edit_target(inst, {:skill, ["evil"]})
    assert :not_found = Panel.edit_target(inst, {:skill, [".."]})
    assert :not_found = Panel.edit_target(inst, {:file, "jobs"})
  end

  test "a built-in hermes dropped from the manifest stays a system skill", %{
    inst: inst,
    dir: dir
  } do
    put(dir, "skills/github/github-auth/SKILL.md", "---\nname: github-auth\n---\nстарый")
    put(dir, "skills/notes/SKILL.md", "---\nname: notes\n---\nсвой")
    put(dir, "skills/.bundled_manifest", "gh:def\n")

    skills = Panel.skills(inst)
    assert Enum.map(skills.own, & &1.name) == ["notes"]
    assert Enum.map(skills.system, & &1.name) == ["github-auth"]
    assert Panel.files(inst).skills == %{own: 1, bundled: 1}
    assert :not_found = Panel.edit_target(inst, {:skill, ["github", "github-auth"]})
  end

  test "no own skills: the system ones still list", %{inst: inst, dir: dir} do
    put(dir, "skills/github/gh/SKILL.md", "---\nname: gh\n---\n")
    put(dir, "skills/.bundled_manifest", "gh:def\n")
    assert %{own: [], system: [%{name: "gh"}]} = Panel.skills(inst)
    assert Panel.files(inst).skills == %{own: 0, bundled: 1}
  end

  describe "file/2, what the editor starts from" do
    test "a file gives its hash, the limit, and editable", %{inst: inst, dir: dir} do
      put(dir, "memories/USER.md", "о вас")

      assert {:ok, %{text: "о вас", editable: true, limit: 1375, truncated: false, sha256: sha}} =
               Panel.file(inst, "user")

      assert sha == :crypto.hash(:sha256, "о вас") |> Base.encode16(case: :lower)
      put(dir, "memories/MEMORY.md", "x")
      assert {:ok, %{limit: 2200}} = Panel.file(inst, "memory")
      put(dir, "SOUL.md", "x")
      assert {:ok, %{limit: 20_000}} = Panel.file(inst, "soul")
    end

    test "no memory file is an empty editable page; no soul is not found", %{inst: inst} do
      for kind <- ["memory", "user"] do
        assert {:ok,
                %{text: "", sha256: nil, editable: true, modified_at: nil, unreadable: false}} =
                 Panel.file(inst, kind)
      end

      assert :not_found = Panel.file(inst, "soul")
    end

    test "a link is unreadable, not absent, and cannot be edited", %{
      inst: inst,
      dir: dir,
      outside: outside
    } do
      File.write!(Path.join(outside, "m"), "чужое")
      File.mkdir_p!(Path.join(dir, "memories"))
      File.ln_s!(Path.join(outside, "m"), Path.join(dir, "memories/MEMORY.md"))
      File.ln_s!(Path.join(outside, "gone"), Path.join(dir, "memories/USER.md"))
      File.ln_s!(Path.join(outside, "m"), Path.join(dir, "SOUL.md"))

      for kind <- ["memory", "user", "soul"] do
        assert {:ok, %{text: "", sha256: nil, editable: false, unreadable: true}} =
                 Panel.file(inst, kind)
      end
    end

    test "a truncated read cannot be edited", %{inst: inst, dir: dir} do
      put(dir, "SOUL.md", String.duplicate("x", 512 * 1024 + 10))
      assert {:ok, %{truncated: true, editable: false, sha256: nil}} = Panel.file(inst, "soul")
    end

    test "not text stays not text", %{inst: inst, dir: dir} do
      put(dir, "SOUL.md", <<0xFF, 0xFE>>)
      assert :not_text = Panel.file(inst, "soul")
    end
  end

  test "the site lists workspace/sites by site, without symlinks", %{
    inst: inst,
    dir: dir,
    outside: outside
  } do
    put(dir, "workspace/sites/promo/index.html", "<h1>hi</h1>")
    put(dir, "workspace/sites/cv/index.html", "cv")
    put(dir, "workspace/sites/promo/_draft.html", "x")
    put(dir, "sites/wrong/index.html", "not served")
    File.ln_s!(outside, Path.join(dir, "workspace/sites/promo/leak"))

    files = Panel.site(inst) |> Enum.filter(&(&1.type == :file))

    assert Enum.map(files, &{&1.site, &1.path}) == [
             {"cv", "cv/index.html"},
             {"promo", "promo/index.html"}
           ]

    assert Panel.files(inst).site == %{files: 2, sites: ["cv", "promo"]}

    assert Panel.site(%{inst | website_hosting_enabled: false}) == nil
  end

  test "published/1 shows what the gateway serves, [] when off, nil when it does not answer", %{inst: inst} do
    stub = Druzhok.RuocStub.start()
    inst = %{inst | ruoc_api_key: "ruoc_bot"}

    Bypass.stub(stub.bypass, "GET", "/v1/sites", fn conn ->
      Druzhok.RuocStub.reply(conn, 200, %{
        "sites" => [
          %{"name" => "cv", "url" => "https://vasya.oldey.dev/cv/", "files" => 2, "bytes" => 10,
            "published_at" => "2026-11-01T10:00:00Z", "disabled" => false, "secret" => "no"}
        ]
      })
    end)

    assert [%{name: "cv", url: "https://vasya.oldey.dev/cv/", files: 2, bytes: 10, disabled: false} = site] =
             Panel.published(inst)

    refute Map.has_key?(site, :secret)

    assert Panel.published(%{inst | website_hosting_enabled: false}) == []

    Bypass.down(stub.bypass)
    assert Panel.published(inst) == nil
    Bypass.up(stub.bypass)
  end

  test "a symlinked workspace hides the site", %{inst: inst, dir: dir, outside: outside} do
    File.mkdir_p!(Path.join(outside, "sites/x"))
    File.write!(Path.join(outside, "sites/x/index.html"), "other tenant")
    File.ln_s!(outside, Path.join(dir, "workspace"))
    assert Panel.site(inst) == nil
  end

  test "the lister's parser keeps files and dirs, drops links, caps, stops at garbage" do
    out = "d 4096 p\0l 4 p/etc\0f 3 p/index.html\0f 9 p/a b.txt\0"

    assert [%{type: :dir}, %{path: "p/index.html", size: 3}, %{path: "p/a b.txt"}] =
             Lister.parse(out, 10)

    assert length(Lister.parse(out, 2)) == 2
    assert [%{path: "p"}] = Lister.parse("d 1 p\0systemd-run: failed\0f 1 q\0", 10)
    assert Lister.parse(nil, 10) == []
  end

  @tag :gnu_find
  test "the real lister with GNU find reports files and no symlinks", %{
    inst: inst,
    dir: dir,
    outside: outside
  } do
    Application.delete_env(:druzhok, :panel_lister)
    put(dir, "workspace/sites/promo/index.html", "hi")
    put(dir, "workspace/sites/promo/_draft.html", "x")
    put(dir, "workspace/sites/promo/.git/HEAD", "x")
    put(dir, "workspace/sites/promo/a/b/c/d/e/f/g/h/deep.html", "x")
    File.ln_s!(outside, Path.join(dir, "workspace/sites/promo/leak"))

    File.ln_s!(
      Path.join(dir, "workspace/sites/promo/index.html"),
      Path.join(dir, "workspace/sites/promo/l.html")
    )

    paths = Lister.list(inst.name, dir, "sites", 8, 100) |> Enum.map(& &1.path)
    assert "promo/index.html" in paths

    refute Enum.any?(
             paths,
             &String.contains?(&1, ["leak", "l.html", "_draft", ".git", "deep.html"])
           )
  end

  test "the panel URL needs a public host and a token", %{inst: inst} do
    assert Panel.url(inst) == nil
    Application.put_env(:druzhok, :public_host, "druzhok.test")
    on_exit(fn -> Application.delete_env(:druzhok, :public_host) end)
    assert Panel.url(inst) == "https://druzhok.test/app/?bot=123"
    assert Panel.url(inst, tab: "billing") == "https://druzhok.test/app/?bot=123&tab=billing"
    assert Panel.url(%{inst | telegram_token: nil}) == nil
  end
end
