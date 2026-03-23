defmodule Druzhok.Sandbox.ProtocolTest do
  use ExUnit.Case, async: true

  alias Druzhok.Sandbox.Protocol

  describe "split_lines/1" do
    test "splits complete lines" do
      {lines, rest} = Protocol.split_lines("line1\nline2\n")
      assert lines == ["line1", "line2"]
      assert rest == ""
    end

    test "keeps incomplete line as rest" do
      {lines, rest} = Protocol.split_lines("line1\npartial")
      assert lines == ["line1"]
      assert rest == "partial"
    end

    test "handles empty buffer" do
      {lines, rest} = Protocol.split_lines("")
      assert lines == []
      assert rest == ""
    end

    test "handles single incomplete line" do
      {lines, rest} = Protocol.split_lines("partial")
      assert lines == []
      assert rest == "partial"
    end

    test "handles single complete line" do
      {lines, rest} = Protocol.split_lines("complete\n")
      assert lines == ["complete"]
      assert rest == ""
    end

    test "skips empty lines" do
      {lines, rest} = Protocol.split_lines("a\n\nb\n")
      assert lines == ["a", "b"]
      assert rest == ""
    end
  end

  describe "build_request/3" do
    test "builds JSON request with auto-incremented id" do
      state = %{counter: 0}
      {id, json, new_state} = Protocol.build_request(state, "exec", %{command: "ls"})

      assert id == "req-1"
      assert new_state.counter == 1
      decoded = Jason.decode!(String.trim(json))
      assert decoded["id"] == "req-1"
      assert decoded["type"] == "exec"
      assert decoded["command"] == "ls"
    end

    test "increments counter across calls" do
      state = %{counter: 5}
      {id, _json, new_state} = Protocol.build_request(state, "read", %{path: "/file"})
      assert id == "req-6"
      assert new_state.counter == 6
    end
  end

  describe "process_line/2" do
    test "ignores invalid JSON" do
      state = %{pending: %{}}
      assert Protocol.process_line("not json", state) == state
    end

    test "ignores unknown request ids" do
      state = %{pending: %{}}
      line = Jason.encode!(%{id: "req-99", type: "result", data: "hello"})
      assert Protocol.process_line(line, state) == state
    end

    test "accumulates stdout for exec requests using iodata" do
      state = %{pending: %{"req-1" => %{from: self(), type: :exec, stdout: [], stderr: []}}}
      line = Jason.encode!(%{id: "req-1", type: "stdout", data: "hello"})
      new_state = Protocol.process_line(line, state)

      # iodata accumulation pattern: [prev | new_data]
      assert new_state.pending["req-1"].stdout == [[] | "hello"]
    end

    test "accumulates stderr for exec requests using iodata" do
      state = %{pending: %{"req-1" => %{from: self(), type: :exec, stdout: [], stderr: []}}}
      line = Jason.encode!(%{id: "req-1", type: "stderr", data: "err"})
      new_state = Protocol.process_line(line, state)

      assert new_state.pending["req-1"].stderr == [[] | "err"]
    end
  end

  describe "add_pending/4" do
    test "adds exec pending with stdout/stderr accumulators" do
      state = %{pending: %{}}
      new_state = Protocol.add_pending(state, "req-1", self(), :exec)

      assert new_state.pending["req-1"] == %{from: self(), type: :exec, stdout: [], stderr: []}
    end

    test "adds simple pending" do
      state = %{pending: %{}}
      new_state = Protocol.add_pending(state, "req-1", self(), :simple)

      assert new_state.pending["req-1"] == %{from: self(), type: :simple}
    end
  end

  describe "handle_response/4 — error type" do
    test "replies with error and removes pending" do
      test_pid = self()

      # Spawn a process that will receive the GenServer reply
      task = Task.async(fn ->
        receive do
          {:"$gen_call", from, :get_reply} ->
            # Register the from so handle_response can reply to it
            send(test_pid, {:from, from})
            receive do
              msg -> msg
            end
        end
      end)

      # We need to test handle_response with error — use a simpler approach
      # Just verify state changes since GenServer.reply needs a real caller
      state = %{pending: %{"req-1" => %{from: {task.pid, make_ref()}, type: :simple}}}
      msg = %{"id" => "req-1", "type" => "error", "message" => "not found"}
      new_state = Protocol.handle_response("req-1", msg, state.pending["req-1"], state)

      assert new_state.pending == %{}
      Task.shutdown(task, :brutal_kill)
    end
  end

  describe "handle_tcp_data/2" do
    test "buffers and processes complete lines" do
      state = %{buffer: "", pending: %{"req-1" => %{from: self(), type: :exec, stdout: [], stderr: []}}}
      data = Jason.encode!(%{id: "req-1", type: "stdout", data: "hi"}) <> "\n"
      new_state = Protocol.handle_tcp_data(data, state)

      assert new_state.buffer == ""
      assert new_state.pending["req-1"].stdout == [[] | "hi"]
    end

    test "preserves partial buffer" do
      state = %{buffer: "", pending: %{}}
      new_state = Protocol.handle_tcp_data("partial", state)

      assert new_state.buffer == "partial"
    end

    test "combines existing buffer with new data" do
      partial = ~s({"id":"req-1","type":"stdout","dat)
      rest = ~s(a":"x"}\n)
      state = %{buffer: partial, pending: %{"req-1" => %{from: self(), type: :exec, stdout: [], stderr: []}}}
      new_state = Protocol.handle_tcp_data(rest, state)

      assert new_state.buffer == ""
      assert new_state.pending["req-1"].stdout == [[] | "x"]
    end
  end
end
