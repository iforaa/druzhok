defmodule Druzhok.Runtime do
  @moduledoc """
  Behaviour for bot runtime adapters. Each supported runtime (Hermes, ZeroClaw,
  PicoClaw, OpenClaw, NullClaw) implements this behaviour. Adding a new runtime
  = one new module + one registry entry.
  """

  @type instance :: map()
  @type workspace_file ::
          {path :: String.t(), content :: String.t()}
          | {path :: String.t(), content :: String.t(), :always | :create_only}

  @callback env_vars(instance) :: %{String.t() => String.t()}
  @callback workspace_files(instance) :: [workspace_file()]
  @callback sync_config(instance, data_root :: String.t()) :: :ok | {:error, term()}
  @callback docker_image() :: String.t()
  @callback gateway_command() :: String.t() | [String.t()]
  @callback data_mount_path() :: String.t()
  @callback file_browser_root(instance) :: String.t()
  @callback post_start(instance) :: :ok | {:error, term()}
  @callback supports_feature?(atom()) :: boolean()
  @callback read_allowed_users(data_root :: String.t()) :: [String.t()]
  @callback add_allowed_user(data_root :: String.t(), user_id :: String.t()) :: :ok | {:error, term()}
  @callback remove_allowed_user(data_root :: String.t(), user_id :: String.t()) :: :ok | {:error, term()}
  @callback clear_sessions(data_root :: String.t()) :: :ok
  @callback parse_log_rejection(line :: String.t()) :: {:rejected, user_id :: String.t()} | :ignore

  @optional_callbacks sync_config: 2

  @runtimes %{
    "hermes" => Druzhok.Runtime.Hermes,
    "zeroclaw" => Druzhok.Runtime.ZeroClaw,
    "picoclaw" => Druzhok.Runtime.PicoClaw,
    "openclaw" => Druzhok.Runtime.OpenClaw,
    "nullclaw" => Druzhok.Runtime.NullClaw,
  }

  def get(name) do
    Map.fetch!(@runtimes, to_string(name))
  end

  def get(name, default) do
    Map.get(@runtimes, to_string(name), default)
  end

  def list, do: @runtimes
  def names, do: Map.keys(@runtimes)

  def parse_user_input(input) do
    trimmed = String.trim(input)
    cond do
      String.contains?(trimmed, "bind-telegram") ->
        trimmed |> String.split() |> List.last()
      true ->
        trimmed
    end
  end

  def proxy_host, do: System.get_env("LLM_PROXY_HOST") || "host.docker.internal"

  def base_env(instance) do
    proxy_host = proxy_host()
    proxy_port = System.get_env("LLM_PROXY_PORT") || "4000"

    tenant_key = Map.get(instance, :tenant_key, "") || ""
    %{
      "OPENAI_BASE_URL" => "http://#{proxy_host}:#{proxy_port}/v1",
      "OPENAI_API_KEY" => tenant_key,
      "ZEROCLAW_API_KEY" => tenant_key,
      "API_KEY" => tenant_key,
      "TZ" => Map.get(instance, :timezone, "UTC") || "UTC",
    }
  end
end
