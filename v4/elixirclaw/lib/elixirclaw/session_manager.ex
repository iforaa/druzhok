defmodule ElixirClaw.SessionManager do
  @moduledoc """
  Manages PiCore sessions. One session per chat_id, created on demand.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def prompt(session_id, message) do
    GenServer.call(__MODULE__, {:prompt, session_id, message}, 120_000)
  end

  def get_session(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:prompt, session_id, message}, from, state) do
    {session_pid, state} = ensure_session(session_id, state)

    # Send prompt async, collect response via message
    Task.start(fn ->
      try do
        PiCore.Session.set_caller(session_pid, self())
        PiCore.Session.prompt(session_pid, message)

        response = receive do
          {:pi_response, %{text: text}} -> {:ok, text || ""}
          {:pi_response, %{error: error}} -> {:error, error}
        after
          110_000 -> {:error, :timeout}
        end

        GenServer.reply(from, response)
      rescue
        e -> GenServer.reply(from, {:error, Exception.message(e)})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    {:reply, Map.get(state.sessions, session_id), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    sessions = state.sessions
    |> Enum.reject(fn {_id, p} -> p == pid end)
    |> Map.new()
    {:noreply, %{state | sessions: sessions}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_session(session_id, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:ok, pid} = start_session(session_id)
        Process.monitor(pid)
        {pid, %{state | sessions: Map.put(state.sessions, session_id, pid)}}
      pid ->
        if Process.alive?(pid) do
          {pid, state}
        else
          {:ok, pid} = start_session(session_id)
          Process.monitor(pid)
          {pid, %{state | sessions: Map.put(state.sessions, session_id, pid)}}
        end
    end
  end

  defp start_session(session_id) do
    workspace = System.get_env("WORKSPACE") || "/data/workspace"
    model = System.get_env("MODEL") || "default"
    api_url = System.get_env("API_URL") || System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"
    api_key = System.get_env("API_KEY") || System.get_env("OPENAI_API_KEY") || ""

    provider = cond do
      String.contains?(api_url, "anthropic") -> "anthropic"
      true -> "openai"
    end

    PiCore.Session.start_link(%{
      workspace: workspace,
      model: model,
      provider: provider,
      api_url: api_url,
      api_key: api_key,
      chat_id: session_id,
      max_tokens: 16384,
      extra_tool_context: %{
        workspace: workspace,
        instance_name: System.get_env("INSTANCE_NAME") || "elixirclaw",
        timezone: System.get_env("TZ") || "UTC",
      }
    })
  end
end
