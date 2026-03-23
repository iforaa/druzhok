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

            Protocol.init_workspace(state)

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

  defp start_container(container_name, secret) do
    case System.find_executable("docker") do
      nil ->
        {:error, "Docker not installed"}

      _ ->
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
            case System.cmd("docker", ["inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container_name]) do
              {ip_str, 0} ->
                {:ok, {String.trim(ip_str), 9999}}

              _ ->
                {:error, "Failed to get container IP"}
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

  defp cleanup_container(container_name) do
    System.cmd("docker", ["stop", container_name], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
    :ok
  end
end
