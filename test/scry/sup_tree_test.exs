defmodule Scry.SupTreeTest do
  use ExUnit.Case, async: true

  alias Scry.SupTree

  describe "relations/0" do
    test "declares every relation build/1 actually reads" do
      # `supervision_tree` projects the fact set down to this list, and
      # `build/1` treats an absent relation as empty — so a relation read by
      # the code but missing from the list would not fail, it would render a
      # silently wrong tree. Pin the list against the source.
      source = File.read!("lib/scry/sup_tree.ex")

      read =
        ~r/Map\.get\((?:facts|\s*facts\s*),\s*:([a-z_]+)/
        |> Regex.scan(source)
        |> Enum.map(fn [_, rel] -> String.to_atom(rel) end)
        |> Enum.concat(
          ~r/\|>\s*Map\.get\(:([a-z_]+)/
          |> Regex.scan(source)
          |> Enum.map(fn [_, rel] -> String.to_atom(rel) end)
        )
        |> Enum.uniq()
        |> Enum.sort()

      declared = Enum.sort(SupTree.relations())

      assert read != [], "the scan found nothing — the extraction regex has drifted"

      assert read -- declared == [],
             "SupTree.build/1 reads #{inspect(read -- declared)} but relations/0 " <>
               "does not declare it; the projection would silently supply []"
    end
  end
end
