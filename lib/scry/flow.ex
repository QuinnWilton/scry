defmodule Scry.Flow do
  @moduledoc """
  Intraprocedural flow graphs for flowistry-style slicing.

  Combines argus's two per-function views of a compiled module — data
  dependences (`Argus.Dataflow.def_use_edges/1`) and the control-flow
  graph (`Argus.Cfg`) — into one instruction-level dependence graph per
  function: `deps` (what an instruction needs — its data definitions
  plus the branch it is control-dependent on) and `uses` (the inverse).
  A slice is a reachability walk over these maps.

  Control dependence and post-dominators come from argus
  (`Argus.Cfg.Function.control_deps/1` and the `ipdom` field); this
  module only lowers block-level control dependence to instruction
  level and fuses it with the data edges.

  ## Honest limits

  Slices are **line-granular** (BEAM Line chunks carry no columns),
  **intraprocedural** (a call is a dependence on the call site, not on
  the callee's body), and **not exception-complete** (`Argus.Dataflow`
  deliberately skips exception edges). Instructions that cannot raise
  carry no line marker of their own and inherit the previous line, so a
  condition's `if` line may be represented by its data sources rather
  than the keyword's own line. Blocks that never reach the function
  exit (genuine infinite loops) have no post-dominator and
  conservatively contribute no control edges.
  """

  alias Argus.Cfg

  @type idx :: non_neg_integer()
  @type adjacency :: %{idx() => [idx()]}
  @type t :: %{deps: adjacency(), uses: adjacency()}

  # Everything Argus.Cfg.build/1 and Argus.Dataflow.def_use_edges/1 read.
  @flow_relations [
    :instruction,
    :label_at,
    :jump,
    :branch,
    :bif_call,
    :bs_start,
    :try_start,
    :select_branch,
    :function_def,
    # Argus.Cfg roots each function's graph at its entry label, which moved
    # into function_entry in schema v8 (positional data, split out of
    # function_def so the semantic relations stop churning on body edits).
    :function_entry,
    :def,
    :use,
    :next
  ]

  @doc """
  Builds per-function flow graphs from a module's raw facts (the
  `module_extraction` value), keyed by function ID (`"Mod:fun/arity"`).

  The value is line-free — pure instruction-index adjacency — so it
  backdates under line-only edits.
  """
  @spec build(%{optional(atom()) => [[String.t()]]}) :: %{String.t() => t()}
  def build(raw_facts) do
    typed = raw_facts |> Map.take(@flow_relations) |> Argus.Facts.decode()
    cfgs = Cfg.build(typed)
    data_edges = Argus.Dataflow.def_use_edges(typed)

    func_ids =
      for row <- Map.get(typed, :function_def, []), into: %{} do
        {{row.name, row.arity}, row.func}
      end

    for {{name, arity} = key, cfg} <- cfgs,
        func_id = Map.get(func_ids, key),
        func_id != nil,
        into: %{} do
      {func_id, function_flow(cfg, data_edges, name, arity)}
    end
  end

  @doc """
  The transitive slice over a function flow from a set of focus
  instruction indexes — backward (what feeds them), forward (what they
  feed), or both. The focus itself is always included.
  """
  @spec slice(t(), [idx()] | MapSet.t(idx()), :backward | :forward | :both) :: MapSet.t(idx())
  def slice(flow, focus, direction) do
    focus = MapSet.new(focus)

    case direction do
      :backward -> reach(focus, flow.deps)
      :forward -> reach(focus, flow.uses)
      :both -> MapSet.union(reach(focus, flow.deps), reach(focus, flow.uses))
    end
  end

  defp reach(focus, adjacency) do
    reach(MapSet.to_list(focus), focus, adjacency)
  end

  defp reach([], seen, _adjacency), do: seen

  defp reach([idx | rest], seen, adjacency) do
    fresh = adjacency |> Map.get(idx, []) |> Enum.reject(&MapSet.member?(seen, &1))
    reach(fresh ++ rest, Enum.into(fresh, seen), adjacency)
  end

  # ── per-function graph ────────────────────────────────────────────

  defp function_flow(cfg, data_edges, name, arity) do
    data =
      for {d, u} <- data_edges, d.func == name, d.arity == arity, do: {u.idx, d.idx}

    control = control_edges(cfg)

    deps = collect(data ++ control)
    uses = collect(for {dependent, on} <- data ++ control, do: {on, dependent})
    %{deps: deps, uses: uses}
  end

  defp collect(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {k, vs} -> {k, vs |> Enum.uniq() |> Enum.sort()} end)
  end

  # Instruction-level control dependence: every instruction of a
  # control-dependent block depends on the deciding block's terminator
  # (its last instruction — the branch or select).
  defp control_edges(cfg) do
    for {dependent_block, deciders} <- Cfg.Function.control_deps(cfg),
        decider <- deciders,
        branch_idx = branch_index(cfg, decider),
        idx <- block_indexes(cfg, dependent_block),
        idx != branch_idx do
      {idx, branch_idx}
    end
  end

  defp branch_index(cfg, block_id) do
    {_first, last} = cfg.blocks[block_id].range
    last
  end

  defp block_indexes(cfg, block_id) do
    {first, last} = cfg.blocks[block_id].range
    Enum.to_list(first..last)
  end
end
