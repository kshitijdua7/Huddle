defmodule Huddle.ReactionsTest do
  use ExUnit.Case, async: true

  alias Huddle.Reactions

  test "toggle/3 adds a person, then removes them and the empty emoji" do
    reactions = Reactions.toggle(%{}, "👍", "ada")
    assert reactions == %{"👍" => ["ada"]}
    assert Reactions.toggle(reactions, "👍", "ada") == %{}
  end

  test "summarize/2 counts each emoji in display order and marks the viewer's own" do
    reactions = %{"🎉" => ["ada"], "👍" => ["ada", "grace"]}

    assert Reactions.summarize(reactions, "grace") == [
             %{emoji: "👍", index: 0, count: 2, mine?: true},
             %{emoji: "🎉", index: 2, count: 1, mine?: false}
           ]
  end
end
