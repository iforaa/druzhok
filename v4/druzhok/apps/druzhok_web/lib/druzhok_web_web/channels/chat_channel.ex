defmodule DruzhokWebWeb.ChatChannel do
  use DruzhokWebWeb, :channel
  require Logger

  @impl true
  def join("chat:lobby", _payload, socket) do
    {:ok, socket}
  end

  def join(_, _, _), do: {:error, %{reason: "invalid topic"}}

  # --- Incoming messages ---

  @impl true
  def handle_in("message", %{"text" => text, "chat_id" => chat_id}, socket) do
    Druzhok.Events.broadcast(socket.assigns.instance_name, %{
      type: :user_message, text: text, sender: "app:#{chat_id}", chat_id: chat_id
    })
    dispatch_prompt(socket.assigns.instance_name, chat_id, text)
    {:noreply, socket}
  end

  def handle_in("audio", %{"audio" => base64_audio, "chat_id" => chat_id}, socket) do
    instance_name = socket.assigns.instance_name
    case Base.decode64(base64_audio) do
      {:ok, audio_bytes} when byte_size(audio_bytes) <= 10_000_000 ->
        transcribe_and_send(audio_bytes, instance_name, chat_id, socket)
      {:ok, _} ->
        push(socket, "error", %{text: "Audio too large (max 10MB)", chat_id: chat_id})
      :error ->
        push(socket, "error", %{text: "Invalid audio data", chat_id: chat_id})
    end
    {:noreply, socket}
  end

  def handle_in("history", %{"chat_id" => chat_id}, socket) do
    instance_name = socket.assigns.instance_name
    messages = load_chat_history(instance_name, chat_id)
    push(socket, "history", %{messages: messages, chat_id: chat_id})
    {:noreply, socket}
  end

  def handle_in("reset", %{"chat_id" => _chat_id}, socket) do
    # Session reset not available in v4 orchestrator
    {:noreply, socket}
  end

  def handle_in("abort", %{"chat_id" => _chat_id}, socket) do
    # Session abort not available in v4 orchestrator
    {:noreply, socket}
  end

  # --- Outgoing events from PiCore ---

  @impl true
  def handle_info({:pi_delta, chunk, chat_id}, socket) do
    push(socket, "delta", %{text: chunk, chat_id: chat_id})
    {:noreply, socket}
  end

  def handle_info({:pi_delta, chunk}, socket) do
    push(socket, "delta", %{text: chunk})
    {:noreply, socket}
  end

  def handle_info({:pi_response, %{error: true, text: text} = payload}, socket) do
    push(socket, "error", %{text: text, chat_id: payload[:chat_id]})
    {:noreply, socket}
  end

  def handle_info({:pi_response, %{text: text} = payload}, socket)
      when is_binary(text) and text != "" do
    # Filter silent replies
    if silent_reply?(text) do
      {:noreply, socket}
    else
      Druzhok.Events.broadcast(socket.assigns.instance_name, %{
        type: :agent_reply, text: text, chat_id: payload[:chat_id]
      })
      push(socket, "response", %{text: text, chat_id: payload[:chat_id]})
      {:noreply, socket}
    end
  end

  def handle_info({:pi_response, _}, socket), do: {:noreply, socket}

  # Transcription callbacks from async Task
  def handle_info({:transcription_result, text, chat_id}, socket) do
    push(socket, "transcription", %{text: text, chat_id: chat_id})
    {:noreply, socket}
  end

  def handle_info({:transcription_error, error, chat_id}, socket) do
    push(socket, "error", %{text: error, chat_id: chat_id})
    {:noreply, socket}
  end

  def handle_info({:dispatch_prompt, chat_id, text}, socket) do
    dispatch_prompt(socket.assigns.instance_name, chat_id, text)
    {:noreply, socket}
  end

  def handle_info({:pi_tool_status, tool_name, chat_id}, socket) do
    push(socket, "tool_status", %{tool: tool_name, status: tool_name, chat_id: chat_id})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp dispatch_prompt(_instance_name, _chat_id, _text) do
    # In v4, prompts are dispatched to the Docker bot container, not in-process sessions.
    # This channel is kept for future direct API connections.
    :ok
  end

  defp transcribe_and_send(_audio_bytes, _instance_name, chat_id, _socket) do
    # Transcription not implemented in v4 orchestrator yet.
    channel_pid = self()
    send(channel_pid, {:transcription_error, "Transcription not available in v4", chat_id})
  end

  defp load_chat_history(_instance_name, _chat_id) do
    # In v4, chat history lives inside the Docker bot container.
    # Direct history loading is not available from the orchestrator.
    []
  end

  defp silent_reply?(text) do
    trimmed = String.trim(text)
    trimmed == "[NO_REPLY]" or trimmed == "" or
      (String.contains?(trimmed, "HEARTBEAT_OK") and String.length(trimmed) <= 300)
  end
end
