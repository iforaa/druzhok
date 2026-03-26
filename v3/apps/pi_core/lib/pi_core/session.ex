defmodule PiCore.Session do
  use GenServer

  alias PiCore.Loop
  alias PiCore.LLM.Client
  alias PiCore.LLM.Retry
  alias PiCore.Compaction
  alias PiCore.SessionStore

  defstruct [
    :workspace, :model, :provider, :api_url, :api_key,
    :system_prompt, :tools, :on_delta, :on_event, :caller, :llm_fn,
    :workspace_loader, :instance_name, :extra_tool_context,
    :chat_id, :idle_timer, :budget, :model_info_fn, :timezone,
    group: false,
    messages: [],
    active_task: nil,
    parallel_tasks: %{},
    heartbeat_refs: MapSet.new(),
    heartbeat_msg_counts: %{}
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

  @doc "Like prompt/2 but suppresses streaming and filters HEARTBEAT_OK responses."
  def prompt_heartbeat(pid, text) do
    GenServer.cast(pid, {:prompt_heartbeat, text})
  end

  @doc "Append a user message to history without triggering LLM. For non-triggered group messages."
  def push_message(pid, text) do
    GenServer.cast(pid, {:push_message, text})
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
    tools = opts[:tools] || build_tools(opts)

    context_window = if model_info_fn do
      model_info_fn.(:context_window, opts.model)
    else
      32_000
    end

    budget = PiCore.TokenBudget.compute(context_window)

    extra_ctx = opts[:extra_tool_context] || %{}
    system_prompt = build_system_prompt(loader, opts.workspace, group, budget, opts.model, extra_ctx)

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
      model_info_fn: model_info_fn,
      timezone: opts[:timezone] || "UTC"
    }

    # Load persisted session messages
    loaded_messages = if opts[:chat_id] do
      SessionStore.load(opts.workspace, opts[:chat_id])
    else
      []
    end

    state = %{state | messages: loaded_messages}

    state = schedule_idle_timeout(state)
    {:ok, state}
  end

  def handle_cast({:prompt, text}, state) do
    do_prompt(text, state, heartbeat: false)
  end

  def handle_cast({:prompt_heartbeat, text}, state) do
    do_prompt(text, state, heartbeat: true)
  end

  def handle_cast({:push_message, text}, state) do
    state = schedule_idle_timeout(state)
    user_msg = %Loop.Message{role: "user", content: text, timestamp: System.os_time(:millisecond)}
    state = %{state | messages: state.messages ++ [user_msg]}
    if state.chat_id, do: SessionStore.append_many(state.workspace, state.chat_id, [user_msg])
    {:noreply, state}
  end

  def handle_cast({:set_caller, pid}, state) do
    on_delta = if state.chat_id do
      chat_id = state.chat_id
      fn chunk, _cid -> send(pid, {:pi_delta, chunk, chat_id}) end
    else
      fn chunk -> send(pid, {:pi_delta, chunk}) end
    end
    {:noreply, %{state | caller: pid, on_delta: on_delta}}
  end

  def handle_cast({:set_model, model, opts}, state) do
    context_window = if state.model_info_fn do
      state.model_info_fn.(:context_window, model)
    else
      32_000
    end

    budget = PiCore.TokenBudget.compute(context_window)
    system_prompt = build_system_prompt(state.workspace_loader, state.workspace, state.group, budget, model, state.extra_tool_context)

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
      ref = state.active_task.ref
      Task.shutdown(state.active_task, :brutal_kill)
      {:noreply, %{state | active_task: nil, heartbeat_refs: MapSet.delete(state.heartbeat_refs, ref), heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:reset, state) do
    if state.chat_id, do: SessionStore.clear(state.workspace, state.chat_id)
    {:noreply, %{state | messages: [], active_task: nil, parallel_tasks: %{}, heartbeat_refs: MapSet.new(), heartbeat_msg_counts: %{}}}
  end

  def handle_call(:get_workspace, _from, state) do
    {:reply, state.workspace, state}
  end

  # Task completed successfully
  def handle_info({ref, {:ok, new_messages}}, state) do
    Process.demonitor(ref, [:flush])
    is_heartbeat = MapSet.member?(state.heartbeat_refs, ref)
    state = %{state | heartbeat_refs: MapSet.delete(state.heartbeat_refs, ref)}

    if state.active_task && state.active_task.ref == ref do
      if is_heartbeat && heartbeat_should_prune?(new_messages) do
        # HEARTBEAT_OK — discard entire exchange
        pre_count = Map.get(state.heartbeat_msg_counts, ref)
        rolled_back = if pre_count, do: Enum.take(state.messages, pre_count), else: state.messages
        state = %{state | messages: rolled_back, active_task: nil, heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}
        if pre_count && state.chat_id do
          SessionStore.save(state.workspace, state.chat_id, rolled_back)
        end
        {:noreply, state}
      else
        # Normal completion
        state = %{state | messages: state.messages ++ new_messages, active_task: nil, heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}
        if state.chat_id, do: SessionStore.append_many(state.workspace, state.chat_id, new_messages)
        deliver_last_assistant(new_messages, ref, state, heartbeat: is_heartbeat)
        {:noreply, state}
      end
    else
      case Map.pop(state.parallel_tasks, ref) do
        {%{user_msg: user_msg}, remaining} ->
          # Parallel task completed — merge Q&A back
          state = %{state | messages: state.messages ++ [user_msg | new_messages], parallel_tasks: remaining}
          if state.chat_id, do: SessionStore.append_many(state.workspace, state.chat_id, [user_msg | new_messages])
          deliver_last_assistant(new_messages, ref, state, heartbeat: is_heartbeat)
          {:noreply, state}

        {nil, _} ->
          {:noreply, state}
      end
    end
  end

  # Task returned error (e.g. LLM 429, network error)
  def handle_info({ref, {:error, reason}}, state) do
    Process.demonitor(ref, [:flush])
    state = %{state | heartbeat_refs: MapSet.delete(state.heartbeat_refs, ref),
                      heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}

    if state.active_task && state.active_task.ref == ref do
      pid = response_target(state)
      payload = %{text: "Error: #{inspect(reason)}", error: true}
      payload = if state.chat_id, do: Map.put(payload, :chat_id, state.chat_id), else: payload
      if pid, do: send(pid, {:pi_response, payload})
      {:noreply, %{state | active_task: nil}}
    else
      {:noreply, %{state | parallel_tasks: Map.delete(state.parallel_tasks, ref)}}
    end
  end

  # Task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    state = %{state | heartbeat_refs: MapSet.delete(state.heartbeat_refs, ref),
                      heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}

    if state.active_task && state.active_task.ref == ref do
      pid = response_target(state)
      payload = %{text: "Error: #{inspect(reason)}", prompt_id: ref, error: true}
      payload = if state.chat_id, do: Map.put(payload, :chat_id, state.chat_id), else: payload
      if pid, do: send(pid, {:pi_response, payload})
      {:noreply, %{state | active_task: nil}}
    else
      {:noreply, %{state | parallel_tasks: Map.delete(state.parallel_tasks, ref)}}
    end
  end


  def handle_info({:pi_tool_status, tool_name}, state) do
    pid = response_target(state)
    if pid && pid != self() do
      send(pid, {:pi_tool_status, tool_name, state.chat_id})
    end
    {:noreply, state}
  end

  def handle_info(:idle_timeout, state) do
    {:stop, :normal, state}
  end

  # Catch-all for unexpected messages
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp do_prompt(text, state, opts) do
    state = schedule_idle_timeout(state)
    user_msg = %Loop.Message{role: "user", content: text, timestamp: System.os_time(:millisecond)}
    heartbeat = opts[:heartbeat] || false
    # Heartbeat prompts run without streaming so HEARTBEAT_OK isn't sent to Telegram
    run_state = if heartbeat, do: %{state | on_delta: nil}, else: state

    if state.active_task do
      snapshot = state.messages ++ [user_msg]
      task = Task.async(fn -> run_prompt(snapshot, run_state) end)
      parallel_tasks = Map.put(state.parallel_tasks, task.ref, %{user_msg: user_msg})
      heartbeat_refs = if heartbeat, do: MapSet.put(state.heartbeat_refs, task.ref), else: state.heartbeat_refs
      {:noreply, %{state | parallel_tasks: parallel_tasks, heartbeat_refs: heartbeat_refs}}
    else
      state = %{state | messages: state.messages ++ [user_msg]}
      task = Task.async(fn -> run_prompt(state.messages, run_state) end)
      heartbeat_refs = if heartbeat, do: MapSet.put(state.heartbeat_refs, task.ref), else: state.heartbeat_refs
      heartbeat_msg_counts = if heartbeat,
        do: Map.put(state.heartbeat_msg_counts, task.ref, length(state.messages) - 1),
        else: state.heartbeat_msg_counts
      {:noreply, %{state | active_task: task, heartbeat_refs: heartbeat_refs, heartbeat_msg_counts: heartbeat_msg_counts}}
    end
  end

  defp deliver_last_assistant(new_messages, ref, state, opts \\ []) do
    case Enum.find(Enum.reverse(new_messages), &(&1.role == "assistant")) do
      nil -> :ok
      msg ->
        text = if opts[:heartbeat], do: strip_heartbeat_ok(msg.content), else: msg.content

        if text && text != "" do
          pid = response_target(state)
          payload = %{text: text, prompt_id: ref}
          payload = if state.chat_id, do: Map.put(payload, :chat_id, state.chat_id), else: payload
          if pid, do: send(pid, {:pi_response, payload})
        end
    end
  end

  @heartbeat_ok_token "HEARTBEAT_OK"
  @heartbeat_ack_max_chars 300

  # Strip HEARTBEAT_OK token from response. Returns nil if message should be suppressed.
  defp strip_heartbeat_ok(nil), do: nil
  defp strip_heartbeat_ok(text) do
    trimmed = String.trim(text)

    if not String.contains?(trimmed, @heartbeat_ok_token) do
      trimmed
    else
      stripped =
        trimmed
        |> String.replace(@heartbeat_ok_token, "")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      if stripped == "" or String.length(stripped) <= @heartbeat_ack_max_chars,
        do: nil,
        else: stripped
    end
  end

  defp heartbeat_should_prune?(new_messages) do
    case Enum.find(Enum.reverse(new_messages), &(&1.role == "assistant")) do
      nil -> true
      msg -> strip_heartbeat_ok(msg.content) == nil
    end
  end

  # Find who to send the response to. Prefer the caller set via set_caller
  # (e.g. WebSocket channel), fall back to Telegram agent via Registry.
  defp response_target(state) do
    cond do
      state.caller && state.caller != self() -> state.caller
      state.instance_name ->
        case Registry.lookup(Druzhok.Registry, {state.instance_name, :telegram}) do
          [{p, _}] -> p
          [] -> state.caller
        end
      true -> state.caller
    end
  end

  defp schedule_idle_timeout(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    timer = Process.send_after(self(), :idle_timeout, PiCore.Config.idle_timeout_ms())
    %{state | idle_timer: timer}
  end

  defp run_prompt(messages, state) do
    llm_fn = state.llm_fn || &default_llm_fn(state, &1)
    compaction_llm_fn = build_compaction_llm_fn(state) || llm_fn

    # Compact if conversation is too long
    compaction_opts = if state.budget do
      %{
        budget: state.budget,
        llm_fn: compaction_llm_fn,
        workspace: state.workspace,
        timezone: state.timezone || "UTC",
        memory_flush: true
      }
    else
      %{llm_fn: compaction_llm_fn, max_messages: PiCore.Config.compaction_max_messages(), keep_recent: PiCore.Config.compaction_keep_recent()}
    end

    {compacted_messages, did_compact} = Compaction.maybe_compact(messages, compaction_opts)

    if did_compact and state.chat_id do
      SessionStore.truncate_after_compaction(state.workspace, state.chat_id, compacted_messages)
    end

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

  defp build_compaction_llm_fn(state) do
    ctx = state.extra_tool_context || %{}
    model = ctx[:compaction_model]
    api_url = ctx[:compaction_api_url]
    api_key = ctx[:compaction_api_key]

    if model && api_url && api_key do
      fn opts ->
        Retry.with_retry(fn ->
          Client.completion(%{
            model: model,
            provider: "openai",
            api_url: api_url,
            api_key: api_key,
            system_prompt: opts.system_prompt,
            messages: opts.messages,
            tools: opts[:tools] || [],
            max_tokens: 4096,
            stream: false,
            on_delta: nil,
            on_event: nil
          })
        end)
      end
    else
      nil
    end
  end

  defp build_tools(opts) do
    tools = default_tools()
    ctx = opts[:extra_tool_context] || %{}

    if ctx[:image_generation_enabled] do
      tools ++ [PiCore.Tools.GenerateImage.new()]
    else
      tools
    end
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
      PiCore.Tools.MemoryWrite.new(),
      PiCore.Tools.SetReminder.new(),
      PiCore.Tools.CancelReminder.new(),
      PiCore.Tools.SendFile.new(),
      PiCore.Tools.WebFetch.new(),
    ]
  end

  defp build_system_prompt(loader, workspace, group, budget, model, extra_tool_context \\ %{}) do
    skills = PiCore.Skills.Loader.load(workspace)

    {prompt, _tokens} = PiCore.PromptBudget.build(workspace, %{
      budget_tokens: budget.system_prompt,
      group: group,
      skills: skills,
      read_fn: fn path -> File.read(Path.join(workspace, path)) end
    })

    # If PromptBudget returned empty (no workspace files), fall back to loader
    prompt = if prompt == "" do
      loader.load(workspace, %{group: group})
    else
      prompt
    end

    prompt = append_model_info(prompt, model)
    runtime_fn = extra_tool_context[:runtime_info_fn]
    if runtime_fn, do: prompt <> "\n\n" <> runtime_fn.(), else: prompt
  end

  defp append_model_info(prompt, model) do
    prompt <> "\n\n## Модель\n\nТы работаешь на модели `#{model}`. Если спросят какая ты модель — отвечай именно это. Не говори что ты Claude, GPT или другая модель — это неправда."
  end
end
