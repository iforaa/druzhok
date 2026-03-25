# Remove Parent Docker Container — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the Elixir app directly on the host, eliminating the parent Docker container while keeping sandbox containers Docker-based.

**Architecture:** Single Elixir process on the host connects to xray VPN proxy at `127.0.0.1:10809` via Finch's HTTP proxy support. Sandbox containers are spawned via Docker CLI. systemd manages the Elixir process.

**Tech Stack:** Elixir 1.18 / OTP 28, Rust (Readability NIF), Docker (sandboxes only), systemd, xray

**Server:** `ssh -l igor 158.160.25.25`

---

### Task 1: Install Elixir 1.18 and Rust on host

Currently the host has Elixir 1.14 / OTP 25. The app requires Elixir 1.18 / OTP 28.

**Files:** None (server setup only)

- [ ] **Step 1: Install Erlang/OTP 28 and Elixir 1.18**

```bash
ssh -l igor 158.160.25.25

# Add erlang-solutions repo
wget https://binaries2.erlang-solutions.com/ubuntu/pool/contrib/e/esl-erlang/esl-erlang_28.2-1~ubuntu~jammy_amd64.deb
sudo dpkg -i esl-erlang_28.2-1~ubuntu~jammy_amd64.deb || sudo apt-get install -f -y

# Install Elixir 1.18
wget https://github.com/elixir-lang/elixir/releases/download/v1.18.4/elixir-otp-28.zip
sudo unzip elixir-otp-28.zip -d /usr/local/elixir-1.18
sudo ln -sf /usr/local/elixir-1.18/bin/* /usr/local/bin/
```

Note: The exact package names and URLs may vary. Use `asdf` if the above doesn't work:
```bash
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
source ~/.bashrc
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 28.2
asdf install elixir 1.18.4-otp-28
asdf global erlang 28.2
asdf global elixir 1.18.4-otp-28
```

- [ ] **Step 2: Install Rust**

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
```

- [ ] **Step 3: Install build dependencies**

```bash
sudo apt-get install -y build-essential git sqlite3 libsqlite3-dev
```

- [ ] **Step 4: Verify installations**

```bash
elixir --version
# Expected: Elixir 1.18.x (compiled with Erlang/OTP 28)

rustc --version
# Expected: rustc 1.x.x

mix --version
# Expected: Mix 1.18.x
```

---

### Task 2: Simplify `docker_client.ex` for host execution

When running on the host, `sandbox_host/0` should return `"127.0.0.1"` since both the app and sandbox containers share the host network. The `/proc/net/route` logic was only needed when the app ran inside a bridge-network container.

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/sandbox/docker_client.ex:194-210`

- [ ] **Step 1: Update `sandbox_host/0`**

Replace the current `sandbox_host/0` function (lines 194-210) with:

```elixir
  # When running on host, sandbox containers use --network host,
  # so they listen on 127.0.0.1.
  # When running inside Docker (bridge network), fall back to
  # reading the bridge gateway from /proc/net/route.
  defp sandbox_host do
    case File.read("/proc/net/route") do
      {:ok, content} ->
        case Regex.run(~r/\w+\t00000000\t([0-9A-F]+)\t/, content) do
          [_, hex_ip] ->
            <<d, c, b, a>> = Base.decode16!(hex_ip)
            "#{a}.#{b}.#{c}.#{d}"
          _ -> "127.0.0.1"
        end
      # Not in Docker (no /proc/net/route on macOS or when running on host directly)
      _ -> "127.0.0.1"
    end
  end
```

The only change: default fallback from `"172.17.0.1"` to `"127.0.0.1"`. On the host, `/proc/net/route` exists but the default gateway is the real network gateway, not Docker bridge — so the parsed IP will be correct for non-Docker scenarios. The key case: when `/proc/net/route` doesn't exist (macOS local dev) or when parsing fails, we default to localhost.

Actually, on Linux host `/proc/net/route` will exist and return the real gateway (e.g. `10.129.0.1`), not `172.17.0.1`. That's wrong — sandbox is on `127.0.0.1`. We need to detect whether we're in Docker.

Better approach:

