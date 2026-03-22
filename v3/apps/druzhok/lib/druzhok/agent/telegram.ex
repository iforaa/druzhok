defmodule Druzhok.Agent.Telegram do
  @moduledoc """
  Per-user Telegram bot GenServer. Long-polls for updates, dispatches
  messages to a PiCore.Session, delivers responses via streaming edits.
  """
  use GenServer

  alias Druzhok.Telegram.API

  @min_chars_first_send 30
  @edit_interval_ms 1_000

  defstruct [
    :token,
    :session_pid,
    :chat_id,
    # Streaming state
    :draft_message_id,
    :draft_text,
    :last_edit_at,
    offset: 0
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    state = %__MODULE__{
      token: opts.token,
      session_pid: opts.session_pid,
    }

    if opts.session_pid, do: send(self(), :poll)
    {:ok, state}
  end

  # --- Polling ---

  def handle_cast({:set_session, pid}, state) do
    unless state.session_pid, do: send(self(), :poll)
    {:noreply, %{state | session_pid: pid}}
  end

  def handle_info(:poll, state) do
    case API.get_updates(state.token, state.offset) do
      {:ok, updates} when is_list(updates) ->
        state = Enum.reduce(updates, state, &handle_update(&1, &2))
        send(self(), :poll)
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :poll, 5_000)
        {:noreply, state}
    end
  end

  # --- Streaming deltas from PiCore (individual chunks) ---

  def handle_info({:pi_delta, chunk}, state) when is_binary(chunk) do
    # Accumulate chunks into draft_text
    accumulated = (state.draft_text || "") <> chunk
    state = handle_streaming_delta(accumulated, %{state | draft_text: accumulated})
    {:noreply, state}
  end

  # --- Final response from PiCore ---

  def handle_info({:pi_response, %{text: text}}, state) when is_binary(text) and text != "" do
    state = finalize_response(text, state)
    {:noreply, state}
  end

  def handle_info({:pi_response, _}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Streaming logic ---

  defp handle_streaming_delta(text, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      # No draft yet — wait for enough text, then send first message
      is_nil(state.draft_message_id) and String.length(text) >= @min_chars_first_send ->
        case API.send_message(state.token, state.chat_id, text) do
          {:ok, %{"message_id" => msg_id}} ->
            %{state | draft_message_id: msg_id, draft_text: text, last_edit_at: now}
          _ ->
            %{state | draft_text: text}
        end

      # No draft yet but not enough text — just buffer
      is_nil(state.draft_message_id) ->
        %{state | draft_text: text}

      # Draft exists — edit if enough time has passed
      now - (state.last_edit_at || 0) >= @edit_interval_ms ->
        API.edit_message_text(state.token, state.chat_id, state.draft_message_id, text)
        %{state | draft_text: text, last_edit_at: now}

      # Too soon to edit — just buffer
      true ->
        %{state | draft_text: text}
    end
  end

  defp finalize_response(text, state) do
    if state.draft_message_id do
      # Edit draft with final text
      if text != state.draft_text do
        API.edit_message_text(state.token, state.chat_id, state.draft_message_id, text)
      end
    else
      # No draft was created (very short response) — send fresh
      API.send_message(state.token, state.chat_id, text)
    end

    # Reset streaming state
    %{state | draft_message_id: nil, draft_text: nil, last_edit_at: nil}
  end

  # --- Update handling ---

  defp handle_update(%{"update_id" => update_id} = update, state) do
    state = %{state | offset: update_id + 1}

    case extract_message(update) do
      nil -> state
      {chat_id, text, sender_name} ->
        state = %{state | chat_id: chat_id, draft_message_id: nil, draft_text: nil}

        API.send_chat_action(state.token, chat_id)

        case parse_command(text) do
          {:command, "start"} ->
            prompt = "Пользователь #{sender_name} только что запустил бота. Представься и начни знакомство."
            PiCore.Session.prompt(state.session_pid, prompt)
            state

          {:command, "reset"} ->
            PiCore.Session.reset(state.session_pid)
            API.send_message(state.token, chat_id, "Сессия сброшена!")
            state

          {:command, "abort"} ->
            PiCore.Session.abort(state.session_pid)
            API.send_message(state.token, chat_id, "Отменено.")
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
end
