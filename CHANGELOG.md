# Changelog

## 0.1.12 — 2026-09-12

- Fixes 0.1.11, which listed the `Argus.Extractors.Ports` extractor argus
  0.8.0 folded into `Argus.Extractors.ApiCalls`; every extraction raised
  `UndefinedFunctionError`. The resource extractors the supervision-tree
  overlay needs are now `ETS` and `ApiCalls`.

## 0.1.11 — 2026-09-12

- Argus 0.8.0 (schema 30): the consolidation release. No finding scry
  reports changes except the ETS false positive it fixes on Erlang
  application modules; extraction is 9-37% faster on the corpus.

## 0.1.10 — 2026-09-11

- Pins argus v0.7.3. 0.1.9 said it did and still pinned v0.7.2; a
  project depending on both scry and a newer argus saw a divergence.

## 0.1.9 — 2026-09-11

- Elixir requirement lowered to `~> 1.18` (roux v0.1.1, argus 0.7.3);
  OTP 28 remains required. The compiler's fixture projects declare the
  same.

## 0.1.8 — 2026-09-11

- Argus 0.7.2: `init_waits_on_blocking_server` counts only unbounded
  handler operations; `permanent_child_stops_normally` and inferred
  `rest_for_one_orphaned_children` rows are `:info`.

## 0.1.7 — 2026-09-11

- Argus 0.7.1 (schema 28): `monitor_leak` reports a monitor whose ref is
  discarded at the call site, and reaches helpers through closures.

## 0.1.6 — 2026-09-11

- Argus 0.7.0 (schema 27): ten new rules from replaying historical OTP
  bug fixes — supervisor management calls from `init/1`, an init waiting
  on a server whose handler blocks, permanent children that stop
  themselves, `rest_for_one` owners of processes in earlier siblings,
  `trap_exit` without an `{:EXIT, ...}` clause, `handle_info/2` without a
  catch-all, monitors a server never releases, write-only ETS tables,
  gen_statem states without an `:info` catch-all and timeouts nobody
  handles. Trees built with `Keyword.get/3` defaults and cons-built child
  lists extract in source order.

## 0.1.5 — 2026-09-11

- Argus 0.6.1: supervision trees defined outside `Supervisor` modules
  (a GenServer's `init/1` calling `Supervisor.start_link/2`) and child
  specs built by helpers and comprehensions are extracted, so more
  `sync_call_in_init` findings are proven safe by an earlier sibling.

## 0.1.4 — 2026-09-11

- Argus 0.6.0: stage 0 now also yields `unconditional_call_edge`, which
  the fact projections carry like `call_edge` and `call_site`;
  `sync_call_in_init` findings say whether the blocking call is
  conditional on a branch in `init/1`.

## 0.1.3 — 2026-09-11

- Argus 0.5.1: literal facts drop Logger location metadata (a comment
  above a `Logger.warning` no longer re-solves analyses), coupling
  findings are graded call vs cast, unverified `sync_call_in_init` rows
  are `:info`, and any module with `handle_info/2` counts as consuming
  its task replies.
- Beams are hashed and memoized in canonical form (`Scry.Beam.canonical/1`
  drops the `ExCk` and `Docs` chunks). Elixir rewrites the `ExCk` chunk of
  every compile-time dependent when a module is recompiled, so a
  comment-only edit re-extracted two to six modules on the projects
  surveyed (Finch, Postgrex, Oban, Cachex, ...) before the semantic
  cutoff caught them; now it re-extracts exactly the edited one.

## 0.1.2 — 2026-09-11

- `mix scry` compiles with `--no-prune-code-paths`. In a project with an
  explicit `applications:` list, Mix's code-path pruning removed scry
  itself after the compile step and the task died with `Scry.Config is
  not available` (found on `amqp`). The `:scry` compiler in such projects
  needs `prune_code_paths: false`; the README says so.

## 0.1.1 — 2026-09-11

- `makeup_elixir` and `makeup_erlang` are optional dependencies. A hard
  dependency collided with the `only: :docs` / `only: :dev` restriction
  projects put on the makeup lexers (Phoenix declares them that way, and
  ex_doc pulls them in `only: :dev` everywhere else), which made scry
  impossible to add to such a project. Add the lexers to your own deps to
  keep highlighted terminal frames; without them frames render plain.

## 0.1.0 — 2026-09-11

Initial release: an analysis-only Mix compiler for BEAM projects.

- **Scry is the compiler and the shared analysis layer, nothing more**:
  the supervision tree, flowistry focus/slicing, and the debug twin
  (`Scry.SupTree`, `Scry.Flow`, `Scry.DebugSlice`, and the
  `supervision_tree`, `refined_line_table`, `debug_twin`,
  `debug_bundle`, `module_flow`, `function_flow` queries) moved to
  planchette, whose LSP is their only consumer and the only frontend
  that supplies the `source_text` input they need. Query names are
  unchanged, so planchette manifests stay warm. Scry no longer depends
  on gloss or beam_spy.
- **Extraction memos follow the argus schema**: `module_extraction`
  now reads `env_fingerprint` (which carries `Argus.Schema.version/0`),
  so a warm manifest re-extracts after an argus upgrade instead of
  serving rows the previous encoder wrote. The compile-time
  `Argus.Schema.Pin` is gone with it — argus removed the mechanism.
- **Labels span the line's code**: finding anchors render as inline
  labels under the anchored line's code extent (first non-blank column
  to the end of the trimmed line) instead of column-1 bracket labels.
  BEAM anchors are still line-granular; a source line that cannot be
  read degrades to a one-column span.

- **Syntax-highlighted terminal diagnostics**: the stderr frames now
  colorize their source excerpts (via pentiment's optional makeup
  lexers, included as scry dependencies). The `details` field on
  `Mix.Task.Compiler.Diagnostic` and the sidecar remain plain text.

- **The shared analysis layer**, extracted verbatim from planchette:
  `Scry.Analysis` (per-module argus extraction → semantic-facts cutoff
  seam → per-relation projections → content-addressed Souffle fact
  dirs → solve → line-free findings → late line resolution). Query
  names are the ABI — planchette's LSP consumes the same layer with its
  in-memory compile frontend. `souffle_solve` re-materializes its fact
  directory when a concurrent prune removed it (the scratch window is
  shared between LSP sessions and compiler runs).
- **`mix compile.scry`** (`compilers: Mix.compilers() ++ [:scry]`): a
  disk-beam roux frontend over the ebin the stock compilers just
  wrote, with cross-run incrementality via `Roux.Lang.Manifest` — a
  warm run re-analyzes nothing, a comment-only edit re-extracts one
  module and re-runs zero solves, and prior findings re-emit from memo
  hits on every run. Configuration under the `scry:` project key:
  `analyses`, per-analysis `severity` overrides, `ignore`
  (modules/files), `include_deps`, `fail_on`, and `souffle`
  (`:warn` degrades with one notice and demands no solves — nothing
  poisons the manifest, and the souffle version in the environment
  fingerprint heals everything when the solver appears; `:require`
  makes it an error).
- **Pentiment-rendered diagnostics**: labels on the line-granular
  anchors annotated with the finding's `at_label`,
  cross-file evidence as `├─` continuation frames against their own
  files, detail as a note, and `help` remediation trailers. Editors
  get a short message + line via the standard compiler diagnostics;
  terminals get the full frame.
- **`mix scry`**: the credo-style one-shot over the same manifest —
  positional analysis selection, `--all`, `--list`, `--format json`
  (stable machine schema), `--fail-above N`, `--include-deps`,
  `--force`.
