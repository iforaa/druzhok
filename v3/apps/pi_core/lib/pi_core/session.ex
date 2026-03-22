defmodule PiCore.Session do
  use GenServer

  alias PiCore.Loop
  alias PiCore.LLM.Client

  defstruct [
    :workspace, :model, :api_url, :api_key,
    :system_prompt, :tools, :on_delta, :caller, :llm_fn,
    :workspace_loader,
    messages: [],
    active_task: nil,
    parallel_tasks: %{}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def prompt(pid, text) do
    GenServer.cast(pid, {:prompt, text})
  end

  def abort(pid) do
    GenServer.cast(pid, :abort)
  end

  def reset(pid) do
    GenServer.cast(pid, :reset)
  end

  # --- Callbacks ---

  def init(opts) do
    loader = opts[:workspace_loader] || PiCore.WorkspaceLoader.Default
    system_prompt = loader.load(opts.workspace, %{})
    tools = opts[:tools] || default_tools()

    state = %__MODULE__{
      workspace: opts.workspace,
      model: opts.model,
      api_url: opts.api_url,
      api_key: opts.api_key,
      system_prompt: system_prompt,
      tools: tools,
      on_delta: opts[:on_delta],
      caller: opts[:caller] || self(),
      llm_fn: opts[:llm_fn],
      workspace_loader: loader
    }

    {:ok, state}
  end

  def handle_cast({:prompt, text}, state) do
    user_msg = %Loop.Message{role: "user", content: text, timestamp: System.os_time(:millisecond)}

    if state.active_task do
      # Busy — spawn parallel with history snapshot
      snapshot = state.messages ++ [user_msg]
      task = Task.async(fn -> run_prompt(snapshot, state) end)
      parallel_tasks = Map.put(state.parallel_tasks, task.ref, %{user_msg: user_msg})
      {:noreply, %{state | parallel_tasks: parallel_tasks}}
    else
      # Idle — run inline
      state = %{state | messages: state.messages ++ [user_msg]}
      task = Task.async(fn -> run_prompt(state.messages, state) end)
      {:noreply, %{state | active_task: task}}
    end
  end

  def handle_cast(:abort, state) do
    if state.active_task do
      Task.shutdown(state.active_task, :brutal_kill)
      {:noreply, %{state | active_task: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:reset, state) do
    PiCore.SessionStore.clear(state.workspace)
    {:noreply, %{state | messages: [], active_task: nil, parallel_tasks: %{}}}
  end

  # Task completed successfully
  def handle_info({ref, {:ok, new_messages}}, state) do
    Process.demonitor(ref, [:flush])

    if state.active_task && state.active_task.ref == ref do
      # Main task completed
      state = %{state | messages: state.messages ++ new_messages, active_task: nil}
      deliver_last_assistant(new_messages, ref, state)
      {:noreply, state}
    else
      case Map.pop(state.parallel_tasks, ref) do
        {%{user_msg: user_msg}, remaining} ->
          # Parallel task completed — merge Q&A back
          state = %{state | messages: state.messages ++ [user_msg | new_messages], parallel_tasks: remaining}
          deliver_last_assistant(new_messages, ref, state)
          {:noreply, state}

        {nil, _} ->
          {:noreply, state}
      end
    end
  end

  # Task failed
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if state.active_task && state.active_task.ref == ref do
      send(state.caller, {:pi_response, %{text: "Error: #{inspect(reason)}", prompt_id: ref, error: true}})
      {:noreply, %{state | active_task: nil}}
    else
      {:noreply, %{state | parallel_tasks: Map.delete(state.parallel_tasks, ref)}}
    end
  end

  # Catch-all for unexpected messages
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp deliver_last_assistant(new_messages, ref, state) do
    case Enum.find(Enum.reverse(new_messages), &(&1.role == "assistant")) do
      nil -> :ok
      msg -> send(state.caller, {:pi_response, %{text: msg.content, prompt_id: ref}})
    end
  end

  defp run_prompt(messages, state) do
    llm_fn = state.llm_fn || &default_llm_fn(state, &1)

    Loop.run(%{
      system_prompt: state.system_prompt,
      messages: messages,
      tools: state.tools,
      tool_context: %{workspace: state.workspace},
      llm_fn: llm_fn,
      on_delta: state.on_delta
    })
  end

  defp default_llm_fn(state, opts) do
    Client.completion(%{
      model: state.model,
      api_url: state.api_url,
      api_key: state.api_key,
      system_prompt: opts.system_prompt,
      messages: opts.messages,
      tools: opts.tools,
      max_tokens: 16384,
      stream: true,
      on_delta: opts[:on_delta]
    })
  end

  defp default_tools do
    [
      PiCore.Tools.Bash.new(),
      PiCore.Tools.Read.new(),
      PiCore.Tools.Write.new(),
      PiCore.Tools.Edit.new()
    ]
  end
end
