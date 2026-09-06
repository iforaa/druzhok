defmodule Druzhok.InstanceTest do
  use ExUnit.Case, async: true

  alias Druzhok.Instance

  @base %{name: "memtest", model: "ruoc-flash", workspace: "/tmp/x"}

  test "memory_provider defaults to builtin and accepts mnemosyne" do
    assert %Instance{memory_provider: "builtin"} = %Instance{}
    assert Instance.changeset(%Instance{}, @base).changes[:memory_provider] == nil
    assert Instance.changeset(%Instance{}, Map.put(@base, :memory_provider, "mnemosyne")).valid?
  end

  test "an unknown memory_provider is rejected" do
    cs = Instance.changeset(%Instance{}, Map.put(@base, :memory_provider, "hindsight"))
    refute cs.valid?
    assert {"is invalid", _} = cs.errors[:memory_provider]
  end

  test "memory_providers lists the two values in order" do
    assert Instance.memory_providers() == ["builtin", "mnemosyne"]
  end
end
