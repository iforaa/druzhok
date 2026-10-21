defmodule Mix.Tasks.Druzhok do
  @shortdoc "Operator CLI: mix druzhok help"
  @moduledoc "Runs `Druzhok.CLI` against the dev database. On the server use `sudo ops/druzhok`."
  use Mix.Task

  @impl true
  def run(args) do
    Application.put_env(:druzhok, :manager_bot, false)
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    case Druzhok.CLI.main(args) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
