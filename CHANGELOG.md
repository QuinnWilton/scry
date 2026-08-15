# Changelog

## Unreleased

Initial release: an analysis-only Mix compiler for BEAM projects.

- **Syntax-highlighted terminal diagnostics**: the stderr frames now
  colorize their source excerpts (via pentiment's optional makeup
  lexers, included as scry dependencies). The `details` field on
  `Mix.Task.Compiler.Diagnostic` and the sidecar remain plain text.

- **The shared analysis layer**, extracted verbatim from planchette:
  `Scry.Analysis` (per-module argus extraction → semantic-facts cutoff
  seam → per-relation projections → content-addressed Souffle fact
  dirs → solve → line-free findings → late line resolution), plus
  `Scry.SupTree`, `Scry.Flow`, and `Scry.DebugSlice`. Query names are
  the ABI — planchette's LSP consumes the same layer with its
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
- **Pentiment-rendered diagnostics**: bracket labels on the
  line-granular anchors annotated with the finding's `at_label`,
  cross-file evidence as `├─` continuation frames against their own
  files, detail as a note, and `help` remediation trailers. Editors
  get a short message + line via the standard compiler diagnostics;
  terminals get the full frame.
- **`mix scry`**: the credo-style one-shot over the same manifest —
  positional analysis selection, `--all`, `--list`, `--format json`
  (stable machine schema), `--fail-above N`, `--include-deps`,
  `--force`.
