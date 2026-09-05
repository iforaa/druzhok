defmodule DruzhokWebWeb.FetchStub do
  @moduledoc """
  Stands in for `Druzhok.Fetch` in controller tests: answers per URL from an
  Agent the test fills with `reply/2`, records every call.
  """

  def start do
    {:ok, pid} = Agent.start(fn -> %{replies: %{}, calls: []} end)
    Application.put_env(:druzhok_web, :fetch_module, __MODULE__)
    Application.put_env(:druzhok_web, :fetch_stub, pid)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:druzhok_web, :fetch_module)
      Application.delete_env(:druzhok_web, :fetch_stub)
      Agent.stop(pid)
    end)

    pid
  end

  def reply(url, result), do: Agent.update(agent(), &put_in(&1, [:replies, url], result))
  def calls, do: agent() |> Agent.get(& &1.calls) |> Enum.reverse()

  def fetch(url, _opts \\ []) do
    Agent.get_and_update(agent(), fn state ->
      {Map.get(state.replies, url, {:error, :unreachable, %{}}), %{state | calls: [url | state.calls]}}
    end)
  end

  defp agent, do: Application.fetch_env!(:druzhok_web, :fetch_stub)
end
