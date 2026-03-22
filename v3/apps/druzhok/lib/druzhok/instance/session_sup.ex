defmodule Druzhok.Instance.SessionSup do
  @moduledoc """
  DynamicSupervisor for per-chat PiCore.Session processes within an instance.
  Sessions are started on demand when a message arrives for a new chat_id.
  """
  use DynamicSupervisor

  def start_link(opts) do
    case opts[:registry_name] do
      nil -> DynamicSupervisor.start_link(__MODULE__, opts)
      name -> DynamicSupervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a session for the given chat_id, or return the existing one.
  Session config is read from :persistent_term (stored by Instance.Sup).
  """
  def start_session(instance_name, chat_id, extra_opts \\ %{}) do
    base_config = :persistent_term.get({:druzhok_session_config, instance_name}, nil)

    if base_config do
      case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
        [{existing, _}] ->
          {:ok, existing}

        [] ->
          case Registry.lookup(Druzhok.Registry, {instance_name, :session_sup}) do
            [{sup_pid, _}] ->
              session_opts = Map.merge(base_config, extra_opts)
              session_opts = Map.merge(session_opts, %{
                name: {:via, Registry, {Druzhok.Registry, {instance_name, :session, chat_id}}},
                chat_id: chat_id,
              })
              DynamicSupervisor.start_child(sup_pid, {PiCore.Session, session_opts})

            [] ->
              {:error, :session_sup_not_found}
          end
      end
    else
      {:error, :no_config}
    end
  end
end
