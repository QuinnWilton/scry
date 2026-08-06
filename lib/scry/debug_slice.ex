defmodule Scry.DebugSlice do
  @moduledoc """
  Bytecode-grounded variable focus, via OTP 28 debug information.

  Source-level focus (`Gloss.SourceFlow`) models Elixir's binding
  semantics by hand. This module instead grounds a variable slice in the
  compiled bytecode: it recompiles a module's Erlang abstract forms with
  `beam_debug_info` (a *debug twin* — used only for focusing; every real
  analysis stays on the optimized production bytecode), reads the `DbgB`
  chunk to map each source variable to its register at each line, and
  runs argus's def-use slice over the twin.

  The debug twin distinguishes rebindings the way the compiler does —
  Elixir's SSA counter names them `_state@1`, `_state@2` — so a slice
  follows exactly one binding through its registers (including moves
  across a stack frame) rather than every same-named variable.

  ## Honest limits

  The twin has optimizations disabled, so its register allocation is not
  the production module's — which is why it grounds *focusing only*. Seed
  selection is conservative on register reuse (it may include a few extra
  lines rather than miss one). When the cursor's binding cannot be
  resolved unambiguously (two bindings of one name live on the cursor
  line, and the occurrence kind does not disambiguate), the caller falls
  back to the source-level slice.
  """

  @type bundle :: %{String.t() => func_bundle()}
  @type func_bundle :: %{
          flow: Scry.Flow.t(),
          lines: %{non_neg_integer() => pos_integer()},
          def_by_reg: %{String.t() => [non_neg_integer()]},
          occupancy: %{String.t() => [{pos_integer(), String.t()}]}
        }

  # Everything Scry.Flow reads, plus def/line facts for seeding.
  @relations [
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
    :def,
    :use,
    :next
  ]

  @doc """
  Compiles a module's debug twin from its optimized beam's `Dbgi` chunk
  (the Erlang abstract forms), recompiled with `beam_debug_info`.

  Returns `{:error, :no_debug_info}` when the beam carries no abstract
  code (compiled without `debug_info`).
  """
  @spec twin(module(), binary()) :: {:ok, binary()} | {:error, term()}
  def twin(module, beam) do
    case :beam_lib.chunks(beam, [:debug_info]) do
      {:ok, {_mod, [{:debug_info, {:debug_info_v1, backend, data}}]}} ->
        with {:ok, forms} <- forms(backend, module, data),
             {:ok, _mod, twin, _warns} <-
               :compile.forms(forms, [:beam_debug_info, :binary, :return]) do
          {:ok, twin}
        else
          _ -> {:error, :twin_compile_failed}
        end

      _ ->
        {:error, :no_debug_info}
    end
  end

  defp forms(backend, module, data) do
    case backend.debug_info(:erlang_v1, module, data, []) do
      {:ok, forms} -> {:ok, forms}
      _ -> {:error, :no_forms}
    end
  end

  @doc """
  Builds the per-function focus bundle from a debug twin: the flow graph,
  the per-instruction line map, register→def-instructions, and per-source
  variable occupancy `{binding_name => [{line, register}]}`.
  """
  @spec build(binary()) :: {:ok, bundle()} | {:error, term()}
  def build(twin) do
    with {:ok, raw} <- Argus.Pipeline.extract([twin]),
         {:ok, by_line} <- BeamSpy.DebugInfo.by_line(twin) do
      raw = Map.take(raw, @relations)
      flows = Scry.Flow.build(raw)
      func_ids = function_ids(raw)

      bundle =
        for {func_id, flow} <- flows, into: %{} do
          lines = line_map(raw, func_id)
          {func_id, %{flow: flow, lines: lines, def_by_reg: def_by_reg(raw, func_id)}}
        end

      {:ok, attach_occupancy(bundle, by_line, func_ids)}
    end
  end

  @doc """
  The bytecode-grounded slice for a variable, or `:no_binding` when the
  cursor is not on a resolvable binding (the caller falls back to the
  source slice).

  `func_id` is the function under the cursor; `name` the source variable;
  `line` the cursor line; `kind` the occurrence kind (`:def` picks the
  binding that begins here, `:use` a binding that began earlier).
  """
  @spec slice(func_bundle(), String.t(), pos_integer(), :def | :use, :backward | :forward | :both) ::
          {:ok, [pos_integer()]} | :no_binding
  def slice(fb, name, line, kind, direction) do
    # Elixir's SSA counter (`_state@2`) is scope-local: the same mangled
    # name is reused for each clause's rebind. Segment every binding into
    # contiguous runs (a run per live-range) and select the run the
    # cursor refers to — a `:def` cursor to the run beginning at or just
    # after this line (a new binding is live from the next debug_line), a
    # `:use` cursor to the run spanning this line.
    runs =
      for {binding, occ} <- fb.occupancy,
          demangle(binding) == name,
          run <- runs_of(occ) do
        run
      end

    case select_run(runs, line, kind) do
      {:ok, run} -> {:ok, slice_binding(fb, run, direction, line)}
      :none -> :no_binding
    end
  end

  # Split a binding's `{line, reg}` list into contiguous runs — a gap of
  # more than @run_gap source lines starts a new run (a different clause
  # reusing the same SSA name).
  @run_gap 3
  defp runs_of(occ) do
    occ
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_while(
      [],
      fn {line, _} = rec, acc ->
        case acc do
          [{prev, _} | _] when line - prev > @run_gap -> {:cont, Enum.reverse(acc), [rec]}
          _ -> {:cont, [rec | acc]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp select_run(runs, line, kind) do
    matches =
      Enum.filter(runs, fn run ->
        lines = Enum.map(run, &elem(&1, 0))
        min = Enum.min(lines)
        max = Enum.max(lines)

        case kind do
          # A new binding is live from the next debug_line, so its run
          # begins at the def line or the one after.
          :def -> min == line or min == line + 1
          # A read sits inside its binding's live range.
          :use -> line >= min and line <= max
        end
      end)

    case matches do
      [one] -> {:ok, one}
      [] -> :none
      many -> {:ok, Enum.min_by(many, fn run -> run |> Enum.map(&elem(&1, 0)) |> Enum.min() end)}
    end
  end

  defp slice_binding(fb, run, direction, focus_line) do
    # Seed from the def instructions of every register the binding
    # occupies within this run (following the compiler's moves across a
    # stack frame). The defining instruction lands on the def line — one
    # before the run's DbgB liveness begins — so the seed window runs
    # from the focus/def line through the run's last line, which keeps a
    # register reused by another clause out.
    run_line_nums = Enum.map(run, &elem(&1, 0))
    low = min(focus_line, Enum.min(run_line_nums) - 1)
    high = Enum.max(run_line_nums)
    seed_lines = MapSet.new(low..high)

    seed =
      for {_line, reg} <- run,
          idx <- Map.get(fb.def_by_reg, reg, []),
          MapSet.member?(seed_lines, Map.get(fb.lines, idx)),
          uniq: true,
          do: idx

    fb.flow
    |> Scry.Flow.slice(seed, direction)
    |> Enum.map(&Map.get(fb.lines, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.concat([focus_line])
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ── bundle assembly ─────────────────────────────────────────────────

  defp function_ids(raw) do
    for [func_id, _mod, name, arity | _] <- Map.get(raw, :function_def, []),
        into: %{} do
      {{name, String.to_integer(arity)}, func_id}
    end
  end

  defp line_map(raw, func_id) do
    prefix = func_id <> "#"

    for [id, line] <- Map.get(raw, :line_info, []),
        String.starts_with?(id, prefix),
        into: %{} do
      {idx_of(id), String.to_integer(line)}
    end
  end

  defp def_by_reg(raw, func_id) do
    prefix = func_id <> "#"

    for [id, reg] <- Map.get(raw, :def, []),
        String.starts_with?(id, prefix) do
      {reg, idx_of(id)}
    end
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # DbgB entries are keyed by source line; attribute each to the function
  # whose line map covers that line, and record every named variable's
  # register there (integer names are parameter positions in entry
  # items — skipped; the same variable also appears named in line items).
  defp attach_occupancy(bundle, by_line, _func_ids) do
    line_owner =
      for {func_id, fb} <- bundle, {_idx, line} <- fb.lines, into: %{}, do: {line, func_id}

    occ =
      for entry <- by_line,
          func_id = Map.get(line_owner, entry.line),
          func_id != nil,
          {name, {tag, n}} when tag in [:x, :y] <- entry.vars,
          is_binary(name),
          reduce: %{} do
        acc ->
          rec = {entry.line, "#{tag}#{n}"}

          Map.update(acc, func_id, %{name => [rec]}, fn m ->
            Map.update(m, name, [rec], &[rec | &1])
          end)
      end

    Map.new(bundle, fn {func_id, fb} ->
      {func_id, Map.put(fb, :occupancy, Map.get(occ, func_id, %{}))}
    end)
  end

  defp idx_of(instr_id), do: instr_id |> String.split("#") |> List.last() |> String.to_integer()

  # `_state@2` -> `state`; a bare `state` is returned unchanged.
  defp demangle(mangled) do
    case Regex.run(~r/^_?([a-zA-Z][a-zA-Z0-9_]*?)(?:@\d+)?$/, mangled) do
      [_, base] -> base
      _ -> mangled
    end
  end
end
