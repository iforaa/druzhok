defmodule Druzhok.TenantFilesTest do
  use ExUnit.Case, async: true

  alias Druzhok.TenantFiles

  setup do
    dir = Path.join(System.tmp_dir!(), "tenantfiles-#{System.unique_integer([:positive])}")
    outside = dir <> "-outside"
    File.mkdir_p!(Path.join(dir, "memories"))
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "token")
    on_exit(fn -> File.rm_rf!(dir) && File.rm_rf!(outside) end)
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
end
