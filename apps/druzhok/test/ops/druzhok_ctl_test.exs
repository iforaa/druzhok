defmodule Druzhok.Ops.DruzhokCtlTest do
  @moduledoc """
  Runs the webhook port functions of `ops/druzhok-ctl` in bash with
  `nft`, `systemctl` and `id` stubbed, since the script itself needs root.
  """
  use ExUnit.Case, async: true

  @ctl Path.expand("../../../../ops/druzhok-ctl", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ctl-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Extract the named functions from the script and call `body` with them.
  defp run(dir, env_file, body) do
    envf = Path.join(dir, "bot.env")
    File.write!(envf, env_file)
    calls = Path.join(dir, "calls")

    functions =
      for f <- ~w(uid_of webhook_port nft_webhook_add nft_webhook_del remove_bind_lock),
          into: "" do
        [fun] = Regex.run(~r/^#{f}\(\) \{.*?^\}\n|^#{f}\(\) +\{[^\n]*\}\n/ms, File.read!(@ctl))
        fun
      end

    script = """
    set -euo pipefail
    NFT_FAMILY=inet NFT_TABLE=druzhok NFT_WEBHOOK_SET=bot_webhook
    UNIT_DIR=#{dir}/units unit=hermes@kot.service user=bot-kot envf=#{envf}
    nft() { echo "nft $*" >> #{calls}; }
    systemctl() { echo "systemctl $*" >> #{calls}; }
    id() { echo 1234; }
    #{functions}
    #{body}
    """

    {out, code} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert code == 0, out

    %{
      calls: if(File.exists?(calls), do: File.read!(calls), else: ""),
      units: Path.join(dir, "units")
    }
  end

  # The box's systemd ignores SocketBindAllow/Deny (no BPF_FRAMEWORK), so the
  # drop-in an earlier druzhok-ctl wrote is removed rather than kept as a
  # lock that only looks like one.
  test "a leftover bind-lock drop-in is removed, with one daemon-reload", %{dir: dir} do
    dropin = Path.join(dir, "units/hermes@kot.service.d")
    File.mkdir_p!(dropin)
    File.write!(Path.join(dropin, "webhook.conf"), "[Service]\nSocketBindDeny=any\n")

    %{calls: calls} = run(dir, ~s(TELEGRAM_WEBHOOK_PORT="20009"\n), "remove_bind_lock; remove_bind_lock")

    refute File.exists?(dropin)
    assert calls == "systemctl daemon-reload\n"
  end

  test "no drop-in, nothing to do", %{dir: dir} do
    assert %{calls: ""} = run(dir, ~s(OTHER="x"\n), "remove_bind_lock")
  end

  test "the nft element pairs the bot's uid with its port", %{dir: dir} do
    %{calls: calls} =
      run(dir, ~s(TELEGRAM_WEBHOOK_PORT="20009"\n), "nft_webhook_add; nft_webhook_del")

    assert calls ==
             "nft add element inet druzhok bot_webhook { 1234 . 20009 }\n" <>
               "nft delete element inet druzhok bot_webhook { 1234 . 20009 }\n"
  end

  test "no port, no nft element", %{dir: dir} do
    assert %{calls: ""} = run(dir, ~s(OTHER="x"\n), "nft_webhook_add")
  end

  test "a port line that is not a plain number is ignored", %{dir: dir} do
    assert %{calls: ""} = run(dir, ~s(TELEGRAM_WEBHOOK_PORT="20009; reboot"\n), "nft_webhook_add")
  end
end
