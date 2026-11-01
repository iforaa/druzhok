defmodule Druzhok.StatusTest do
  use ExUnit.Case, async: true

  alias Druzhok.Status

  describe "parse_df/1" do
    test "reads total and available in MB, rounded up as df -m does" do
      out = """
      Filesystem     1024-blocks    Used Available Capacity Mounted on
      /dev/vda1          5095040 3123200   1712128      65% /
      """

      assert Status.parse_df(out) == {4976, 1672}
    end

    test "a device name with spaces does not shift the columns" do
      out = """
      Filesystem 1024-blocks Used Available Capacity Mounted on
      my disk 2048 1024 1024 50% /data
      """

      assert Status.parse_df(out) == {2, 1}
    end

    test "output it cannot read gives no numbers" do
      assert Status.parse_df("") == {nil, nil}
      assert Status.parse_df("Filesystem\n") == {nil, nil}
      assert Status.parse_df("h\nx y z\n") == {nil, nil}
      assert Status.parse_df("h\ndev a b c 50% /\n") == {nil, nil}
    end
  end
end