```elixir
  defp sandbox_host do
    if File.exists?("/.dockerenv") do
      # Inside Docker container — reach sandbox via bridge gateway
      case File.read("/proc/net/route") do
        {:ok, content} ->
          case Regex.run(~r/\w+\t00000000\t([0-9A-F]+)\t/, content) do
            [_, hex_ip] ->
              <<d, c, b, a>> = Base.decode16!(hex_ip)
              "#{a}.#{b}.#{c}.#{d}"
            _ -> "172.17.0.1"
          end
        _ -> "172.17.0.1"
      end
    else
      # Running on host — sandbox uses --network host, so localhost
      "127.0.0.1"
    end
  end
```

- [ ] **Step 2: Verify compilation**

```bash
cd ~/druzhok/v3
mix compile
```
Expected: compiles with no new warnings.

- [ ] **Step 3: Commit**

```bash
git add apps/druzhok/lib/druzhok/sandbox/docker_client.ex
git commit -m "fix sandbox_host: use 127.0.0.1 when running on host, detect Docker via /.dockerenv"
```

---

### Task 3: Migrate data from Docker volume to host directory

**Files:** None (server operations only)

- [ ] **Step 1: Create host data directory and copy data**

```bash
ssh -l igor 158.160.25.25

# Find current volume data
sudo ls /var/lib/docker/volumes/druzhok-data/_data/

# Copy to host directory
sudo cp -a /var/lib/docker/volumes/druzhok-data/_data /home/igor/druzhok-data
sudo chown -R igor:igor /home/igor/druzhok-data
```

- [ ] **Step 2: Verify data**

```bash
ls ~/druzhok-data/
# Expected: druzhok.db  druzhok.db-shm  druzhok.db-wal  instances

ls ~/druzhok-data/instances/igor/workspace/
# Expected: AGENTS.md  HEARTBEAT.md  IDENTITY.md  MEMORY.md  SOUL.md  USER.md  inbox  memory  sessions
```

---

### Task 4: Revert xray to listen on 127.0.0.1

Now that the app runs on the host, xray doesn't need to be reachable from the Docker bridge network.

**Files:** `/usr/local/etc/xray/config.json` on the server

- [ ] **Step 1: Update xray config**

```bash
ssh -l igor 158.160.25.25

sudo python3 -c "
import json
with open('/usr/local/etc/xray/config.json') as f:
    c = json.load(f)
for i in c['inbounds']:
    if i.get('protocol') == 'http':
        i['listen'] = '127.0.0.1'
with open('/usr/local/etc/xray/config.json', 'w') as f:
    json.dump(c, f, indent=2)
print('Reverted HTTP inbound listen to 127.0.0.1')
"
```

- [ ] **Step 2: Restart xray and verify**

```bash
sudo systemctl restart xray
ss -tlnp | grep 10809
# Expected: LISTEN ... 127.0.0.1:10809 ...
```

---

### Task 5: Sync code and build on host

**Files:** None (server operations)

- [ ] **Step 1: Sync latest code to server**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
rsync -avz --delete \
  --exclude='.git' --exclude='deps' --exclude='_build' --exclude='node_modules' \
  v3/ igor@158.160.25.25:~/druzhok/v3/
rsync -avz workspace-template/ igor@158.160.25.25:~/druzhok/workspace-template/
```

- [ ] **Step 2: Install deps and compile on server**

```bash
ssh -l igor 158.160.25.25
cd ~/druzhok/v3
mix local.hex --force
mix local.rebar --force
mix deps.get
mix compile
```

Expected: compiles successfully (Rust NIF will take a minute on first build, then cached).

- [ ] **Step 3: Verify sandbox image exists**

```bash
docker image inspect druzhok-sandbox:latest >/dev/null 2>&1 && echo "OK" || echo "MISSING"
# Expected: OK (already built from previous deployment)
```

If missing, build it:
```bash
cd ~/druzhok/v3/services/sandbox-agent
docker build -t druzhok-sandbox:latest .
```

- [ ] **Step 4: Run migrations**

```bash
cd ~/druzhok/v3
DATABASE_PATH=/home/igor/druzhok-data/druzhok.db mix ecto.migrate
```

---

### Task 6: Create systemd service

**Files:**
- Create: `/etc/systemd/system/druzhok.service` (on server)

- [ ] **Step 1: Create service file**

```bash
ssh -l igor 158.160.25.25

