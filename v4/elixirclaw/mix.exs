defmodule ElixirClaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixirclaw,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirClaw.Application, []}
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:plug, "~> 1.16"},
    ]
  end
end
