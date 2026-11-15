defmodule Huddle.IdentityTest do
  use ExUnit.Case, async: true

  alias Huddle.Identity

  test "generate/0 builds a unique identity with a name and a hex colour" do
    first = Identity.generate()
    second = Identity.generate()

    assert first["id"] != second["id"]
    assert first["name"] == "Kshitij Dua"
    assert second["name"] == "Kshitij Dua"
    assert first["color"] =~ ~r/^#[0-9a-f]{6}$/
  end

  test "rename/2 trims and limits the name, keeping id and colour" do
    identity = Identity.generate()

    assert {:ok, renamed} = Identity.rename(identity, "  Kshitij  ")
    assert renamed["name"] == "Kshitij"
    assert renamed["id"] == identity["id"]
    assert renamed["color"] == identity["color"]

    assert {:ok, %{"name" => name}} = Identity.rename(identity, String.duplicate("a", 50))
    assert String.length(name) == 24
  end

  test "rename/2 rejects a blank name" do
    assert {:error, _message} = Identity.rename(Identity.generate(), "   ")
  end

  test "initials/1 returns up to two uppercase initials" do
    assert Identity.initials("brave otter") == "BO"
    assert Identity.initials("Kshitij") == "K"
    assert Identity.initials("a b c") == "AB"
    assert Identity.initials("") == "?"
  end
end
