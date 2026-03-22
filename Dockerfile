FROM elixir:1.18-slim

RUN apt-get update -qq && apt-get install -y -qq \
    build-essential git npm nodejs python3 \
    sqlite3 libsqlite3-dev bash curl \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI only (daemon is on the host via socket mount)
RUN curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz | tar xz -C /tmp \
    && mv /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker

WORKDIR /app
ENV MIX_ENV=dev

RUN mix local.hex --force && mix local.rebar --force

# Deps layer
COPY v3/mix.exs v3/mix.lock ./
COPY v3/apps/pi_core/mix.exs apps/pi_core/
COPY v3/apps/druzhok/mix.exs apps/druzhok/
COPY v3/apps/druzhok_web/mix.exs apps/druzhok_web/

RUN mix deps.get && mix deps.compile

# App code
COPY v3/apps/ apps/
COPY v3/config/ config/

RUN mix compile

# Workspace template
COPY workspace-template /app/workspace-template

# Sandbox agent source (built as sandbox image on first run)
COPY v3/services/sandbox-agent /app/sandbox-agent

# Entrypoint
COPY v3/docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

ENV DATABASE_PATH=/data/druzhok.db
ENV PORT=4000

EXPOSE 4000
VOLUME ["/data"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
