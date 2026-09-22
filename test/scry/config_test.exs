defmodule Scry.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Scry.Config

  test "the default analyses are argus's default set" do
    assert Config.load([]).analyses == Scry.Analysis.default_analyses()
    assert {:ok, Config.load([]).analyses} == Argus.Analysis.set(:default)
  end

  test "a named set expands to its members, once" do
    {:ok, security} = Argus.Analysis.set(:security)
    assert Config.load(analyses: [:security, :exposure]).analyses == security
  end

  test "a retired name expands to its concerns with a notice" do
    output =
      capture_io(fn ->
        send(self(), {:analyses, Config.load(analyses: [:unsafe_task, :coupling]).analyses})
      end)

    assert_received {:analyses, [:failure, :mailbox, :coupling]}
    assert output =~ ":unsafe_task is retired in argus 0.17"
    assert output =~ ":failure, :mailbox"
  end

  test "a severity override keyed by a retired name follows its findings" do
    assert Config.load(severity: [gen_statem: :error, ets: :info]).severity ==
             %{mailbox: :error, state_machine: :error, ets: :info}
  end

  test "an unknown analysis fails with the concerns and the sets" do
    assert_raise Mix.Error, ~r/unknown analyses \[:nonsense\].*or a set: \[:all, :default/s, fn ->
      Config.load(analyses: [:coupling, :nonsense])
    end
  end
end
