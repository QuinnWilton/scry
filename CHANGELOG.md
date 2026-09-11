# Changelog

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
