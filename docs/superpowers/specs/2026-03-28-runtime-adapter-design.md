# Runtime Adapter System Design

Replace hardcoded runtime branches in BotConfig/BotManager/HealthMonitor with a pluggable behaviour. Adding a new bot runtime = one new module implementing the behaviour.

## Behaviour

```elixir
defmodule Druzhok.Runtime do
  @type instance :: map()

  @callback env_vars(instance) :: %{String.t() => String.t()}
  @callback workspace_files(instance) :: [{path :: String.t(), content :: String.t()}]
  @callback docker_image() :: String.t()
  @callback gateway_command() :: String.t()
  @callback health_path() :: String.t()
  @callback health_port() :: integer()
  @callback supports_feature?(atom()) :: boolean()
end
```

## Registry

Map of runtime name to module, stored in `Druzhok.Runtime`:

```elixir
@runtimes %{
  "zeroclaw" => Druzhok.Runtime.ZeroClaw,
  "picoclaw" => Druzhok.Runtime.PicoClaw,
}

def get(name), do: Map.fetch!(@runtimes, to_string(name))
def list, do: @runtimes
def names, do: Map.keys(@runtimes)
```

## Adapter Modules

### `Druzhok.Runtime.ZeroClaw`

- `env_vars/1`: `ZEROCLAW_AGENT_MODEL`, `ZEROCLAW_PROVIDER_TYPE=compatible`, telegram env vars if token present
- `workspace_files/1`: writes `config.toml` with `[channels.telegram]` section (bot_token, allowed_users)
- `docker_image/0`: env `ZEROCLAW_IMAGE` or `"zeroclaw:latest"`
- `gateway_command/0`: `"gateway"`
- `health_path/0`: `"/api/health"`
- `health_port/0`: `18790`
- `supports_feature?(:pairing)`: true
- `supports_feature?(:hot_reload_config)`: true

### `Druzhok.Runtime.PicoClaw`

- `env_vars/1`: `PICOCLAW_AGENTS_DEFAULTS_MODEL_NAME`, telegram token + allow_from via env vars
- `workspace_files/1`: empty list (PicoClaw uses env vars, not config files)
- `docker_image/0`: env `PICOCLAW_IMAGE` or `"picoclaw:latest"`
- `gateway_command/0`: `"gateway"`
- `health_path/0`: `"/health"`
- `health_port/0`: `18790`
- `supports_feature?(:pairing)`: false

## What Changes in Existing Code

### Delete `Druzhok.BotConfig`

Replaced entirely by `Runtime.get(name)` + base env vars in BotManager.

### `Druzhok.BotManager`

Replace:
```elixir
env = BotConfig.build(instance)
image = BotConfig.docker_image(instance)
```

With:
```elixir
runtime = Druzhok.Runtime.get(instance.bot_runtime)
base_env = %{
  "OPENAI_BASE_URL" => "http://#{proxy_host}:#{proxy_port}/v1",
  "OPENAI_API_KEY" => instance.tenant_key,
  "TZ" => instance.timezone || "UTC",
}
env = Map.merge(base_env, runtime.env_vars(instance))
image = runtime.docker_image()
command = runtime.gateway_command()

# Write config files before starting container
for {path, content} <- runtime.workspace_files(instance) do
  full_path = Path.join(instance.workspace, path)
  File.mkdir_p!(Path.dirname(full_path))
  File.write!(full_path, content)
end
```

### `Druzhok.HealthMonitor`

Replace hardcoded `docker inspect` with runtime-aware check. Use `container_name` from BotManager (already public).

### Dashboard

Replace hardcoded `<option>` tags with:
```heex
<%= for name <- Druzhok.Runtime.names() do %>
  <option value={name}><%= name %></option>
<% end %>
```

## File Map

| Action | File |
|--------|------|
| Create | `lib/druzhok/runtime.ex` (behaviour + registry) |
| Create | `lib/druzhok/runtime/zero_claw.ex` |
| Create | `lib/druzhok/runtime/pico_claw.ex` |
| Delete | `lib/druzhok/bot_config.ex` |
| Modify | `lib/druzhok/bot_manager.ex` |
| Modify | `lib/druzhok/health_monitor.ex` |
| Modify | `dashboard_live.ex` (runtime dropdown) |
