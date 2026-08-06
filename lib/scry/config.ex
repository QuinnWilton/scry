defmodule Scry.Config do
  @moduledoc """
  The `scry:` project configuration, validated loudly.

      def project do
        [
          compilers: Mix.compilers() ++ [:scry],
          scry: [
            analyses: [:supervision, :unsafe_task],
            severity: [unsafe_task: :error],
            ignore: [modules: [~r/^MyApp\\.Gen/], files: ["lib/legacy/**"]],
            include_deps: false,
            fail_on: :error,
            souffle: :warn
          ]
        ]
      end

  Every key is optional. `analyses` defaults to the shared layer's
  curated quiet set (`Scry.Analysis.default_analyses/0`); analysis names
  are validated against the argus registry so a typo aborts the compile
  instead of silently analyzing nothing.
  """

  @enforce_keys [
    :analyses,
    :severity,
    :ignore_modules,
    :ignore_files,
    :include_deps,
    :fail_on,
    :souffle
  ]
  defstruct [
    :analyses,
    :severity,
    :ignore_modules,
    :ignore_files,
    :include_deps,
    :fail_on,
    :souffle
  ]

  @type t :: %__MODULE__{
          analyses: [atom()],
          severity: %{optional(atom()) => :error | :warning | :info},
          ignore_modules: [Regex.t() | module()],
          ignore_files: [String.t()],
          include_deps: boolean(),
          fail_on: :error | :warning,
          souffle: :warn | :require
        }

  @severities [:error, :warning, :info]

  @doc """
  Loads and validates the current project's `scry:` keyword.
  """
  @spec load() :: t()
  def load do
    load(Mix.Project.config()[:scry] || [])
  end

  @doc """
  Validates a raw `scry:` keyword list into a config.
  """
  @spec load(keyword()) :: t()
  def load(raw) when is_list(raw) do
    known_keys = [:analyses, :severity, :ignore, :include_deps, :fail_on, :souffle]

    case Keyword.keys(raw) -- known_keys do
      [] -> :ok
      unknown -> fail("unknown scry config #{inspect(unknown)}; known: #{inspect(known_keys)}")
    end

    ignore = Keyword.get(raw, :ignore, [])

    %__MODULE__{
      analyses: analyses!(Keyword.get(raw, :analyses, Scry.Analysis.default_analyses())),
      severity: severity!(Keyword.get(raw, :severity, [])),
      ignore_modules: ignore_modules!(Keyword.get(ignore, :modules, [])),
      ignore_files: ignore_files!(Keyword.get(ignore, :files, [])),
      include_deps: boolean!(:include_deps, Keyword.get(raw, :include_deps, false)),
      fail_on: enum!(:fail_on, Keyword.get(raw, :fail_on, :error), [:error, :warning]),
      souffle: enum!(:souffle, Keyword.get(raw, :souffle, :warn), [:warn, :require])
    }
  end

  def load(other) do
    fail("scry config must be a keyword list, got: #{inspect(other)}")
  end

  defp analyses!(names) when is_list(names) do
    known = Enum.map(Argus.Analysis.builtin_analysis_modules(), & &1.name())

    case Enum.reject(names, &(&1 in known)) do
      [] ->
        names

      unknown ->
        fail("unknown analyses #{inspect(unknown)}; available: #{inspect(Enum.sort(known))}")
    end
  end

  defp analyses!(other), do: fail("analyses must be a list of atoms, got: #{inspect(other)}")

  defp severity!(pairs) when is_list(pairs) do
    Enum.each(pairs, fn
      {analysis, severity} when is_atom(analysis) and severity in @severities ->
        :ok

      other ->
        fail(
          "severity entries must be {analysis, :error | :warning | :info}, " <>
            "got: #{inspect(other)}"
        )
    end)

    Map.new(pairs)
  end

  defp severity!(other), do: fail("severity must be a keyword list, got: #{inspect(other)}")

  defp ignore_modules!(patterns) when is_list(patterns) do
    Enum.each(patterns, fn
      %Regex{} -> :ok
      atom when is_atom(atom) -> :ok
      other -> fail("ignore modules must be regexes or module atoms, got: #{inspect(other)}")
    end)

    patterns
  end

  defp ignore_modules!(other), do: fail("ignore modules must be a list, got: #{inspect(other)}")

  defp ignore_files!(globs) when is_list(globs) do
    Enum.each(globs, fn
      glob when is_binary(glob) -> :ok
      other -> fail("ignore files must be glob strings, got: #{inspect(other)}")
    end)

    globs
  end

  defp ignore_files!(other), do: fail("ignore files must be a list, got: #{inspect(other)}")

  defp boolean!(_key, value) when is_boolean(value), do: value
  defp boolean!(key, value), do: fail("#{key} must be a boolean, got: #{inspect(value)}")

  defp enum!(key, value, allowed) do
    if value in allowed do
      value
    else
      fail("#{key} must be one of #{inspect(allowed)}, got: #{inspect(value)}")
    end
  end

  @spec fail(String.t()) :: no_return()
  defp fail(message), do: Mix.raise("scry: " <> message)
end