sudo tee /etc/systemd/system/druzhok.service << 'EOF'
[Unit]
Description=Druzhok Telegram Bot
After=network.target docker.service xray.service
Requires=docker.service

[Service]
Type=simple
User=igor
Group=igor
WorkingDirectory=/home/igor/druzhok/v3
Environment=MIX_ENV=dev
Environment=DATABASE_PATH=/home/igor/druzhok-data/druzhok.db
Environment=HTTP_PROXY_URL=http://127.0.0.1:10809
Environment=PORT=4000
Environment=PHX_SERVER=true
Environment=SECRET_KEY_BASE=generate-a-real-one
Environment=HOME=/home/igor
ExecStart=/usr/local/bin/mix phx.server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Note: `SECRET_KEY_BASE` should be generated with `mix phx.gen.secret` and placed in the service file or an env file.

- [ ] **Step 2: Generate secret key base**

```bash
cd ~/druzhok/v3
mix phx.gen.secret
# Copy output and update the service file:
sudo systemctl edit druzhok --force
# Add: Environment=SECRET_KEY_BASE=<generated-value>
```

Or use an env file:
```bash
echo "SECRET_KEY_BASE=$(cd ~/druzhok/v3 && mix phx.gen.secret)" > ~/druzhok/.env.prod
# Then add EnvironmentFile=/home/igor/druzhok/.env.prod to the service
```

- [ ] **Step 3: Add API keys to env file**

```bash
cat >> ~/druzhok/.env.prod << 'EOF'
NEBIUS_API_KEY=<key>
NEBIUS_BASE_URL=https://api.tokenfactory.us-central1.nebius.com/v1
ANTHROPIC_API_KEY=<key>
OPENROUTER_API_KEY=<key>
EOF
chmod 600 ~/druzhok/.env.prod
```

Update service to use env file:
```bash
sudo sed -i '/\[Service\]/a EnvironmentFile=/home/igor/druzhok/.env.prod' /etc/systemd/system/druzhok.service
```

- [ ] **Step 4: Reload systemd**

```bash
sudo systemctl daemon-reload
```

---

### Task 7: Stop parent Docker container and start host service

- [ ] **Step 1: Stop the Docker container**

```bash
ssh -l igor 158.160.25.25
docker stop druzhok
docker rm druzhok
```

- [ ] **Step 2: Start the systemd service**

```bash
sudo systemctl start druzhok
sudo systemctl status druzhok
```

Expected: active (running), no errors in journal.

- [ ] **Step 3: Check logs**

```bash
journalctl -u druzhok -f --no-pager | head -30
```

Expected: Phoenix starts, instances load, sandbox container spawns.

- [ ] **Step 4: Verify sandbox works**

```bash
docker ps
# Expected: druzhok-N-igor sandbox container running
```

- [ ] **Step 5: Test the bot**

Send a message to the Telegram bot. Verify it responds.

- [ ] **Step 6: Enable on boot**

```bash
sudo systemctl enable druzhok
```

---

### Task 8: Cleanup and update docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md deploy instructions**

Update the "Deploying to Cloud" section to reflect the new workflow:

```markdown
## Deploying to Cloud

```bash
# On the server (ssh -l igor 158.160.25.25):

# 1. Pull latest code
cd ~/druzhok && git pull

# 2. Compile
cd v3 && mix deps.get && mix compile

# 3. Run migrations
DATABASE_PATH=/home/igor/druzhok-data/druzhok.db mix ecto.migrate

# 4. Restart
sudo systemctl restart druzhok

# 5. Check logs
journalctl -u druzhok -f
```
```

- [ ] **Step 2: Remove Docker build references from CLAUDE.md**

Remove the "Docker image rebuilds" and "Prune dangling images after deploy" rules since the parent Docker is gone. Keep sandbox-related Docker info.

- [ ] **Step 3: Optionally clean up old Docker image**

```bash
ssh -l igor 158.160.25.25
docker rmi druzhok:latest
docker rmi elixir:1.18-slim
docker image prune -f
```

Keep `druzhok-sandbox:latest` — it's still needed.

- [ ] **Step 4: Commit all changes**

```bash
git add CLAUDE.md v3/apps/druzhok/lib/druzhok/sandbox/docker_client.ex
git commit -m "remove parent Docker: run Elixir on host, simplify sandbox_host"
```
