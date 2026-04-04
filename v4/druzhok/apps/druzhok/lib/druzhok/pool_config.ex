defmodule Druzhok.PoolConfig do
  @moduledoc "Generates OpenClaw multi-agent JSON config for a pool of instances."

  @default_port 18800

  @doc """
  Builds a multi-agent OpenClaw JSON config map for the given list of instances.

  Each instance must have: name, model, on_demand_model, tenant_key, telegram_token, workspace.

  Options:
    - `:port` — gateway port (default #{@default_port})

  Returns a map suitable for `Jason.encode!/1`.
  """
  def build(instances, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    proxy_host = Druzhok.Runtime.proxy_host()

    %{
      "gateway" => %{
        "bind" => "loopback",
        "port" => port,
        "reload" => %{"mode" => "hybrid"},
        "auth" => %{"mode" => "none"}
      },
      "session" => %{
        "dmScope" => "per-channel-peer"
      },
      "models" => %{
        "providers" => build_providers(instances, proxy_host)
      },
      "agents" => %{
        "defaults" => %{"sandbox" => %{"mode" => "off"}},
        "list" => build_agent_list(instances)
      },
      "channels" => %{
        "telegram" => %{
          "accounts" => build_telegram_accounts(instances)
        }
      },
      "bindings" => build_bindings(instances)
    }
  end

  defp build_providers(instances, proxy_host) do
    Map.new(instances, fn instance ->
      name = instance.name
      provider_id = "tenant-#{name}"

      provider = %{
        "baseUrl" => "http://#{proxy_host}:4000/v1",
        "apiKey" => instance.tenant_key,
        "api" => "openai-completions",
        "models" => build_model_list(instance.model, instance.on_demand_model)
      }

      {provider_id, provider}
    end)
  end

  defp build_model_list(model, nil) do
    [%{"id" => model, "name" => "default"}]
  end

  defp build_model_list(model, on_demand_model) do
    [
      %{"id" => model, "name" => "default"},
      %{"id" => on_demand_model, "name" => "smart"}
    ]
  end

  defp build_agent_list(instances) do
    Enum.map(instances, fn instance ->
      name = instance.name
      %{
        "id" => name,
        "model" => "tenant-#{name}/#{instance.model}",
        "workspace" => "/data/workspaces/#{name}"
      }
    end)
  end

  defp build_telegram_accounts(instances) do
    Map.new(instances, fn instance ->
      allowed = build_allow_from(instance)
      groups = build_group_config(instance)

      account = %{
        "botToken" => instance.telegram_token,
        "dmPolicy" => "pairing",
        "allowFrom" => allowed,
        "groupPolicy" => "open"
      }

      account = if map_size(groups) > 0 do
        Map.put(account, "groups", groups)
      else
        account
      end

      {instance.name, account}
    end)
  end

  defp build_allow_from(instance) do
    owner = case Map.get(instance, :owner_telegram_id) do
      nil -> []
      id -> [to_string(id)]
    end

    db_ids = Druzhok.Instance.get_allowed_ids(instance)

    (owner ++ db_ids) |> Enum.uniq()
  end

  defp build_group_config(instance) do
    case Map.get(instance, :name) do
      nil -> %{}
      name ->
        Druzhok.AllowedChat.groups_for_instance(name)
        |> Enum.filter(&(&1.status == "approved"))
        |> Map.new(fn chat ->
          {to_string(chat.chat_id), %{
            "enabled" => true,
            "groupPolicy" => "open"
          }}
        end)
    end
  end

  defp build_bindings(instances) do
    Enum.map(instances, fn instance ->
      %{
        "agentId" => instance.name,
        "match" => %{
          "channel" => "telegram",
          "accountId" => instance.name
        }
      }
    end)
  end
end
