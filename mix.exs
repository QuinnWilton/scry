defmodule Scry.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/QuinnWilton/scry"

  def project do
    [
      app: :scry,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ],

      # Hex
      description:
        "Analysis-only Mix compiler for BEAM projects: incremental argus analyses via roux, " <>
          "reported as rich compiler diagnostics",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:roux, path: "../roux"},
      {:argus, path: "../argus"},
      {:gloss, path: "../gloss"},
      {:beam_spy, path: "../beam_spy"},
      {:pentiment, path: "../pentiment"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "Scry",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
