defmodule Scry.Test.EusapiaFixture do
  @moduledoc """
  Checks out a dependency-free copy of eusapia (the keynote patient)
  with scry appended to its compilers, so the full `mix compile` chain —
  `:elixir` producing beams, `:scry` analyzing them — runs against a
  real project with known findings.

  Known argus goldens for the pristine copy (verified against batch
  `scripts/analyze_project.exs`, 2026-07-16, and re-verified through
  this suite): `one_for_one_coupling: 2` (anchored at the tree
  definition in application.ex), `supervision: 0`, `unsafe_task
  (leaked_async_task): 1`.

  The scry compiler task itself is resolved from THIS test VM (the host
  app), so the fixture needs no dependency on scry.
  """

  @eusapia Path.expand("../../../eusapia", __DIR__)

  @doc """
  Copies eusapia into `dest` (wiped first) and returns `dest`.

  `scry_config` is rendered into the fixture's `scry:` project keyword.
  Accord-dependent files are excluded — the fixture's premise is a
  dependency-free patient.
  """
  @spec checkout!(Path.t(), keyword()) :: Path.t()
  def checkout!(dest, scry_config \\ []) do
    File.rm_rf!(dest)
    File.mkdir_p!(dest)
    File.cp_r!(Path.join(@eusapia, "lib"), Path.join(dest, "lib"))

    dest
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.filter(&String.contains?(File.read!(&1), "Accord."))
    |> Enum.each(&File.rm!/1)

    write_mix_exs!(dest, scry_config)

    dest
  end

  @doc """
  Rewrites the fixture's mix.exs with a different `scry:` config
  (between runs of an already-checked-out fixture).
  """
  @spec write_mix_exs!(Path.t(), keyword()) :: :ok
  def write_mix_exs!(dest, scry_config) do
    File.write!(Path.join(dest, "mix.exs"), """
    defmodule Eusapia.MixProject do
      use Mix.Project

      def project do
        [
          app: :eusapia,
          version: "0.1.0",
          elixir: "~> 1.19",
          start_permanent: false,
          compilers: Mix.compilers() ++ [:scry],
          scry: #{inspect(scry_config, limit: :infinity)},
          deps: []
        ]
      end

      def application do
        [extra_applications: [:logger], mod: {Eusapia.Application, []}]
      end
    end
    """)

    :ok
  end
end
