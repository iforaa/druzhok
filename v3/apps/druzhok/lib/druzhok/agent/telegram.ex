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

  @min_chars_first_send 30
  @edit_interval_ms 1_000

  defstruct [
    :token,
    :chat_id,
    :instance_name,
    :poll_task,
    :bot_id,
    :bot_username,
    :bot_name,
    :workspace,
    # Streaming state
    :draft_message_id,
    :draft_text,
    :last_edit_at,
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
    {:noreply, %{state | bot_name: name}}
  end

  def handle_cast({:set_workspace, workspace}, state) do
    {:noreply, %{state | workspace: workspace}}
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
    state = %{state | chat_id: chat_id}
    accumulated = (state.draft_text || "") <> chunk
    state = handle_streaming_delta(accumulated, %{state | draft_text: accumulated})
    {:noreply, state}
  end

  # --- Streaming deltas from PiCore (without chat_id, backward compat) ---

  def handle_info({:pi_delta, chunk}, state) when is_binary(chunk) do
    accumulated = (state.draft_text || "") <> chunk
    state = handle_streaming_delta(accumulated, %{state | draft_text: accumulated})
    {:noreply, state}
  end

  # --- Final response from PiCore (with chat_id) ---

  def handle_info({:pi_response, %{text: text, chat_id: chat_id}}, state) when is_binary(text) and text != "" do
    state = %{state | chat_id: chat_id}
    emit(state, :agent_reply, %{text: text})
    state = finalize_response(text, state)
    {:noreply, state}
  end

  # --- Final response from PiCore (without chat_id, backward compat) ---

  def handle_info({:pi_response, %{text: text}}, state) when is_binary(text) and text != "" do
    emit(state, :agent_reply, %{text: text})
    state = finalize_response(text, state)
    {:noreply, state}
  end

  def handle_info({:pi_response, %{error: true, text: text}}, state) do
    emit(state, :error, %{text: text})
    {:noreply, state}
  end

  def handle_info({:pi_response, _}, state), do: {:noreply, state}

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

  defp handle_streaming_delta(text, state) do
    now = System.monotonic_time(:millisecond)
    display_text = strip_artifacts(text)

    cond do
      is_nil(state.draft_message_id) and String.length(display_text) >= @min_chars_first_send ->
        case API.send_message(state.token, state.chat_id, display_text) do
          {:ok, %{"message_id" => msg_id}} ->
            %{state | draft_message_id: msg_id, draft_text: text, last_edit_at: now}
          _ ->
            %{state | draft_text: text}
        end

      is_nil(state.draft_message_id) ->
        %{state | draft_text: text}

      now - (state.last_edit_at || 0) >= @edit_interval_ms ->
        case API.edit_message_text(state.token, state.chat_id, state.draft_message_id, display_text) do
          {:error, reason} ->
            Logger.warning("Telegram edit failed: #{inspect(reason)}")
          _ -> :ok
        end
        %{state | draft_text: text, last_edit_at: now}

      true ->
        %{state | draft_text: text}
    end
  end

  defp finalize_response(text, state) do
    html = Format.to_telegram_html(text)
    html_opts = %{parse_mode: "HTML"}

    result = cond do
      state.draft_message_id ->
        API.edit_message_text(state.token, state.chat_id, state.draft_message_id, html, html_opts)

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
          if state.draft_message_id do
            API.edit_message_text(state.token, state.chat_id, state.draft_message_id, text)
          else
            API.send_message(state.token, state.chat_id, text)
          end
        end
      _ -> :ok
    end

    %{state | draft_message_id: nil, draft_text: nil, last_edit_at: nil}
  end

  # --- Update handling / Routing ---

  defp handle_update(%{"update_id" => update_id} = update, state) do
    state = %{state | offset: update_id + 1}

    case extract_message(update) do
      nil -> state
      {chat_id, chat_type, text, sender_id, sender_name, file, chat_title} ->
        is_reply = is_reply_to_bot?(update, state)

        case chat_type do
          "private" ->
            handle_dm(chat_id, text, sender_id, sender_name, file, state)

          type when type in ["group", "supergroup"] ->
            handle_group(chat_id, text, sender_id, sender_name, file, is_reply, chat_title, state)

          _ -> state
        end
    end
  end

  # --- DM handling with pairing ---

  defp handle_dm(chat_id, text, sender_id, sender_name, file, state) do
    instance = Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name)
    state = %{state | chat_id: chat_id, draft_message_id: nil, draft_text: nil, last_edit_at: nil}

    cond do
      # Owner exists and this is the owner
      instance && instance.owner_telegram_id == sender_id ->
        process_owner_message(chat_id, text, sender_name, file, false, state)

      # Owner exists but this is someone else
      instance && instance.owner_telegram_id ->
        API.send_message(state.token, chat_id, "This bot is private.")
        state

      # No owner — handle pairing
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

  # --- Group handling with triggers ---

  defp handle_group(chat_id, text, sender_id, sender_name, file, is_reply_to_bot, chat_title, state) do
    chat = Druzhok.AllowedChat.get(state.instance_name, chat_id)

    cond do
      chat && chat.status == "approved" ->
        if triggered?(text, is_reply_to_bot, state) do
          state = %{state | chat_id: chat_id, draft_message_id: nil, draft_text: nil, last_edit_at: nil}
          instance = Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name)

          case parse_command(text) do
            {:command, "reset"} ->
              if instance && instance.owner_telegram_id == sender_id do
                dispatch_session(chat_id, state, &PiCore.Session.reset/1)
                API.send_message(state.token, chat_id, "Session reset!")
              end
              state

            {:command, "abort"} ->
              if instance && instance.owner_telegram_id == sender_id do
                dispatch_session(chat_id, state, &PiCore.Session.abort/1)
                API.send_message(state.token, chat_id, "Aborted.")
              end
              state

            _ ->
              process_owner_message(chat_id, text, sender_name, file, true, state)
          end
        else
          state
        end

      chat && chat.status == "rejected" ->
        state

      true ->
        # Pending or unknown — create pending record
        Druzhok.AllowedChat.upsert_pending(state.instance_name, chat_id, "group", chat_title)

        if mentioned_by_username?(text, state) && (is_nil(chat) || !chat.info_sent) do
          API.send_message(state.token, chat_id, "This bot requires approval. Ask the admin to approve this group in the dashboard.")
          Druzhok.AllowedChat.mark_info_sent(state.instance_name, chat_id)
        end

        state
    end
  end

  # --- Shared message processing (used by both DM owner and approved group) ---

  defp process_owner_message(chat_id, text, sender_name, file, is_group, state) do
    saved_file = if file, do: save_incoming_file(file, chat_id, state), else: nil
    prompt_text = build_prompt(text, sender_name, saved_file)
    emit(state, :user_message, %{text: prompt_text, sender: sender_name, chat_id: chat_id})
    API.send_chat_action(state.token, chat_id)

    case parse_command(text) do
      {:command, "start"} ->
        dispatch_prompt("User #{sender_name} just started the bot. Introduce yourself.", chat_id, is_group, state)
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
        dispatch_prompt(prompt_text, chat_id, is_group, state)
        state
    end
  end

  # --- Trigger detection ---

  defp triggered?(text, is_reply_to_bot, state) do
    is_reply_to_bot ||
    mentioned_by_username?(text, state) ||
    name_mentioned?(text, state)
  end

  defp mentioned_by_username?(_text, %{bot_username: nil}), do: false
  defp mentioned_by_username?(text, %{bot_username: username}) do
    String.contains?(String.downcase(text), "@" <> String.downcase(username))
  end

  defp name_mentioned?(_text, %{bot_name: nil}), do: false
  defp name_mentioned?(text, %{bot_name: name}) do
    Regex.match?(~r/\b#{Regex.escape(name)}\b/iu, text)
  end

  defp is_reply_to_bot?(update, state) do
    case get_in(update, ["message", "reply_to_message", "from", "id"]) do
      nil -> false
      id -> id == state.bot_id
    end
  end

  # --- Message extraction ---

  defp extract_message(%{"message" => msg}) do
    from = msg["from"]
    if from && !from["is_bot"] do
      chat_id = msg["chat"]["id"]
      chat_type = msg["chat"]["type"] || "private"
      text = msg["text"] || msg["caption"] || ""
      sender_id = from["id"]
      name = [from["first_name"], from["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      file = extract_file(msg)
      chat_title = msg["chat"]["title"]
      {chat_id, chat_type, text, sender_id, name, file, chat_title}
    else
      nil
    end
  end
  defp extract_message(_), do: nil

  defp extract_file(msg) do
    cond do
      msg["document"] -> %{file_id: msg["document"]["file_id"], name: msg["document"]["file_name"] || "document"}
      msg["photo"] -> %{file_id: List.last(msg["photo"])["file_id"], name: "photo.jpg"}
      msg["voice"] -> %{file_id: msg["voice"]["file_id"], name: "voice.ogg"}
      msg["audio"] -> %{file_id: msg["audio"]["file_id"], name: msg["audio"]["file_name"] || "audio.mp3"}
      msg["video"] -> %{file_id: msg["video"]["file_id"], name: msg["video"]["file_name"] || "video.mp4"}
      msg["sticker"] -> %{file_id: msg["sticker"]["file_id"], name: "sticker.webp"}
      true -> nil
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

  defp parse_command("/start" <> _), do: {:command, "start"}
  defp parse_command("/reset" <> _), do: {:command, "reset"}
  defp parse_command("/abort" <> _), do: {:command, "abort"}
  defp parse_command("/" <> _), do: :text
  defp parse_command(_), do: :text

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

  defp emit(%{instance_name: nil}, _type, _data), do: :ok
  defp emit(%{instance_name: name}, type, data) do
    Events.broadcast(name, Map.put(data, :type, type))
  end

  defp strip_artifacts(text), do: PiCore.Sanitize.strip_artifacts(text)
end
