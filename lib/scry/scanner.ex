defmodule Scry.Scanner do
  @moduledoc """
  Beam discovery and change detection for the compiler driver.

  `scan/1` globs the project's ebin (and dependency ebins when
  `include_deps` is set) into a `module => beam_path` map, applying
  module-level ignores at discovery so ignored modules are never even
  extracted.

  `sync/3` diffs the scan against the previous run's source metadata and
  updates the roux inputs: an mtime+size match skips the file without
  reading it (mix-grade staleness, same trade as the Elixir compiler);
  anything else is read and content-hashed, and `Input.set`'s equality
  cutoff absorbs recompiled-but-identical beams. Modules whose beams are
  gone are GC'd out of the input space.
  """

  alias Roux.Database
  alias Roux.GC
  alias Roux.Input

  @typedoc "Per-beam manifest metadata: the mtime+size prefilter plus a content hash."
  @type meta :: %{mtime: integer(), size: non_neg_integer(), hash: binary()}

  @typedoc "The result of syncing a scan into the database."
  @type sync_result :: %{
          sources: %{optional(String.t()) => meta()},
          changed: [module()],
          removed: [module()]
        }

  @doc """
  Discovers the beams to analyze: `module => beam_path`.
  """
  @spec scan(Scry.Config.t()) :: %{optional(module()) => String.t()}
  def scan(%Scry.Config{} = config) do
    ebins =
      if config.include_deps do
        [Mix.Project.compile_path() | dep_ebins()]
      else
        [Mix.Project.compile_path()]
      end

    for ebin <- ebins,
        path <- Path.wildcard(Path.join(ebin, "*.beam")),
        module = module_of(path),
        not ignored_module?(module, config.ignore_modules),
        into: %{} do
      {module, path}
    end
  end

  @doc """
  Syncs a scan into the database inputs, diffing against the prior run's
  source metadata (the manifest's `sources` map). Returns the fresh
  metadata to persist, plus which modules changed or disappeared.
  """
  @spec sync(Database.t(), %{optional(module()) => String.t()}, %{
          optional(String.t()) => meta()
        }) :: sync_result()
  def sync(%Database{} = db, discovered, prior_sources) do
    now = System.os_time(:second)

    {sources, changed} =
      Enum.reduce(discovered, {%{}, []}, fn {module, path}, {sources, changed} ->
        case sync_one(db, module, path, Map.get(prior_sources, path), now) do
          {:unchanged, meta} -> {Map.put(sources, path, meta), changed}
          {:changed, meta} -> {Map.put(sources, path, meta), [module | changed]}
        end
      end)

    removed = mark_removed(db, discovered)

    module_set = discovered |> Map.keys() |> Enum.sort()
    :ok = Input.set(db, :module_set, :all, module_set)

    %{sources: sources, changed: Enum.sort(changed), removed: removed}
  end

  defp sync_one(db, module, path, prior, now) do
    %File.Stat{mtime: mtime, size: size} = File.stat!(path, time: :posix)

    case prior do
      %{mtime: ^mtime, size: ^size} when mtime < now - 1 ->
        # The prefilter: an untouched file is never read. Files written
        # within the last second are exempt — mtime has one-second
        # granularity, and scry runs moments after :elixir, so a
        # fast edit-compile-edit-compile sequence can rewrite a beam in
        # the same second with the same size. Recent files get
        # content-hashed; on a warm noop nothing is recent and nothing
        # is read.
        {:unchanged, prior}

      _ ->
        content = File.read!(path)
        hash = :erlang.md5(content)
        meta = %{mtime: mtime, size: size, hash: hash}

        # Equal hash means a touch or a byte-identical recompile: the
        # input value is unchanged, so Input.set's cutoff advances
        # nothing and the run stays a noop.
        changed? = not match?(%{hash: ^hash}, prior)
        :ok = Input.set(db, :beam_meta, module, %{path: path, hash: hash})

        if changed?, do: {:changed, meta}, else: {:unchanged, meta}
    end
  end

  defp mark_removed(db, discovered) do
    removed =
      for module <- Input.keys(db, :beam_meta),
          not Map.has_key?(discovered, module) do
        :ok = GC.mark_input_removed(db, :beam_meta, module)
        module
      end

    Enum.sort(removed)
  end

  # basename → module. `String.to_atom`, not `to_existing_atom`: the
  # env-scoped ebin the compiler chain just wrote is authoritative (this
  # is not `mix argus`'s cross-env glob), and the atom count is bounded
  # by project size.
  defp module_of(path) do
    path |> Path.basename(".beam") |> String.to_atom()
  end

  defp ignored_module?(module, patterns) do
    name = inspect(module)

    Enum.any?(patterns, fn
      %Regex{} = regex -> Regex.match?(regex, name)
      atom when is_atom(atom) -> atom == module
    end)
  end

  defp dep_ebins do
    Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    |> Enum.reject(&(&1 == Mix.Project.compile_path()))
  end
end
