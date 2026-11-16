defmodule Druzhok.TenantFilesTest do
  use ExUnit.Case, async: true

  alias Druzhok.TenantFiles

  # Every call here runs the real helper (priv/tenant-fs/tenant_fs.py), as the
  # caller. What it refuses as root is in test/tenant_fs/test_tenant_fs.py;
  # becoming the bot needs root and a bot, and ops/smoke.sh does one real read
  # through sudo on the box.
  setup do
    parent = Path.join(System.tmp_dir!(), "tenantfiles-#{System.unique_integer([:positive])}")
    dir = Path.join(parent, "t")
    outside = Path.join(parent, "outside")
    File.mkdir_p!(Path.join(dir, "memories"))
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "token")
    on_exit(fn -> File.rm_rf!(parent) end)
    %{dir: dir, outside: outside}
  end

  test "reads a file with its size and time", %{dir: dir} do
    File.write!(Path.join(dir, "SOUL.md"), "# Кот")
    assert {:ok, r} = TenantFiles.read_text(dir, ["SOUL.md"], 100)
    assert r.text == "# Кот" and r.truncated == false and r.size == byte_size("# Кот")
    assert %DateTime{} = r.modified_at
  end

  test "a symlinked file or a symlinked directory is never read", %{dir: dir, outside: outside} do
    File.ln_s!(Path.join(outside, "secret"), Path.join(dir, "SOUL.md"))
    assert :not_found = TenantFiles.read_text(dir, ["SOUL.md"], 100)

    File.rm_rf!(Path.join(dir, "memories"))
    File.ln_s!(outside, Path.join(dir, "memories"))
    File.write!(Path.join(outside, "MEMORY.md"), "x")
    assert :not_found = TenantFiles.read_text(dir, ["memories", "MEMORY.md"], 100)
  end

  test "a missing file and a directory are not found", %{dir: dir} do
    assert :not_found = TenantFiles.read(dir, ["nope"], 10)
    assert :not_found = TenantFiles.read(dir, ["memories"], 10)
    assert :not_found = TenantFiles.read(dir <> "-nope", ["a"], 10)
  end

  test "missing: true tells nothing there from something unreadable", %{dir: dir, outside: outside} do
    assert :missing = TenantFiles.read(dir, ["nope"], 10, missing: true)
    assert :missing = TenantFiles.read(dir, ["cron", "jobs.json"], 10, missing: true)
    assert :missing = TenantFiles.read(dir <> "-nope", ["a"], 10, missing: true)
    assert :not_found = TenantFiles.read(dir, ["memories"], 10, missing: true)
    File.ln_s!(Path.join(outside, "secret"), Path.join(dir, "link"))
    assert :not_found = TenantFiles.read(dir, ["link"], 10, missing: true)
  end

  test "index: true serves a directory as its index.html", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "site"))
    File.write!(Path.join(dir, "site/index.html"), "<p>")
    assert {:ok, %{bytes: "<p>"}} = TenantFiles.read(dir, ["site"], 10, index: true)
    assert :not_found = TenantFiles.read(dir, ["site"], 10)
  end

  test "several files, and several bots, are read in one call", %{dir: dir} do
    File.write!(Path.join(dir, "a"), "1")
    File.write!(Path.join(dir, "memories/b"), "22")

    assert [{:ok, %{bytes: "1"}}, :not_found, {:ok, %{bytes: "22", size: 2}}] =
             TenantFiles.read_many(dir, [{["a"], 10}, {["nope"], 10}, {["memories", "b"], 10}])

    assert [{:ok, %{text: "1"}}, :not_found] = TenantFiles.read_texts(dir, [{["a"], 10}, {["x"], 1}])

    # A limit of 0 gives the size and date and none of the bytes.
    assert [{:ok, %{bytes: "", size: 2, truncated: true}}] =
             TenantFiles.read_many(dir, [{["memories", "b"], 0}])

    assert [[{:ok, %{bytes: "1"}}], [:not_found]] =
             TenantFiles.read_all([{dir, [{["a"], 10}]}, {dir <> "-nope", [{["a"], 10}]}])

    assert TenantFiles.read_all([]) == []
  end

  test "lstat says what is there and follows nothing", %{dir: dir, outside: outside} do
    File.write!(Path.join(dir, "f"), "abc")
    File.ln_s!(Path.join(outside, "gone"), Path.join(dir, "dangling"))
    File.ln_s!(outside, Path.join(dir, "out"))
    assert {:ok, %{type: :regular, size: 3}} = TenantFiles.lstat(dir, ["f"])
    assert {:ok, %{type: :directory}} = TenantFiles.lstat(dir, ["memories"])
    assert {:ok, %{type: :symlink}} = TenantFiles.lstat(dir, ["dangling"])
    assert {:error, :enoent} = TenantFiles.lstat(dir, ["nope"])
    assert {:error, :enoent} = TenantFiles.lstat(dir, ["nope", "deeper"])
    assert {:error, :not_a_directory} = TenantFiles.lstat(dir, ["out", "secret"])
    assert {:error, :enoent} = TenantFiles.lstat(dir <> "-nope", ["f"])
  end

  test "ls lists a real directory only", %{dir: dir, outside: outside} do
    File.write!(Path.join(dir, "memories/b"), "")
    File.write!(Path.join(dir, "memories/a"), "")
    assert {:ok, ["a", "b"]} = TenantFiles.ls(dir, ["memories"])
    assert {:ok, ["memories"]} = TenantFiles.ls(dir, [])
    File.ln_s!(outside, Path.join(dir, "out"))
    assert {:error, :not_a_directory} = TenantFiles.ls(dir, ["out"])
    assert {:error, :enoent} = TenantFiles.ls(dir, ["nope"])
  end

  test "a path that climbs out is refused", %{dir: dir} do
    assert :not_found = TenantFiles.read(dir, ["..", "outside", "secret"], 10)
    assert {:error, :bad_path} = TenantFiles.write(dir, ["..", "outside", "x"], "x")
    assert {:error, :bad_path} = TenantFiles.write(dir, ["a/b"], "x")
    assert {:error, :bad_path} = TenantFiles.rm_tree(dir, [])
  end

  describe "delete/2 and rm_tree/2" do
    test "delete removes a regular file and never a link or a directory", %{dir: dir, outside: outside} do
      File.write!(Path.join(dir, "f"), "x")
      assert :ok = TenantFiles.delete(dir, ["f"])
      assert :not_found = TenantFiles.delete(dir, ["f"])
      assert {:error, :not_regular} = TenantFiles.delete(dir, ["memories"])
      File.ln_s!(Path.join(outside, "secret"), Path.join(dir, "link"))
      assert {:error, :not_regular} = TenantFiles.delete(dir, ["link"])
      File.ln_s!(outside, Path.join(dir, "out"))
      assert {:error, :not_a_directory} = TenantFiles.delete(dir, ["out", "secret"])
      assert File.read!(Path.join(outside, "secret")) == "token"
    end

    test "rm_tree removes the tree and unlinks links without following them", %{dir: dir, outside: outside} do
      File.mkdir_p!(Path.join(dir, "sessions/a/b"))
      File.write!(Path.join(dir, "sessions/a/b/f"), "x")
      File.ln_s!(outside, Path.join(dir, "sessions/a/out"))
      assert :ok = TenantFiles.rm_tree(dir, ["sessions"])
      refute File.exists?(Path.join(dir, "sessions"))
      assert File.read!(Path.join(outside, "secret")) == "token"
      # Nothing there, and no tenant dir, are both fine.
      assert :ok = TenantFiles.rm_tree(dir, ["sessions"])
      assert :ok = TenantFiles.rm_tree(dir <> "-nope", ["sessions"])
      # A link at the name itself is unlinked, its target kept.
      File.ln_s!(outside, Path.join(dir, "sessions"))
      assert :ok = TenantFiles.rm_tree(dir, ["sessions"])
      assert File.dir?(outside) and not File.exists?(Path.join(dir, "sessions"))
    end
  end

  test "a long file is cut back to a whole character", %{dir: dir} do
    # Cut right after the lead byte of a 2-byte character («д» = D0 B4).
    File.write!(Path.join(dir, "a"), String.duplicate("x", 9) <> "дд")
    assert {:ok, %{text: "xxxxxxxxx", truncated: true}} = TenantFiles.read_text(dir, ["a"], 10)

    # Cut in the middle of a 3-byte character (€ = E2 82 AC), after 1 and 2 bytes.
    File.write!(Path.join(dir, "b"), "xxxxxxxx€€")
    assert {:ok, %{text: "xxxxxxxx", truncated: true}} = TenantFiles.read_text(dir, ["b"], 9)
    assert {:ok, %{text: "xxxxxxxx", truncated: true}} = TenantFiles.read_text(dir, ["b"], 10)
    assert {:ok, %{text: "xxxxxxxx€", truncated: true}} = TenantFiles.read_text(dir, ["b"], 11)

    # An exact fit is not truncated.
    assert {:ok, %{text: "xxxxxxxx€€", truncated: false}} = TenantFiles.read_text(dir, ["b"], 14)
  end

  test "invalid UTF-8 is not text", %{dir: dir} do
    File.write!(Path.join(dir, "bin"), <<0xFF, 0xFE, 0x00>>)
    assert :not_text = TenantFiles.read_text(dir, ["bin"], 10)
  end

  test "trim_utf8 keeps complete characters" do
    assert TenantFiles.trim_utf8("abc") == "abc"
    assert TenantFiles.trim_utf8("aд") == "aд"
    assert TenantFiles.trim_utf8(<<"a", 0xD0>>) == "a"
    assert TenantFiles.trim_utf8(<<"a", 0xF0, 0x9F, 0x98>>) == "a"
    assert TenantFiles.trim_utf8("a😀") == "a😀"
    assert TenantFiles.trim_utf8("") == ""
  end

  test "real_dir? refuses a symlinked component", %{dir: dir, outside: outside} do
    File.mkdir_p!(Path.join([dir, "workspace", "sites"]))
    assert TenantFiles.real_dir?(dir, ["workspace", "sites"])
    File.rm_rf!(Path.join(dir, "workspace"))
    File.ln_s!(outside, Path.join(dir, "workspace"))
    refute TenantFiles.real_dir?(dir, ["workspace", "sites"])
    refute TenantFiles.real_dir?(dir, ["missing"])
  end

  test "request segments are validated" do
    assert TenantFiles.valid_segments?(["notes", "SKILL.md"])

    for bad <- [[""], ["."], [".."], [".hidden"], ["_draft"], ["a/b"], ["a\0b"]] do
      refute TenantFiles.valid_segments?(bad), inspect(bad)
    end
  end

  describe "write/4" do
    test "replaces a regular file, keeping its mode", %{dir: dir} do
      path = Path.join(dir, "config.yaml")
      File.write!(path, "old")
      File.chmod!(path, 0o640)
      assert :ok = TenantFiles.write(dir, ["config.yaml"], "new")
      assert File.read!(path) == "new"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o640
      # Nothing of the write is left beside it.
      assert File.ls!(dir) |> Enum.sort() == ["config.yaml", "memories"]
    end

    test "creates missing directories and a new file", %{dir: dir} do
      assert :ok = TenantFiles.write(dir, ["workspace", "AGENTS.md"], "# hi")
      assert File.read!(Path.join([dir, "workspace", "AGENTS.md"])) == "# hi"
      assert File.stat!(Path.join([dir, "workspace", "AGENTS.md"])).uid == File.stat!(dir).uid
    end

    test "never writes through a symlinked target", %{dir: dir, outside: outside} do
      File.ln_s!(Path.join(outside, "secret"), Path.join(dir, "config.yaml"))
      assert {:error, :not_regular} = TenantFiles.write(dir, ["config.yaml"], "pwned")
      assert File.read!(Path.join(outside, "secret")) == "token"
    end

    test "a dangling symlink is refused, and its target is not created", %{
      dir: dir,
      outside: outside
    } do
      target = Path.join(outside, "created")
      File.ln_s!(target, Path.join(dir, "config.yaml"))

      assert {:error, :not_regular} =
               TenantFiles.write(dir, ["config.yaml"], "seed", create: true)

      assert {:error, :not_regular} = TenantFiles.write(dir, ["config.yaml"], "seed")
      refute File.exists?(target)
    end

    test "never writes below a symlinked directory", %{dir: dir, outside: outside} do
      File.ln_s!(outside, Path.join(dir, "workspace"))
      assert {:error, :not_a_directory} = TenantFiles.write(dir, ["workspace", "AGENTS.md"], "x")
      refute File.exists?(Path.join(outside, "AGENTS.md"))
    end

    test "create: true leaves an existing file alone", %{dir: dir} do
      File.write!(Path.join(dir, "config.yaml"), "mine")
      assert {:ok, :exists} = TenantFiles.write(dir, ["config.yaml"], "seed", create: true)
      assert File.read!(Path.join(dir, "config.yaml")) == "mine"
      assert :ok = TenantFiles.write(dir, ["new.yaml"], "seed", create: true)
      assert File.read!(Path.join(dir, "new.yaml")) == "seed"
      # The seed's temp copy is gone once it is linked into place.
      assert File.ls!(dir) |> Enum.sort() == ["config.yaml", "memories", "new.yaml"]
    end

    test "new directories are 0700 and a new file takes the mode given", %{dir: dir} do
      assert :ok = TenantFiles.write(dir, ["workspace", "a", "x"], "x", mode: 0o600)
      assert Bitwise.band(File.stat!(Path.join(dir, "workspace/a")).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(Path.join(dir, "workspace/a/x")).mode, 0o777) == 0o600
      assert :ok = TenantFiles.write(dir, ["y"], "y")
      assert Bitwise.band(File.stat!(Path.join(dir, "y")).mode, 0o777) == 0o644
      assert File.ls!(Path.join(dir, "workspace/a")) == ["x"]
    end

    test "a failed write leaves nothing behind", %{dir: dir, outside: outside} do
      File.ln_s!(outside, Path.join(dir, "workspace"))
      assert {:error, :not_a_directory} = TenantFiles.write(dir, ["workspace", "x"], "x")
      assert File.ls!(outside) == ["secret"]
      assert {:error, :not_regular} = TenantFiles.write(dir, ["memories"], "x")
      assert File.ls!(dir) |> Enum.sort() == ["memories", "workspace"]
    end

    test "ensure_dir makes real directories and refuses a link", %{dir: dir, outside: outside} do
      assert {:ok, path} = TenantFiles.ensure_dir(dir, ["workspace", "sites"])
      assert path == Path.join(dir, "workspace/sites") and File.dir?(path)
      assert {:ok, _} = TenantFiles.ensure_dir(dir, ["workspace"])
      File.ln_s!(outside, Path.join(dir, "out"))
      assert {:error, :not_a_directory} = TenantFiles.ensure_dir(dir, ["out"])
      assert {:error, :no_tenant_dir} = TenantFiles.ensure_dir(dir <> "-nope", ["workspace"])
    end

    test "a missing tenant dir is an error", %{dir: dir} do
      assert {:error, :no_tenant_dir} = TenantFiles.write(dir <> "-nope", ["config.yaml"], "x")
    end
  end
