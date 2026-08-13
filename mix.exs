defmodule Acs.MixProject do
  use Mix.Project

  def project do
    [
      app: :steward_acs,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      releases: [
        steward_acs: [
          include_executables_for: [:unix],
          steps: [:assemble],
          validate_compile_env: false,
          strip_beams: [keep: ["Docs"]],
          applications: [opentelemetry_exporter: :permanent, opentelemetry: :temporary]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Acs.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The OTLP exporter must appear before the SDK so releases start it first.
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.3.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_logger_metadata, "~> 0.2.0"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22"},
      {:postgrex, "~> 0.19", only: [:prod]},
      {:jason, "~> 1.2"},
      {:req, "~> 0.6.3"},
      {:llm_utils, github: "NaharEmet/llm_utils_elixir", branch: "main"},
      {:dotenvy, "~> 1.0", override: true},
      {:yaml_elixir, "~> 2.9"},
      {:bandit, "~> 1.5"},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_pubsub, "~> 2.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.1"},
      {:file_system, "~> 1.0", override: true},
      {:esbuild, "~> 0.8", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:cors_plug, "~> 3.0"},
      {:jose, "~> 1.11"},
      {:assent, "~> 0.3.1"},
      # Optional production email (Resend) — enabled at runtime when RESEND_API_KEY is set
      {:swoosh, "~> 1.26"}
    ]
  end

  def cli do
    [
      preferred_envs: [test: :test, coveralls: :test, "coveralls.html": :test]
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      setup: ["deps.get", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"],
      coveralls: ["ecto.create --quiet", "ecto.migrate", "coveralls"],
      "coveralls.html": ["ecto.create --quiet", "ecto.migrate", "coveralls.html"],
      "assets.deploy": ["esbuild steward_acs --minify", "phx.digest"]
    ]
  end
end
