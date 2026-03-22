defmodule Druzhok.Agent.Telegram do
  @moduledoc """
  Per-user Telegram bot GenServer. Long-polls for updates, dispatches
  messages to a PiCore.Session, delivers responses back to Telegram.
  """
  use GenServer

  alias Druzhok.Telegram.API

  defstruct [
    :token,
    :session_pid,
    :chat_id,
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

    send(self(), :poll)
    {:ok, state}
  end

  # --- Polling ---

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

  # --- Responses from PiCore ---

  def handle_info({:pi_response, %{text: text}}, state) when is_binary(text) and text != "" do
    if state.chat_id do
      API.send_message(state.token, state.chat_id, text)
    end
    {:noreply, state}
  end

  def handle_info({:pi_response, _}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp handle_update(%{"update_id" => update_id} = update, state) do
    state = %{state | offset: update_id + 1}

    case extract_message(update) do
      nil -> state
      {chat_id, text, sender_name} ->
        state = %{state | chat_id: chat_id}

        # Send typing indicator
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
  defp parse_command("/" <> _), do: :text  # unknown commands treated as text
  defp parse_command(_), do: :text
end
