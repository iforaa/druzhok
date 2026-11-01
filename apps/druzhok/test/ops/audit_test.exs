defmodule Druzhok.Ops.AuditTest do
  @moduledoc "Runs `ops/audit.sh apt` against a stub apt, the one section whose logic is the script's own."
  use ExUnit.Case, async: true

  @script Path.expand("../../../../ops/audit.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "audit-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp apt(dir, body) do
    path = Path.join(dir, "apt")
    File.write!(path, "#!/usr/bin/env bash\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    File.touch!(Path.join(dir, "noble_main_binary-amd64_Packages.lz4"))

    System.cmd("bash", [@script, "apt"],
      stderr_to_stdout: true,
      env: [{"PATH", "#{dir}:#{System.get_env("PATH")}"}, {"APT_LISTS_DIR", dir}]
    )
  end

  test "a failing apt list is incomplete, not clean", %{dir: dir} do
    assert {out, 1} = apt(dir, "exit 100")
    assert out =~ "could not complete: apt list failed"
    refute out =~ "nothing found"
  end

  test "pending security updates are findings", %{dir: dir} do
    assert {out, 1} = apt(dir, ~s(echo "openssl/noble-security 3.0 amd64"))
    assert out =~ "openssl/noble-security"
  end

  test "ordinary updates are not", %{dir: dir} do
    assert {out, 0} = apt(dir, ~s(echo "apport/noble-updates 2.28 all"))
    assert out =~ "audit: nothing found"
  end

  test "lists with no package index are incomplete, not clean", %{dir: dir} do
    File.write!(Path.join(dir, "apt"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(dir, "apt"), 0o755)

    assert {out, 1} =
             System.cmd("bash", [@script, "apt"],
               stderr_to_stdout: true,
               env: [{"PATH", "#{dir}:#{System.get_env("PATH")}"}, {"APT_LISTS_DIR", dir}]
             )

    assert out =~ "empty or over 7 days old"
  end

  test "no apt lists is not applicable, and passes", %{dir: dir} do
    assert {out, 0} =
             System.cmd("bash", [@script, "apt"],
               stderr_to_stdout: true,
               env: [{"APT_LISTS_DIR", Path.join(dir, "absent")}]
             )

    assert out =~ "not applicable"
  end

  test "an unknown section is refused" do
    assert {_, 2} = System.cmd("bash", [@script, "nope"], stderr_to_stdout: true)
  end
end
