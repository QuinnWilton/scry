# scry

This project inherits all shared conventions from the top-level CLAUDE.md.

Analysis-only Mix compiler for BEAM projects: incremental argus analyses
via roux, reported as rich compiler diagnostics.

## What it does

Scry runs **after** `:elixir` (`compilers: Mix.compilers() ++ [:scry]`),
reads the `.beam` files the stock compiler produced, and runs argus's
Datalog analyses over them through a roux query graph. Findings are
`Mix.Task.Compiler.Diagnostic` structs whose `details` carry a rendered
pentiment frame (responsible lines, cross-file evidence as continuation
frames, `help:` remediation). Cross-run incrementality comes from
`Roux.Lang.Manifest`: a comment-only edit re-extracts one module and
re-runs zero Souffle solves.

Scry also hosts the **shared analysis layer** (`Scry.Analysis`,
extracted from planchette): the frontend-agnostic roux query pipeline
per-module extraction → semantic facts (line_info split out — THE
early-cutoff seam) → per-relation projections → per-analysis
content-addressed Souffle fact dirs → solve → line-free findings → late
line resolution. Planchette consumes it for the LSP with its own
in-memory compile frontend; scry drives it with a disk-beam frontend.

## Architecture

Two layers over one `Roux.Database`:

1. **Frontend** (`Scry.Frontend`): inputs `beam_meta` (module →
   %{path, mtime, size, hash}, :medium), `module_set`, `env_fingerprint`
   (:high); queries `module_beam` (disk read; the tracked signal is the
   hash input), `file_of` (beam compile_info source, realpath-normalized),
   `module_map`. Registers the same query names as planchette's frontend —
   **query names are the ABI** (roux dispatches by name; memo keys are
   {query_name, key}).
2. **Analysis** (`Scry.Analysis` + `Scry.SupTree`/`Scry.Flow`/
   `Scry.DebugSlice`, moved verbatim from planchette): never rename a
   query, never change a key or value shape without planchette in the
   same review. Schema coupling is pinned via `use Argus.Schema.Pin`.

Driver side (never inside queries): `Scry.Scanner` (beam discovery +
mtime/size/hash diff vs manifest sources), `Scry.Runner` (db lifecycle,
warm start, input sync, souffle check, demand), `Scry.Diagnostics`
(resolved finding → Pentiment.Report → Diagnostic; printing; sidecar for
`diagnostics/0`), `Mix.Tasks.Compile.Scry`, `Mix.Tasks.Scry`.

Key invariants:

- **Durability**: never introduce `:low` anywhere in the input→facts
  chain — durability propagates as the min and `:low` derived memos are
  dropped from the manifest (the fact memos are the bulk of the win).
- **Query values must survive `term_to_binary`** (manifest persistence).
- **Artifact emission and rendering are driver work** from query values,
  never query side effects.
- Souffle missing + `souffle: :warn`: never demand solves (no error
  memos poison the manifest); the souffle version lives in
  `env_fingerprint` so installing it heals everything.
- Souffle scratch root `scry_souffle` is shared with planchette's LSP
  sessions (content-addressed, staged+renamed); `souffle_solve` guards
  with a `File.dir?/1` re-materialize check.

## Development commands

```bash
mix test                      # run all tests
mix format                    # format code
mix format --check-formatted  # check formatting
mix credo --strict            # lint
mix dialyzer                  # static analysis
```

Souffle-dependent tests are tagged `:souffle` and need a `souffle`
binary on PATH.

## Commit message style

```
[component] brief description

Optional longer explanation.
```

## Testing conventions

- Unit tests mirror `lib/` structure in `test/`.
- Test support modules go in `test/support/`.
- Use `stream_data` for property-based testing.
- Compiler tests drive a fixture project checked out to a tmp dir via
  `Mix.Project.in_project/3` + `Mix.Task.rerun("compile")` — the real
  chain, so `:elixir` genuinely produces the beams scry reads.
- Telemetry edit-replay tests assert exact recompute sets (the QueryLog
  pattern from planchette).

## Non-goals (v1, keep the README honest)

Umbrella-wide analysis (per-app only; `include_deps: true` is the
escape hatch), parallel solves, incremental Datalog, focus/slicing in
the compiler (the queries exist for planchette's LSP; scry never
demands them).

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an
`## Unreleased` section at the top.
