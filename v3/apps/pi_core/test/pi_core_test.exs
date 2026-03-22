defmodule PiCoreTest do
  use ExUnit.Case

  test "public API delegates are defined" do
    exports = PiCore.__info__(:functions)
    assert {:start_session, 1} in exports
    assert {:prompt, 2} in exports
    assert {:abort, 1} in exports
    assert {:reset, 1} in exports
  end
end
