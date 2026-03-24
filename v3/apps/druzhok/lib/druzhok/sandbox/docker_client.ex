defmodule Druzhok.Sandbox.DockerClient do
  use GenServer
  require Logger

  alias Druzhok.Sandbox.Protocol

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
    workspace = opts[:workspace]
    secret = :crypto.strong_rand_bytes(16) |> Base.encode64()
    # Use DB id + name for unique container naming
    db_id = case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
      %{id: id} -> id
      _ -> :rand.uniform(99999)
    end
    container_name = "druzhok-#{db_id}-#{instance_name}"

    # Resolve host-absolute workspace path for volume mount
    # Inside Docker, /data is a volume mount — we need the actual host path
    host_workspace = if workspace, do: resolve_host_path(Path.expand(workspace)), else: nil

    case start_container(container_name, secret, host_workspace) do
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

            # If no shared volume, fall back to TCP-based workspace init
            unless host_workspace, do: Protocol.init_workspace(state)

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
    {id, state} = Protocol.next_id(state)
    Protocol.send_request(state.socket, %{id: id, type: "exec", command: command})
    {:noreply, Protocol.add_pending(state, id, from, :exec)}
  end

  def handle_call({:read, path}, from, state) do
    {id, state} = Protocol.next_id(state)
    Protocol.send_request(state.socket, %{id: id, type: "read", path: path})
    {:noreply, Protocol.add_pending(state, id, from, :simple)}
  end

  def handle_call({:write, path, content}, from, state) do
    {id, state} = Protocol.next_id(state)
    Protocol.send_request(state.socket, %{id: id, type: "write", path: path, content: content})
    {:noreply, Protocol.add_pending(state, id, from, :simple)}
  end

  def handle_call({:ls, path}, from, state) do
    {id, state} = Protocol.next_id(state)
    Protocol.send_request(state.socket, %{id: id, type: "ls", path: path})
    {:noreply, Protocol.add_pending(state, id, from, :simple)}
  end

  # --- TCP data handling ---

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    {:noreply, Protocol.handle_tcp_data(data, state)}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.error("Sandbox TCP connection closed for #{state.instance_name}")
    Protocol.reply_all_pending(state, {:error, :sandbox_disconnected})
    {:stop, :tcp_closed, %{state | pending: %{}}}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("Sandbox TCP error for #{state.instance_name}: #{inspect(reason)}")
    Protocol.reply_all_pending(state, {:error, :sandbox_disconnected})
    {:stop, {:tcp_error, reason}, %{state | pending: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Docker-specific private helpers ---

  defp start_container(container_name, secret, host_workspace) do
    case System.find_executable("docker") do
      nil ->
        {:error, "Docker not installed"}

      _ ->
        System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)

        port = pick_free_port()

        volume_args = if host_workspace do
          ["-v", "#{host_workspace}:/workspace"]
        else
          []
        end

        case System.cmd(
               "docker",
               [
                 "run",
                 "-d",
                 "--name",
                 container_name,
                 "--network",
                 "host",
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
                 "-e",
                 "SANDBOX_PORT=#{port}"
               ] ++ volume_args ++ ["druzhok-sandbox:latest"],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            {:ok, {sandbox_host(), port}}

          {output, _} ->
            {:error, "Failed to start container: #{output}"}
        end
    end
  end

  # When running inside a Docker container with bridge networking,
  # 127.0.0.1 is the container's own loopback — not the host's.
  # The sandbox container uses --network host, so we reach it via the bridge gateway.
  defp sandbox_host do
    # Read the default gateway from /proc/net/route (always available, no ip command needed)
    case File.read("/proc/net/route") do
      {:ok, content} ->
        case Regex.run(~r/\w+\t00000000\t([0-9A-F]+)\t/, content) do
          [_, hex_ip] ->
            # Gateway IP is in little-endian hex
            <<d, c, b, a>> = Base.decode16!(hex_ip)
            "#{a}.#{b}.#{c}.#{d}"
          _ -> "172.17.0.1"
        end
      _ -> "172.17.0.1"
    end
  end

  defp pick_free_port do
    # Let the OS assign a free port, then close the socket
    {:ok, socket} = :gen_tcp.listen(0, [:binary, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
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

  defp resolve_host_path(container_path) do
    # When running inside Docker with -v druzhok-data:/data,
    # paths like /data/instances/... need to be translated to the
    # actual host path for nested docker run -v mounts.
    # Query the Docker volume mountpoint and replace the prefix.
    case System.cmd("docker", ["volume", "inspect", "druzhok-data", "--format", "{{.Mountpoint}}"],
           stderr_to_stdout: true) do
      {mountpoint, 0} ->
        host_mount = String.trim(mountpoint)
        String.replace(container_path, ~r"^/data", host_mount)

      _ ->
        # Not in Docker or volume not found — use path as-is (local dev)
        container_path
    end
  end

  defp cleanup_container(container_name) do
    System.cmd("docker", ["stop", container_name], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
    :ok
  end
end
