defmodule DruzhokWebWeb.ChatChannel do
  use DruzhokWebWeb, :channel

  alias Druzhok.Instance.SessionSup

  @impl true
  def join("chat:lobby", _payload, socket) do
    {:ok, socket}
  end

  def join(_, _, _), do: {:error, %{reason: "invalid topic"}}

  @impl true
  def handle_in("message", %{"text" => text, "chat_id" => chat_id}, socket) do
    dispatch_prompt(socket.assigns.instance_name, chat_id, text)
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

  @impl true
  def handle_info({:pi_delta, chunk, chat_id}, socket) do
    push(socket, "delta", %{text: chunk, chat_id: chat_id})
    {:noreply, socket}
  end

  def handle_info({:pi_delta, chunk}, socket) do
    push(socket, "delta", %{text: chunk})
    {:noreply, socket}
  end

  def handle_info({:pi_response, %{text: text} = payload}, socket)
      when is_binary(text) and text != "" do
    push(socket, "response", payload)
    {:noreply, socket}
  end

  def handle_info({:pi_response, %{error: true, text: text}}, socket) do
    push(socket, "error", %{text: text})
    {:noreply, socket}
  end

  def handle_info({:pi_response, _}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp dispatch_prompt(instance_name, chat_id, text) do
    pid =
      case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
        [{pid, _}] ->
          pid

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
end
