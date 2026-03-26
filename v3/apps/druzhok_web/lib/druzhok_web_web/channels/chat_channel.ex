defmodule DruzhokWebWeb.ChatChannel do
  use DruzhokWebWeb, :channel
  require Logger

  alias Druzhok.Instance.SessionSup

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

  def handle_in("reset", %{"chat_id" => chat_id}, socket) do
    case Registry.lookup(Druzhok.Registry, {socket.assigns.instance_name, :session, chat_id}) do
      [{pid, _}] -> PiCore.Session.reset(pid)
      [] -> :ok
    end
    {:noreply, socket}
  end

  def handle_in("abort", %{"chat_id" => chat_id}, socket) do
    case Registry.lookup(Druzhok.Registry, {socket.assigns.instance_name, :session, chat_id}) do
      [{pid, _}] -> PiCore.Session.abort(pid)
      [] -> :ok
    end
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
    lang = Druzhok.I18n.lang(socket.assigns[:instance_name])
    status = Druzhok.Agent.ToolStatus.status_text(tool_name, lang)
    push(socket, "tool_status", %{tool: tool_name, status: status, chat_id: chat_id})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp dispatch_prompt(instance_name, chat_id, text) do
    pid =
      case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
        [{pid, _}] -> pid
        [] ->
          case SessionSup.start_session(instance_name, chat_id, %{group: false}) do
            {:ok, pid} -> pid
            {:error, _} -> nil
          end
      end

    if pid do
      GenServer.cast(pid, {:set_caller, self()})
      PiCore.Session.prompt(pid, text)
    end
  end

  defp transcribe_and_send(audio_bytes, instance_name, chat_id, socket) do
    channel_pid = self()
    Task.start(fn ->
      api_key = Druzhok.Settings.api_key("openrouter")
      api_url = Druzhok.Settings.api_url("openrouter")
      model = Druzhok.Settings.get("transcription_model") || "google/gemini-2.0-flash-lite-001"

      if api_key do
        case PiCore.Transcription.transcribe(audio_bytes,
          format: "webm",
          model: model,
          api_url: api_url,
          api_key: api_key
        ) do
          {:ok, text} ->
            lang = Druzhok.I18n.lang(instance_name)
            voice_label = Druzhok.I18n.t(:voice_message, lang)
            prompt = "#{voice_label} #{text}"
            Druzhok.Events.broadcast(instance_name, %{
              type: :user_message, text: prompt, sender: "app:#{chat_id}", chat_id: chat_id
            })

            # Push transcription back to client and dispatch to LLM
            send(channel_pid, {:transcription_result, text, chat_id})
            send(channel_pid, {:dispatch_prompt, chat_id, prompt})

          {:error, reason} ->
            Logger.warning("Audio transcription failed: #{inspect(reason)}")
            send(channel_pid, {:transcription_error, "Transcription failed", chat_id})
        end
      else
        send(channel_pid, {:transcription_error, "No transcription API configured", chat_id})
      end
    end)
  end

  defp load_chat_history(instance_name, chat_id) do
    workspace = case :persistent_term.get({:druzhok_session_config, instance_name}, nil) do
      %{workspace: ws} -> ws
      _ -> nil
    end

    if workspace do
      path = Path.join([workspace, "sessions", "#{chat_id}.jsonl"])
      case File.read(path) do
        {:ok, content} ->
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&decode_message/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(-100)  # last 100 messages

        {:error, _} -> []
      end
    else
      []
    end
  end

  defp decode_message(line) do
    case Jason.decode(line) do
      {:ok, %{"role" => "user", "content" => content}} when is_binary(content) and content != "" ->
        # Skip system/heartbeat messages
        if String.starts_with?(content, "HEARTBEAT") or String.starts_with?(content, "[System:") do
          nil
        else
          %{role: "user", content: content, timestamp: nil}
        end

      {:ok, %{"role" => "assistant", "content" => content, "tool_calls" => tc}}
          when (is_nil(tc) or tc == []) and is_binary(content) and content != "" ->
        # Only assistant messages with actual content (no tool-only messages)
        if silent_reply?(content) do
          nil
        else
          %{role: "assistant", content: content, timestamp: nil}
        end

      _ -> nil
    end
  end

  defp silent_reply?(text) do
    trimmed = String.trim(text)
    trimmed == "[NO_REPLY]" or trimmed == "" or
      (String.contains?(trimmed, "HEARTBEAT_OK") and String.length(trimmed) <= 300)
  end
end
