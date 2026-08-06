defmodule Mix.Tasks.Compile.ScryTest do
  @moduledoc """
  The Mix compiler integration, driven through the REAL chain:
  `compile!()` runs `:elixir` (producing the beams) and
  then `:scry` (analyzing them) inside a checked-out eusapia fixture.
  Each scry run builds a fresh roux database restored from the manifest,
  so every warm assertion exercises the cross-VM serialization path.
  """

  # Mix project stack + cwd changes — never async.
  use ExUnit.Case, async: false

  alias Scry.Test.{EusapiaFixture, QueryLog}

  @moduletag timeout: 300_000
  @moduletag :souffle

  setup do
    copy = EusapiaFixture.checkout!(Path.join(System.tmp_dir!(), "scry_mix_eusapia"))
    log = QueryLog.start()
    on_exit(fn -> QueryLog.detach(log) end)
    %{copy: copy, log: log}
  end

  # The full chain, repeatable: `Mix.Task.clear/0` re-enables the nested
  # compile tasks between runs, and `--no-prune-code-paths` keeps this
  # test VM's own apps (scry and its deps) loadable inside the fixture —
  # a real project gets that for free from its scry dependency.
  defp compile! do
    Mix.Task.clear()
    Mix.Task.run("compile", ["--no-prune-code-paths"])
  end

  # Writes a fixture source and bumps its mtime forward: back-to-back
  # edits inside one posix second are invisible to :elixir's
  # second-granularity staleness check.
  defp edit!(path, content) do
    File.write!(path, content)

    bump = Process.get({__MODULE__, :bump}, 0) + 1
    Process.put({__MODULE__, :bump}, bump)
    File.touch!(path, System.os_time(:second) + bump)
  end

  defp scry_diagnostics({_status, diagnostics}) do
    Enum.filter(diagnostics, &(&1.compiler_name == "scry"))
  end

  defp counts_by_code(diagnostics) do
    diagnostics
    |> Enum.map(&code_of/1)
    |> Enum.frequencies()
  end

  defp code_of(%{message: message}) do
    case Regex.run(~r/^\[scry\.([a-z_]+)\]/, message) do
      [_, code] -> code
      nil -> :infrastructure
    end
  end

  test "cold build, warm noop, line-only edit, semantic edit, deleted file", %{
    copy: copy,
    log: log
  } do
    Mix.Project.in_project(:eusapia, copy, fn _module ->
      # ── cold build ──────────────────────────────────────────────────
      result = compile!()
      diags = scry_diagnostics(result)

      # The eusapia goldens: two coupling findings at the tree
      # definition, one leaked task. Nothing else from the default set.
      assert counts_by_code(diags) == %{"one_for_one_coupling" => 2, "unsafe_task" => 1}

      coupling = Enum.filter(diags, &(code_of(&1) == "one_for_one_coupling"))
      assert Enum.all?(coupling, &String.ends_with?(&1.file, "lib/eusapia/application.ex"))
      assert Enum.all?(coupling, &is_integer(&1.position))
      assert Enum.all?(coupling, &(&1.severity == :warning))

      # The rendered frame carries the anchor label, the excerpt, the
      # remediation, and the cross-file evidence as a continuation frame.
      [first_coupling | _] = coupling
      assert first_coupling.details =~ "╭─[lib/eusapia/application.ex:"
      assert first_coupling.details =~ "supervision tree defined here"

      assert first_coupling.details =~
               "help: restart-coupled siblings belong under `rest_for_one`"

      assert first_coupling.details =~ "├─["
      assert first_coupling.details =~ "coupling call"

      # Extraction ran for every fixture module.
      modules = QueryLog.executions(log, :module_extraction)
      assert length(modules) == length(Path.wildcard(Path.join(copy, "lib/**/*.ex")))

      manifest = Path.join(Mix.Project.manifest_path(), "compile.scry")
      assert File.exists?(manifest)
      assert File.exists?(Path.join(Mix.Project.manifest_path(), "compile.scry.diagnostics"))

      # ── warm noop ───────────────────────────────────────────────────
      QueryLog.reset(log)
      result = compile!()
      diags = scry_diagnostics(result)

      # Prior findings re-emit from memo hits: same diagnostics, zero
      # extraction, zero solves.
      assert counts_by_code(diags) == %{"one_for_one_coupling" => 2, "unsafe_task" => 1}
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []

      # The persisted diagnostics callback serves the same list.
      assert Mix.Tasks.Compile.Scry.diagnostics() != []

      # ── line-only edit (the headline) ───────────────────────────────
      # A comment shifts every line: :elixir rewrites the beam
      # (Line/Dbgi chunks), scry re-extracts exactly that module, the
      # semantic facts compare equal, and NO solve re-runs — while the
      # reported line moves down by one.
      application = Path.join(copy, "lib/eusapia/application.ex")
      [%{position: line_before} | _] = coupling
      edit!(application, "# a comment\n" <> File.read!(application))

      QueryLog.reset(log)
      result = compile!()
      diags = scry_diagnostics(result)

      assert QueryLog.executions(log, :module_extraction) == [Eusapia.Application]
      assert QueryLog.executions(log, :souffle_solve) == []

      coupling = Enum.filter(diags, &(code_of(&1) == "one_for_one_coupling"))
      assert [%{position: line_after} | _] = coupling
      assert line_after == line_before + 1

      # ── semantic edit ───────────────────────────────────────────────
      # one_for_one → rest_for_one clears the coupling findings (the
      # keynote beat); the leaked task remains.
      rewritten =
        application
        |> File.read!()
        |> String.replace(":one_for_one", ":rest_for_one")

      edit!(application, rewritten)

      QueryLog.reset(log)
      result = compile!()
      diags = scry_diagnostics(result)

      assert counts_by_code(diags) == %{"unsafe_task" => 1}
      assert :one_for_one_coupling in QueryLog.executions(log, :souffle_solve)

      # ── deleted file ────────────────────────────────────────────────
      # Removing the module with the leaked task prunes its beam; the
      # input is GC'd and the finding disappears.
      # The diagnostic's file is absolute (and realpath'd — /private/var
      # while the checkout says /var); remove it directly.
      [unsafe] = Enum.filter(diags, &(code_of(&1) == "unsafe_task"))
      File.rm!(unsafe.file)

      QueryLog.reset(log)
      result = compile!()
      diags = scry_diagnostics(result)

      assert counts_by_code(diags) == %{}

      # And a further run is a clean noop.
      QueryLog.reset(log)
      result = compile!()
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []
      assert scry_diagnostics(result) == []
    end)
  end

  test "touch without edit is a noop past the prefilter", %{copy: copy, log: log} do
    Mix.Project.in_project(:eusapia, copy, fn _module ->
      compile!()

      # Touch a beam directly (mtime moves, content identical): the
      # scanner re-reads and re-hashes that one file, the input value
      # compares equal, and nothing downstream executes.
      beam = Path.join(Mix.Project.compile_path(), "Elixir.Eusapia.Queue.beam")
      File.touch!(beam, System.os_time(:second) + 5)

      QueryLog.reset(log)
      compile!()
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []
    end)
  end

  test "corrupt manifest falls back to a clean cold build", %{copy: copy, log: log} do
    Mix.Project.in_project(:eusapia, copy, fn _module ->
      result = compile!()
      assert counts_by_code(scry_diagnostics(result)) != %{}

      manifest = Path.join(Mix.Project.manifest_path(), "compile.scry")
      File.write!(manifest, "not a manifest")

      QueryLog.reset(log)
      result = compile!()

      # Full rebuild, same findings, no crash.
      assert counts_by_code(scry_diagnostics(result)) ==
               %{"one_for_one_coupling" => 2, "unsafe_task" => 1}

      assert QueryLog.executions(log, :module_extraction) != []
    end)
  end
end
