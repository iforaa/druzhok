# Firecracker Sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Firecracker microVM sandbox backend so agent tools execute inside isolated VMs with vsock communication, running on the Raspberry Pi 5 with KVM.

**Architecture:** Each instance gets a Firecracker microVM with a minimal Alpine rootfs. The same Go agent binary runs inside the VM, listening on vsock port 9999 instead of TCP. The BEAM communicates via AF_UNIX socket (Firecracker's vsock proxy). A `Druzhok.Sandbox.Firecracker` module implements the existing Sandbox behaviour, reusing the same JSON line protocol as Docker.

**Tech Stack:** Firecracker v1.15.0 (aarch64), Go (vsock agent), Alpine Linux rootfs, Elixir (Unix socket client)

**Pi specs:** Raspberry Pi 5, 8GB RAM, 4 CPUs, Debian 13, KVM enabled, Firecracker installed at `/usr/local/bin/firecracker`

---

### Task 1: Download/build aarch64 kernel for Firecracker

**Files:**
- On Pi: `/opt/firecracker/vmlinux`

- [ ] **Step 1: Download pre-built kernel from Firecracker CI**

```bash
ssh iforaa@IgorPi.local "
  sudo mkdir -p /opt/firecracker
  # Download kernel from Firecracker's S3 artifacts
  ARCH=aarch64
  curl -fsSL -o /tmp/vmlinux.bin \
    https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.11/${ARCH}/vmlinux-6.1.102
  sudo cp /tmp/vmlinux.bin /opt/firecracker/vmlinux
  sudo chmod 644 /opt/firecracker/vmlinux
  ls -la /opt/firecracker/vmlinux
"
```

If that URL doesn't work, build from source:
```bash
ssh iforaa@IgorPi.local "
  sudo apt-get install -y flex bison bc libssl-dev libelf-dev
  git clone --depth 1 -b microvm-kernel-6.1 https://github.com/amazonlinux/linux.git /tmp/linux-build
  cd /tmp/linux-build
  curl -o .config https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-ci-aarch64-6.1.config
  make olddefconfig
  make -j4 Image
  sudo cp arch/arm64/boot/Image /opt/firecracker/vmlinux
"
```

- [ ] **Step 2: Verify kernel**

```bash
ssh iforaa@IgorPi.local "file /opt/firecracker/vmlinux"
# Expected: Linux kernel ARM64 boot executable Image or similar
```

- [ ] **Step 3: Commit docs/notes (no code change)**

---

### Task 2: Update Go agent binary for vsock support

**Files:**
- Modify: `v3/services/sandbox-agent/main.go`
- Modify: `v3/services/sandbox-agent/go.mod`

- [ ] **Step 1: Add vsock dependency**

```bash
cd v3/services/sandbox-agent
go get github.com/mdlayher/vsock
```

- [ ] **Step 2: Update main.go to support both TCP and vsock**

Add a `--vsock` flag. When set, listen on vsock port 9999 instead of TCP:

```go
import (
    "flag"
    "github.com/mdlayher/vsock"
)

func main() {
    useVsock := flag.Bool("vsock", false, "Listen on vsock instead of TCP")
    flag.Parse()

    var listener net.Listener
    var err error

    if *useVsock {
        listener, err = vsock.Listen(9999, nil)
        log.Println("Listening on vsock port 9999")
    } else {
        listener, err = net.Listen("tcp", ":9999")
        log.Println("Listening on TCP :9999")
    }
    // ... rest unchanged, listener.Accept() works the same
}
```

The `vsock.Conn` implements `net.Conn`, so all existing handler code works unchanged.

- [ ] **Step 3: Cross-compile for aarch64 Linux**

```bash
cd v3/services/sandbox-agent
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o sandbox-agent-arm64 .
```

- [ ] **Step 4: Copy to Pi**

```bash
scp v3/services/sandbox-agent/sandbox-agent-arm64 iforaa@IgorPi.local:/opt/firecracker/sandbox-agent
ssh iforaa@IgorPi.local "chmod +x /opt/firecracker/sandbox-agent"
```

- [ ] **Step 5: Commit**

```bash
git commit -m "add vsock support to sandbox agent"
```

---

### Task 3: Build Alpine rootfs image

**Files:**
- On Pi: `/opt/firecracker/rootfs.ext4`
- Create: `v3/services/sandbox-agent/build-rootfs.sh`

- [ ] **Step 1: Create rootfs build script**

```bash
#!/bin/bash
# build-rootfs.sh — builds Alpine rootfs for Firecracker microVMs
# Run on the Pi (aarch64)
set -e

ROOTFS="/tmp/rootfs.ext4"
MOUNT="/tmp/rootfs-mount"
SIZE_MB=512

# Create ext4 image
dd if=/dev/zero of=$ROOTFS bs=1M count=0 seek=$SIZE_MB
mkfs.ext4 $ROOTFS

# Mount
mkdir -p $MOUNT
sudo mount $ROOTFS $MOUNT

# Bootstrap Alpine
sudo docker run --rm --platform linux/arm64 -v $MOUNT:/rootfs alpine:3.20 sh -c '
  apk add --no-cache --root /rootfs --initdb \
    alpine-base openrc busybox-openrc \
    python3 py3-pip nodejs npm git curl wget jq bash build-base openssh-client
'

# Configure
sudo chroot $MOUNT /bin/sh -c "
  # Serial console
  sed -i 's/#ttyS0/ttyS0/' /etc/inittab
  echo 'ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100' >> /etc/inittab

  # Networking
  echo 'auto eth0' > /etc/network/interfaces
  echo 'iface eth0 inet dhcp' >> /etc/network/interfaces

  # DNS
  echo 'nameserver 8.8.8.8' > /etc/resolv.conf

  # Hostname
  echo 'sandbox' > /etc/hostname

  # Root autologin (no password needed, agent handles auth)
  passwd -d root

  # OpenRC boot services
  rc-update add networking boot
  rc-update add hostname boot

  # Create workspace
  mkdir -p /workspace
"

# Copy agent binary
sudo cp /opt/firecracker/sandbox-agent $MOUNT/usr/local/bin/sandbox-agent
sudo chmod +x $MOUNT/usr/local/bin/sandbox-agent

# Create agent init script (starts with --vsock flag)
sudo tee $MOUNT/etc/init.d/sandbox-agent << 'INITEOF'
#!/sbin/openrc-run
description="Sandbox Agent"
command="/usr/local/bin/sandbox-agent"
command_args="--vsock"
command_background=true
pidfile="/run/sandbox-agent.pid"
output_log="/var/log/sandbox-agent.log"
error_log="/var/log/sandbox-agent.log"
depend() {
    need localmount
}
INITEOF
sudo chmod +x $MOUNT/etc/init.d/sandbox-agent
sudo chroot $MOUNT rc-update add sandbox-agent default

# Unmount
sudo umount $MOUNT
sudo mv $ROOTFS /opt/firecracker/rootfs.ext4
echo "Rootfs built at /opt/firecracker/rootfs.ext4"
```

- [ ] **Step 2: Build rootfs on Pi**

Note: This requires Docker on the Pi for bootstrapping, OR use `apk --root` with Alpine APK tools. Since Docker isn't on the Pi, use the direct approach:

```bash
ssh iforaa@IgorPi.local "
  sudo apt-get install -y debootstrap
  # Alternative: download Alpine minirootfs and expand it
  cd /tmp
  curl -fsSL -o alpine-minirootfs.tar.gz \
    https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.6-aarch64.tar.gz

  # Create ext4 image
  dd if=/dev/zero of=rootfs.ext4 bs=1M count=0 seek=512
  mkfs.ext4 rootfs.ext4
  mkdir -p /tmp/rootfs-mount
  sudo mount rootfs.ext4 /tmp/rootfs-mount

  # Extract Alpine
  sudo tar xzf alpine-minirootfs.tar.gz -C /tmp/rootfs-mount

  # Install packages
  sudo cp /etc/resolv.conf /tmp/rootfs-mount/etc/resolv.conf
  sudo chroot /tmp/rootfs-mount /bin/sh -c '
    apk add --no-cache openrc busybox-openrc \
      python3 py3-pip nodejs npm git curl wget jq bash build-base openssh-client util-linux

    # Serial console for Firecracker
    echo \"ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100\" >> /etc/inittab

    # Networking
    echo \"auto eth0\" > /etc/network/interfaces
    echo \"iface eth0 inet dhcp\" >> /etc/network/interfaces

    # DNS
    echo \"nameserver 8.8.8.8\" > /etc/resolv.conf

    # Hostname
    echo \"sandbox\" > /etc/hostname

    # No root password
    passwd -d root

    # Boot services
    rc-update add networking boot
    rc-update add hostname boot

    # Create workspace
    mkdir -p /workspace
  '

  # Copy agent binary
  sudo cp /opt/firecracker/sandbox-agent /tmp/rootfs-mount/usr/local/bin/sandbox-agent
  sudo chmod +x /tmp/rootfs-mount/usr/local/bin/sandbox-agent

  # Agent init script
  sudo tee /tmp/rootfs-mount/etc/init.d/sandbox-agent << 'INITEOF'
#!/sbin/openrc-run
description=\"Sandbox Agent\"
command=\"/usr/local/bin/sandbox-agent\"
command_args=\"--vsock\"
command_background=true
pidfile=\"/run/sandbox-agent.pid\"
output_log=\"/var/log/sandbox-agent.log\"
error_log=\"/var/log/sandbox-agent.log\"
depend() { need localmount; }
INITEOF
  sudo chmod +x /tmp/rootfs-mount/etc/init.d/sandbox-agent
  sudo chroot /tmp/rootfs-mount rc-update add sandbox-agent default

  # Unmount
  sudo umount /tmp/rootfs-mount
  sudo mv /tmp/rootfs.ext4 /opt/firecracker/rootfs.ext4
  echo 'Rootfs built!'
"
```

- [ ] **Step 3: Test rootfs with Firecracker manually**

```bash
ssh iforaa@IgorPi.local "
  # Copy rootfs for this test (Firecracker writes to it)
  cp /opt/firecracker/rootfs.ext4 /tmp/test-rootfs.ext4

  # Start Firecracker
  rm -f /tmp/fc-test.sock
  sudo /usr/local/bin/firecracker --api-sock /tmp/fc-test.sock &
  FC_PID=\$!
  sleep 1

  # Configure VM
  sudo curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/machine-config \
    -H 'Content-Type: application/json' \
    -d '{\"vcpu_count\": 1, \"mem_size_mib\": 128}'

  sudo curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/boot-source \
    -H 'Content-Type: application/json' \
    -d '{\"kernel_image_path\": \"/opt/firecracker/vmlinux\", \"boot_args\": \"keep_bootcon console=ttyS0 reboot=k panic=1 pci=off\"}'

  sudo curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/drives/rootfs \
    -H 'Content-Type: application/json' \
    -d '{\"drive_id\": \"rootfs\", \"path_on_host\": \"/tmp/test-rootfs.ext4\", \"is_root_device\": true, \"is_read_only\": false}'

  sudo curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/vsock \
    -H 'Content-Type: application/json' \
    -d '{\"guest_cid\": 3, \"uds_path\": \"/tmp/test-v.sock\"}'

  # Start VM
  sudo curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/actions \
    -H 'Content-Type: application/json' \
    -d '{\"action_type\": \"InstanceStart\"}'

  sleep 3
  echo 'VM started, checking vsock...'

  # Kill after test
  sudo kill \$FC_PID 2>/dev/null
"
```

- [ ] **Step 4: Commit build script**

```bash
git commit -m "add rootfs build script for Firecracker"
```

---

### Task 4: Firecracker sandbox Elixir implementation

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/sandbox/firecracker.ex`
- Create: `v3/apps/druzhok/lib/druzhok/sandbox/firecracker_client.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/sandbox.ex`

- [ ] **Step 1: Create FirecrackerClient GenServer**

Similar to DockerClient but:
- Starts a Firecracker process (via `Port.open` or `System.cmd`)
- Configures VM via HTTP API over Unix socket
- Connects to agent via vsock (Unix socket + CONNECT handshake)
- Same JSON line protocol for commands

```elixir
defmodule Druzhok.Sandbox.FirecrackerClient do
  use GenServer
  require Logger

  @kernel_path "/opt/firecracker/vmlinux"
  @base_rootfs "/opt/firecracker/rootfs.ext4"
  @agent_binary "/opt/firecracker/sandbox-agent"
  @vcpu_count 1
  @mem_size_mib 128

  defstruct [:socket, :instance_name, :fc_pid, :api_socket_path, :vsock_path, :rootfs_path,
             pending: %{}, counter: 0, buffer: ""]

  def start_link(opts) do
    name = opts[:registry_name]
    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  # Same exec/read_file/write_file/list_dir API as DockerClient
  def exec(pid, command, timeout \\ 300_000), do: GenServer.call(pid, {:exec, command}, timeout)
  def read_file(pid, path, timeout \\ 30_000), do: GenServer.call(pid, {:read, path}, timeout)
  def write_file(pid, path, content, timeout \\ 30_000), do: GenServer.call(pid, {:write, path, content}, timeout)
  def list_dir(pid, path, timeout \\ 30_000), do: GenServer.call(pid, {:ls, path}, timeout)

  def init(opts) do
    instance_name = opts.instance_name
    cid = opts[:cid] || 3  # assigned by caller

    api_socket = "/tmp/fc-#{instance_name}.sock"
    vsock_path = "/tmp/fc-#{instance_name}-v.sock"
    rootfs_path = "/tmp/fc-#{instance_name}-rootfs.ext4"

    # Copy base rootfs for this instance
    File.cp!(@base_rootfs, rootfs_path)

    # Start Firecracker process
    fc_port = Port.open({:spawn_executable, "/usr/local/bin/firecracker"},
      [:binary, :exit_status, args: ["--api-sock", api_socket]])

    Process.sleep(500)  # wait for socket

    # Configure and start VM
    case configure_and_start(api_socket, rootfs_path, vsock_path, cid) do
      :ok ->
        # Connect to agent via vsock
        Process.sleep(2000)  # wait for VM boot + agent start
        case connect_vsock(vsock_path, 9999) do
          {:ok, socket} ->
            :inet.setopts(socket, active: true)
            state = %__MODULE__{
              socket: socket,
              instance_name: instance_name,
              fc_pid: fc_port,
              api_socket_path: api_socket,
              vsock_path: vsock_path,
              rootfs_path: rootfs_path,
            }
            init_workspace(state)
            {:ok, state}
          {:error, reason} ->
            Port.close(fc_port)
            {:stop, {:vsock_failed, reason}}
        end
      {:error, reason} ->
        Port.close(fc_port)
        {:stop, {:config_failed, reason}}
    end
  end

  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    if state.fc_pid, do: Port.close(state.fc_pid)
    File.rm(state.api_socket_path)
    File.rm(state.vsock_path)
    # Keep rootfs for persistence (or delete for fresh start)
    :ok
  end

  # ... handle_call/handle_info same as DockerClient (reuse or extract shared module)
end
```

- [ ] **Step 2: Implement VM configuration**

```elixir
defp configure_and_start(api_socket, rootfs_path, vsock_path, cid) do
  api = fn method, path, body ->
    # HTTP over Unix socket
    {:ok, sock} = :gen_tcp.connect({:local, api_socket}, 0, [:binary, active: false], 5000)
    payload = Jason.encode!(body)
    request = "#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(payload)}\r\n\r\n#{payload}"
    :gen_tcp.send(sock, request)
    {:ok, response} = :gen_tcp.recv(sock, 0, 5000)
    :gen_tcp.close(sock)
    if String.contains?(response, "204") or String.contains?(response, "200"), do: :ok, else: {:error, response}
  end

  with :ok <- api.("PUT", "/machine-config", %{vcpu_count: @vcpu_count, mem_size_mib: @mem_size_mib}),
       :ok <- api.("PUT", "/boot-source", %{kernel_image_path: @kernel_path, boot_args: "keep_bootcon console=ttyS0 reboot=k panic=1 pci=off"}),
       :ok <- api.("PUT", "/drives/rootfs", %{drive_id: "rootfs", path_on_host: rootfs_path, is_root_device: true, is_read_only: false}),
       :ok <- api.("PUT", "/vsock", %{guest_cid: cid, uds_path: vsock_path}),
       :ok <- api.("PUT", "/actions", %{action_type: "InstanceStart"}) do
    :ok
  end
end
```

- [ ] **Step 3: Implement vsock connection**

```elixir
defp connect_vsock(vsock_path, port, retries \\ 10, delay \\ 500) do
  if retries == 0 do
    {:error, "vsock connection timeout"}
  else
    case :gen_tcp.connect({:local, vsock_path}, 0, [:binary, active: false], 2000) do
      {:ok, sock} ->
        # Firecracker vsock handshake: send CONNECT <port>\n
        :gen_tcp.send(sock, "CONNECT #{port}\n")
        case :gen_tcp.recv(sock, 0, 5000) do
          {:ok, data} ->
            if String.starts_with?(String.trim(data), "OK") do
              # Now authenticate with the agent
              secret = System.get_env("SANDBOX_SECRET") || "firecracker"
              :gen_tcp.send(sock, Jason.encode!(%{type: "auth", secret: secret}) <> "\n")
              case :gen_tcp.recv(sock, 0, 5000) do
                {:ok, auth_resp} ->
                  case Jason.decode(String.trim(auth_resp)) do
                    {:ok, %{"type" => "auth_ok"}} -> {:ok, sock}
                    _ -> :gen_tcp.close(sock); {:error, "auth failed"}
                  end
                _ -> :gen_tcp.close(sock); {:error, "auth timeout"}
              end
            else
              :gen_tcp.close(sock)
              Process.sleep(delay)
              connect_vsock(vsock_path, port, retries - 1, delay)
            end
          _ ->
            :gen_tcp.close(sock)
            Process.sleep(delay)
            connect_vsock(vsock_path, port, retries - 1, delay)
        end
      {:error, _} ->
        Process.sleep(delay)
        connect_vsock(vsock_path, port, retries - 1, delay)
    end
  end
end
```

- [ ] **Step 4: Create Firecracker sandbox module**

```elixir
defmodule Druzhok.Sandbox.Firecracker do
  @behaviour Druzhok.Sandbox

  def start(_instance_name, _opts), do: {:ok, :started}
  def stop(instance_name) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
      [{pid, _}] -> GenServer.stop(pid, :normal, 10_000)
      [] -> :ok
    end
  end

  def exec(instance_name, command), do: with_client(instance_name, &Druzhok.Sandbox.FirecrackerClient.exec(&1, command))
  def read_file(instance_name, path), do: with_client(instance_name, &Druzhok.Sandbox.FirecrackerClient.read_file(&1, path))
  def write_file(instance_name, path, content), do: with_client(instance_name, &Druzhok.Sandbox.FirecrackerClient.write_file(&1, path, content))
  def list_dir(instance_name, path), do: with_client(instance_name, &Druzhok.Sandbox.FirecrackerClient.list_dir(&1, path))

  defp with_client(instance_name, fun) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
      [{pid, _}] -> fun.(pid)
      [] -> {:error, "Sandbox not running"}
    end
  end
end
```

- [ ] **Step 5: Update Sandbox.impl to handle "firecracker"**

```elixir
def impl(sandbox_type) do
  case sandbox_type do
    "firecracker" -> Druzhok.Sandbox.Firecracker
    "docker" -> Druzhok.Sandbox.Docker
    _ -> Druzhok.Sandbox.Local
  end
end
```

- [ ] **Step 6: Update Instance.Sup to handle "firecracker" sandbox type**

Add `"firecracker"` case alongside `"docker"` in the sandbox_fns and sandbox_children sections of `Instance.Sup.init/1`.

- [ ] **Step 7: Update detect_sandbox in InstanceManager**

```elixir
defp detect_sandbox do
  cond do
    File.exists?("/opt/firecracker/vmlinux") and File.exists?("/opt/firecracker/rootfs.ext4") ->
      "firecracker"
    System.find_executable("docker") ->
      case System.cmd("docker", ["image", "inspect", "druzhok-sandbox:latest"], stderr_to_stdout: true) do
        {_, 0} -> "docker"
        _ -> "local"
      end
    true -> "local"
  end
end
```

- [ ] **Step 8: Add CID management**

Each Firecracker VM needs a unique CID (3+). Add a simple counter:

```elixir
# In InstanceManager or a dedicated module
defp next_cid do
  # Atomic counter via persistent_term
  current = :persistent_term.get(:firecracker_next_cid, 3)
  :persistent_term.put(:firecracker_next_cid, current + 1)
  current
end
```

- [ ] **Step 9: Run tests (local mode unchanged)**

```bash
cd v3 && mix test
```

- [ ] **Step 10: Commit**

```bash
git commit -m "add Firecracker sandbox backend"
```

---

### Task 5: Extract shared client logic (DRY)

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/sandbox/agent_client.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/sandbox/docker_client.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/sandbox/firecracker_client.ex`

- [ ] **Step 1: Extract shared protocol handling**

DockerClient and FirecrackerClient share identical JSON line protocol handling (handle_call, handle_info for TCP data, process_line, handle_response, split_lines, next_id, send_request, reply_all_pending). Extract into a shared module:

```elixir
defmodule Druzhok.Sandbox.AgentClient do
  # Shared request/response handling for the sandbox agent protocol
  # Both DockerClient and FirecrackerClient delegate to this

  def handle_exec_call(id, command, from, state) do ...
  def handle_read_call(id, path, from, state) do ...
  def process_tcp_data(data, state) do ...
  def handle_response(id, msg, pending, state) do ...
  # etc.
end
```

Or simpler: use `__using__` macro to inject the shared behavior.

- [ ] **Step 2: Refactor DockerClient to use shared module**

- [ ] **Step 3: Refactor FirecrackerClient to use shared module**

- [ ] **Step 4: Run tests**

```bash
cd v3 && mix test
```

- [ ] **Step 5: Commit**

```bash
git commit -m "extract shared sandbox agent protocol handling"
```

---

### Task 6: Deploy and test on Pi

- [ ] **Step 1: Sync code to Pi**

```bash
rsync -az --exclude '_build' --exclude 'deps' --exclude 'data' \
  v3/ iforaa@IgorPi.local:~/druzhok/v3/
```

- [ ] **Step 2: Build on Pi**

```bash
ssh iforaa@IgorPi.local "cd ~/druzhok/v3 && mix deps.get && mix compile"
```

- [ ] **Step 3: Build rootfs on Pi (Task 3)**

- [ ] **Step 4: Update DB to use firecracker sandbox**

```bash
ssh iforaa@IgorPi.local "sqlite3 ~/druzhok/v3/data/druzhok.db 'UPDATE instances SET sandbox = \"firecracker\" WHERE active = 1'"
```

- [ ] **Step 5: Restart service**

```bash
ssh iforaa@IgorPi.local "systemctl --user restart druzhok.service"
```

- [ ] **Step 6: Test — send message to bot**

Check logs for "Firecracker VM started" and tool execution inside VM.

- [ ] **Step 7: Verify isolation**

Send bot a command like "cat /etc/hostname" — should return "sandbox", not "IgorPi".
Send "ls /" — should show Alpine filesystem, not Debian.

- [ ] **Step 8: Final commit**

```bash
git commit -m "firecracker sandbox: complete implementation"
```
