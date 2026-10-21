# Remove Parent Docker Container

Run the Elixir app directly on the host instead of inside a Docker container. Sandbox containers remain Docker-based.

## Motivation

The parent Docker container adds build time (~5 min per deploy), networking complexity (bridge → xray on 172.17.0.1), and Docker-in-Docker hacks (volume path resolution). Since this is a single-tenant server, containerizing the app provides no meaningful isolation benefit.

## Current State

```
HOST
├── xray (172.17.0.1:10809)
└── druzhok container (bridge, 172.17.0.2)
    ├── Elixir app (port 4000)
    ├── Docker socket → spawns sandbox containers
    └── druzhok-data volume at /data
```

## Target State

```
HOST
├── xray (127.0.0.1:10809)
├── Elixir app (mix phx.server, port 4000)
│   ├── HTTP_PROXY_URL=http://127.0.0.1:10809
│   ├── DATABASE_PATH=~/druzhok-data/druzhok.db
│   └── spawns sandbox containers via Docker
└── sandbox containers (host network, no internet)
    └── workspace bind-mounted from ~/druzhok-data/instances/*/workspace
```

## Changes Required

### 1. Install dependencies on host

The host currently has Elixir 1.14 / OTP 25. The app requires Elixir 1.18 / OTP 28.

```bash
# Install OTP 28 + Elixir 1.18 (via asdf or erlang-solutions repo)
# Install Rust (for Readability NIF)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# sqlite3 is already installed
```

### 2. Simplify `docker_client.ex`

**`sandbox_host/0`**: When running on host, the sandbox (host network) is on `127.0.0.1`. The current code reads `/proc/net/route` to find the Docker bridge gateway — this was needed when the Elixir app ran inside a bridge-network container. On host, just return `"127.0.0.1"`.

Keep the `/proc/net/route` fallback for the case where someone runs the app inside Docker during development.

**`resolve_host_path/1`**: This translates `/data/instances/...` to the Docker volume's host mountpoint for nested `docker run -v` mounts. When running on host, workspace paths are already real paths — no translation needed. The current fallback path (return as-is when volume not found) already handles this correctly, so no code change needed.

### 3. Revert xray listen address

Change xray HTTP inbound back from `172.17.0.1` to `127.0.0.1`. The app is on the host now and can reach `127.0.0.1` directly. This also closes the proxy to Docker network access (security improvement).

### 4. Migrate data from Docker volume

```bash
# Copy data from Docker volume to host directory
sudo cp -a /var/lib/docker/volumes/druzhok-data/_data ~/druzhok-data
sudo chown -R igor:igor ~/druzhok-data
```

### 5. Create systemd service

```ini
[Unit]
Description=Druzhok Telegram Bot
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=igor
WorkingDirectory=/home/igor/druzhok/v3
Environment=MIX_ENV=dev
Environment=DATABASE_PATH=/home/igor/druzhok-data/druzhok.db
Environment=HTTP_PROXY_URL=http://127.0.0.1:10809
Environment=PORT=4000
Environment=PHX_SERVER=true
ExecStart=/usr/local/bin/mix phx.server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 6. Deploy workflow

After this change, deploying is:
```bash
ssh igor@158.160.25.25
cd ~/druzhok
git pull
cd v3 && mix deps.get && mix compile
sudo systemctl restart druzhok
```

No Docker build, no dangling images, seconds instead of minutes.

### 7. Cleanup

- Stop and remove the `druzhok` container
- Remove the `druzhok:latest` image
- Keep `druzhok-sandbox:latest` image (still needed)
- Remove the `Dockerfile` (or keep for reference)
- Remove `docker-entrypoint.sh`
- Update `CLAUDE.md` deploy instructions

## What does NOT change

- Sandbox containers — still Docker, host network, same `docker_client.ex` logic
- `druzhok-sandbox:latest` image
- xray VPN setup (just the listen address)
- All application code except minor `docker_client.ex` simplification
- Web dashboard on port 4000
- SQLite database (just moved from volume to host dir)

## Risks

- **Elixir version upgrade**: OTP 25 → 28 is a major jump. May need to handle deps compatibility. Mitigated: the app was developed on 1.18/OTP 28 in the Docker image.
- **No rollback container**: If the host setup breaks, we can't just `docker start druzhok`. Mitigated: keep the old image around for a few days.
