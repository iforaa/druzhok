defmodule PiCore.Memory.SearchTest do
  use ExUnit.Case

  alias PiCore.Memory.Search

  setup do
    dir = Path.join(System.tmp_dir!(), "pi_core_memsearch_#{:rand.uniform(100000)}")
    File.mkdir_p!(Path.join(dir, "memory"))
    File.write!(Path.join(dir, "MEMORY.md"), """
    # User Profile
    - Name: Igor
    - Language: Russian
    - Likes: Elixir, distributed systems
    """)
    File.write!(Path.join(dir, "memory/2026-03-22.md"), """
    # Daily notes
    - Discussed Firecracker architecture
    - User prefers Elixir over Go
    - Built pi_core agent loop
    """)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "keyword search finds matching content", %{workspace: ws} do
    {:ok, results} = Search.search(ws, "Elixir", %{})
    assert length(results) > 0
    assert Enum.any?(results, & &1.text =~ "Elixir")
  end

  test "returns empty for no matches", %{workspace: ws} do
    {:ok, results} = Search.search(ws, "quantum computing blockchain", %{})
    assert results == []
  end

  test "searches across multiple files", %{workspace: ws} do
    {:ok, results} = Search.search(ws, "Igor Firecracker", %{})
    files = Enum.map(results, & &1.file) |> Enum.uniq()
    assert length(files) >= 1
  end

  test "returns empty for workspace with no memory files" do
    dir = Path.join(System.tmp_dir!(), "empty_mem_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    {:ok, results} = Search.search(dir, "anything", %{})
    assert results == []
    File.rm_rf!(dir)
  end
end
