defmodule Scry.Frontend do
  @moduledoc """
  The disk-beam roux frontend: `Scry.Analysis`'s frontend contract,
  satisfied from the `.beam` files the stock compilers just produced.

  Registers the same query names as planchette's in-memory compile
  frontend — roux dispatches by name, so the shared analysis layer works
  over either without change. What this frontend provides:

  - `:beam_meta` input — `module => %{path, hash}`. The driver
    (`Scry.Scanner`) sets it from an mtime/size-prefiltered scan, hashing
    content only for files that moved; a recompiled-but-identical beam
    produces an equal value and advances nothing.
  - `:module_set` input — `:all => sorted [module]`, the project's
    analyzed modules.
  - `:env_fingerprint` input — `:all =>` toolchain/rule-environment map
    (`Scry.Runner` builds it); `:high` durability so an upgrade
    invalidates the whole graph.
  - `:module_beam` query — beam bytes, read from disk. The read itself is
    untracked; the tracked signal is the `:beam_meta` value, and roux's
    early cutoff backdates downstream work when re-read bytes compare
    equal (a `touch` re-reads one file and recomputes nothing else).
  - `:module_source` / `:module_map` / `:file_of` queries — source
    attribution from each beam's `compile_info`.

  Durability: everything here is `:medium` or `:high` — never `:low`.
  Durability propagates as the minimum over dependencies, and `:low`
  derived memos are dropped from the manifest, which would evict the
  fact memos that make warm starts worth having.

  The focus/slicing surface of `Scry.Analysis` additionally wants
  `:source_text` and `:declared_modules`; this frontend deliberately
  does not provide them — the compiler never demands those queries, and
  roux is demand-driven, so their absence costs nothing.
  """

  use Roux.Query

  alias Roux.Runtime

  definput(:beam_meta, durability: :medium)
  definput(:module_set, durability: :medium)
  definput(:env_fingerprint, durability: :high)

  defquery :module_beam, key: module, returns: {:ok, binary()} | :external | {:error, term()} do
    case Runtime.input(db, :beam_meta, module) do
      nil ->
        # Not a scanned module: a related anchor pointing outside the
        # project. The shared layer matches on this exact atom.
        :external

      %{path: path} ->
        case File.read(path) do
          {:ok, beam} -> {:ok, beam}
          {:error, reason} -> {:error, {:beam_read, module, reason}}
        end
    end
  end

  # The source path a module's diagnostics anchor to, from the beam's own
  # compile_info. Per-module so that a beam edit recomputes one path,
  # compares equal, and backdates — module_map above it then validates
  # without executing.
  defquery :module_source, key: module, returns: String.t() | :external do
    case Runtime.input(db, :beam_meta, module) do
      nil ->
        :external

      %{path: beam_path} ->
        case Runtime.query(db, :module_beam, module) do
          {:ok, beam} -> source_path(beam, beam_path)
          _other -> :external
        end
    end
  end

  defquery :module_map, key: :all, returns: %{optional(module()) => String.t()} do
    for module <- Runtime.input!(db, :module_set, :all),
        path = Runtime.query(db, :module_source, module),
        path != :external,
        into: %{} do
      {module, path}
    end
  end

  # Per-module projection of module_map — the shape the shared layer's
  # anchor resolution demands. `:external` for anything outside the map.
  defquery :file_of, key: module, returns: String.t() | :external do
    Map.get(Runtime.query(db, :module_map, :all), module, :external)
  end

  # The compiler recorded the source absolute-at-compile-time; when the
  # file no longer exists there (moved checkout, stripped compile_info),
  # fall back to the beam path itself — a visible, honest anchor beats
  # silently dropping the module's findings (its facts still feed every
  # cross-module analysis either way).
  defp source_path(beam, beam_path) do
    with {:ok, {_mod, [compile_info: info]}} <- :beam_lib.chunks(beam, [:compile_info]),
         source when is_list(source) <- Keyword.get(info, :source, :missing),
         path = Path.expand(to_string(source)),
         true <- File.exists?(path) do
      path
    else
      _ -> beam_path
    end
  end
end
