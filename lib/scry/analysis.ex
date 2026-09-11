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
           │                    ╲
      stage0_facts(:all)         ╲  supervision_tree(:all)
       (shared call graph —       ╲  (projected to the 8 relations
        THE second cutoff seam)    ╲  SupTree declares)
           │
      analysis_facts_dir(analysis)  ← content-addressed, projected to the
           │                          relations THIS analysis reads
      souffle_solve(analysis)
           │
      findings(analysis)

      module_extraction(module) → module_flow(module) → function_flow({m, fa})
                                    (flowistry slices — line-free index
                                     adjacency; lines resolve late)

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
  `:module_beam`, `:module_map`, `:file_of`, and `:declared_modules`,
  and the inputs `:source_text` and `:env_fingerprint` (inputs are the
  frontend's to declare — this module defines queries only).
  """

  use Roux.Query

  alias Roux.Runtime

  # Compile-time schema pin, per the argus embedding contract
  # (the lowdown pattern): fact shapes changed → the shared analysis
  # layer must be revisited, not silently drift.
  #
  # v3 revisit: line_info became per-instruction (sticky from the last
  # marker), so module_line_table's by_instr lookup resolves call-site
  # anchors to exact lines instead of falling back to by_func. The
  # semantic-facts seam is unaffected (line_info is dropped there).
  #
  # v4: argus added the supervisor_child_name relation; SupTree.build reads
  # it to anchor dynamic children by registered name.
  #
  # v5/v6: global_register arity + the statem_initial relation (the
  # gen_statem precision audit) — Layer-2 additions consumed via argus's
  # own analyses, no planchette code change.
  #
  # v7: argus added the port_open relation; SupTree.build reads it (with
  # ets_new/ets_option) to overlay ETS tables and ports onto their owners.
  # v8: positional columns split out of the semantic relations —
  # `function_def` lost its entry label to the new `function_entry`, and
  # `call_arg` lost its call-site instruction ID. Both renumbered on any
  # body edit while no rule read them, so they dirtied every analysis that
  # touched those relations. The gloss/flow paths pick `function_entry` up
  # explicitly (Argus.Cfg needs it); the semantic path deliberately does
  # not, which is what lets a supervision finding survive a body edit.
  #
  # Pinned to a single version, unlike gloss and lowdown: this layer is the
  # only consumer that reads BOTH layers and projects relation subsets, so a
  # Layer-2 addition is never obviously irrelevant here the way it is for a
  # Layer-1-only consumer. Every bump gets read.
  # v9: parameter forwarding moved out of `call_arg`'s value column (where
  # it was the string "arg:N") into the new `call_arg_forward` relation, so
  # the rules stop decoding it with a partial functor. Both relations are
  # projected per analysis from `input_relations`, so nothing here hardcodes
  # either name — but the new relation does widen the input set of the seven
  # analyses that read call_arg, which is visible in the analysis-layer
  # cutoff and is why this bump is worth a note.
  # v10: the call-shaped relations carry `caller`, so the rules no longer
  # join `instruction` to recover it. This is the bump this layer cares most
  # about: stage 0 and two of the three instruction-reading analyses drop
  # `instruction` from their input sets entirely, which is a 40% cut in the
  # facts a full analysis run serializes. `Scry.Flow` and the gloss
  # paths still request `instruction` explicitly and are unaffected.
  # v11: `call_followed_by_branch` replaces unsafe_task's two `instruction`
  # joins. With that, NO analysis reads `instruction` — the largest and most
  # volatile relation in the schema no longer gates any analysis's
  # incrementality, and `relation_facts(:instruction)` has no demander left
  # in the analysis path. `Scry.Flow` and the gloss alignment paths
  # still request it explicitly and are unaffected.
  # v12: `recv_start` gains `caller` and `blocking`, feeding the new
  # callback_receive analysis. Projected per analysis like everything else,
  # so no code here names it.
  # v13: send_msg and make_fun gain `caller`; dynamic_call records calls the
  # graph cannot follow; Layer 2 gains the purity-contract relations. All
  # projected per analysis, so no code here names them.
  # v14: `impure_call` gains `mode`, so transaction safety can look at
  # writes without purity losing reads. Projected per analysis; no
  # code here names it.
  # v15: `callback_return` and `callback_drops_from` for reply_contract,
  # both new Layer-2 relations. Same story — projected per analysis, and
  # the gloss relation list is untouched.
  use Argus.Schema.Pin, versions: 13..25, review: "Scry.Analysis and Scry.SupTree"

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
    returns: %{call_edge: [[String.t()]], call_site: [[String.t()]]} do
    facts =
      Map.new(stage0_input_relations(), fn relation ->
        {relation, Runtime.query(db, :relation_facts, relation)}
      end)

    dir = materialize_facts(facts, "stage0")
    :ok = Argus.Analysis.derive_stage0(dir)

    %{
      call_edge: read_facts_file(Path.join(dir, "call_edge.facts")),
      call_site: read_facts_file(Path.join(dir, "call_site.facts"))
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
      # call_edge and call_site are stage 0's outputs, not extracted relations.
      :call_edge -> {:call_edge, Runtime.query(db, :stage0_facts, :all).call_edge}
      :call_site -> {:call_site, Runtime.query(db, :stage0_facts, :all).call_site}
      relation -> {relation, Runtime.query(db, :relation_facts, relation)}
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

  # Projected to the eight relations SupTree declares, not the whole-program
  # union: the tree renders supervision structure, so an edit that moves only
  # bytecode relations leaves every input here backdated and the tree
  # validates without rebuilding — and without a redraw reaching the editor.
  defquery :supervision_tree, key: :all, returns: Scry.SupTree.t() do
    Scry.SupTree.relations()
    |> Map.new(&{&1, Runtime.query(db, :relation_facts, &1)})
    |> Scry.SupTree.build()
  end

  # ── flowistry-style slicing ─────────────────────────────────────────

  # Everything gloss's entry builder, adapters, and CFG construction read.
  @gloss_relations [
    :instruction,
    :line_info,
    :type_test,
    :label_at,
    :jump,
    :branch,
    :bif_call,
    :bs_start,
    :try_start,
    :select_branch,
    :function_def,
    # The entry label moved out of function_def in argus schema v8 (it is
    # positional, and no Datalog rule read it). Argus.Cfg still needs it to
    # root each function's control-flow graph, so the gloss path must carry
    # it — the SEMANTIC path deliberately does not.
    :function_entry,
    :def,
    :use,
    :next
  ]

  # The line table the FOCUS path resolves through: raw per-instruction
  # lines refined by gloss's alignment passes, which recover attribution
  # for lines the compiler never recorded (non-raising code — a bare
  # `_ -> {:reply, :ok, state}` arm owns no Line-chunk marker at all).
  # Diagnostics keep the raw module_line_table: finding anchors are
  # marker-borne call sites, where raw and refined agree.
  defquery :refined_line_table, key: module, returns: {:ok, map()} | {:error, term()} do
    with {:ok, facts} <- Runtime.query(db, :module_extraction, module),
         path when path != :external <- Runtime.query(db, :file_of, module) do
      source = Runtime.input!(db, :source_text, path)
      {:ok, refine_lines(module, facts, source)}
    else
      :external -> {:error, {:external, module}}
      {:error, _} = error -> error
    end
  end

  # The debug twin (OTP 28 beam_debug_info) for bytecode-grounded
  # variable focusing — recompiled from the optimized beam's abstract
  # forms. Focus-only: analyses stay on the production bytecode.
  defquery :debug_twin, key: module, returns: {:ok, binary()} | {:error, term()} do
    with {:ok, beam} <- Runtime.query(db, :module_beam, module) do
      Scry.DebugSlice.twin(module, beam)
    end
  end

  # Per-function focus bundle over the twin: flow graph, line map,
  # register defs, and per-binding register occupancy from the DbgB
  # chunk. Line-free enough to backdate under line-only edits (register
  # numbering is stable when the code is unchanged).
  defquery :debug_bundle, key: module, returns: {:ok, map()} | {:error, term()} do
    with {:ok, twin} <- Runtime.query(db, :debug_twin, module) do
      Scry.DebugSlice.build(twin)
    end
  end

  defp refine_lines(module, facts, source) do
    typed = facts |> Map.take(@gloss_relations) |> Argus.Facts.decode()
    cfgs = Argus.Cfg.build(typed)
    flow = Gloss.Adapters.dataflow(typed)
    type_tests = Gloss.Adapters.type_tests(typed)
    src_facts = Gloss.Source.facts(source)

    refined_by_func =
      for {{name, arity} = fa, cfg} <- cfgs do
        {entries, marked} = Gloss.Entries.from_typed_facts(typed, fa)
        src = Gloss.Source.for_function(src_facts, {String.to_existing_atom(name), arity})

        refined =
          Gloss.align(entries, cfg, src,
            flow: Map.get(flow, fa, %{}),
            type_tests: Map.get(type_tests, fa, %{}),
            marked: marked
          )

        {"#{inspect(module)}:#{name}/#{arity}", refined, marked}
      end

    by_instr =
      for {prefix, entries, _marked} <- refined_by_func,
          %{idx: idx, line: line} <- entries,
          line != nil,
          into: %{} do
        {"#{prefix}##{idx}", line}
      end

    by_func =
      for {prefix, entries, _marked} <- refined_by_func,
          lines = for(%{line: l} <- entries, l != nil, do: l),
          lines != [],
          into: %{} do
        {prefix, Enum.min(lines)}
      end

    # Marker-vouched instructions: the compiler recorded their line
    # directly. Their raw line is identity; refinement never overrides
    # it for focus resolution.
    vouched =
      for {prefix, _entries, marked} <- refined_by_func,
          idx <- marked,
          into: MapSet.new() do
        "#{prefix}##{idx}"
      end

    %{by_instr: by_instr, by_func: by_func, vouched: vouched}
  end

  # Per-function dependence graphs over instruction indexes — line-free
  # by construction (pure index adjacency), so line-only edits recompute
  # this but backdate it, and slices re-resolve lines late through
  # module_line_table exactly like diagnostics do.
  defquery :module_flow, key: module, returns: {:ok, map()} | {:error, term()} do
    case Runtime.query(db, :module_extraction, module) do
      {:ok, facts} -> {:ok, Scry.Flow.build(facts)}
      {:error, _} = error -> error
    end
  end

  # Per-function projection of module_flow: the cutoff grain below the
  # module — an edit elsewhere in the module recomputes module_flow, but
  # untouched functions produce equal projections and downstream slices
  # validate without executing.
  defquery :function_flow, key: mf, returns: {:ok, Scry.Flow.t()} | {:error, term()} do
    {module, func_id} = mf

    with {:ok, flows} <- Runtime.query(db, :module_flow, module) do
      case Map.fetch(flows, func_id) do
        {:ok, flow} -> {:ok, flow}
        :error -> {:error, {:unknown_function, func_id}}
      end
    end
  end

  @doc """
  The occurrences of the binding under the cursor — its definition and
  the reads that resolve to it (scope-aware, one hop over the source
  binding web). This is the tight, predictable default: "where is this
  variable used", not "everything it transitively influences".

  A rebound name resolves to the specific binding the cursor sits on, so
  focusing one `state` binding does not light another's occurrences.
  """
  @spec variable_occurrences(Roux.Database.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, %{lines: [pos_integer()], variable: String.t(), occurrences: non_neg_integer()}}
          | :no_variable
  def variable_occurrences(db, path, line, column) do
    source = Runtime.input!(db, :source_text, path)
    %{occurrences: occurrences, edges: edges} = Gloss.SourceFlow.analyze(source)

    at_cursor =
      Enum.find(occurrences, fn o ->
        o.line == line and column >= o.col and column < o.col + o.len
      end)

    case at_cursor do
      nil ->
        :no_variable

      occ ->
        # The cursor's binding: itself if a def, else the def its read
        # resolves to (a data edge `use -> def`).
        def_id =
          case occ.kind do
            :def -> occ.id
            _ -> Enum.find_value(edges, occ.id, &data_target(&1, occ.id))
          end

        members =
          for e <- edges, e.kind == :data, e.to == def_id, into: MapSet.new([def_id]), do: e.from

        lines_by_id = Map.new(occurrences, &{&1.id, &1.line})

        lines =
          members
          |> Enum.map(&Map.get(lines_by_id, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, %{lines: lines, variable: occ.name, occurrences: MapSet.size(members)}}
    end
  end

  defp data_target(%{kind: :data, from: from, to: to}, from), do: to
  defp data_target(_edge, _from), do: nil

  @doc """
  The variable-level slice: the binding web of the identifier under the
  cursor, resolved on the source AST via `Gloss.SourceFlow.analyze/1` —
  no bytecode line markers involved, so it works on any occurrence,
  function-head parameters included.

  `:backward` collects what flows into the occurrence, `:forward` what
  it flows into, `:both` the union of the two directional closures
  (deliberately not the connected component — a rebound variable's
  sources must not drag in every consumer of the *old* binding).

  Returns `:no_variable` when the cursor is not on an identifier
  occurrence — callers fall back to the line slice.
  """
  @spec variable_slice(
          Roux.Database.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          :backward | :forward | :both
        ) ::
          {:ok, %{lines: [pos_integer()], variable: String.t(), occurrences: non_neg_integer()}}
          | :no_variable
  def variable_slice(db, path, line, column, direction, opts \\ [])
      when direction in [:backward, :forward, :both] do
    source = Runtime.input!(db, :source_text, path)
    %{occurrences: occurrences, edges: edges} = Gloss.SourceFlow.analyze(source)

    at_cursor =
      Enum.find(occurrences, fn o ->
        o.line == line and column >= o.col and column < o.col + o.len
      end)

    case at_cursor do
      nil ->
        :no_variable

      occ ->
        # Source-level is the default: it understands clause scoping, so
        # for idiomatic multi-clause Elixir it is tighter than the
        # bytecode slice (where all clauses share one function and the
        # shared parameter traces to the function entry). Bytecode
        # grounding is opt-in — ground truth through macro expansions and
        # register moves — and falls back to source when a debug twin is
        # unavailable or the binding cannot be resolved.
        case Keyword.get(opts, :grounding, :source) do
          :bytecode ->
            case bytecode_variable_slice(db, path, occ, line, direction) do
              {:ok, result} -> {:ok, result}
              :fallback -> source_variable_slice(occurrences, edges, occ, direction)
            end

          _ ->
            source_variable_slice(occurrences, edges, occ, direction)
        end
    end
  end

  defp bytecode_variable_slice(db, path, occ, line, direction) do
    with {:ok, {module, func_id}} <- locate(db, path, line),
         {:ok, bundle} <- Runtime.query(db, :debug_bundle, module),
         %{} = fb <- Map.get(bundle, func_id, :fallback),
         {:ok, lines} <- Scry.DebugSlice.slice(fb, occ.name, line, occ.kind, direction) do
      {:ok, %{lines: lines, variable: occ.name, occurrences: length(lines), grounding: :bytecode}}
    else
      _ -> :fallback
    end
  end

  defp source_variable_slice(occurrences, edges, occ, direction) do
    # Edge {from, to} reads "from depends on to".
    into = Enum.group_by(edges, & &1.from, & &1.to)
    out_of = Enum.group_by(edges, & &1.to, & &1.from)

    reached =
      case direction do
        :backward ->
          occ_reach([occ.id], MapSet.new([occ.id]), into)

        :forward ->
          occ_reach([occ.id], MapSet.new([occ.id]), out_of)

        :both ->
          MapSet.union(
            occ_reach([occ.id], MapSet.new([occ.id]), into),
            occ_reach([occ.id], MapSet.new([occ.id]), out_of)
          )
      end

    lines_by_id = Map.new(occurrences, &{&1.id, &1.line})

    lines =
      reached
      |> Enum.map(&Map.get(lines_by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok,
     %{
       lines: lines,
       variable: occ.name,
       occurrences: MapSet.size(reached),
       grounding: :source
     }}
  end

  defp occ_reach([], seen, _adjacency), do: seen

  defp occ_reach([id | rest], seen, adjacency) do
    fresh = adjacency |> Map.get(id, []) |> Enum.reject(&MapSet.member?(seen, &1))
    occ_reach(fresh ++ rest, Enum.into(fresh, seen), adjacency)
  end

  @doc """
  The enclosing construct heads of the slice lines — the `fn`, `case`,
  arm, and definition heads a lit line sits under. Kept visible so a
  highlight reads as a program (which arm? whose case?) even when
  nothing on those heads is itself in the slice.
  """
  @spec slice_context(Roux.Database.t(), String.t(), [pos_integer()]) :: [pos_integer()]
  def slice_context(db, path, lines) do
    source = Runtime.input!(db, :source_text, path)
    line_set = MapSet.new(lines)

    # For each construct enclosing a slice line, keep its head, its
    # matching `end`, and its block-continuation keywords (else / rescue
    # / catch / after), so a scope reads as one closed, connected block
    # rather than disjoint fragments. Arms have neither end nor keywords.
    construct_context =
      Gloss.SourceFlow.construct_spans(source)
      |> Enum.filter(fn %{span: {first, last}} ->
        Enum.any?(lines, &(&1 >= first and &1 <= last))
      end)
      |> Enum.flat_map(fn %{head: head, end_line: end_line, keywords: keywords} ->
        [head, end_line | keywords]
      end)

    # A pipeline is one expression: when a slice line is any stage of a
    # `|>` chain, keep the whole chain visible so it does not read as a
    # dangling stage.
    pipeline_context =
      Gloss.SourceFlow.pipeline_spans(source)
      |> Enum.filter(fn %{lines: chain} -> Enum.any?(chain, &MapSet.member?(line_set, &1)) end)
      |> Enum.flat_map(& &1.lines)

    (construct_context ++ pipeline_context)
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(line_set, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Finds the function containing `line` in `path` — the innermost
  bytecode function (lambdas included) whose stamped lines span it.

  Returns `{:ok, {module, func_id}}` or `{:error, :no_code_at_line}`
  (blank lines, comments, module attributes).
  """
  @spec locate(Roux.Database.t(), String.t(), pos_integer()) ::
          {:ok, {module(), String.t()}} | {:error, :no_code_at_line}
  def locate(db, path, line) do
    candidates =
      for module <- Runtime.query(db, :declared_modules, path),
          {:ok, table} <- [Runtime.query(db, :refined_line_table, module)],
          {func_id, {min, max}} <- function_line_spans(table),
          min <= line and line <= max do
        {max - min, func_id, module}
      end

    case Enum.sort(candidates) do
      [{_span, func_id, module} | _] -> {:ok, {module, func_id}}
      [] -> {:error, :no_code_at_line}
    end
  end

  @doc """
  The flowistry slice for `line` of `func_id`: every source line the
  focused line's instructions depend on (`:backward`), feed
  (`:forward`), or both.

  Line-granular, intraprocedural, and not exception-complete — see
  `Scry.Flow` for the honest limits.
  """
  @spec slice(
          Roux.Database.t(),
          module(),
          String.t(),
          pos_integer(),
          :backward | :forward | :both
        ) ::
          {:ok, %{lines: [pos_integer()], instructions: non_neg_integer()}}
          | {:error, term()}
  def slice(db, module, func_id, line, direction)
      when direction in [:backward, :forward, :both] do
    with {:ok, flow} <- Runtime.query(db, :function_flow, {module, func_id}),
         {:ok, raw_table} <- Runtime.query(db, :module_line_table, module),
         {:ok, refined_table} <- Runtime.query(db, :refined_line_table, module) do
      raw = function_lines(raw_table, func_id)
      refined = function_lines(refined_table, func_id)
      prefix = func_id <> "#"

      # Focus resolves through both attributions: raw (the compiler's
      # sticky markers) plus gloss's refinement, which recovers lines the
      # compiler never recorded — a pure-data case arm becomes standable.
      # Refinement is only trusted for instructions the compiler did NOT
      # vouch for directly (gloss's viewer semantics may pull a vouched
      # computation onto its consumer's band; its identity stays put).
      focus =
        for {idx, l} <- raw, l == line, into: MapSet.new(), do: idx

      focus =
        for {idx, l} <- refined,
            l == line,
            not MapSet.member?(refined_table.vouched, "#{prefix}#{idx}"),
            into: focus,
            do: idx

      case MapSet.size(focus) do
        0 ->
          # BEAM only marks instructions that can raise, so a line of
          # pure data movement (a bare `{:reply, :ok, state}` arm) owns
          # no instructions at all — and when even gloss's refinement
          # cannot place it, point at the nearest lines that exist.
          {:error, {:no_code_at_line, nearest_stamped(raw, refined, line)}}

        _ ->
          sliced = Scry.Flow.slice(flow, focus, direction)

          # Result lines report through raw attribution, excluding the
          # focus instructions themselves (their display line is the
          # focus line): raw sticky lines are the compiler's truth for
          # everything else, and mapping results through the refined
          # bands would bleed sibling arms into each other's slices.
          lines =
            for(
              idx <- sliced,
              not MapSet.member?(focus, idx),
              found = Map.get(raw, idx),
              found != nil,
              do: found
            )
            |> Enum.concat([line])
            |> Enum.uniq()
            |> Enum.sort()

          {:ok, %{lines: lines, instructions: MapSet.size(sliced)}}
      end
    end
  end

  defp nearest_stamped(raw, refined, line) do
    stamped = Enum.uniq(Map.values(raw) ++ Map.values(refined))

    %{
      previous: stamped |> Enum.filter(&(&1 < line)) |> Enum.max(fn -> nil end),
      next: stamped |> Enum.filter(&(&1 > line)) |> Enum.min(fn -> nil end)
    }
  end

  # by_instr keys are "Mod:fun/arity#idx" — the trailing "#" keeps
  # "Mod:f/1" from matching "Mod:f/12".
  defp function_lines(table, func_id) do
    prefix = func_id <> "#"

    for {id, line} <- table.by_instr, String.starts_with?(id, prefix), into: %{} do
      idx = id |> String.split("#") |> List.last() |> String.to_integer()
      {idx, line}
    end
  end

  defp function_line_spans(table) do
    table.by_instr
    |> Enum.group_by(
      fn {id, _line} -> id |> String.split("#", parts: 2) |> hd() end,
      fn {_id, line} -> line end
    )
    |> Enum.map(fn {func_id, lines} -> {func_id, Enum.min_max(lines)} end)
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

  # NOTE: InstrId fields are the fact-encoded STRINGS ("Eusapia.Archive"),
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

    # Resource extractors power the supervision-tree overlay — ETS tables and
    # ports attributed to their owning process. ETS also rides the `ets`
    # analysis, but list both explicitly so the overlay never depends on
    # which analyses happen to be built in.
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
        atom in [:call_edge, :call_site] or MapSet.member?(known, atom),
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
