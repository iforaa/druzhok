defmodule Druzhok.Sandbox.DockerClient do
  use GenServer
  require Logger

  defstruct [:socket, :container, :instance_name, :secret, pending: %{}, counter: 0, buffer: ""]

  def start_link(opts) do
    name = opts[:registry_name]

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  def exec(pid, command, timeout \\ 300_000) do
    GenServer.call(pid, {:exec, command}, timeout)
  end

  def read_file(pid, path, timeout \\ 30_000) do
    GenServer.call(pid, {:read, path}, timeout)
  end

  def write_file(pid, path, content, timeout \\ 30_000) do
    GenServer.call(pid, {:write, path, content}, timeout)
  end

  def list_dir(pid, path, timeout \\ 30_000) do
    GenServer.call(pid, {:ls, path}, timeout)
  end

  # --- Init ---

  @impl true
  def init(opts) do
    instance_name = opts.instance_name
    secret = :crypto.strong_rand_bytes(16) |> Base.encode64()
    # Use DB id + name for unique container naming
    db_id = case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
      %{id: id} -> id
      _ -> :rand.uniform(99999)
    end
    container_name = "druzhok-#{db_id}-#{instance_name}"

    case start_container(container_name, secret) do
      {:ok, {host, port}} ->
        case connect_with_retry(host, port, secret, 10, 500) do
          {:ok, socket} ->
            :inet.setopts(socket, active: true)
            Logger.info("Sandbox started for #{instance_name} on port #{port}")

            state = %__MODULE__{
              socket: socket,
              container: container_name,
              instance_name: instance_name,
              secret: secret
            }

            # Initialize workspace with template files if empty
            init_workspace(state)

            {:ok, state}

          {:error, reason} ->
            cleanup_container(container_name)
            {:stop, {:connection_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:container_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    cleanup_container(state.container)
    :ok
  end

  # --- Call handlers ---

  @impl true
  def handle_call({:exec, command}, from, state) do
    {id, state} = next_id(state)
    send_request(state.socket, %{id: id, type: "exec", command: command})
    pending = Map.put(state.pending, id, %{from: from, type: :exec, stdout: [], stderr: []})
    {:noreply, %{state | pending: pending}}
  end

  def handle_call({:read, path}, from, state) do
    {id, state} = next_id(state)
    send_request(state.socket, %{id: id, type: "read", path: path})
    pending = Map.put(state.pending, id, %{from: from, type: :simple})
    {:noreply, %{state | pending: pending}}
  end

  def handle_call({:write, path, content}, from, state) do
    {id, state} = next_id(state)
    send_request(state.socket, %{id: id, type: "write", path: path, content: content})
    pending = Map.put(state.pending, id, %{from: from, type: :simple})
    {:noreply, %{state | pending: pending}}
  end

  def handle_call({:ls, path}, from, state) do
    {id, state} = next_id(state)
    send_request(state.socket, %{id: id, type: "ls", path: path})
    pending = Map.put(state.pending, id, %{from: from, type: :simple})
    {:noreply, %{state | pending: pending}}
  end

  # --- TCP data handling ---

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    buffer = state.buffer <> data
    {lines, rest} = split_lines(buffer)
    state = %{state | buffer: rest}
    state = Enum.reduce(lines, state, &process_line/2)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.error("Sandbox TCP connection closed for #{state.instance_name}")
    reply_all_pending(state, {:error, :sandbox_disconnected})
    {:stop, :tcp_closed, %{state | pending: %{}}}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("Sandbox TCP error for #{state.instance_name}: #{inspect(reason)}")
    reply_all_pending(state, {:error, :sandbox_disconnected})
    {:stop, {:tcp_error, reason}, %{state | pending: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp process_line(line, state) do
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

  defp handle_response(
         id,
         %{"type" => "stdout", "data" => data},
         %{type: :exec} = pending,
         state
       ) do
    pending = %{pending | stdout: [pending.stdout | data]}
    %{state | pending: Map.put(state.pending, id, pending)}
  end

  defp handle_response(
         id,
         %{"type" => "stderr", "data" => data},
         %{type: :exec} = pending,
         state
       ) do
    pending = %{pending | stderr: [pending.stderr | data]}
    %{state | pending: Map.put(state.pending, id, pending)}
  end

  defp handle_response(id, %{"type" => "exit", "code" => code}, %{type: :exec} = pending, state) do
    GenServer.reply(pending.from, {:ok, %{stdout: IO.iodata_to_binary(pending.stdout), stderr: IO.iodata_to_binary(pending.stderr), exit_code: code}})
    %{state | pending: Map.delete(state.pending, id)}
  end

  defp handle_response(id, %{"type" => "result", "data" => data}, %{type: :simple} = pending, state) do
    GenServer.reply(pending.from, {:ok, data})
    %{state | pending: Map.delete(state.pending, id)}
  end

  defp handle_response(id, %{"type" => "error", "message" => msg}, pending, state) do
    GenServer.reply(pending.from, {:error, msg})
    %{state | pending: Map.delete(state.pending, id)}
  end

  defp handle_response(_id, _msg, _pending, state), do: state

  defp next_id(state) do
    id = "req-#{state.counter + 1}"
    {id, %{state | counter: state.counter + 1}}
  end

  defp send_request(socket, request) do
    case :gen_tcp.send(socket, Jason.encode!(request) <> "\n") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reply_all_pending(state, reply) do
    for {_id, %{from: from}} <- state.pending do
      GenServer.reply(from, reply)
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")

    case List.last(parts) do
      "" -> {parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == "")), ""}
      rest -> {parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == "")), rest}
    end
  end

  defp start_container(container_name, secret) do
    case System.find_executable("docker") do
      nil ->
        {:error, "Docker not installed"}

      _ ->
        # Remove old container if exists
        System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)

        case System.cmd(
               "docker",
               [
                 "run",
                 "-d",
                 "--name",
                 container_name,
                 "--memory",
                 "1g",
                 "--cpus",
                 "1",
                 "--cap-drop",
                 "ALL",
                 "--cap-add",
                 "CHOWN",
                 "--cap-add",
                 "SETUID",
                 "--cap-add",
                 "SETGID",
                 "--security-opt",
                 "no-new-privileges",
                 "-e",
                 "SANDBOX_SECRET=#{secret}",
                 "druzhok-sandbox:latest"
               ],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            # Get container IP directly (works inside Docker-in-Docker)
            case System.cmd("docker", ["inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container_name]) do
              {ip_str, 0} ->
                ip = String.trim(ip_str)
                port = 9999

                {:ok, port}

              _ ->
                {:error, "Failed to get container port"}
            end

          {output, _} ->
            {:error, "Failed to start container: #{output}"}
        end
    end
  end

  defp connect_with_retry(_host, _port, _secret, 0, _delay), do: {:error, "Connection timeout"}

  defp connect_with_retry(host, port, secret, retries, delay) do
    case :gen_tcp.connect(~c"#{host}", port, [:binary, {:active, false}], 2_000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, Jason.encode!(%{type: "auth", secret: secret}) <> "\n")

        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} ->
            case Jason.decode(String.trim(data)) do
              {:ok, %{"type" => "auth_ok"}} -> {:ok, socket}
              _ ->
                :gen_tcp.close(socket)
                {:error, "Auth failed"}
            end

          _ ->
            :gen_tcp.close(socket)
            {:error, "Auth timeout"}
        end

      {:error, _} ->
        Process.sleep(delay)
        connect_with_retry(host, port, secret, retries - 1, delay)
    end
  end

  defp init_workspace(state) do
    # Check if workspace has files already (container volume persists across restarts)
    check = Jason.encode!(%{id: "init-check", type: "ls", path: "/workspace"}) <> "\n"
    :inet.setopts(state.socket, active: false)
    :gen_tcp.send(state.socket, check)
    case :gen_tcp.recv(state.socket, 0, 5_000) do
      {:ok, data} ->
        case Jason.decode(String.trim(data)) do
          {:ok, %{"type" => "result", "data" => entries_json}} ->
            entries = case Jason.decode(entries_json) do
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

  defp copy_workspace_template(state) do
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
      # Create memory dir
      msg = Jason.encode!(%{id: "init-mem", type: "mkdir", path: "/workspace/memory"}) <> "\n"
      :gen_tcp.send(state.socket, msg)
      :gen_tcp.recv(state.socket, 0, 5_000)
      Logger.info("Workspace template copied to sandbox for #{state.instance_name}")
    end
  end

  defp cleanup_container(container_name) do
    System.cmd("docker", ["stop", container_name], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
    :ok
  end
end
