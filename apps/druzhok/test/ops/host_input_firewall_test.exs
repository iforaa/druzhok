defmodule Druzhok.Ops.HostInputFirewallTest do
  @moduledoc """
  There is no nft or systemd on a dev machine. The rules are held as text; the
  apply script runs for real in bash against stubs of nft, systemctl and friends,
  where the stub nft keeps "the live table" in a file and the stub timer can fire.
  """
  use ExUnit.Case, async: true

  @ops Path.expand("../../../../ops", __DIR__)
  @rules Path.join(@ops, "nftables-host-input.nft")
  @script Path.join(@ops, "host-input-firewall.sh")

  describe "rules" do
    defp rules, do: File.read!(@rules)

    defp input_chain do
      [_, body] = Regex.run(~r/chain input \{(.*?)^  \}/ms, rules())

      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    end

    test "default drop on the input hook, ending in a counted drop" do
      assert [hook | _] = input_chain()
      assert hook == "type filter hook input priority 0; policy drop;"
      assert List.last(input_chain()) == "counter drop"
    end

    test "only loopback, established traffic, ssh, web and link upkeep are accepted" do
      accepted = input_chain() |> Enum.filter(&String.ends_with?(&1, " accept")) |> Enum.sort()

      assert accepted ==
               Enum.sort([
                 ~s(iif "lo" accept),
                 "ct state established,related accept",
                 "tcp dport 22 accept",
                 "tcp dport { 80, 443 } accept",
                 "udp dport 443 accept",
                 "udp sport 67 udp dport 68 accept",
                 "icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } ip6 hoplimit 255 accept"
               ])
    end

    test "loopback comes before the invalid drop, which comes before the open ports" do
      chain = input_chain()
      index = fn rule -> Enum.find_index(chain, &(&1 == rule)) end

      assert index.(~s(iif "lo" accept)) < index.("ct state invalid drop")
      assert index.("ct state invalid drop") < index.("tcp dport 22 accept")
    end

    test "a table of its own, swapped atomically, that leaves the rest of the ruleset alone" do
      assert rules() =~ ~r/^table inet host_input\ndelete table inet host_input\n/m
      refute rules() =~ ~r/^\s*flush\b/m
      refute rules() =~ "inet druzhok\n"
      assert [_] = Regex.scan(~r/^table inet host_input \{/m, rules())
    end
  end

  # A fake root: stubs on PATH, every system path pointed into a temp dir.
  setup do
    dir = Path.join(System.tmp_dir!(), "fw-test-#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(dir, "nftables.d"))
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "nftables.conf"), ~s|flush ruleset\ninclude "/etc/nftables.d/*.nft"\n|)
    File.write!(Path.join(dir, "rules.nft"), "new-rules\n")
    File.write!(Path.join(dir, "sshd_port"), "22\n")

    stub(bin, "id", "echo 0")
    stub(bin, "flock", "exit 0")
    stub(bin, "install", ~S|args=("$@"); n=${#args[@]}; cp "${args[n-2]}" "${args[n-1]}"|)
    stub(bin, "sshd", ~s|[ ! -f #{dir}/sshd_fail ] \|\| exit 1; echo "port $(cat #{dir}/sshd_port)"; echo "usepam yes"|)
    stub(bin, "sha256sum", "cksum")

    stub(bin, "systemd-run", """
    echo "systemd-run $*" >> #{dir}/calls
    [ ! -f #{dir}/timer_fail ] || exit 1
    touch #{dir}/timer
    """)

    # is-active answers for the timer; stop removes it.
    stub(bin, "systemctl", """
    echo "systemctl $*" >> #{dir}/calls
    case "$1" in
      is-active) [ -f #{dir}/timer ] ;;
      stop) rm -f #{dir}/timer ;;
      *) exit 0 ;;
    esac
    """)

    # The live table is the file `live`. `-f` loads a file's text over it, as one
    # transaction; an empty rollback (the two header lines) leaves no table. Real nft
    # would merge a rollback with no `delete table` into the live chain, so the stub
    # refuses one rather than pretend it replaced anything.
    stub(bin, "nft", """
    echo "nft $*" >> #{dir}/calls
    case "$*" in
      "list table inet host_input"|"-s list table inet host_input")
        [ -f #{dir}/live ] || exit 1; cat #{dir}/live ;;
      "delete table inet host_input") rm -f #{dir}/live ;;
      -c\\ -f\\ *)
        [ ! -f #{dir}/check_fail ] || exit 1
        if [ -f #{dir}/conf_check_fail ] && [ "$3" = #{dir}/nftables.conf ]; then exit 1; fi
        if [ -f #{dir}/previous_check_fail ] && [ "$3" = #{dir}/state/previous.nft ]; then exit 1; fi ;;
      -f\\ *)
        [ ! -f #{dir}/load_fail ] || exit 1
        case "$2" in
          */previous.nft)
            [ ! -f #{dir}/restore_fail ] || exit 1
            grep -qx 'delete table inet host_input' "$2" || exit 1 ;;
        esac
        grep -vE '^(table inet host_input|delete table inet host_input)$' "$2" > #{dir}/live.new || true
        if [ -s #{dir}/live.new ]; then mv #{dir}/live.new #{dir}/live; else rm -f #{dir}/live #{dir}/live.new; fi ;;
      *) exit 1 ;;
    esac
    """)

    %{dir: dir, bin: bin}
  end

  defp stub(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/usr/bin/env bash\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  defp fw(%{dir: dir, bin: bin}, cmd) do
    System.cmd("bash", [@script, cmd],
      stderr_to_stdout: true,
      env: [
        {"PATH", "#{bin}:#{System.get_env("PATH")}"},
        {"HOST_INPUT_RULES", Path.join(dir, "rules.nft")},
        {"HOST_INPUT_NFT_CONF", Path.join(dir, "nftables.conf")},
        {"HOST_INPUT_SAVED", Path.join(dir, "nftables.d/host-input.nft")},
        {"HOST_INPUT_STATE", Path.join(dir, "state")}
      ]
    )
  end

  defp ok(ctx, cmd) do
    {out, code} = fw(ctx, cmd)
    assert code == 0, out
    out
  end

  defp refused(ctx, cmd) do
    {out, code} = fw(ctx, cmd)
    assert code != 0, "expected #{cmd} to be refused: #{out}"
    out
  end

  defp live(%{dir: dir}) do
    case File.read(Path.join(dir, "live")) do
      {:ok, text} -> text
      {:error, :enoent} -> nil
    end
  end

  defp saved?(%{dir: dir}), do: File.exists?(Path.join(dir, "nftables.d/host-input.nft"))
  defp timer?(%{dir: dir}), do: File.exists?(Path.join(dir, "timer"))
  defp calls(%{dir: dir}), do: File.read!(Path.join(dir, "calls")) |> String.split("\n", trim: true)

  # What the timer does when it fires: runs the command it was given, then is gone.
  defp fire_timer(%{dir: dir, bin: bin}) do
    [run] = File.read!(Path.join(dir, "calls")) |> String.split("\n") |> Enum.filter(&(&1 =~ "systemd-run"))
    [_, file] = Regex.run(~r/ -f (\S+)$/, run)
    {_, 0} = System.cmd(Path.join(bin, "nft"), ["-f", file])
    File.rm!(Path.join(dir, "timer"))
  end

  test "apply loads the rules live and saves nothing", ctx do
    assert ok(ctx, "apply") =~ "Rolls back in 300 s"
    assert live(ctx) == "new-rules\n"
    assert timer?(ctx)
    refute saved?(ctx)
  end

  test "the timer is scheduled, for 5 minutes, before the rules load", ctx do
    ok(ctx, "apply")
    log = calls(ctx)
    timer = Enum.find_index(log, &(&1 =~ "systemd-run"))
    load = Enum.find_index(log, &(&1 =~ ~r/^nft -f .*applied\.nft$/))

    assert timer < load
    assert Enum.at(log, timer) =~ "--on-active=300"
  end

  test "the timer firing removes a first-time firewall and saves nothing", ctx do
    ok(ctx, "apply")
    fire_timer(ctx)

    assert live(ctx) == nil
    refute saved?(ctx)
  end

  test "the timer firing restores the table that was there before", ctx do
    File.write!(Path.join(ctx.dir, "live"), "old-rules\n")
    ok(ctx, "apply")
    assert live(ctx) == "new-rules\n"

    fire_timer(ctx)
    assert live(ctx) == "old-rules\n"
  end

  test "confirm cancels the timer and saves what was applied", ctx do
    ok(ctx, "apply")
    # A later rsync must not change what gets saved.
    File.write!(Path.join(ctx.dir, "rules.nft"), "edited-after-apply\n")
    ok(ctx, "confirm")

    refute timer?(ctx)
    assert live(ctx) == "new-rules\n"
    assert File.read!(Path.join(ctx.dir, "nftables.d/host-input.nft")) == "new-rules\n"
  end

  test "confirm after the timer fired saves nothing", ctx do
    ok(ctx, "apply")
    fire_timer(ctx)

    assert refused(ctx, "confirm") =~ "no rollback pending"
    refute saved?(ctx)
  end

  test "confirm that loses the race with the rollback saves nothing", ctx do
    File.write!(Path.join(ctx.dir, "live"), "old-rules\n")
    ok(ctx, "apply")
    # Fired, but the timer unit still reads as active.
    {_, 0} = System.cmd(Path.join(ctx.bin, "nft"), ["-f", Path.join(ctx.dir, "state/previous.nft")])

    assert refused(ctx, "confirm") =~ "already ran"
    refute saved?(ctx)
  end

  test "a conf that does not parse with the rules saved keeps them out of it", ctx do
    ok(ctx, "apply")
    File.write!(Path.join(ctx.dir, "conf_check_fail"), "")

    assert refused(ctx, "confirm") =~ "saved file left as it was"
    refute saved?(ctx)
  end

  test "a conf that fails on confirm keeps the firewall saved earlier", ctx do
    File.write!(Path.join(ctx.dir, "rules.nft"), "new-rules\n")
    ok(ctx, "apply")
    ok(ctx, "confirm")

    File.write!(Path.join(ctx.dir, "rules.nft"), "newer-rules\n")
    ok(ctx, "apply")
    File.write!(Path.join(ctx.dir, "conf_check_fail"), "")

    assert refused(ctx, "confirm") =~ "saved file left as it was"
    assert File.read!(Path.join(ctx.dir, "nftables.d/host-input.nft")) == "new-rules\n"
  end

  test "a rollback that fails to load keeps the timer, and can be retried", ctx do
    File.write!(Path.join(ctx.dir, "live"), "old-rules\n")
    ok(ctx, "apply")
    File.write!(Path.join(ctx.dir, "restore_fail"), "")

    assert refused(ctx, "rollback") =~ "still pending"
    assert timer?(ctx)
    assert live(ctx) == "new-rules\n"

    File.rm!(Path.join(ctx.dir, "restore_fail"))
    ok(ctx, "rollback")
    assert live(ctx) == "old-rules\n"
    refute timer?(ctx)
  end

  test "a rollback file that does not parse stops apply before anything loads", ctx do
    File.write!(Path.join(ctx.dir, "live"), "old-rules\n")
    File.write!(Path.join(ctx.dir, "previous_check_fail"), "")

    assert refused(ctx, "apply") =~ "cannot build a rollback"
    assert live(ctx) == "old-rules\n"
    refute timer?(ctx)
  end

  test "a second apply is refused while a rollback is pending", ctx do
    ok(ctx, "apply")
    assert refused(ctx, "apply") =~ "pending"
    assert refused(ctx, "remove") =~ "pending"
  end

  test "rollback restores at once and cancels the timer", ctx do
    File.write!(Path.join(ctx.dir, "live"), "old-rules\n")
    ok(ctx, "apply")
    ok(ctx, "rollback")

    assert live(ctx) == "old-rules\n"
    refute timer?(ctx)
    assert refused(ctx, "rollback") =~ "no rollback pending"
  end

  test "remove drops a confirmed firewall, live and saved", ctx do
    ok(ctx, "apply")
    ok(ctx, "confirm")
    ok(ctx, "remove")

    assert live(ctx) == nil
    refute saved?(ctx)
  end

  test "rules that do not parse change nothing", ctx do
    File.write!(Path.join(ctx.dir, "check_fail"), "")
    assert refused(ctx, "apply") =~ "do not parse"
    assert live(ctx) == nil
    refute timer?(ctx)
  end

  test "rules that fail to load cancel the timer", ctx do
    File.write!(Path.join(ctx.dir, "load_fail"), "")
    assert refused(ctx, "apply") =~ "did not load"
    refute timer?(ctx)
  end

  test "no timer, no rules", ctx do
    File.write!(Path.join(ctx.dir, "timer_fail"), "")
    assert refused(ctx, "apply") =~ "cannot schedule"
    assert live(ctx) == nil
  end

  test "sshd on another port is refused: the rules would lock everybody out", ctx do
    File.write!(Path.join(ctx.dir, "sshd_port"), "2222\n")
    assert refused(ctx, "apply") =~ "sshd must listen on 22"
    assert live(ctx) == nil
    refute timer?(ctx)
  end

  test "a failing sshd -T is refused with a reason", ctx do
    File.write!(Path.join(ctx.dir, "sshd_fail"), "")
    assert refused(ctx, "apply") =~ "sshd -T failed"
    assert live(ctx) == nil
    refute timer?(ctx)
  end

  test "a conf that does not load /etc/nftables.d is refused", ctx do
    File.write!(Path.join(ctx.dir, "nftables.conf"), "flush ruleset\n")
    assert refused(ctx, "apply") =~ "does not include"
    refute timer?(ctx)
  end

  test "non-root is refused", ctx do
    stub(ctx.bin, "id", "echo 1000")
    assert refused(ctx, "status") =~ "must run as root"
  end

  test "the script never reloads nftables.service or flushes the ruleset" do
    code =
      File.read!(@script)
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
      |> Enum.join("\n")

    refute code =~ ~r/systemctl[^\n]*nftables/
    refute code =~ "flush ruleset"
  end
end
