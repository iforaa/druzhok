defmodule Druzhok.Agent.Telegram do
  @moduledoc """
  Per-user Telegram bot GenServer. Long-polls for updates, dispatches
  messages to a PiCore.Session, delivers responses via streaming edits.
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
    :session_pid,
    :chat_id,
    :instance_name,
    :poll_task,
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
      session_pid: opts.session_pid,
      instance_name: opts[:instance_name],
    }

    if opts.session_pid, do: send(self(), :start_poll)
    {:ok, state}
  end

  # --- Polling (async — never blocks the GenServer) ---

  def handle_cast({:set_session, pid}, state) do
    unless state.session_pid, do: send(self(), :start_poll)
    {:noreply, %{state | session_pid: pid}}
  end

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

  # --- Streaming deltas from PiCore (individual chunks) ---

  def handle_info({:pi_delta, chunk}, state) when is_binary(chunk) do
    accumulated = (state.draft_text || "") <> chunk
    state = handle_streaming_delta(accumulated, %{state | draft_text: accumulated})
    {:noreply, state}
  end

  # --- Final response from PiCore ---

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

    cond do
      is_nil(state.draft_message_id) and String.length(text) >= @min_chars_first_send ->
        case API.send_message(state.token, state.chat_id, text) do
          {:ok, %{"message_id" => msg_id}} ->
            %{state | draft_message_id: msg_id, draft_text: text, last_edit_at: now}
          _ ->
            %{state | draft_text: text}
        end

      is_nil(state.draft_message_id) ->
        %{state | draft_text: text}

      now - (state.last_edit_at || 0) >= @edit_interval_ms ->
        case API.edit_message_text(state.token, state.chat_id, state.draft_message_id, text) do
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
        # Always do final edit with HTML formatting
        API.edit_message_text(state.token, state.chat_id, state.draft_message_id, html, html_opts)

      state.chat_id ->
        # No draft started — send as new message with HTML
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
          # Fallback: send plain text without HTML if parsing failed
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

  # --- Update handling ---

  defp handle_update(%{"update_id" => update_id} = update, state) do
    state = %{state | offset: update_id + 1}

    case extract_message(update) do
      nil -> state
      {chat_id, text, sender_name} ->
        state = %{state | chat_id: chat_id, draft_message_id: nil, draft_text: nil, last_edit_at: nil}

        emit(state, :user_message, %{text: text, sender: sender_name, chat_id: chat_id})
        API.send_chat_action(state.token, chat_id)

        case parse_command(text) do
          {:command, "start"} ->
            prompt = "User #{sender_name} just started the bot. Introduce yourself."
            PiCore.Session.prompt(state.session_pid, prompt)
            state

          {:command, "reset"} ->
            PiCore.Session.reset(state.session_pid)
            API.send_message(state.token, chat_id, "Session reset!")
            state

          {:command, "abort"} ->
            PiCore.Session.abort(state.session_pid)
            API.send_message(state.token, chat_id, "Aborted.")
            state

          :text ->
            PiCore.Session.prompt(state.session_pid, text)
            state
        end
    end
  end

  defp extract_message(%{"message" => msg}) do
    from = msg["from"]
    if from && !from["is_bot"] do
      chat_id = msg["chat"]["id"]
      text = msg["text"] || msg["caption"] || ""
      name = [from["first_name"], from["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      {chat_id, text, name}
    else
      nil
    end
  end
  defp extract_message(_), do: nil

  defp parse_command("/start" <> _), do: {:command, "start"}
  defp parse_command("/reset" <> _), do: {:command, "reset"}
  defp parse_command("/abort" <> _), do: {:command, "abort"}
  defp parse_command("/" <> _), do: :text
  defp parse_command(_), do: :text

  defp emit(%{instance_name: nil}, _type, _data), do: :ok
  defp emit(%{instance_name: name}, type, data) do
    Events.broadcast(name, Map.put(data, :type, type))
  end
end
