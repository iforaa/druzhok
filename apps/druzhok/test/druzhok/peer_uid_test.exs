defmodule Druzhok.PeerUidTest do
  use ExUnit.Case, async: false

  alias Druzhok.PeerUid

  @header "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

  # druzhok listens on 127.0.0.1:4000 (0FA0) as uid 1000; bot uid 1001 is the
  # client on port 54321 (D431); a TIME_WAIT row (06) is uid 0.
  @tcp @header <>
         "   0: 0100007F:0FA0 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 11 1 0000000000000000 100 0 0 10 0\n" <>
         "   1: 0100007F:0FA0 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 12 1 0000000000000000 20 4 30 10 -1\n" <>
         "   2: 0100007F:D431 0100007F:0FA0 01 00000000:00000000 00:00000000 00000000  1001        0 13 1 0000000000000000 20 4 30 10 -1\n" <>
         "   3: 0100007F:D432 0100007F:0FA0 06 00000000:00000000 03:00000F9F 00000000     0        0 0 3 0000000000000000\n"

  # IPv4-mapped (a dual-stack listener) and ::1.
  @tcp6 @header <>
          "   0: 0000000000000000FFFF00000100007F:D433 0000000000000000FFFF00000100007F:0FA0 01 00000000:00000000 00:00000000 00000000  1002        0 21 1 0000000000000000 20 4 30 10 -1\n" <>
          "   1: 00000000000000000000000001000000:D434 00000000000000000000000001000000:0FA0 01 00000000:00000000 00:00000000 00000000  1003        0 22 1 0000000000000000 20 4 30 10 -1\n"

  @passwd """
  root:x:0:0:root:/root:/bin/bash
  ubuntu:x:1000:1000::/home/ubuntu:/bin/bash
  bot-vasya:x:1001:1001::/data/tenants/vasya:/usr/sbin/nologin
  bot-petya:x:1002:1002::/data/tenants/petya:/usr/sbin/nologin
  bot-Bad.Name:x:1003:1003::/nonexistent:/usr/sbin/nologin
  cleo-docs:x:1004:1004::/nonexistent:/usr/sbin/nologin
  """

  @server {{127, 0, 0, 1}, 4000}

  describe "parse/1" do
    test "reads IPv4 rows: addresses, ports, state and uid" do
      rows = PeerUid.parse(@tcp)
      assert length(rows) == 4

      assert %{local: {{127, 0, 0, 1}, 54321}, remote: {{127, 0, 0, 1}, 4000}, state: 1, uid: 1001} in rows
      assert %{local: {{127, 0, 0, 1}, 4000}, remote: {{0, 0, 0, 0}, 0}, state: 0x0A, uid: 1000} in rows
    end

    test "reads IPv6 rows, turning IPv4-mapped addresses into IPv4" do
      rows = PeerUid.parse(@tcp6)

      assert %{local: {{127, 0, 0, 1}, 0xD433}, remote: {{127, 0, 0, 1}, 4000}, state: 1, uid: 1002} in rows
      assert %{local: {{0, 0, 0, 0, 0, 0, 0, 1}, 0xD434}, remote: {{0, 0, 0, 0, 0, 0, 0, 1}, 4000}, state: 1, uid: 1003} in rows
    end

    test "skips the header and lines that do not parse" do
      assert PeerUid.parse(@header <> "garbage line\n   9: XYZ:0FA0 0100007F:0FA0 01 a b c 5\n") == []
    end
  end

  describe "owner/3" do
    test "is the uid of the ESTABLISHED client end, not the server's end" do
      rows = PeerUid.parse(@tcp)
      assert PeerUid.owner(rows, {{127, 0, 0, 1}, 54321}, @server) == 1001
    end

    test "matches an IPv4-mapped peer as given by a dual-stack listener" do
      rows = PeerUid.parse(@tcp6)
      assert PeerUid.owner(rows, {{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, 0xD433}, @server) == 1002
    end

    test "is nil for a closed (TIME_WAIT) row, an unknown port or another server port" do
      rows = PeerUid.parse(@tcp)
      assert PeerUid.owner(rows, {{127, 0, 0, 1}, 0xD432}, @server) == nil
      assert PeerUid.owner(rows, {{127, 0, 0, 1}, 1}, @server) == nil
      assert PeerUid.owner(rows, {{127, 0, 0, 1}, 54321}, {{127, 0, 0, 1}, 4001}) == nil
    end

    test "is nil when two uids claim the same pair" do
      [row] = PeerUid.parse(@tcp) |> Enum.filter(&(&1.uid == 1001))
      assert PeerUid.owner([row, %{row | uid: 1002}], {{127, 0, 0, 1}, 54321}, @server) == nil
    end
  end

  describe "bot names" do
    test "only bot-<valid name> users are bots" do
      assert PeerUid.bot_of(PeerUid.user_name(@passwd, 1001)) == "vasya"
      assert PeerUid.bot_of(PeerUid.user_name(@passwd, 1000)) == nil
      assert PeerUid.bot_of(PeerUid.user_name(@passwd, 1003)) == nil
      assert PeerUid.bot_of(PeerUid.user_name(@passwd, 1004)) == nil
      assert PeerUid.bot_of(PeerUid.user_name(@passwd, 0)) == nil
      assert PeerUid.user_name(@passwd, 4242) == nil
      assert PeerUid.bot_of(nil) == nil
    end

    @tag :tmp_dir
    test "bot_name/2 reads the tables and passwd", %{tmp_dir: dir} do
      tcp = Path.join(dir, "tcp")
      tcp6 = Path.join(dir, "tcp6")
      passwd = Path.join(dir, "passwd")
      File.write!(tcp, @tcp)
      File.write!(tcp6, @tcp6)
      File.write!(passwd, @passwd)

      Application.put_env(:druzhok, :peer_uid_tables, [tcp, tcp6, Path.join(dir, "missing")])
      Application.put_env(:druzhok, :peer_uid_passwd, passwd)

      on_exit(fn ->
        Application.delete_env(:druzhok, :peer_uid_tables)
        Application.delete_env(:druzhok, :peer_uid_passwd)
      end)

      assert PeerUid.bot_name({{127, 0, 0, 1}, 54321}, @server) == "vasya"
      assert PeerUid.bot_name({{127, 0, 0, 1}, 0xD433}, @server) == "petya"
      assert PeerUid.bot_name({{127, 0, 0, 1}, 0xD432}, @server) == nil
    end
  end
end
