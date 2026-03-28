defmodule Druzhok.Sandbox.FirecrackerClient do
  use GenServer
  require Logger

  alias Druzhok.Sandbox.Protocol

  @default_fc_bin "/usr/local/bin/firecracker"
  @default_kernel "/opt/firecracker/vmlinux"
  @default_rootfs "/opt/firecracker/rootfs.ext4"
  @vcpu_count 1
  @mem_size_mib 128
  @vsock_guest_port 9999

  defstruct [:socket, :instance_name, :fc_port, :api_socket_path, :vsock_path, :rootfs_path,
             pending: %{}, counter: 0, buffer: ""]

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
    fc_bin = System.get_env("FIRECRACKER_BIN") || @default_fc_bin
    kernel_path = System.get_env("FIRECRACKER_KERNEL") || @default_kernel
    base_rootfs = System.get_env("FIRECRACKER_ROOTFS") || @default_rootfs

    cid = next_cid()
    api_socket = "/tmp/fc-#{instance_name}.sock"
    vsock_path = "/tmp/fc-#{instance_name}-v.sock"
    rootfs_path = "/tmp/fc-#{instance_name}-rootfs.ext4"

    # Clean up any stale files from a previous run
    cleanup_files(api_socket, vsock_path, rootfs_path)

    # Copy base rootfs so each VM gets its own writable image
    # TODO: Use copy-on-write (overlayfs/btrfs snapshot) instead of full copy
    # Current: ~100MB per instance, grows linearly
    case File.cp(base_rootfs, rootfs_path) do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("Failed to copy rootfs: #{inspect(reason)}")
        {:stop, {:rootfs_copy_failed, reason}}
    end

    # Start Firecracker process
    fc_port = Port.open(
      {:spawn_executable, fc_bin},
      [:binary, :exit_status, :stderr_to_stdout,
       args: ["--api-sock", api_socket]]
    )

    # Wait for API socket to appear
    case wait_for_file(api_socket, 50, 100) do
      :ok -> :ok
      :timeout ->
        Port.close(fc_port)
        cleanup_files(api_socket, vsock_path, rootfs_path)
        {:stop, :api_socket_timeout}
    end

    # Configure VM via Firecracker API
    with :ok <- fc_api(api_socket, "PUT", "/machine-config", %{
           vcpu_count: @vcpu_count,
           mem_size_mib: @mem_size_mib
         }),
         :ok <- fc_api(api_socket, "PUT", "/boot-source", %{
           kernel_image_path: kernel_path,
           boot_args: "console=ttyS0 reboot=k panic=1 pci=off"
         }),
         :ok <- fc_api(api_socket, "PUT", "/drives/rootfs", %{
           drive_id: "rootfs",
           path_on_host: rootfs_path,
           is_root_device: true,
           is_read_only: false
         }),
         :ok <- fc_api(api_socket, "PUT", "/vsock", %{
           guest_cid: cid,
           uds_path: vsock_path
         }),
         :ok <- fc_api(api_socket, "PUT", "/actions", %{action_type: "InstanceStart"}) do

      # Wait for VM to boot
      Process.sleep(3_000)

      # Connect to agent via vsock
      case connect_vsock(vsock_path, @vsock_guest_port) do
        {:ok, socket} ->
          :inet.setopts(socket, active: true)
          Logger.info("Firecracker sandbox started for #{instance_name} (CID=#{cid})")

          state = %__MODULE__{
            socket: socket,
            instance_name: instance_name,
            fc_port: fc_port,
            api_socket_path: api_socket,
            vsock_path: vsock_path,
            rootfs_path: rootfs_path,
          }

          Protocol.init_workspace(state)

          {:ok, state}

        {:error, reason} ->
          Port.close(fc_port)
          cleanup_files(api_socket, vsock_path, rootfs_path)
          {:stop, {:vsock_connect_failed, reason}}
      end
    else
      {:error, reason} ->
        Port.close(fc_port)
        cleanup_files(api_socket, vsock_path, rootfs_path)
        {:stop, {:vm_config_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    if state.fc_port, do: Port.close(state.fc_port)
    cleanup_files(state.api_socket_path, state.vsock_path, state.rootfs_path)
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

  def handle_info({_port, {:exit_status, code}}, state) do
    Logger.error("Firecracker process exited with code #{code} for #{state.instance_name}")
    Protocol.reply_all_pending(state, {:error, :firecracker_exited})
    {:stop, {:firecracker_exited, code}, %{state | pending: %{}}}
  end

  def handle_info({_port, {:data, data}}, state) do
    Logger.debug("Firecracker stdout: #{data}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Firecracker-specific helpers ---

  defp fc_api(api_socket, method, path, body) do
    case :gen_tcp.connect({:local, api_socket}, 0, [:binary, active: false], 5_000) do
      {:ok, sock} ->
        payload = Jason.encode!(body)
        request = "#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(payload)}\r\n\r\n#{payload}"
        :gen_tcp.send(sock, request)
        {:ok, response} = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.close(sock)
        if String.contains?(response, "204") or String.contains?(response, "200"),
          do: :ok,
          else: {:error, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect_vsock(vsock_path, port, retries \\ 10, delay \\ 500)
  defp connect_vsock(_path, _port, 0, _delay), do: {:error, "vsock connection timeout"}

  defp connect_vsock(path, port, retries, delay) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 2_000) do
      {:ok, sock} ->
        :gen_tcp.send(sock, "CONNECT #{port}\n")

        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} ->
            if String.starts_with?(String.trim(data), "OK") do
              {:ok, sock}
            else
              :gen_tcp.close(sock)
              Process.sleep(delay)
              connect_vsock(path, port, retries - 1, delay)
            end

          _ ->
            :gen_tcp.close(sock)
            Process.sleep(delay)
            connect_vsock(path, port, retries - 1, delay)
        end

      {:error, _} ->
        Process.sleep(delay)
        connect_vsock(path, port, retries - 1, delay)
    end
  end

  defp next_cid do
    current = :persistent_term.get(:firecracker_next_cid, 3)
    :persistent_term.put(:firecracker_next_cid, current + 1)
    current
  end

  defp wait_for_file(_path, 0, _delay), do: :timeout

  defp wait_for_file(path, retries, delay) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(delay)
      wait_for_file(path, retries - 1, delay)
    end
  end

  defp cleanup_files(api_socket, vsock_path, rootfs_path) do
    File.rm(api_socket)
    File.rm(vsock_path)
    File.rm(rootfs_path)
    :ok
  end
end
