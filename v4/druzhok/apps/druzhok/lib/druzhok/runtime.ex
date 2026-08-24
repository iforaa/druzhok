defmodule Druzhok.Runtime do
  @moduledoc """
  Behaviour for bot runtime adapters. Hermes is the only runtime; the
  behaviour stays so config/workspace generation is cleanly separated
  from process control (see `Druzhok.Host`).
  """

  @type instance :: map()
  @type workspace_file ::
          {path :: String.t(), content :: String.t()}
          | {path :: String.t(), content :: String.t(), :always | :create_only}

  @callback env_vars(instance) :: %{String.t() => String.t()}
  @callback workspace_files(instance) :: [workspace_file()]
  @callback sync_config(instance, data_root :: String.t()) :: :ok | {:error, term()}
  @callback data_root(instance) :: String.t()
  @callback supports_feature?(atom()) :: boolean()
  @callback read_allowed_users(data_root :: String.t()) :: [String.t()]
  @callback add_allowed_user(data_root :: String.t(), user_id :: String.t()) :: :ok | {:error, term()}
  @callback remove_allowed_user(data_root :: String.t(), user_id :: String.t()) :: :ok | {:error, term()}
  @callback clear_sessions(data_root :: String.t()) :: :ok

  @doc "Runtime adapter for an instance (map or struct). Hermes is the only one."
  def for_instance(_instance), do: Druzhok.Runtime.Hermes

  def parse_user_input(input) do
    trimmed = String.trim(input)
    cond do
      String.contains?(trimmed, "bind-telegram") ->
        trimmed |> String.split() |> List.last()
      true ->
        trimmed
    end
  end

  @doc "Base URL of Druzhok's OpenAI-compatible proxy, as seen by bots and probes."
  def proxy_url do
    host = System.get_env("LLM_PROXY_HOST") || "127.0.0.1"
    port = System.get_env("LLM_PROXY_PORT") || "4000"
    "http://#{host}:#{port}/v1"
  end

  def base_env(instance) do
    %{
      "OPENAI_BASE_URL" => proxy_url(),
      "OPENAI_API_KEY" => Map.get(instance, :tenant_key, "") || "",
      "TZ" => Map.get(instance, :timezone, "UTC") || "UTC"
    }
  end
end
