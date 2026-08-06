defmodule Scry.SupTree do
  @moduledoc """
  Builds the statically inferred supervision tree from argus facts.

  Pure presentation logic over the `supervisor`, `supervisor_child`,
  `dynamic_child`, and `imprecision` relations. The tree value is
  line-free by construction — anchor/line resolution happens at the
  consumer (LSP) — so whitespace edits can never force a redraw: roux's
  early cutoff backdates the `supervision_tree` query when the structure
  is unchanged.

  Honesty notes carried into the value itself:

    * Nodes whose child specs could not be statically resolved carry
      `incomplete` markers (from `imprecision` facts — extraction runs
      with tracing enabled).
    * `DynamicSupervisor.start_child/2` call sites are anchored to their
      supervisor whenever the supervisor argument resolves — to a module
      (a supervisor's own `start_child` helper) or to a registered name a
      child spec carries (`{DynamicSupervisor, name: X}` matched against a
      `start_child(X, _)` call). Only the genuinely unresolvable sites (a
      supervisor pid held in state) are surfaced under `unanchored_dynamic`
      rather than dropped.
    * Registered names (`name:` on a child spec) ride on the node so a
      generic `DynamicSupervisor`/`Registry` child renders as the name
      everyone refers to it by, and same-module siblings stay distinct.
    * Orphan supervisors (registered but reachable from no root) appear
      as additional roots — showing them is a feature.

  Module names are the fact-encoded strings (`"Eusapia.Queue"`), ready
  for rendering.
  """

  @typedoc """
  A non-process resource owned by the node's process. ETS tables and ports
  both die with their owner, so they attribute to the owning process in the
  tree. Attribution is by the module that creates the resource — an
  approximation: a table created in a shared helper module, or ownership
  transferred via `heir`/`give_away`, is not tracked.
  """
  @type resource_t ::
          %{kind: :ets, name: String.t(), attrs: [String.t()]}
          | %{kind: :port, mechanism: String.t(), target: String.t()}

  @type node_t :: %{
          module: String.t(),
          kind: :supervisor | :worker,
          strategy: String.t() | nil,
          restart: String.t() | nil,
          child_type: String.t() | nil,
          position: non_neg_integer() | nil,
          dynamic: boolean(),
          name: String.t() | nil,
          incomplete: [%{category: String.t(), reason: String.t()}],
          resources: [resource_t()],
          children: [node_t()]
        }

  @type t :: %{
          roots: [node_t()],
          unanchored_dynamic: [%{module: String.t(), caller: String.t()}]
        }

  # Child-spec metadata threaded into a node: nil at a root, otherwise
  # {position, restart, type, dynamic?, registered_name}.
  @typep spec_meta ::
           nil
           | {non_neg_integer() | nil, String.t() | nil, String.t() | nil, boolean(),
              String.t() | nil}

  # Only a supervisor's OWN static composition marks its node. A
  # `dynamic_child` imprecision is a `start_child` call site whose parent
  # (or child) couldn't be resolved — that belongs in `unanchored_dynamic`,
  # not folded onto the caller's node: the caller is often a GenServer with
  # no children at all (Oban.Midwife), and the resolved-child case is
  # already reported below, so the marker would double-count and mislabel.
  @imprecision_relations ~w(supervisor supervisor_child)

  @relations [
    :supervisor,
    :supervisor_child,
    :supervisor_child_name,
    :dynamic_child,
    :imprecision,
    :ets_new,
    :ets_option,
    :port_open
  ]

  @doc """
  The fact relations `build/1` reads.

  Declared here so a caller can project exactly this slice instead of
  assembling a whole-program fact map. `build/1` treats an absent relation
  as empty, so a caller that under-projects would silently render a wrong
  tree — hence the list lives with the code that reads it, and
  `relations_are_exhaustive` in the test suite pins it against the source.
  """
  @spec relations() :: [atom()]
  def relations, do: @relations

  @doc """
  Builds the tree from a raw fact map (`%{relation => [[field, ...]]}`).
  """
  @spec build(%{optional(atom()) => [[String.t()]]}) :: t()
  def build(facts) do
    # Two columns since argus schema v8 — the tree-definition site moved
    # to `supervisor_site`, which the tree does not need (it renders
    # structure, not positions).
    supervisors =
      Map.new(Map.get(facts, :supervisor, []), fn [mod, strategy] -> {mod, strategy} end)

    children_by_sup =
      facts
      |> Map.get(:supervisor_child, [])
      |> Enum.group_by(fn [sup | _] -> sup end)

    dynamic_by_sup =
      facts
      |> Map.get(:dynamic_child, [])
      |> Enum.group_by(fn [sup | _] -> sup end)

    # Registered names a child spec carries (`{DynamicSupervisor, name: X}`),
    # keyed by the child's `{sup, position}`. A `dynamic_child` whose parent
    # is one of these names anchors to the child that registers it instead of
    # floating free — the parent of `DynamicSupervisor.start_child(X, _)` is
    # the *name* X, not any module.
    names_by_sup_pos =
      Map.new(Map.get(facts, :supervisor_child_name, []), fn [sup, pos, name] ->
        {{sup, pos}, name}
      end)

    registered_names = names_by_sup_pos |> Map.values() |> MapSet.new()

    # A dynamic parent is anchored when it names a supervisor module or a
    # name a child spec registers; its children are then reachable and never
    # reported as unanchored.
    anchored? = fn sup ->
      Map.has_key?(supervisors, sup) or MapSet.member?(registered_names, sup)
    end

    incomplete_by_mod = incomplete_markers(Map.get(facts, :imprecision, []))

    static_children =
      for {_sup, rows} <- children_by_sup, [_sup, _pos, child | _] <- rows, into: MapSet.new() do
        child
      end

    dynamic_children =
      for {sup, rows} <- dynamic_by_sup,
          anchored?.(sup),
          [_sup, child | _] <- rows,
          into: MapSet.new() do
        child
      end

    reachable = MapSet.union(static_children, dynamic_children)

    roots =
      supervisors
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(reachable, &1))
      |> Enum.sort()
      |> Enum.map(
        &build_node(
          &1,
          nil,
          supervisors,
          children_by_sup,
          dynamic_by_sup,
          names_by_sup_pos,
          incomplete_by_mod,
          %{}
        )
      )

    unanchored =
      for {sup, rows} <- dynamic_by_sup,
          not anchored?.(sup),
          [_sup, child, caller | _] <- rows do
        %{module: child, caller: caller}
      end

    # Resources (ETS tables, ports) attribute by owning module, so they
    # attach in a post-pass rather than threading through the walk.
    resources = resources_by_module(facts)
    roots = Enum.map(roots, &attach_resources(&1, resources))

    %{roots: roots, unanchored_dynamic: Enum.sort(unanchored)}
  end

  defp attach_resources(node, resources) do
    %{
      node
      | resources: Map.get(resources, node.module, []),
        children: Enum.map(node.children, &attach_resources(&1, resources))
    }
  end

  # Group ETS tables and ports by the module that creates them (the module
  # part of each fact's `func` id), each as a display-ready descriptor.
  defp resources_by_module(facts) do
    Map.merge(ets_by_module(facts), ports_by_module(facts), fn _mod, a, b -> a ++ b end)
  end

  defp ets_by_module(facts) do
    options =
      facts
      |> Map.get(:ets_option, [])
      |> Enum.group_by(fn [id | _] -> id end, fn [_id, key, value] -> {key, value} end)

    facts
    |> Map.get(:ets_new, [])
    |> Enum.group_by(
      fn [_id, func, _name] -> module_of(func) end,
      fn [id, _func, name] ->
        %{kind: :ets, name: name, attrs: ets_attrs(Map.get(options, id, []))}
      end
    )
  end

  # The lifecycle-relevant options, in a stable order: whether the table is
  # registered under a name (shared, survives lookups by name only while the
  # owner lives), its access, and its type.
  defp ets_attrs(pairs) do
    opts = Map.new(pairs)

    named = if opts["named_table"] == "true", do: ["named"], else: ["anonymous"]

    named ++ Enum.filter([opts["access"], opts["type"]], & &1)
  end

  defp ports_by_module(facts) do
    facts
    |> Map.get(:port_open, [])
    |> Enum.group_by(
      fn [_id, func, _mech, _target] -> module_of(func) end,
      fn [_id, _func, mechanism, target] ->
        %{kind: :port, mechanism: mechanism, target: target}
      end
    )
  end

  # "Mod:func/arity" → "Mod". Module names never contain a colon.
  defp module_of(func), do: func |> String.split(":", parts: 2) |> hd()

  @spec build_node(
          String.t(),
          spec_meta(),
          %{optional(String.t()) => String.t()},
          %{optional(String.t()) => [[String.t()]]},
          %{optional(String.t()) => [[String.t()]]},
          %{optional({String.t(), String.t()}) => String.t()},
          %{optional(String.t()) => [%{category: String.t(), reason: String.t()}]},
          %{optional(String.t()) => true}
        ) :: node_t()
  defp build_node(
         mod,
         spec_meta,
         supervisors,
         children_by_sup,
         dynamic_by_sup,
         names_by_sup_pos,
         incomplete,
         visited
       ) do
    {position, restart, child_type, dynamic?, name} =
      case spec_meta do
        nil -> {nil, nil, nil, false, nil}
        {pos, restart, type, dyn, name} -> {pos, restart, type, dyn, name}
      end

    # Dynamic children key off a parent *string*: a supervisor module for a
    # self-anchored `start_child`, or the registered name a generic
    # `{DynamicSupervisor, name: X}` child carries. Both cases resolve here.
    dynamic_parents = Enum.filter([mod, name], &(&1 && Map.has_key?(dynamic_by_sup, &1)))

    # A node is a supervisor if it declares the behaviour or if it parents
    # runtime children under its registered name (a named DynamicSupervisor
    # child spec, which carries no supervisor fact of its own).
    supervisor? = Map.has_key?(supervisors, mod) or dynamic_parents != []

    # The Datalog child_subtree is cycle-safe by fixpoint; this walk must
    # guard explicitly (a supervisor listed under itself, however wrong,
    # must render rather than loop). A plain map keyed by module name is the
    # visited set — MapSet's opaque internals confuse dialyzer across the
    # recursive threading here.
    cycle? = Map.has_key?(visited, mod)
    visited = Map.put(visited, mod, true)

    static =
      if supervisor? and not cycle? do
        children_by_sup
        |> Map.get(mod, [])
        |> Enum.sort_by(fn [_sup, pos | _] -> String.to_integer(pos) end)
        |> Enum.map(fn [_sup, pos, child, child_restart, child_type] ->
          child_name = Map.get(names_by_sup_pos, {mod, pos})

          build_node(
            child,
            {String.to_integer(pos), child_restart, child_type, false, child_name},
            supervisors,
            children_by_sup,
            dynamic_by_sup,
            names_by_sup_pos,
            incomplete,
            visited
          )
        end)
      else
        []
      end

    dynamic =
      if cycle? do
        []
      else
        dynamic_parents
        |> Enum.flat_map(&Map.fetch!(dynamic_by_sup, &1))
        |> Enum.map(fn [_sup, child | _] -> child end)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(fn child ->
          build_node(
            child,
            {nil, nil, nil, true, nil},
            supervisors,
            children_by_sup,
            dynamic_by_sup,
            names_by_sup_pos,
            incomplete,
            visited
          )
        end)
      end

    %{
      module: mod,
      kind: if(supervisor?, do: :supervisor, else: :worker),
      strategy: Map.get(supervisors, mod),
      restart: restart,
      child_type: child_type,
      position: position,
      dynamic: dynamic?,
      name: name,
      incomplete: Map.get(incomplete, mod, []),
      # Filled by attach_resources/2 once the tree structure is built.
      resources: [],
      children: static ++ dynamic
    }
  end

  # imprecision rows: [category, func ("Mod:init/1"), relation, reason].
  # Only supervisor-composition rows (see @imprecision_relations) mark the
  # owning module's node.
  defp incomplete_markers(rows) do
    rows
    |> Enum.filter(fn [_category, _func, relation, _reason] ->
      relation in @imprecision_relations
    end)
    |> Enum.flat_map(fn [category, func, _relation, reason] ->
      case String.split(func, ":", parts: 2) do
        [mod, _fa] -> [{mod, %{category: category, reason: reason}}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {mod, markers} -> {mod, Enum.uniq(Enum.sort(markers))} end)
  end
end
