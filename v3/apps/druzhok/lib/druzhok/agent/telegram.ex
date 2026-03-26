defmodule Druzhok.Agent.Telegram do
  @moduledoc """
  Per-user Telegram bot GenServer. Long-polls for updates, dispatches
  messages to per-chat PiCore.Session processes, delivers responses via streaming edits.

  Routing:
    - DM from owner -> normal agent conversation
    - DM from stranger -> pairing flow (generate activation code)
    - Group chat (approved) -> respond only on triggers (@mention, name, reply)
    - Group chat (pending/unknown) -> create pending record, notify once
  """
  use GenServer

  require Logger

  alias Druzhok.Telegram.API
  alias Druzhok.Telegram.Format
  alias Druzhok.Events
  alias Druzhok.Agent.Router
  alias Druzhok.Agent.Streamer

  defstruct [
    :token,
    :chat_id,
    :instance_name,
    :poll_task,
    :bot_id,
    :bot_username,
    :bot_name,
    :bot_name_regex,
    :workspace,
    :owner_telegram_id,
    :streamer,
    :typing_timer,
    offset: 0
  ]

  def start_link(opts) do
    case opts[:registry_name] do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def init(opts) do
    state = %__MODULE__{
      token: opts.token,
      instance_name: opts[:instance_name],
      streamer: Streamer.new(),
    }

    # Fetch bot identity and workspace asynchronously
    me = self()
    token = opts.token
    instance_name = opts[:instance_name]

    Task.start(fn ->
      case API.get_me(token) do
        {:ok, %{"id" => id, "username" => username}} ->
          GenServer.cast(me, {:set_bot_info, id, username})
        _ -> :ok
      end

      workspace = case :persistent_term.get({:druzhok_session_config, instance_name}, nil) do
        %{workspace: ws} -> ws
        _ -> nil
      end

      if workspace do
        GenServer.cast(me, {:set_workspace, workspace})
        case File.read(Path.join(workspace, "IDENTITY.md")) do
          {:ok, content} ->
            case Regex.run(~r/\*\*(?:Имя|Name):\*\*\s*(.+)/iu, content) do
              [_, name] -> GenServer.cast(me, {:set_bot_name, String.trim(name)})
              _ -> :ok
            end
          _ -> :ok
        end
      end
    end)

    send(self(), :start_poll)
    {:ok, state}
  end

  # --- Bot identity casts ---

  def handle_cast({:set_bot_info, id, username}, state) do
    {:noreply, %{state | bot_id: id, bot_username: username}}
  end

  def handle_cast({:set_bot_name, name}, state) do
    regex = Regex.compile!("\\b#{Regex.escape(name)}\\b", "iu")
    {:noreply, %{state | bot_name: name, bot_name_regex: regex}}
  end

  def handle_cast({:set_workspace, workspace}, state) do
    owner_id = case Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name) do
      %{owner_telegram_id: id} -> id
      _ -> nil
    end
    {:noreply, %{state | workspace: workspace, owner_telegram_id: owner_id}}
  end

  # --- Polling (async — never blocks the GenServer) ---

  def handle_call(:get_chat_id, _from, state) do
    {:reply, state.chat_id, state}
  end

  def handle_info(:start_poll, state) do
    state = start_async_poll(state)
    {:noreply, state}
  end

  # Poll task completed successfully
  def handle_info({ref, {:poll_result, result}}, state) when state.poll_task != nil and ref == state.poll_task.ref do
    Process.demonitor(ref, [:flush])
    state = %{state | poll_task: nil}

    case result do
      {:ok, updates} when is_list(updates) ->
        state = Enum.reduce(updates, state, &handle_update(&1, &2))
        state = start_async_poll(state)
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :start_poll, 5_000)
        {:noreply, state}
    end
  end

  # Poll task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when state.poll_task != nil and ref == state.poll_task.ref do
    Logger.warning("Poll task crashed: #{inspect(reason)}")
    state = %{state | poll_task: nil}
    Process.send_after(self(), :start_poll, 5_000)
    {:noreply, state}
  end

  # --- Streaming deltas from PiCore (with chat_id) ---

  def handle_info({:pi_delta, chunk, chat_id}, state) when is_binary(chunk) do
    state = cancel_typing_timer(state)
    state = %{state | chat_id: chat_id}
    streamer = Streamer.append(state.streamer, chunk)
    state = handle_streaming_delta(%{state | streamer: streamer})
    {:noreply, state}
  end

  # --- Streaming deltas from PiCore (without chat_id, backward compat) ---

  def handle_info({:pi_delta, chunk}, state) when is_binary(chunk) do
    state = cancel_typing_timer(state)
    streamer = Streamer.append(state.streamer, chunk)
    state = handle_streaming_delta(%{state | streamer: streamer})
    {:noreply, state}
  end

  # --- Final response from PiCore (with chat_id) ---

  def handle_info({:pi_response, %{text: text, chat_id: chat_id}}, state) when is_binary(text) and text != "" do
    state = cancel_typing_timer(state)
    state = %{state | chat_id: chat_id}

    if silent_reply?(text) do
      {:noreply, %{state | streamer: Streamer.reset(state.streamer)}}
    else
      emit(state, :agent_reply, %{text: text})
      state = finalize_response(text, state)
      {:noreply, state}
    end
  end

  # --- Final response from PiCore (without chat_id, backward compat) ---

  def handle_info({:pi_response, %{text: text}}, state) when is_binary(text) and text != "" do
    state = cancel_typing_timer(state)
    if silent_reply?(text) do
      {:noreply, %{state | streamer: Streamer.reset(state.streamer)}}
    else
      emit(state, :agent_reply, %{text: text})
      state = finalize_response(text, state)
      {:noreply, state}
    end
  end

  def handle_info({:pi_response, %{error: true, text: text}}, state) do
    state = cancel_typing_timer(state)
    emit(state, :error, %{text: text})
    {:noreply, %{state | streamer: Streamer.reset(state.streamer)}}
  end

  def handle_info({:pi_response, _}, state) do
    {:noreply, cancel_typing_timer(state)}
  end

  # --- Tool status from PiCore (show status message + start typing refresh) ---

  def handle_info({:pi_tool_status, tool_name, _chat_id}, state), do: handle_tool_status(tool_name, state)
  def handle_info({:pi_tool_status, tool_name}, state), do: handle_tool_status(tool_name, state)

  defp handle_tool_status(tool_name, state) do
    state = cancel_typing_timer(state)
    status_text = Druzhok.Agent.ToolStatus.status_text(tool_name)

    # Edit existing streaming message or send a new one
    state = if state.chat_id do
      streamer = state.streamer
      case streamer.message_id do
        nil ->
          case API.send_message(state.token, state.chat_id, status_text) do
            {:ok, %{"message_id" => msg_id}} ->
              %{state | streamer: Streamer.mark_sent(streamer, System.monotonic_time(:millisecond), msg_id)}
            _ -> state
          end
        msg_id ->
          API.edit_message_text(state.token, state.chat_id, msg_id, status_text)
          state
      end
    else
      state
    end

    # Start typing refresh timer
    state = start_typing_timer(state)
    {:noreply, state}
  end

  def handle_info(:refresh_typing, state) do
    if state.chat_id do
      API.send_chat_action(state.token, state.chat_id)
    end
    state = start_typing_timer(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Async polling ---

  defp start_async_poll(state) do
    token = state.token
    offset = state.offset
    task = Task.async(fn ->
      {:poll_result, API.get_updates(token, offset)}
    end)
    %{state | poll_task: task}
  end

  # --- Streaming logic ---

  defp handle_streaming_delta(state) do
    now = System.monotonic_time(:millisecond)
    streamer = state.streamer

    cond do
      Streamer.should_send?(streamer) ->
        display_text = strip_artifacts(Streamer.text(streamer))
        case API.send_message(state.token, state.chat_id, display_text) do
          {:ok, %{"message_id" => msg_id}} ->
            %{state | streamer: Streamer.mark_sent(streamer, now, msg_id)}
          _ ->
            state
        end

      is_nil(streamer.message_id) ->
        state

      Streamer.should_edit?(streamer, now) ->
        display_text = strip_artifacts(Streamer.text(streamer))
        case API.edit_message_text(state.token, state.chat_id, streamer.message_id, display_text) do
          {:error, reason} ->
            Logger.warning("Telegram edit failed: #{inspect(reason)}")
          _ -> :ok
        end
        %{state | streamer: Streamer.mark_sent(streamer, now)}

      true ->
        state
    end
  end

  defp finalize_response(text, state) do
    html = Format.to_telegram_html(text)
    html_opts = %{parse_mode: "HTML"}
    streamer = state.streamer

    result = cond do
      streamer.message_id ->
        API.edit_message_text(state.token, state.chat_id, streamer.message_id, html, html_opts)

      state.chat_id ->
        API.send_message(state.token, state.chat_id, html, html_opts)

      true -> :ok
    end

    case result do
      {:error, reason} ->
        reason_str = inspect(reason)
        if String.contains?(reason_str, "not modified") do
          :ok
        else
          Logger.error("Telegram finalize failed: #{reason_str}")
          emit(state, :error, %{text: "Telegram send failed: #{reason_str}"})
          if streamer.message_id do
            API.edit_message_text(state.token, state.chat_id, streamer.message_id, text)
          else
            API.send_message(state.token, state.chat_id, text)
          end
        end
      _ -> :ok
    end

    %{state | streamer: Streamer.reset(streamer)}
  end

  # --- Update handling / Routing ---

  defp handle_update(%{"update_id" => update_id} = update, state) do
    state = %{state | offset: update_id + 1}

    case Router.classify(update) do
      {:dm, msg} ->
        text = Router.extract_text(msg)
        sender_id = msg["from"]["id"]
        name = [msg["from"]["first_name"], msg["from"]["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
        file = Router.extract_file(msg)
        handle_dm(msg["chat"]["id"], text, sender_id, name, file, state)

      {:group, msg, chat_title} ->
        text = Router.extract_text(msg)
        sender_id = msg["from"]["id"]
        name = [msg["from"]["first_name"], msg["from"]["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
        file = Router.extract_file(msg)
        is_reply = Router.reply_to_bot?(update, state.bot_id)
        handle_group(msg["chat"]["id"], text, sender_id, name, file, is_reply, chat_title, state)

      :ignore ->
        state
    end
  end

  # --- DM handling with pairing ---

  defp handle_dm(chat_id, text, sender_id, sender_name, file, state) do
    state = %{state | chat_id: chat_id, streamer: Streamer.reset(state.streamer)}
    # Refresh owner from DB if not cached (happens once after pairing approval)
    state = if is_nil(state.owner_telegram_id) do
      case Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name) do
        %{owner_telegram_id: id} when not is_nil(id) -> %{state | owner_telegram_id: id}
        _ -> state
      end
    else
      state
    end

    cond do
      state.owner_telegram_id == sender_id ->
        process_owner_message(chat_id, text, sender_id, sender_name, file, false, state)

      state.owner_telegram_id != nil ->
        API.send_message(state.token, chat_id, "This bot is private.")
        state

      true ->
        handle_pairing(chat_id, sender_id, sender_name, state)
    end
  end

  defp handle_pairing(chat_id, sender_id, sender_name, state) do
    case Druzhok.Pairing.get_pending(state.instance_name) do
      %{telegram_user_id: ^sender_id, code: code} ->
        API.send_message(state.token, chat_id, "Your activation code: #{code}\nEnter it in the dashboard.")
        state

      %{} ->
        API.send_message(state.token, chat_id, "This bot is not available.")
        state

      nil ->
        case Druzhok.Pairing.create_code(state.instance_name, sender_id, nil, sender_name) do
          {:ok, pairing} ->
            emit(state, :pairing_requested, %{text: "Pairing: #{pairing.code}", code: pairing.code, user: sender_name})
            API.send_message(state.token, chat_id, "Your activation code: #{pairing.code}\nEnter it in the dashboard.")
          _ ->
            API.send_message(state.token, chat_id, "Error generating activation code.")
        end
        state
    end
  end

  # --- Group handling ---

  defp handle_group(chat_id, text, sender_id, sender_name, file, is_reply_to_bot, chat_title, state) do
    chat = Druzhok.AllowedChat.get(state.instance_name, chat_id)

    cond do
      chat && chat.status == "approved" ->
        state = %{state | chat_id: chat_id, streamer: Streamer.reset(state.streamer)}
        is_triggered = is_reply_to_bot || Router.triggered?(text, state.bot_username, state.bot_name_regex)
        process_group_message(chat_id, text, sender_id, sender_name, file, is_triggered, state)

      chat && chat.status == "rejected" ->
        state

      true ->
        Druzhok.AllowedChat.upsert_pending(state.instance_name, chat_id, "group", chat_title)

        if Router.mentioned_by_username?(text, state.bot_username) && (is_nil(chat) || !chat.info_sent) do
          API.send_message(state.token, chat_id, "This bot requires approval. Ask the admin to approve this group in the dashboard.")
          Druzhok.AllowedChat.mark_info_sent(state.instance_name, chat_id)
        end

        state
    end
  end

  # Group messages: route based on activation mode
  defp process_group_message(chat_id, text, sender_id, sender_name, file, is_triggered, state) do
    is_owner = state.owner_telegram_id == sender_id
    chat = Druzhok.AllowedChat.get(state.instance_name, chat_id)
    activation = (chat && chat.activation) || "buffer"

    # Commands always processed (regardless of mode)
    case Router.parse_command(text) do
      {:command, "reset"} when is_owner ->
        dispatch_session(chat_id, state, &PiCore.Session.reset/1)
        API.send_message(state.token, chat_id, "Session reset!")
        state

      {:command, "abort"} when is_owner ->
        dispatch_session(chat_id, state, &PiCore.Session.abort/1)
        API.send_message(state.token, chat_id, "Aborted.")
        state

      {:command, "mode", arg} when is_owner ->
        handle_mode_command(arg, chat_id, state)

      {:command, "prompt", arg} when is_owner ->
        handle_prompt_command(arg, chat_id, state)

      {:command, "start"} ->
        prompt = "[#{sender_name} started the bot in group chat]"
        dispatch_prompt(prompt, chat_id, true, state)
        state

      _ ->
        case activation do
          "always" ->
            process_group_message_always(chat_id, text, sender_name, file, is_triggered, chat, state)

          _ ->
            process_group_message_buffer(chat_id, text, sender_name, file, is_triggered, chat, state)
        end
    end
  end

  defp process_group_message_always(chat_id, text, sender_name, file, is_triggered, chat, state) do
    {resolved_text, saved_file} = resolve_voice_or_file(text, file, chat_id, state)
    {prompt, display} = build_group_prompt_with_intro("always", chat, resolved_text, sender_name, saved_file, is_triggered)
    emit(state, :user_message, %{text: display, sender: sender_name, chat_id: chat_id})

    if is_triggered do
      API.send_chat_action(state.token, chat_id)
    end

    dispatch_prompt(prompt, chat_id, true, state)
    state
  end

  defp process_group_message_buffer(chat_id, text, sender_name, file, is_triggered, chat, state) do
    if is_triggered do
      {resolved_text, saved_file} = resolve_voice_or_file(text, file, chat_id, state)
      {prompt, display} = build_group_prompt_with_intro("buffer", chat, resolved_text, sender_name, saved_file, true)

      emit(state, :user_message, %{text: display, sender: sender_name, chat_id: chat_id})
      API.send_chat_action(state.token, chat_id)
      dispatch_prompt(prompt, chat_id, true, state)
      state
    else
      # Persist to session without triggering LLM
      file_ref = if file, do: "[#{file.name || "file"}]", else: nil
      plain_text = if is_list(text), do: PiCore.Multimodal.to_text(text), else: text
      msg_text = build_group_prompt(plain_text, sender_name, file_ref, false)
      persist_group_message(state.instance_name, chat_id, msg_text, state)

      emit(state, :user_message, %{text: "[#{sender_name}]: #{text}", sender: sender_name, chat_id: chat_id})
      state
    end
  end

  defp handle_mode_command(arg, chat_id, state) do
    case arg do
      mode when mode in ["buffer", "always"] ->
        Druzhok.AllowedChat.set_activation(state.instance_name, chat_id, mode)
        label = if mode == "buffer", do: "buffer (respond only when addressed)", else: "always (see all messages)"
        API.send_message(state.token, chat_id, "Mode: #{label}")
        state

      _ ->
        chat = Druzhok.AllowedChat.get(state.instance_name, chat_id)
        current = (chat && chat.activation) || "buffer"
        API.send_message(state.token, chat_id, "Current mode: #{current}\nUsage: /mode buffer | /mode always")
        state
    end
  end

  defp handle_prompt_command("", chat_id, state) do
    chat = Druzhok.AllowedChat.get(state.instance_name, chat_id)
    current = (chat && chat.system_prompt) || "(not set)"
    API.send_message(state.token, chat_id, "Current prompt: #{current}\nUsage: /prompt <text> to set, /prompt clear to remove")
    state
  end

  defp handle_prompt_command("clear", chat_id, state) do
    case Druzhok.AllowedChat.get(state.instance_name, chat_id) do
      nil -> :ok
      chat -> Druzhok.AllowedChat.changeset(chat, %{system_prompt: nil}) |> Druzhok.Repo.update()
    end
    API.send_message(state.token, chat_id, "Group prompt cleared.")
    state
  end

  defp handle_prompt_command(text, chat_id, state) do
    case Druzhok.AllowedChat.get(state.instance_name, chat_id) do
      nil -> :ok
      chat -> Druzhok.AllowedChat.changeset(chat, %{system_prompt: text}) |> Druzhok.Repo.update()
    end
    API.send_message(state.token, chat_id, "Group prompt set: #{text}")
    state
  end

  defp group_intro("buffer", chat) do
    base = "[Системная инструкция: Ты в групповом чате. Тебя вызвали по имени или ответом на твоё сообщение. Контекст недавних сообщений прикреплён ниже. Всегда отвечай — раз ты это видишь, значит к тебе обратились. Будь краток.]\n"
    add_per_group_prompt(base, chat)
  end

  defp group_intro("always", chat) do
    base = "[Системная инструкция: Ты в групповом чате и видишь все сообщения. Если к тебе не обращаются и ты не можешь добавить ценности — ответь [NO_REPLY]. Не доминируй в разговоре.]\n"
    add_per_group_prompt(base, chat)
  end

  defp group_intro(_, chat), do: add_per_group_prompt("", chat)

  defp add_per_group_prompt(base, chat) do
    case chat && chat.system_prompt do
      nil -> base
      "" -> base
      prompt -> base <> "[Инструкция для этого чата: #{prompt}]\n"
    end
  end

  # --- Shared message processing (used by both DM owner and approved group) ---

  defp process_owner_message(chat_id, text, sender_id, sender_name, file, is_group, state) do
    is_owner = state.owner_telegram_id == sender_id

    case Router.parse_command(text) do
      {:command, "start"} ->
        dispatch_prompt("User #{sender_name} just started the bot. Introduce yourself.", chat_id, is_group, state)
        state

      {:command, cmd} when cmd in ["reset", "abort"] and is_group and not is_owner ->
        state

      {:command, "reset"} ->
        dispatch_session(chat_id, state, &PiCore.Session.reset/1)
        API.send_message(state.token, chat_id, "Session reset!")
        state

      {:command, "abort"} ->
        dispatch_session(chat_id, state, &PiCore.Session.abort/1)
        API.send_message(state.token, chat_id, "Aborted.")
        state

      :text ->
        voice_result = maybe_transcribe_voice(file, state)
        image_result = if voice_result == :not_voice, do: maybe_build_image_content(file, text, state), else: :not_image

        prompt_text = case {voice_result, image_result} do
          {{:transcribed, transcribed}, _} ->
            caption = if text != "", do: " #{text}", else: ""
            "[голосовое сообщение]:#{caption} #{transcribed}"

          {_, {:image, content}} ->
            # Multimodal content (list) — LLM will "see" the image
            content

          _ ->
            saved_file = if file, do: save_incoming_file(file, chat_id, state), else: nil
            build_prompt(text, sender_name, saved_file)
        end

        display = if is_list(prompt_text), do: PiCore.Multimodal.to_text(prompt_text), else: prompt_text
        emit(state, :user_message, %{text: display, sender: sender_name, chat_id: chat_id})
        API.send_chat_action(state.token, chat_id)
        dispatch_prompt(prompt_text, chat_id, is_group, state)
        state
    end
  end

  defp save_incoming_file(%{file_id: file_id, name: name}, chat_id, state) do
    with {:ok, %{"file_path" => tg_path}} <- API.get_file(state.token, file_id),
         {:ok, content} <- API.download_file(state.token, tg_path) do
      # Resolve workspace from the session for this chat
      workspace = case Registry.lookup(Druzhok.Registry, {state.instance_name, :session, chat_id}) do
        [{pid, _}] ->
          try do GenServer.call(pid, :get_workspace, 5_000) rescue _ -> nil catch _ -> nil end
        [] ->
          # No session yet — read workspace from persistent_term config
          case :persistent_term.get({:druzhok_session_config, state.instance_name}, nil) do
            %{workspace: ws} -> ws
            _ -> nil
          end
      end

      if workspace do
        inbox = Path.join(workspace, "inbox")
        File.mkdir_p!(inbox)
        dest = Path.join(inbox, name)
        File.write!(dest, content)
        emit(state, :file_received, %{text: "Saved #{name} to inbox/"})
        "inbox/#{name}"
      else
        nil
      end
    else
      _ -> nil
    end
  end

  defp build_prompt(text, _sender, nil), do: text
  defp build_prompt("", _sender, file_path), do: "User sent a file: #{file_path}"
  defp build_prompt(text, _sender, file_path), do: "#{text}\n\n[User attached a file: #{file_path}]"

  defp build_group_prompt_with_intro(mode, chat, resolved_text, sender_name, saved_file, is_triggered) do
    if is_list(resolved_text) do
      # Multimodal content — prepend group context as text, keep image in content
      text_part = PiCore.Multimodal.to_text(resolved_text)
      display = build_group_prompt(text_part, sender_name, saved_file, is_triggered)
      context = group_intro(mode, chat) <> build_group_prompt("", sender_name, saved_file, is_triggered)
      multimodal = [%{"type" => "text", "text" => context} | resolved_text]
      {multimodal, display}
    else
      base_prompt = build_group_prompt(resolved_text, sender_name, saved_file, is_triggered)
      prompt = group_intro(mode, chat) <> base_prompt
      {prompt, base_prompt}
    end
  end

  defp build_group_prompt(text, sender_name, file, is_triggered) do
    base = "[#{sender_name}]: #{text}"
    base = if file, do: base <> "\n[attached: #{file}]", else: base
    if is_triggered, do: base <> "\n[обращение к тебе — ответ обязателен]", else: base
  end

  defp dispatch_prompt(text, chat_id, group, state) do
    case Registry.lookup(Druzhok.Registry, {state.instance_name, :session, chat_id}) do
      [{pid, _}] -> PiCore.Session.prompt(pid, text)
      [] ->
        case Druzhok.Instance.SessionSup.start_session(state.instance_name, chat_id, %{group: group}) do
          {:ok, pid} -> PiCore.Session.prompt(pid, text)
          {:error, reason} ->
            Logger.error("Failed to start session for chat #{chat_id}: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp dispatch_session(chat_id, state, fun) do
    case Registry.lookup(Druzhok.Registry, {state.instance_name, :session, chat_id}) do
      [{pid, _}] -> fun.(pid)
      [] -> :ok
    end
  end

  defp persist_group_message(instance_name, chat_id, text, state) do
    # If session exists, push to it (persists to disk + in-memory)
    case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
      [{pid, _}] ->
        PiCore.Session.push_message(pid, text)
      [] ->
        # No session running — write directly to disk so it's loaded on next session start
        workspace = case :persistent_term.get({:druzhok_session_config, instance_name}, nil) do
          %{workspace: ws} -> ws
          _ -> state.workspace
        end
        if workspace do
          msg = %PiCore.Loop.Message{role: "user", content: text, timestamp: System.os_time(:millisecond)}
          PiCore.SessionStore.append_many(workspace, chat_id, [msg])
        end
    end
  end

  defp emit(%{instance_name: nil}, _type, _data), do: :ok
  defp emit(%{instance_name: name}, type, data) do
    Events.broadcast(name, Map.put(data, :type, type))
  end

  defp maybe_transcribe_voice(file, state) do
    if file && file.name in ["voice.ogg"] do
      transcription_enabled = Druzhok.Settings.get("transcription_enabled") != "false"

      if transcription_enabled do
        case API.fetch_file_by_id(state.token, file.file_id) do
          {:ok, bytes} when byte_size(bytes) <= 10_000_000 ->
            api_key = Druzhok.Settings.api_key("openrouter")
            api_url = Druzhok.Settings.api_url("openrouter")
            model = Druzhok.Settings.get("transcription_model") || "google/gemini-2.0-flash-lite-001"

            if api_key do
              case PiCore.Transcription.transcribe(bytes,
                format: "ogg",
                model: model,
                api_url: api_url,
                api_key: api_key
              ) do
                {:ok, text} -> {:transcribed, text}
                {:error, _reason} -> :skip
              end
            else
              :skip
            end

          {:ok, _too_large} -> :skip
          {:error, _} -> :skip
        end
      else
        :disabled
      end
    else
      :not_voice
    end
  end

  defp maybe_build_image_content(file, text, state) do
    if file && file.name == "photo.jpg" do
      case API.fetch_file_by_id(state.token, file.file_id) do
        {:ok, bytes} when byte_size(bytes) <= 5_000_000 ->
          base64 = Base.encode64(bytes)
          caption = if text != "", do: text, else: "Пользователь отправил изображение"
          content = [
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,#{base64}"}},
            %{"type" => "text", "text" => caption}
          ]
          {:image, content}

        {:ok, _too_large} -> :skip
        {:error, _} -> :skip
      end
    else
      :not_image
    end
  end

  defp resolve_voice_or_file(text, file, chat_id, state) do
    voice_result = maybe_transcribe_voice(file, state)
    image_result = if voice_result == :not_voice, do: maybe_build_image_content(file, text, state), else: :not_image

    case {voice_result, image_result} do
      {{:transcribed, transcribed}, _} ->
        caption = if text != "", do: " #{text}", else: ""
        {"[голосовое сообщение]:#{caption} #{transcribed}", nil}

      {_, {:image, content}} ->
        # Pass multimodal content through for group messages (vision support)
        {content, nil}

      _ ->
        saved = if file, do: save_incoming_file(file, chat_id, state), else: nil
        {text, saved}
    end
  end

  defp strip_artifacts(text), do: PiCore.Sanitize.strip_artifacts(text)

  defp silent_reply?(text) do
    trimmed = String.trim(text)
    trimmed == "[NO_REPLY]" or trimmed == ""
  end

  defp start_typing_timer(state) do
    timer = Process.send_after(self(), :refresh_typing, 4_000)
    %{state | typing_timer: timer}
  end

  defp cancel_typing_timer(%{typing_timer: nil} = state), do: state
  defp cancel_typing_timer(%{typing_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | typing_timer: nil}
  end
end
