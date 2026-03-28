defmodule DruzhokWebWeb.ChatSocket do
  use Phoenix.Socket

  channel "chat:*", DruzhokWebWeb.ChatChannel

  @impl true
  def connect(%{"api_key" => api_key}, socket, _connect_info) do
    case Druzhok.Instance.get_by_api_key(api_key) do
      %{name: name, active: true} ->
        {:ok, assign(socket, :instance_name, name)}

      _ ->
        :error
    end
  end

  def connect(_, _, _), do: :error

  @impl true
  def id(socket), do: "chat_socket:#{socket.assigns.instance_name}"
end
