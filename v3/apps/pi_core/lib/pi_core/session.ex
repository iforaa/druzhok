defmodule PiCore.Session do
  use GenServer

  alias PiCore.Loop
  alias PiCore.LLM.Client
  alias PiCore.LLM.Retry
  alias PiCore.Compaction

  defstruct [
    :workspace, :model, :provider, :api_url, :api_key,
    :system_prompt, :tools, :on_delta, :on_event, :caller, :llm_fn,
    :workspace_loader, :instance_name, :extra_tool_context,
    :chat_id, :idle_timer, :budget, :model_info_fn,
    group: false,
    messages: [],
    active_task: nil,
    parallel_tasks: %{}
  ]

  def start_link(opts) do
    case opts[:name] do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
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

  def set_model(pid, model, opts \\ %{}) do
    GenServer.cast(pid, {:set_model, model, opts})
  end

  # --- Callbacks ---

  def init(opts) do
    loader = opts[:workspace_loader] || PiCore.WorkspaceLoader.Default
    group = opts[:group] || false
    model_info_fn = opts[:model_info_fn]
    tools = opts[:tools] || default_tools()

    context_window = if model_info_fn do
      model_info_fn.(:context_window, opts.model)
    else
      32_000
    end

    budget = PiCore.TokenBudget.compute(context_window)

    system_prompt = build_system_prompt(loader, opts.workspace, group, budget, opts.model)

    state = %__MODULE__{
      workspace: opts.workspace,
      model: opts.model,
      provider: opts[:provider],
      api_url: opts.api_url,
      api_key: opts.api_key,
      system_prompt: system_prompt,
      tools: tools,
      on_delta: opts[:on_delta],
      on_event: opts[:on_event],
      caller: opts[:caller] || self(),
      llm_fn: opts[:llm_fn],
      workspace_loader: loader,
      instance_name: opts[:instance_name],
      extra_tool_context: opts[:extra_tool_context] || %{},
      chat_id: opts[:chat_id],
      group: group,
      budget: budget,
      model_info_fn: model_info_fn
    }

    state = schedule_idle_timeout(state)
    {:ok, state}
  end

  def handle_cast({:prompt, text}, state) do
    state = schedule_idle_timeout(state)
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

  def handle_cast({:set_caller, pid}, state) do
    {:noreply, %{state | caller: pid}}
  end

  def handle_cast({:set_model, model, opts}, state) do
    context_window = if state.model_info_fn do
      state.model_info_fn.(:context_window, model)
    else
      32_000
    end

    budget = PiCore.TokenBudget.compute(context_window)
    system_prompt = build_system_prompt(state.workspace_loader, state.workspace, state.group, budget, model)

    state = %{state | model: model, system_prompt: system_prompt, budget: budget}
    state = if opts[:provider], do: %{state | provider: opts[:provider]}, else: state
    state = if opts[:api_url], do: %{state | api_url: opts[:api_url]}, else: state
    state = if opts[:api_key], do: %{state | api_key: opts[:api_key]}, else: state

    # Run immediate compaction check with new budget
    if state.messages != [] do
      llm_fn = state.llm_fn || &default_llm_fn(state, &1)
      {compacted, _} = Compaction.maybe_compact(state.messages, %{budget: budget, llm_fn: llm_fn})
      {:noreply, %{state | messages: compacted}}
    else
      {:noreply, state}
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

  def handle_call(:get_workspace, _from, state) do
    {:reply, state.workspace, state}
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
      pid = if state.instance_name do
        case Registry.lookup(Druzhok.Registry, {state.instance_name, :telegram}) do
          [{p, _}] -> p
          [] -> nil
        end
      else
        state.caller
      end
      payload = %{text: "Error: #{inspect(reason)}", prompt_id: ref, error: true}
      payload = if state.chat_id, do: Map.put(payload, :chat_id, state.chat_id), else: payload
      if pid, do: send(pid, {:pi_response, payload})
      {:noreply, %{state | active_task: nil}}
    else
      {:noreply, %{state | parallel_tasks: Map.delete(state.parallel_tasks, ref)}}
    end
  end


  def handle_info(:idle_timeout, state) do
    {:stop, :normal, state}
  end

  # Catch-all for unexpected messages
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp deliver_last_assistant(new_messages, ref, state) do
    case Enum.find(Enum.reverse(new_messages), &(&1.role == "assistant")) do
      nil -> :ok
      msg ->
        pid = if state.instance_name do
          case Registry.lookup(Druzhok.Registry, {state.instance_name, :telegram}) do
            [{p, _}] -> p
            [] -> nil
          end
        else
          state.caller
        end

        payload = %{text: msg.content, prompt_id: ref}
        payload = if state.chat_id, do: Map.put(payload, :chat_id, state.chat_id), else: payload
        if pid, do: send(pid, {:pi_response, payload})
    end
  end

  defp schedule_idle_timeout(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    timer = Process.send_after(self(), :idle_timeout, PiCore.Config.idle_timeout_ms())
    %{state | idle_timer: timer}
  end

  defp run_prompt(messages, state) do
    llm_fn = state.llm_fn || &default_llm_fn(state, &1)

    # Compact if conversation is too long
    compaction_opts = if state.budget do
      %{budget: state.budget, llm_fn: llm_fn}
    else
      %{llm_fn: llm_fn, max_messages: PiCore.Config.compaction_max_messages(), keep_recent: PiCore.Config.compaction_keep_recent()}
    end

    {compacted_messages, _did_compact} = Compaction.maybe_compact(messages, compaction_opts)

    wrapped_on_delta = if state.on_delta && state.chat_id do
      fn chunk -> state.on_delta.(chunk, state.chat_id) end
    else
      state.on_delta
    end

    Loop.run(%{
      system_prompt: state.system_prompt,
      messages: compacted_messages,
      tools: state.tools,
      tool_context: Map.merge(state.extra_tool_context, %{workspace: state.workspace, instance_name: state.instance_name, chat_id: state.chat_id}),
      llm_fn: llm_fn,
      model: state.model,
      on_delta: wrapped_on_delta,
      on_event: state.on_event,
      budget: state.budget
    })
  end

  defp default_llm_fn(state, opts) do
    Retry.with_retry(fn ->
      Client.completion(%{
        model: state.model,
        provider: state.provider,
        api_url: state.api_url,
        api_key: state.api_key,
        system_prompt: opts.system_prompt,
        messages: opts.messages,
        tools: opts.tools,
        max_tokens: PiCore.Config.default_max_tokens(),
        stream: true,
        on_delta: opts[:on_delta],
        on_event: opts[:on_event]
      })
    end)
  end

  defp default_tools do
    [
      PiCore.Tools.Bash.new(),
      PiCore.Tools.Read.new(),
      PiCore.Tools.Write.new(),
      PiCore.Tools.Edit.new(),
      PiCore.Tools.Find.new(),
      PiCore.Tools.Grep.new(),
      PiCore.Tools.MemorySearch.new(),
      PiCore.Tools.SetReminder.new(),
      PiCore.Tools.SendFile.new(),
    ]
  end

  defp build_system_prompt(loader, workspace, group, budget, model) do
    {prompt, _tokens} = PiCore.PromptBudget.build(workspace, %{
      budget_tokens: budget.system_prompt,
      group: group,
      read_fn: fn path -> File.read(Path.join(workspace, path)) end
    })

    # If PromptBudget returned empty (no workspace files), fall back to loader
    prompt = if prompt == "" do
      loader.load(workspace, %{group: group})
    else
      prompt
    end

    append_model_info(prompt, model)
  end

  defp append_model_info(prompt, model) do
    prompt <> "\n\n## Модель\n\nТы работаешь на модели `#{model}`. Если спросят какая ты модель — отвечай именно это. Не говори что ты Claude, GPT или другая модель — это неправда."
  end
end
