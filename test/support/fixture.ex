defmodule Scry.Test.Fixture do
  @moduledoc """
  Checks out the fixture project under `test/fixtures/depot` with scry
  appended to its compilers, so the full `mix compile` chain —
  `:elixir` producing beams, `:scry` analyzing them — runs against a
  real project with known findings.

  Goldens for the pristine checkout, from the default analysis set:
  `one_for_one_coupling: 2` (Queue and Sonar against Notifier, anchored
  at the tree definition in application.ex), `unsafe_task: 1` (the
  leaked task in archive.ex), nothing else.

  The scry compiler task itself is resolved from THIS test VM (the host
  app), so the fixture needs no dependency on scry.
  """

  @fixture Path.expand("../fixtures/depot", __DIR__)

  @doc """
  Copies the fixture into `dest` (wiped first) and returns `dest`.

  `scry_config` is rendered into the fixture's `scry:` project keyword.
  `app` must be UNIQUE per distinct config in one test VM:
  `Mix.Project.in_project/3` caches loaded projects by app atom, so two
  fixtures sharing an app name silently share the first one's config.
  """
  @spec checkout!(Path.t(), keyword(), atom()) :: Path.t()
  def checkout!(dest, scry_config \\ [], app \\ :depot) do
    File.rm_rf!(dest)
    File.mkdir_p!(dest)
    File.cp_r!(Path.join(@fixture, "lib"), Path.join(dest, "lib"))
    write_mix_exs!(dest, scry_config, app)
    dest
  end

  @doc """
  Rewrites the fixture's mix.exs with a different `scry:` config
  (between runs of an already-checked-out fixture).
  """
  @spec write_mix_exs!(Path.t(), keyword(), atom()) :: :ok
  def write_mix_exs!(dest, scry_config, app \\ :depot) do
    File.write!(Path.join(dest, "mix.exs"), """
    defmodule #{Macro.camelize(to_string(app))}.MixProject do
      use Mix.Project

      def project do
        [
          app: #{inspect(app)},
          version: "0.1.0",
          elixir: "~> 1.18",
          start_permanent: false,
          compilers: Mix.compilers() ++ [:scry],
          scry: #{inspect(scry_config, limit: :infinity)},
          deps: []
        ]
      end

      def application do
        [extra_applications: [:logger], mod: {Depot.Application, []}]
      end
    end
    """)

    :ok
  end
end
