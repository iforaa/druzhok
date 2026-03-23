defmodule PiCore.Memory.FlushTest do
  use ExUnit.Case

  alias PiCore.Memory.Flush
  alias PiCore.Loop.Message

  @workspace System.tmp_dir!() |> Path.join("flush_test_#{:rand.uniform(99999)}")

  setup do
    File.mkdir_p!(Path.join(@workspace, "memory"))
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "flush writes extracted context to daily memory file" do
    messages = [
      %Message{role: "user", content: "My name is Igor and I work at Acme Corp", timestamp: 1},
      %Message{role: "assistant", content: "Nice to meet you Igor!", timestamp: 2},
      %Message{role: "user", content: "Remember I prefer dark mode", timestamp: 3},
      %Message{role: "assistant", content: "Got it, dark mode preference noted", timestamp: 4},
    ]

    mock_llm = fn _opts ->
      {:ok, %PiCore.LLM.Client.Result{
        content: "- User name: Igor, works at Acme Corp\n- Prefers dark mode",
        tool_calls: []
      }}
    end

    :ok = Flush.flush(messages, mock_llm, @workspace, "UTC")

    today = Date.utc_today() |> Date.to_string()
    path = Path.join(@workspace, "memory/#{today}.md")
    assert File.exists?(path)
    content = File.read!(path)
    assert content =~ "Igor"
    assert content =~ "dark mode"
    assert content =~ "###"
    assert content =~ "auto-flush"
  end

  test "flush does nothing when llm_fn is nil" do
    messages = [%Message{role: "user", content: "test", timestamp: 1}]
    assert :ok = Flush.flush(messages, nil, @workspace, "UTC")
  end

  test "flush handles LLM error gracefully" do
    messages = [%Message{role: "user", content: "test", timestamp: 1}]
    mock_llm = fn _opts -> {:error, "API down"} end
    assert :ok = Flush.flush(messages, mock_llm, @workspace, "UTC")
  end

  test "flush does nothing with empty messages" do
    assert :ok = Flush.flush([], fn _ -> {:ok, %{content: "test"}} end, @workspace, "UTC")
  end
end
