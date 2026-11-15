defmodule Huddle.ChatTest do
  use Huddle.DataCase, async: true

  import Huddle.Fixtures

  alias Huddle.{Boards, Chat}

  setup do
    %{board: board_fixture(), user: user_fixture(%{"name" => "Grace"})}
  end

  test "create_message/3 stores the trimmed body and the author", %{board: board, user: user} do
    assert {:ok, message} = Chat.create_message(board, user, %{"body" => "  hello  "})
    assert message.body == "hello"
    assert message.kind == "user"
    assert message.author_name == "Grace"
  end

  test "create_message/3 rejects blank and oversized messages", %{board: board, user: user} do
    assert {:error, changeset} = Chat.create_message(board, user, %{"body" => "   "})
    assert "can't be blank" in errors_on(changeset).body

    too_long = String.duplicate("a", 1001)
    assert {:error, changeset} = Chat.create_message(board, user, %{"body" => too_long})
    assert "should be at most 1000 character(s)" in errors_on(changeset).body
  end

  test "new messages are broadcast to the board", %{board: board, user: user} do
    Boards.subscribe(board)

    {:ok, message} = Chat.create_message(board, user, %{"body" => "ping"})
    message_id = message.id
    assert_receive {:new_message, %{id: ^message_id, body: "ping"}}

    {:ok, _note} = Chat.create_system_message(board, "Grace moved a card")
    assert_receive {:new_message, %{kind: "system", body: "Grace moved a card"}}
  end

  test "list_messages/2 returns the latest messages oldest first", %{board: board, user: user} do
    for body <- ~w(one two three) do
      {:ok, _message} = Chat.create_message(board, user, %{"body" => body})
    end

    assert Enum.map(Chat.list_messages(board), & &1.body) == ~w(one two three)
    assert Enum.map(Chat.list_messages(board, 2), & &1.body) == ~w(two three)
  end

  test "list_messages/2 only returns messages of that board", %{board: board, user: user} do
    other = board_fixture(%{"name" => "Other"})
    {:ok, _message} = Chat.create_message(other, user, %{"body" => "elsewhere"})

    assert Chat.list_messages(board) == []
  end
end