end

defmodule Druzhok.TenantFilesHelperTest do
  # Not async: the helper's command is app env, which every test shares.
  use ExUnit.Case, async: false

  alias Druzhok.TenantFiles

  setup do
    dir = Path.join(System.tmp_dir!(), "tenantfiles-h-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a tenant dir that cannot be opened is an error for that bot alone, never nothing there",
       %{dir: dir} do
    shut = dir <> "-shut"
    File.mkdir_p!(shut)
    File.write!(Path.join(dir, "a"), "x")
    File.chmod!(shut, 0o000)
    on_exit(fn -> File.chmod(shut, 0o700) && File.rm_rf(shut) end)

    assert_raise TenantFiles.Error, fn -> TenantFiles.read(shut, ["a"], 10, missing: true) end
    assert_raise TenantFiles.Error, fn -> TenantFiles.lstat(shut, ["a"]) end
    assert_raise TenantFiles.Error, fn -> TenantFiles.rm_tree(shut, ["a"]) end

    assert [[{:ok, %{bytes: "x"}}], :error, [:missing]] =
             TenantFiles.read_all(
               [{dir, [{["a"], 10}]}, {shut, [{["a"], 10}]}, {dir <> "-nope", [{["a"], 10}]}],
               missing: true
             )
  end

  test "a helper that does not answer raises, never reads as nothing there", %{dir: dir} do
    Application.put_env(:druzhok, :tenant_fs, ["/bin/sh", "-c", "exit 7"])
    on_exit(fn -> Application.delete_env(:druzhok, :tenant_fs) end)
    assert_raise TenantFiles.Error, fn -> TenantFiles.read(dir, ["a"], 10) end
    assert_raise TenantFiles.Error, fn -> TenantFiles.write(dir, ["a"], "x") end
    assert_raise TenantFiles.Error, fn -> TenantFiles.real_dir?(dir, []) end

    Application.put_env(:druzhok, :tenant_fs, ["/bin/sh", "-c", "echo '{\"jobs\":[]}'"])
    assert_raise TenantFiles.Error, fn -> TenantFiles.read(dir, ["a"], 10) end
  end
end
