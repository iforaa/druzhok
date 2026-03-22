defmodule PiCore.SessionTest do
  use ExUnit.Case

  alias PiCore.LLM.Client.Result

  setup do
    dir = Path.join(System.tmp_dir!(), "pi_core_session_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "AGENTS.md"), "You are a test agent.")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "prompt returns response via message", %{workspace: ws} do
    {:ok, pid} = PiCore.Session.start_link(%{
      workspace: ws, model: "test", api_url: "http://unused", api_key: "unused",
      llm_fn: fn _opts -> {:ok, %Result{content: "Hello!", tool_calls: []}} end,
      caller: self()
    })

    PiCore.Session.prompt(pid, "Hi")
    assert_receive {:pi_response, %{text: "Hello!"}}, 5000
  end

  test "handles parallel prompts", %{workspace: ws} do
    {:ok, pid} = PiCore.Session.start_link(%{
      workspace: ws, model: "test", api_url: "http://unused", api_key: "unused",
      llm_fn: fn opts ->
        # Check last user message to decide speed
        last_user = opts.messages |> Enum.filter(& &1[:role] == "user") |> List.last()
        if last_user && last_user[:content] =~ "slow" do
          Process.sleep(300)
          {:ok, %Result{content: "Slow done", tool_calls: []}}
        else
          {:ok, %Result{content: "Fast done", tool_calls: []}}
        end
      end,
      caller: self()
    })

    PiCore.Session.prompt(pid, "slow task")
    Process.sleep(50)
    PiCore.Session.prompt(pid, "fast question")

    responses = collect_responses(2, 5000)
    texts = Enum.map(responses, & &1.text)
    assert "Fast done" in texts
    assert "Slow done" in texts
  end

  test "reset clears history", %{workspace: ws} do
    {:ok, pid} = PiCore.Session.start_link(%{
      workspace: ws, model: "test", api_url: "http://unused", api_key: "unused",
      llm_fn: fn _opts -> {:ok, %Result{content: "ok", tool_calls: []}} end,
      caller: self()
    })

    PiCore.Session.prompt(pid, "remember this")
    assert_receive {:pi_response, _}, 5000

    PiCore.Session.reset(pid)
    state = :sys.get_state(pid)
    assert state.messages == []
  end

  test "abort stops active task", %{workspace: ws} do
    {:ok, pid} = PiCore.Session.start_link(%{
      workspace: ws, model: "test", api_url: "http://unused", api_key: "unused",
      llm_fn: fn _opts ->
        Process.sleep(10_000)
        {:ok, %Result{content: "should not reach", tool_calls: []}}
      end,
      caller: self()
    })

    PiCore.Session.prompt(pid, "long task")
    Process.sleep(100)
    PiCore.Session.abort(pid)

    # Should be able to send another prompt (not stuck)
    state = :sys.get_state(pid)
    assert state.active_task == nil
  end

  test "public API delegates work", %{workspace: ws} do
    {:ok, pid} = PiCore.start_session(%{
      workspace: ws, model: "test", api_url: "http://unused", api_key: "unused",
      llm_fn: fn _opts -> {:ok, %Result{content: "via API", tool_calls: []}} end,
      caller: self()
    })

    PiCore.prompt(pid, "test")
    assert_receive {:pi_response, %{text: "via API"}}, 5000
  end

  defp collect_responses(0, _timeout), do: []
  defp collect_responses(count, timeout) do
    receive do
      {:pi_response, response} -> [response | collect_responses(count - 1, timeout)]
    after
      timeout -> []
    end
  end
end
