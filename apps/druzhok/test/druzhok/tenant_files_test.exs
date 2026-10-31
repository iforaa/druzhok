defmodule Druzhok.TenantFilesTest do
  use ExUnit.Case, async: true

  alias Druzhok.TenantFiles

  # Each test has its own parent, so the staging dir write/4 keeps next to
  # the tenant dirs (`<parent>/.druzhok-staging`) is private to it.
  setup do
    parent = Path.join(System.tmp_dir!(), "tenantfiles-#{System.unique_integer([:positive])}")
    dir = Path.join(parent, "t")
    outside = Path.join(parent, "outside")
    File.mkdir_p!(Path.join(dir, "memories"))
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "token")
    on_exit(fn -> File.rm_rf!(parent) end)
    %{dir: dir, outside: outside, staging: Path.join(parent, ".druzhok-staging")}
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

  test "a file owned by anyone but the tenant dir's owner is refused", %{dir: dir} do
    File.write!(Path.join(dir, "SOUL.md"), "x")
    %File.Stat{uid: me} = File.lstat!(dir)
    assert {:ok, _} = TenantFiles.read(dir, ["SOUL.md"], 10)
    assert {:ok, _} = TenantFiles.read(dir, ["SOUL.md"], 10, uid: me)
    # Another tenant's file reached through a swapped parent has another owner.
    assert :not_found = TenantFiles.read(dir, ["SOUL.md"], 10, uid: me + 1)
  end

  test "a missing file and a directory are not found", %{dir: dir} do
    assert :not_found = TenantFiles.read(dir, ["nope"], 10)
    assert :not_found = TenantFiles.read(dir, ["memories"], 10)
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
    test "replaces a regular file, keeping its mode", %{dir: dir, staging: staging} do
      path = Path.join(dir, "config.yaml")
      File.write!(path, "old")
      File.chmod!(path, 0o640)
      assert :ok = TenantFiles.write(dir, ["config.yaml"], "new")
      assert File.read!(path) == "new"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o640
      assert File.ls!(dir) |> Enum.sort() == ["config.yaml", "memories"]
      assert File.ls!(staging) == []
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

    test "create: true leaves an existing file alone", %{dir: dir, staging: staging} do
      File.write!(Path.join(dir, "config.yaml"), "mine")
      assert {:ok, :exists} = TenantFiles.write(dir, ["config.yaml"], "seed", create: true)
      assert File.read!(Path.join(dir, "config.yaml")) == "mine"
      assert :ok = TenantFiles.write(dir, ["new.yaml"], "seed", create: true)
      assert File.read!(Path.join(dir, "new.yaml")) == "seed"
      # The seed's staged copy is gone once it is linked into place.
      assert File.ls!(staging) == []
    end

    test "prepares files in a private 0700 staging dir, never in the bot's dir",
         %{dir: dir, staging: staging} do
      refute File.exists?(staging)
      assert :ok = TenantFiles.write(dir, ["workspace", "AGENTS.md"], "x")
      # The staging dir exists only because write/4 used it, and is empty after.
      assert %File.Stat{type: :directory, mode: mode} = File.lstat!(staging)
      assert Bitwise.band(mode, 0o777) == 0o700
      assert File.ls!(staging) == []
      assert File.ls!(dir) |> Enum.sort() == ["memories", "workspace"]
      assert File.ls!(Path.join(dir, "workspace")) == ["AGENTS.md"]
    end

    test "a failed write leaves nothing staged", %{dir: dir, outside: outside, staging: staging} do
      File.ln_s!(outside, Path.join(dir, "workspace"))
      assert {:error, :not_a_directory} = TenantFiles.write(dir, ["workspace", "x"], "x")
      assert File.ls(staging) in [{:ok, []}, {:error, :enoent}]
    end

    test "a missing tenant dir is an error", %{dir: dir} do
      assert {:error, :no_tenant_dir} = TenantFiles.write(dir <> "-nope", ["config.yaml"], "x")
    end
  end

  describe "hand_over/3" do
    test "the file is next to the tenant dir, 0400, the tenant's", %{dir: tenant} do
      parent = Path.dirname(tenant)

      assert {:ok, path} = TenantFiles.hand_over(tenant, "данные", ".panel-save-")
      assert Path.dirname(path) == Path.expand(parent)
      assert String.starts_with?(Path.basename(path), ".panel-save-")
      assert File.read!(path) == "данные"
      stat = File.stat!(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o400
      assert stat.uid == File.stat!(tenant).uid
      assert File.ls!(Path.join(parent, ".druzhok-staging")) == []

      assert {:ok, other} = TenantFiles.hand_over(tenant, "x", ".panel-save-")
      assert other != path
    end

    test "no tenant dir: refused" do
      missing =
        Path.join(System.tmp_dir!(), "handover-none-#{System.unique_integer([:positive])}")

      assert {:error, :no_tenant_dir} = TenantFiles.hand_over(missing, "x", ".p-")
    end
  end
end
