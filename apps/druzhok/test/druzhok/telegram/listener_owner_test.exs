defmodule Druzhok.Telegram.ListenerOwnerTest do
  use ExUnit.Case, async: true

  alias Druzhok.Telegram.ListenerOwner

  # /proc/net/tcp as Linux prints it: 127.0.0.1:20009 (0x4E29) listening as
  # uid 1001, 0.0.0.0:20010 (0x4E2A) as uid 1002, and an established
  # connection from port 20009 that must not count as a listener.
  @proc_net_tcp """
    sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
     0: 0100007F:4E29 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1001        0 41011 1 0000000000000000 100 0 0 10 0
     1: 00000000:4E2A 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1002        0 41012 1 0000000000000000 100 0 0 10 0
     2: 0100007F:4E29 0100007F:B3C2 01 00000000:00000000 00:00000000 00000000  1003        0 41013 1 0000000000000000 20 4 30 10 -1
  """

  test "finds the listeners on a port, any address, listening sockets only" do
    assert ListenerOwner.parse(@proc_net_tcp, 20_009) == [1001]
    assert ListenerOwner.parse(@proc_net_tcp, 20_010) == [1002]
    assert ListenerOwner.parse(@proc_net_tcp, 20_011) == []
  end

  test "every listener on the port must be the bot's uid" do
    assert ListenerOwner.verify([1001], 1001) == :ok
    assert ListenerOwner.verify([], 1001) == {:error, :no_listener}
    assert ListenerOwner.verify([1001, 1002], 1001) == {:error, {:wrong_owner, [1002]}}
  end

  test "nothing to check outside the systemd host" do
    assert ListenerOwner.check("anybot", 20_009) == :ok
  end
end
