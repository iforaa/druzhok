defmodule Druzhok.Sandbox.Protocol do
  @moduledoc """
  Shared TCP JSON-RPC protocol logic for sandbox clients (Docker, Firecracker).

  This is a pure-function module — no GenServer. It processes incoming TCP data,
  manages pending requests, and routes responses.
  """

  require Logger

  # --- Buffer / line splitting ---

  @doc "Split buffer on newlines, returning {complete_lines, remaining_buffer}."
  def split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {init, [rest]} = Enum.split(parts, -1)
    {Enum.reject(init, &(&1 == "")), rest}
  end

  # --- Request building ---

  @doc "Generate next request id and update counter in state."
  def next_id(state) do
    id = "req-#{state.counter + 1}"
    {id, %{state | counter: state.counter + 1}}
  end

  # --- Sending ---

  @doc "Send a JSON request map over a TCP socket."
  def send_request(socket, request) do
    :gen_tcp.send(socket, Jason.encode!(request) <> "\n")
  end

  # --- Pending management ---

  @doc "Add a pending request entry to state."
  def add_pending(state, id, from, :exec) do
    pending = Map.put(state.pending, id, %{from: from, type: :exec, stdout: [], stderr: []})
    %{state | pending: pending}
  end

  def add_pending(state, id, from, :simple) do
    pending = Map.put(state.pending, id, %{from: from, type: :simple})
    %{state | pending: pending}
  end

  @doc "Reply error to all pending requests (e.g. on disconnect)."
  def reply_all_pending(state, reply) do
    for {_id, %{from: from}} <- state.pending do
      GenServer.reply(from, reply)
    end
  end

  # --- TCP data handling ---

  @doc "Handle incoming TCP data: buffer, split lines, process each."
  def handle_tcp_data(data, state) do
    buffer = state.buffer <> data
    {lines, rest} = split_lines(buffer)
    state = %{state | buffer: rest}
    Enum.reduce(lines, state, &process_line/2)
  end

  # --- Line processing ---

  @doc "Decode a JSON line and route to the appropriate response handler."
  def process_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = msg} ->
        case Map.get(state.pending, id) do
          nil -> state
          pending -> handle_response(id, msg, pending, state)
        end

      _ ->
        state
    end
  end

  # --- Response routing ---

  @doc "Route a decoded response based on its type and the pending entry type."
  def handle_response(
        id,
        %{"type" => "stdout", "data" => data},
        %{type: :exec} = pending,
        state
      ) do
    pending = %{pending | stdout: [pending.stdout | data]}
    %{state | pending: Map.put(state.pending, id, pending)}
  end

  def handle_response(
        id,
        %{"type" => "stderr", "data" => data},
        %{type: :exec} = pending,
        state
      ) do
    pending = %{pending | stderr: [pending.stderr | data]}
    %{state | pending: Map.put(state.pending, id, pending)}
  end

  def handle_response(id, %{"type" => "exit", "code" => code}, %{type: :exec} = pending, state) do
    GenServer.reply(pending.from, {:ok, %{
      stdout: IO.iodata_to_binary(pending.stdout),
      stderr: IO.iodata_to_binary(pending.stderr),
      exit_code: code
    }})
    %{state | pending: Map.delete(state.pending, id)}
  end

  def handle_response(id, %{"type" => "result", "data" => data}, %{type: :simple} = pending, state) do
    GenServer.reply(pending.from, {:ok, data})
    %{state | pending: Map.delete(state.pending, id)}
  end

  def handle_response(id, %{"type" => "error", "message" => msg}, pending, state) do
    GenServer.reply(pending.from, {:error, msg})
    %{state | pending: Map.delete(state.pending, id)}
  end

  def handle_response(_id, _msg, _pending, state), do: state

  # --- Workspace initialization ---

  @doc "Check workspace and copy template if empty. Socket must be in passive mode."
  def init_workspace(state) do
    check = Jason.encode!(%{id: "init-check", type: "ls", path: "/workspace"}) <> "\n"
    :inet.setopts(state.socket, active: false)
    :gen_tcp.send(state.socket, check)

    case :gen_tcp.recv(state.socket, 0, 5_000) do
      {:ok, data} ->
        case Jason.decode(String.trim(data)) do
          {:ok, %{"type" => "result", "data" => entries_json}} ->
            entries =
              case Jason.decode(entries_json) do
                {:ok, list} when is_list(list) -> list
                _ -> []
              end

            if entries == [] do
              copy_workspace_template(state)
            end

          _ ->
            copy_workspace_template(state)
        end

      _ ->
        copy_workspace_template(state)
    end

    :inet.setopts(state.socket, active: true)
  end

  @doc "Copy workspace template files to sandbox via TCP."
  def copy_workspace_template(state) do
    template = Path.join([File.cwd!(), "..", "workspace-template"]) |> Path.expand()

    if File.exists?(template) do
      template
      |> File.ls!()
      |> Enum.each(fn name ->
        path = Path.join(template, name)

        if File.regular?(path) do
          content = File.read!(path)
          msg = Jason.encode!(%{id: "init-#{name}", type: "write", path: "/workspace/#{name}", content: content}) <> "\n"
          :gen_tcp.send(state.socket, msg)
          :gen_tcp.recv(state.socket, 0, 5_000)
        end
      end)

      msg = Jason.encode!(%{id: "init-mem", type: "mkdir", path: "/workspace/memory"}) <> "\n"
      :gen_tcp.send(state.socket, msg)
      :gen_tcp.recv(state.socket, 0, 5_000)
      Logger.info("Workspace template copied to sandbox for #{state.instance_name}")
    end
  end
end
