defmodule Druzhok.MixProject do
  use Mix.Project

  def project do
    [
      app: :druzhok,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Regression gate for `mix test --cover`; raise it as coverage grows.
      test_coverage: [summary: [threshold: 70]],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Druzhok.Application, []}
    ]
  end

  # test/support holds the Telegram stub and bot fixtures.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:bypass, "~> 2.1", only: :test},
      {:yaml_elixir, "~> 2.11", only: :test},
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:finch, "~> 0.18"},
      {:tz, "~> 0.28"},
    ]
  end
end
