defmodule Fueltruck.MixProject do
  use Mix.Project

  def project do
    [
      app: :fueltruck,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  # The Discord deps are `runtime: false` so they don't auto-start (nostrum would
  # authenticate at boot). `:load` forces them — and their runtime deps like gun — into
  # the release, loaded but not started; we start nostrum ourselves when DISCORD_ENABLED.
  defp releases do
    [
      fueltruck: [
        applications: [nostrum: :load, nosedrum: :load]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Fueltruck.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:muontrap, "~> 1.5"},
      {:floki, "~> 0.36"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Discord integration (optional, gated behind DISCORD_ENABLED). nosedrum's hex
      # release pins nostrum ~> 0.8; only its master branch supports nostrum 0.10.
      # Discord integration (optional, gated behind DISCORD_ENABLED). nostrum's
      # Shard.Supervisor authenticates to Discord at boot, so letting it auto-start
      # would crash the VM without valid creds. nosedrum (a no-`mod:` library) lists
      # nostrum in its own `applications`, so BOTH must be runtime: false to break the
      # auto-start cascade; we start nostrum ourselves only when DISCORD_ENABLED (see
      # Fueltruck.Application) and their modules stay on the code path for direct use.
      # nosedrum's hex release pins nostrum ~> 0.8; only its master branch supports 0.10.
      {:nostrum, "~> 0.10", runtime: false, override: true},
      {:nosedrum, github: "jchristgit/nosedrum", runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind fueltruck", "esbuild fueltruck"],
      "assets.deploy": [
        "tailwind fueltruck --minify",
        "esbuild fueltruck --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
