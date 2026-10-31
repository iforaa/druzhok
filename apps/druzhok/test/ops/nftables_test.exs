defmodule Druzhok.Ops.NftablesTest do
  @moduledoc """
  Static checks on `ops/nftables-druzhok.nft`. There is no nft on a dev
  machine, so these read the ruleset as text and hold the one invariant the
  egress policy rests on: a bot uid is never allowed out to "anywhere".
  """
  use ExUnit.Case, async: true

  @ruleset Path.expand("../../../../ops/nftables-druzhok.nft", __DIR__)

  # Rules that apply to bot uids: the body of chain `bot_egress`, comments and
  # blanks dropped.
  defp bot_rules do
    @ruleset
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.drop_while(&(not String.starts_with?(&1, "chain bot_egress")))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != "}"))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp set_elements(name) do
    [_, body] = Regex.run(~r/set #{name} \{.*?elements = \{(.*?)\}/s, File.read!(@ruleset))
    body |> String.split(",") |> Enum.map(&String.trim/1)
  end

  test "bot uids, and only they, are sent through bot_egress" do
    assert File.read!(@ruleset) =~ ~r/type filter hook output priority 0; policy accept;\s+meta skuid @bot_uids jump bot_egress\s+\}/
  end

  test "the bot section is found and ends in a drop" do
    assert [_ | _] = rules = bot_rules()
    assert List.last(rules) =~ ~r/\bdrop$/
  end

  test "every accept rule for bots is pinned to a destination" do
    for rule <- bot_rules(), rule =~ ~r/\baccept$/ do
      assert rule =~ ~r/^ip6? daddr /, "bot accept rule has no destination: #{rule}"
    end
  end

  test "DNS is allowed over udp and tcp, to the resolver set only" do
    dns = Enum.filter(bot_rules(), &(&1 =~ "dport 53"))

    assert Enum.sort(dns) == [
             "ip daddr @resolvers4 tcp dport 53 accept",
             "ip daddr @resolvers4 udp dport 53 accept"
           ]
  end

  test "the webhook reply rule is keyed on uid and port and matches replies only" do
    assert ["ip daddr 127.0.0.1 meta skuid . tcp sport @bot_webhook ct direction reply accept"] =
             Enum.filter(bot_rules(), &(&1 =~ "bot_webhook"))

    assert File.read!(@ruleset) =~ "set bot_webhook { type uid . inet_service; }"
  end

  test "the resolver set holds loopback addresses only" do
    assert [_ | _] = resolvers = set_elements("resolvers4")

    for addr <- resolvers do
      assert addr =~ ~r/^127\.\d+\.\d+\.\d+$/, "#{addr} is not a loopback resolver"
    end
  end
end
