defmodule Druzhok.BotFixtures do
  @moduledoc "Setup helpers for tests that create real instances and run fake_hermes.sh."

  import ExUnit.Callbacks, only: [on_exit: 1]

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
      Druzhok.HealthMonitor.unregister(name)

      case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
        nil -> :ok
        inst -> Druzhok.Repo.delete(inst)
      end
    end)
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
