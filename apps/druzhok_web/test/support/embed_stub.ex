defmodule DruzhokWebWeb.EmbedStub do
  @moduledoc "Stands in for `Druzhok.Embed.Worker` in controller tests: one canned reply, records calls."

  def start(reply \\ {:ok, %{vectors: [[0.1, 0.2]], tokens: 3}}) do
    {:ok, pid} = Agent.start(fn -> %{reply: reply, calls: []} end)
    Application.put_env(:druzhok_web, :embed_module, __MODULE__)
    Application.put_env(:druzhok_web, :embed_stub, pid)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:druzhok_web, :embed_module)
      Application.delete_env(:druzhok_web, :embed_stub)
      Agent.stop(pid)
    end)

    pid
  end

  def reply(result), do: Agent.update(agent(), &%{&1 | reply: result})
  def calls, do: agent() |> Agent.get(& &1.calls) |> Enum.reverse()

  def embed(texts, _opts \\ []) do
    Agent.get_and_update(agent(), fn state -> {state.reply, %{state | calls: [texts | state.calls]}} end)
  end

  defp agent, do: Application.fetch_env!(:druzhok_web, :embed_stub)
end
