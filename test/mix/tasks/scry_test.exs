defmodule Mix.Tasks.ScryTest do
  @moduledoc """
  The standalone one-shot task, driven inside the eusapia fixture. The
  compiler runs first (via the full chain), so the standalone runs
  exercise the shared-manifest warm path.
  """

  # Mix project stack + cwd changes — never async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Scry.Test.{EusapiaFixture, QueryLog}

  @moduletag timeout: 300_000
  @moduletag :souffle

  setup do
    copy = EusapiaFixture.checkout!(Path.join(System.tmp_dir!(), "scry_task_eusapia"))
    log = QueryLog.start()
    on_exit(fn -> QueryLog.detach(log) end)
    %{copy: copy, log: log}
  end

  defp compile! do
    Mix.Task.clear()
    Mix.Task.run("compile", ["--return-errors", "--no-prune-code-paths"])
  end

  test "runs warm off the compiler's manifest and reports", %{copy: copy, log: log} do
    Mix.Project.in_project(:eusapia, copy, fn _module ->
      compile!()

      # The standalone task shares the compiler's manifest: nothing
      # re-extracts, nothing re-solves.
      QueryLog.reset(log)

      output =
        capture_io(:stderr, fn ->
          Mix.Task.rerun("scry", [])
        end)

      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []

      assert output =~ "warning[scry.one_for_one_coupling]"
      assert output =~ "warning[scry.unsafe_task]"
      assert output =~ "3 findings (3 warnings)"
    end)
  end

  test "--format json emits the stable schema", %{copy: copy} do
    Mix.Project.in_project(:eusapia, copy, fn _module ->
      compile!()

      json =
        capture_io(fn ->
          Mix.Task.rerun("scry", ["--format", "json"])
        end)

      entries = JSON.decode!(json)
      assert length(entries) == 3

      coupling = Enum.filter(entries, &(&1["analysis"] == "one_for_one_coupling"))
      assert length(coupling) == 2

      [first | _] = coupling
      assert first["severity"] == "warning"
      assert first["file"] == "lib/eusapia/application.ex"
      assert is_integer(first["line"])
      assert first["title"] == "Coupled children under one_for_one"
      assert is_binary(first["detail"])
      assert [help | _] = first["help"]
      assert help =~ "rest_for_one"

      assert Enum.any?(first["related"], fn related ->
               related["label"] == "coupling call" and is_integer(related["line"]) and
                 String.starts_with?(related["file"], "lib/eusapia/")
             end)
    end)
  end

  test "--fail-above raises when the count is exceeded", %{copy: copy} do
    Mix.Project.in_project(:eusapia, copy, fn _module ->
      compile!()

      assert_raise Mix.Error, ~r/3 findings exceed --fail-above 0/, fn ->
        capture_io(:stderr, fn -> Mix.Task.rerun("scry", ["--fail-above", "0"]) end)
      end

      # At or below the threshold passes.
      capture_io(:stderr, fn ->
        assert Mix.Task.rerun("scry", ["--fail-above", "3"]) != :failed
      end)
    end)
  end

  test "positional analyses narrow the run; unknown names abort", %{copy: copy} do
    Mix.Project.in_project(:eusapia, copy, fn _module ->
      compile!()

      output =
        capture_io(:stderr, fn ->
          Mix.Task.rerun("scry", ["unsafe_task"])
        end)

      assert output =~ "warning[scry.unsafe_task]"
      refute output =~ "one_for_one_coupling"
      assert output =~ "1 finding (1 warning)"

      assert_raise Mix.Error, ~r/unknown analyses \[:nonsense\]/, fn ->
        capture_io(:stderr, fn -> Mix.Task.rerun("scry", ["nonsense"]) end)
      end
    end)
  end

  test "--list names every analysis and marks the default set", %{copy: copy} do
    Mix.Project.in_project(:eusapia, copy, fn _module ->
      output = capture_io(fn -> Mix.Task.rerun("scry", ["--list"]) end)

      assert output =~ "* one_for_one_coupling"
      assert output =~ "* unsafe_task"
      assert output =~ "  atom_safety"
      refute output =~ "coverage"
    end)
  end
end
