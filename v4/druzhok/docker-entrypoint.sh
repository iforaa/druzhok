#!/bin/bash
set -e

# Check Docker access (via mounted socket)
if docker info >/dev/null 2>&1; then
  echo "Docker available via socket."

  # Build sandbox image if not exists
  if ! docker image inspect druzhok-sandbox:latest >/dev/null 2>&1; then
    echo "Building sandbox image..."
    cd /app/sandbox-agent
    docker build -t druzhok-sandbox:latest . 2>&1 | tail -3
    cd /app
    echo "Sandbox image built."
  fi
else
  echo "WARNING: Docker not available. Sandboxing will use local mode."
fi

# Ensure data directory
mkdir -p /data

# Run migrations
echo "Running migrations..."
mix ecto.create 2>/dev/null || true
mix ecto.migrate 2>&1 | tail -3

# Seed admin if needed
mix run apps/druzhok/priv/repo/seeds.exs 2>/dev/null || true

# Start Phoenix
echo "Starting Druzhok..."
exec mix phx.server
