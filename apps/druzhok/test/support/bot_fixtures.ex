defmodule Druzhok.BotFixtures do
  @moduledoc "Setup helpers for tests that create real instances and run fake_hermes.sh."

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]

  @doc "Point DRUZHOK_DATA_ROOT at a fresh tmp dir for the test; restore and delete on exit."
  def with_tmp_data_root do
    root = Path.join(System.tmp_dir!(), "druzhok-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = System.get_env("DRUZHOK_DATA_ROOT")
    System.put_env("DRUZHOK_DATA_ROOT", root)

    on_exit(fn ->
      if prev, do: System.put_env("DRUZHOK_DATA_ROOT", prev), else: System.delete_env("DRUZHOK_DATA_ROOT")
      File.rm_rf!(root)
    end)

    %{data_root: root}
  end

  @doc "Guarantee the bot's process and row are gone after the test, whatever happened."
  def cleanup_instance(name) do
    on_exit(fn ->
      Druzhok.Host.destroy(name)

      case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
        nil -> :ok
        inst -> Druzhok.Repo.delete(inst)
      end
    end)
  end

  @doc """
  Insert a bot row with an id inside the webhook port range (1-999; the test
  DB's autoincrement is far past it) and delete it, with its queue, on exit.
  """
  def relay_instance(attrs \\ %{}) do
    id = Map.get(attrs, :id) || 100 + rem(System.unique_integer([:positive]), 899)
    Druzhok.Repo.delete_all(from(i in Druzhok.Instance, where: i.id == ^id))

    instance =
      Druzhok.Repo.insert!(
        struct(
          Druzhok.Instance,
          Map.merge(
            %{id: id, name: "relay#{id}", model: "m", workspace: "/tmp/relay#{id}/workspace"},
            attrs
          )
        )
      )

    on_exit(fn -> Druzhok.Repo.delete_all(from(i in Druzhok.Instance, where: i.id == ^id)) end)
    instance
  end

  @doc """
  Run the lifecycle controller for this test (it carries out BotManager's
  requests). `scan: false`: it only looks after bots that are poked, never
  the other rows of the shared test DB.
  """
  def start_lifecycle do
    ExUnit.Callbacks.start_supervised!({Druzhok.Lifecycle, scan: false})
    :ok
  end

  @doc "Poll `fun` every 50 ms until it returns truthy or `tries` run out."
  def eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
