defmodule Scry.Analysis do
  @moduledoc """
  Incremental argus analysis as a roux query graph.

  ## Query DAG

      module_beam(module)                                 [frontend]
           │
      module_extraction(module)     ← Argus.Pipeline.extract, per module
       │              │
      module_semantic_facts   module_line_table
       (line_info dropped —    (anchor resolution,
        THE cutoff seam)        consumed late by LSP)
           │
      module_relation_facts({module, relation})   ← per-module projection
           │
      relation_facts(relation)      ← one relation across the project
           │
      stage0_facts(:all)
       (shared call graph —
        THE second cutoff seam)
           │
      analysis_facts_dir(analysis)  ← content-addressed, projected to the
           │                          relations THIS analysis reads
      souffle_solve(analysis)
           │
      findings(analysis)

  Planchette's LSP-only surface (`Planchette.SupTree`'s supervision tree,
  `Planchette.Focus`'s flowistry slices) hangs off `module_extraction`
  and `relation_facts` by query name from its own modules; nothing here
  depends on it.

  There is no whole-program fact node. Everything downstream of extraction
  is projected — per module, then per relation, then per analysis — so an
  edit propagates only along the relations it actually moved.

  The line-shift immunity story: a whitespace/comment edit changes the
  beam (Line/Dbgi chunks) → `module_extraction` recomputes and differs
  (its `line_info` rows changed) → `module_semantic_facts` recomputes,
  produces an EQUAL value → roux backdates it → every projection below it
  validates green without executing. Zero Souffle runs for a comment edit.

  The body-edit story: an edit that changes what a function COMPUTES but
  not what it CALLS moves `instruction` and friends, so the analyses that
  anchor at instruction sites re-solve — but `supervisor`, `sync_call` and
  the rest of the structural relations backdate at
  `module_relation_facts`, so `relation_facts` never executes for them and
  the supervision analyses stop before Souffle.

  Rule fidelity: every analysis stays in Souffle — the `.dl` files are
  the single source of truth, and incremental findings must equal batch
  `Argus.Findings.run/2` exactly (the honesty principle). Fact rows are
  sorted per relation so equal extractions produce equal values (roux
  compares with `==`); Souffle has set semantics, so ordering cannot
  change results.

  Purity deviation: `analysis_facts_dir`, `stage0_facts` and
  `souffle_solve` touch the filesystem and shell out — content-addressed
  and idempotent, the same pragmatic loophole as the frontend's code
  loading.

  ## Shared-layer contract

  This module is consumed by BOTH planchette (LSP, in-memory compile
  frontend) and scry's Mix compiler (disk-beam frontend). Roux dispatches
  queries by NAME and memo keys are `{query_name, key}`, so **query
  names, key shapes, and value shapes are the ABI** — rename nothing
  without revisiting every consumer and its persisted manifests. The
  frontend contract this module demands, by name: the queries
  `:module_beam`, `:module_map`, and `:file_of`, and the input
  `:env_fingerprint` (inputs are the frontend's to declare — this module
  defines queries only).
  """

  use Roux.Query

  alias Roux.Runtime

  # The vsn attribute value is a module checksum no Datalog rule
  # consumes; dropping it keeps any line-sensitivity it might have out
  # of the semantic cutoff.
  @vsn_attribute "vsn"

  # Bumped whenever the on-disk fact encoding changes. Directories are
  # addressed by content, so without this a stale directory written by an
  # older encoder is indistinguishable from a fresh one and gets reused —
  # which is how a malformed empty-relation file survived the fix for it.
  @facts_format_version 2

  defquery :module_extraction, key: module, returns: {:ok, map()} | {:error, term()} do
    # The rows are a function of argus's fact schema as much as of the
    # beam, and the schema version rides the fingerprint — so a warm
    # manifest cannot serve rows an older encoder wrote for an unchanged
    # beam. Without this edge the only reader of the fingerprint was
    # `analysis_input_relations`, and a column reorder would have
    # misaligned every memoized projection silently.
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)

    case Runtime.query(db, :module_beam, module) do
      {:ok, beam} ->
        case Argus.Pipeline.extract([beam],
               extractors: all_extractors(),
               trace_imprecision: true
             ) do
          {:ok, facts} -> {:ok, canonicalize(facts)}
          {:error, reason} -> {:error, {:extraction, module, reason}}
        end

      :external ->
        {:error, {:external, module}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defquery :module_semantic_facts, key: module, returns: {:ok, map()} | {:error, term()} do
    case Runtime.query(db, :module_extraction, module) do
      {:ok, facts} ->
        semantic =
          facts
          |> Map.delete(:line_info)
          |> Map.replace_lazy(:module_attribute, fn rows ->
            Enum.reject(rows, fn
              [_mod, @vsn_attribute | _] -> true
              _ -> false
            end)
          end)

        {:ok, semantic}

      {:error, _} = error ->
        error
    end
  end

  defquery :module_line_table, key: module, returns: {:ok, map()} | {:error, term()} do
    case Runtime.query(db, :module_extraction, module) do
      {:ok, facts} ->
        rows = Map.get(facts, :line_info, [])

        by_instr = Map.new(rows, fn [id, line] -> {id, String.to_integer(line)} end)

        by_func =
          rows
          |> Enum.group_by(
            fn [id, _line] -> id |> String.split("#", parts: 2) |> hd() end,
            fn [_id, line] -> String.to_integer(line) end
          )
          |> Map.new(fn {func, lines} -> {func, Enum.min(lines)} end)

        {:ok, %{by_instr: by_instr, by_func: by_func}}

      {:error, _} = error ->
        error
    end
  end

  # One module's rows for one relation. The projection that makes the seam
  # below actually cut: editing a module changes its `instruction` rows but
  # leaves its `supervisor` rows byte-identical, so this backdates for every
  # relation the edit did not touch — and the union above it then validates
  # without executing at all.
  #
  # Without this split, `relation_facts` depended on whole-module fact sets,
  # so ANY edit invalidated EVERY relation's union. They recomputed, produced
  # identical values, and backdated — correct, but the recompute was pure
  # waste, measured at 18 of 21 unions on an ordinary edit.
  defquery :module_relation_facts, key: mr, returns: [[String.t()]] do
    {module, relation} = mr

    case Runtime.query(db, :module_semantic_facts, module) do
      {:ok, facts} -> Map.get(facts, relation, [])
      {:error, _} -> []
    end
  end

  defquery :relation_facts, key: relation, returns: [[String.t()]] do
    modules =
      db
      |> Runtime.query(:module_map, :all)
      |> Map.keys()
      |> Enum.sort()

    Enum.flat_map(modules, &Runtime.query(db, :module_relation_facts, {&1, relation}))
  end

  # The relations a given analysis reads, straight from argus (which
  # resolves them from Souffle's transformed RAM — the form that actually
  # executes). Reads no inputs, so roux keeps it at `:high` durability and
  # revalidates it for the cost of an atomics read.
  defquery :analysis_input_relations, key: analysis, returns: [atom()] do
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)

    case Argus.Analysis.input_relations(analysis) do
      {:ok, relations} -> to_relation_atoms(relations)
      {:error, _} -> []
    end
  end

  # Stage 0: the shared call graph, derived once instead of inside every
  # solve. This is the cutoff seam that makes the whole scheme work — its
  # OUTPUT is far more stable than its input. Editing a function body
  # renumbers `instruction` and churns the control-flow relations, but
  # leaves call_edge byte-identical, so roux backdates this and every
  # analysis downstream validates green.
  defquery :stage0_facts,
    key: :all,
    returns: %{
      call_edge: [[String.t()]],
      call_site: [[String.t()]],
      unconditional_call_edge: [[String.t()]]
    } do
    facts =
      Map.new(stage0_input_relations(), fn relation ->
        {relation, Runtime.query(db, :relation_facts, relation)}
      end)

    dir = materialize_facts(facts, "stage0")
    :ok = Argus.Analysis.derive_stage0(dir)

    %{
      call_edge: read_facts_file(Path.join(dir, "call_edge.facts")),
      call_site: read_facts_file(Path.join(dir, "call_site.facts")),
      unconditional_call_edge: read_facts_file(Path.join(dir, "unconditional_call_edge.facts"))
    }
  end

  # A fact directory holding exactly what one analysis reads. Content
  # addressed, so an unchanged projection reuses the directory on disk and
  # — the point — an unchanged projection means roux never re-executes the
  # solve below it.
  defquery :analysis_facts_dir, key: analysis, returns: %{dir: String.t(), key: String.t()} do
    dir = materialize_facts(analysis_facts_map(db, analysis), "analysis_#{analysis}")
    %{dir: dir, key: Path.basename(dir)}
  end

  defp analysis_facts_map(db, analysis) do
    Map.new(Runtime.query(db, :analysis_input_relations, analysis), fn
      # Stage 0's outputs, not extracted relations.
      relation when relation in [:call_edge, :call_site, :unconditional_call_edge] ->
        {relation, Map.fetch!(Runtime.query(db, :stage0_facts, :all), relation)}

      relation ->
        {relation, Runtime.query(db, :relation_facts, relation)}
    end)
  end

  defquery :souffle_solve, key: analysis, returns: {:ok, map()} | {:error, term()} do
    %{dir: dir} = Runtime.query(db, :analysis_facts_dir, analysis)

    # The scratch window is shared across processes (an LSP session and a
    # compiler run prune the same root), so a concurrent prune can remove
    # a directory the memo above still names. Rebuild before solving:
    # content addressing guarantees the same path, and `untracked` keeps
    # the rebuild's demands out of this query's dependency edges — the
    # graph must look identical whether or not the race happened.
    unless File.dir?(dir) do
      Runtime.untracked(fn ->
        materialize_facts(analysis_facts_map(db, analysis), "analysis_#{analysis}")
      end)
    end

    # The directory holds exactly the relations this analysis reads, with
    # call_edge and call_site already supplied from `stage0_facts` when
    # they are among them. Argus must not try to derive stage 0 itself: the layer-1 facts
    # it would need are deliberately absent from a projected directory.
    case Argus.Analysis.run_rules(dir, analysis, stage0: :provided) do
      {:ok, results} ->
        outputs =
          results
          |> Argus.Analysis.filter_to_outputs(analysis)
          |> Map.new(fn {relation, rows} -> {relation, Enum.sort(rows)} end)

        {:ok, outputs}

      {:error, reason} ->
        # Degradation stays a visible value (Souffle missing/timeout),
        # never a crash — the argus contract.
        {:error, {:souffle, analysis, reason}}
    end
  end

  # Line-free by construction (anchors are module/mfa/instr IDs, not
  # lines) → findings backdate independently of line edits, and the
  # per-analysis grain means an analysis whose output rows are unchanged
  # stops propagation even when others changed.
  defquery :findings, key: analysis, returns: {:ok, [map()]} | {:error, term()} do
    case Runtime.query(db, :souffle_solve, analysis) do
      {:ok, outputs} ->
        module = analysis_module!(analysis)
        {:ok, build_findings(module, outputs)}

      {:error, _} = error ->
        error
    end
  end

  # Findings with anchors resolved to file + line — the LATE positional
  # step: findings themselves are line-free, so this is the only query
  # that re-runs when a line-shifting edit touches an anchored module.
  # Grouped by file, ready for LSP publication.
  defquery :analysis_diagnostics,
    key: analysis,
    returns: {:ok, %{optional(String.t()) => [map()]}} | {:error, term()} do
    case Runtime.query(db, :findings, analysis) do
      {:ok, findings} ->
        resolved =
          for finding <- findings,
              entry = resolve_finding(db, finding),
              entry != nil,
              do: entry

        {:ok, Enum.group_by(resolved, & &1.file)}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_finding(db, finding) do
    module = anchor_module(finding)

    with true <- module != nil,
         path when path != :external <- Runtime.query(db, :file_of, module) do
      %{
        file: path,
        line: anchor_line(db, module, finding),
        severity: finding.severity,
        code: Atom.to_string(finding.analysis),
        title: finding.title,
        detail: finding.detail,
        # Map.get, not dot access: findings memoized before the shape
        # gained these fields (a warm manifest) must still resolve.
        at_label: Map.get(finding, :at_label),
        help: Map.get(finding, :help, []),
        related: resolve_related(db, Map.get(finding, :related, []))
      }
    else
      _ -> nil
    end
  end

  defp resolve_related(db, related) do
    for entry <- related,
        module = anchor_module(entry),
        module != nil,
        path = Runtime.query(db, :file_of, module),
        path != :external do
      %{
        label: Map.get(entry, :label, ""),
        file: path,
        line: anchor_line(db, module, entry)
      }
    end
  end

  # NOTE: InstrId fields are the fact-encoded STRINGS ("Depot.Archive"),
  # not atoms — anchors resolved through file_of must come from the
  # finding's module/mfa fields (atoms, present whenever the instr
  # parsed).
  defp anchor_module(%{module: module}) when is_atom(module) and module != nil, do: module
  defp anchor_module(%{mfa: {module, _f, _a}}) when is_atom(module), do: module
  defp anchor_module(_), do: nil

  # Best-effort line resolution through the module's line table:
  # instruction ID → exact line; MFA → the function's first line;
  # module-only → line 1 (the defmodule line is not recoverable from
  # bytecode — an honest, predictable anchor).
  defp anchor_line(db, module, finding) do
    case Runtime.query(db, :module_line_table, module) do
      {:ok, table} ->
        instr_line(table, Map.get(finding, :instr)) ||
          mfa_line(table, Map.get(finding, :mfa)) || 1

      {:error, _} ->
        1
    end
  end

  defp instr_line(_table, nil), do: nil

  # InstrId fields are already the fact-encoded strings — reassemble the
  # id exactly as line_info keys it.
  defp instr_line(table, %Argus.InstrId{module: m, func: f, arity: a, idx: idx}) do
    id = "#{m}:#{f}/#{a}##{idx}"
    Map.get(table.by_instr, id) || Map.get(table.by_func, "#{m}:#{f}/#{a}")
  end

  defp mfa_line(_table, nil), do: nil

  defp mfa_line(table, {m, f, a}) do
    Map.get(table.by_func, "#{inspect(m)}:#{f}/#{a}")
  end

  # -- helpers --

  @doc """
  The union of every built-in analysis's extractors (coverage excluded,
  mirroring `Argus.Findings.run/2`) — one extraction serves all solves.
  """
  @spec all_extractors() :: [module()]
  def all_extractors do
    analysis_extractors =
      Argus.Analysis.builtin_analysis_modules()
      |> Enum.reject(&(&1.name() == :coverage))
      |> Enum.flat_map(& &1.extractors())

    # Resource extractors power planchette's supervision-tree overlay — ETS
    # tables and ports attributed to their owning process — over this same
    # extraction. ETS also rides the `ets` analysis, but list both
    # explicitly so the overlay never depends on which analyses happen to
    # be built in.
    (analysis_extractors ++ [Argus.Extractors.ETS, Argus.Extractors.Ports])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The always-on analyses (keynote-narrative, low-noise). The rest run
  on demand.
  """
  @spec default_analyses() :: [atom()]
  def default_analyses do
    [
      :deferred_startup_deadlock,
      :one_for_one_coupling,
      :supervision,
      :sync_call_in_init,
      :unlinked_spawn,
      :unsafe_task
    ]
  end

  defp canonicalize(facts) do
    Map.new(facts, fn {relation, rows} -> {relation, Enum.sort(rows)} end)
  end

  defp analysis_module!(analysis) do
    Enum.find(Argus.Analysis.builtin_analysis_modules(), &(&1.name() == analysis)) ||
      raise ArgumentError, "unknown argus analysis: #{inspect(analysis)}"
  end

  # Mirrors Argus.Findings.build_findings/2 (sorted relations, rows in
  # solver order — already sorted by souffle_solve, witness rows
  # collapsed by the shared dedupe_rows identity rule) so incremental
  # findings equal batch findings field for field.
  defp build_findings(module, outputs) do
    relations = Map.new(module.output_relations(), &{Atom.to_string(&1.name), &1})
    has_builder? = function_exported?(module, :finding, 2)

    for {relation_string, rows} <- Enum.sort(outputs),
        relation = Map.fetch!(relations, relation_string),
        row <- Argus.Findings.dedupe_rows(relation, rows) do
      attrs =
        if has_builder? do
          module.finding(relation.name, row)
        else
          %{
            severity: :info,
            title: Atom.to_string(relation.name),
            detail: Enum.join(row, ", "),
            module: nil,
            mfa: nil,
            instr: nil,
            at_label: nil,
            help: [],
            related: []
          }
        end

      Map.put(attrs, :analysis, module.name())
    end
  end

  defp scratch_root do
    Path.join(System.tmp_dir!(), "scry_souffle")
  end

  # How many fact directories to keep. Each edit that moves a relation
  # mints a new content-addressed directory, and nothing else ever removes
  # them — an editing session used to grow the scratch root without bound
  # (measured at 506MB / 31 directories after a single afternoon). Keeping
  # a window preserves the point of content addressing (re-visiting a
  # previous state is still a hit) while bounding the cost.
  @scratch_keep 24

  # Writes `facts` to a directory named for their content, and returns it.
  # Idempotent: identical facts map to the same directory, which is what
  # makes revisiting a prior edit state free.
  defp materialize_facts(facts, prefix) do
    key =
      {@facts_format_version, facts}
      |> :erlang.term_to_binary([:deterministic])
      |> :erlang.md5()
      |> Base.encode16(case: :lower)

    dir = Path.join(scratch_root(), "#{prefix}_#{key}")
    unless File.dir?(dir), do: write_facts_dir!(facts, dir)
    dir
  end

  defp write_facts_dir!(facts, dir) do
    # Build under a unique temporary name and rename into place, so a
    # concurrent reader never observes a half-written directory and
    # concludes the facts are simply missing (Souffle reads an absent
    # relation as empty for pruned inputs, which would be a silent wrong
    # answer rather than a loud failure).
    staging = "#{dir}.#{System.unique_integer([:positive])}"
    File.mkdir_p!(staging)
    write_projected_facts!(facts, staging)

    case File.rename(staging, dir) do
      :ok -> :ok
      # Lost the race to an identical directory: content-addressed, so
      # the winner's contents are ours. Drop the duplicate.
      {:error, _} -> File.rm_rf!(staging)
    end

    prune_scratch()
    :ok
  end

  # Writes exactly the projected relations and nothing else.
  #
  # Deliberately not `Argus.Pipeline.write_facts/2`, which pre-creates an
  # empty file for every schema relation so Souffle never fails on a
  # missing input. That is the right default for a full extraction and the
  # wrong one here: it would make an under-projection FAIL SILENTLY, with
  # Souffle reading a relation we forgot to supply as empty and returning
  # fewer findings. Writing only what we projected makes the same mistake
  # abort with "cannot open fact file", which is the failure mode a static
  # analyzer should have.
  defp write_projected_facts!(facts, dir) do
    Enum.each(facts, fn {relation, rows} ->
      content =
        case rows do
          [] -> ""
          rows -> Enum.map_join(rows, "\n", &Enum.join(&1, "\t")) <> "\n"
        end

      File.write!(Path.join(dir, "#{relation}.facts"), content)
    end)
  end

  defp prune_scratch do
    root = scratch_root()

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(fn dir ->
          mtime =
            case File.stat(dir, time: :posix) do
              {:ok, %{mtime: mtime}} -> mtime
              _ -> 0
            end

          {mtime, dir}
        end)
        |> Enum.sort(:desc)
        |> Enum.drop(@scratch_keep)
        |> Enum.each(fn {_mtime, dir} -> File.rm_rf(dir) end)

      {:error, _} ->
        :ok
    end
  end

  # Relation names arrive from argus as strings. Only relations the schema
  # knows can appear in an extraction, so an unknown name is dropped
  # rather than minting an atom from external input.
  defp to_relation_atoms(names) do
    known = MapSet.new(Argus.Schema.names())

    for name <- names,
        atom = safe_existing_atom(name),
        atom != nil,
        atom in [:call_edge, :call_site, :unconditional_call_edge] or MapSet.member?(known, atom),
        do: atom
  end

  defp safe_existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # The layer-1 relations stage0.dl reads, asked of Souffle rather than
  # hardcoded, so adding a call-graph rule upstream cannot silently leave
  # the projection feeding stage 0 an incomplete fact set.
  defp stage0_input_relations do
    case Argus.Souffle.input_relations(Argus.Analysis.stage0_rules_path()) do
      {:ok, relations} -> to_relation_atoms(relations)
      {:error, _} -> []
    end
  end

  # Souffle fact files are tab separated, one tuple per line.
  defp read_facts_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end
end
