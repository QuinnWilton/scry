# scry

[![CI](https://github.com/QuinnWilton/scry/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/scry/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/scry.svg)](https://hex.pm/packages/scry)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/scry)

Analysis-only Mix compiler for BEAM projects: incremental [argus](https://github.com/QuinnWilton/argus)
analyses via [roux](https://github.com/QuinnWilton/roux), reported as rich compiler diagnostics.

Scry runs **after** the Elixir compiler, reads the `.beam` files it produced, and
runs argus's Datalog analyses over them — supervision-tree anti-patterns, leaked
tasks, deadlock-prone call cycles, unsafe deserialization, and more. Findings
flow through the standard Mix compiler diagnostics infrastructure (editors and
CI see them like any compiler warning) and render as
[pentiment](https://github.com/QuinnWilton/pentiment) frames that show the
responsible lines, connected evidence in other files, and how to fix the issue.

Fact extraction and Datalog solving are incremental: results are memoized in a
roux database persisted across `mix compile` runs, so a comment-only edit
re-extracts one module and re-runs zero analyses.

## Installation

Add scry in **all** environments with `runtime: false` (an `only:` dep breaks
`MIX_ENV=prod mix compile`, because `compilers:` would reference a missing
task; `runtime: false` keeps scry out of releases):

```elixir
def project do
  [
    # ...
    compilers: Mix.compilers() ++ [:scry]
  ]
end

def deps do
  [
    {:scry, "~> 0.1.0", runtime: false}
  ]
end
```

Solving requires a [Souffle](https://souffle-lang.github.io/) binary on
`PATH`. Without one, scry skips analyses and emits a single notice (set
`scry: [souffle: :require]` to make it a hard error instead).

## Usage

`mix compile` now reports findings. Configuration lives under the `:scry`
project key:

```elixir
def project do
  [
    # ...
    scry: [
      analyses: [:supervision, :unsafe_task],  # default: a curated quiet set
      severity: [unsafe_task: :error],         # per-analysis override
      ignore: [modules: [~r/^MyApp\.Gen/], files: ["lib/legacy/**"]],
      include_deps: false,
      fail_on: :error,                         # :warning promotes findings to build failures
      souffle: :warn                           # | :require
    ]
  ]
end
```

A standalone task drives the same incremental core for one-shot and CI use:

```bash
mix scry                     # all configured analyses
mix scry supervision         # a specific analysis
mix scry --list              # available analyses
mix scry --format json       # machine-readable findings
mix scry --fail-above 0      # exit 1 on any finding
```

## License

MIT
