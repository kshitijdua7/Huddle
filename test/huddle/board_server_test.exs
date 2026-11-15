defmodule Huddle.BoardServerTest do
  use ExUnit.Case, async: true

  alias Huddle.{Boards, BoardServer}

  setup do
    # BoardServer never touches the database, so any unique id works. A string
    # keeps these ids apart from the integer ids of real boards in other tests.
    board_id = "test-board-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Huddle.PubSub, Boards.topic(board_id))
    %{board_id: board_id}
  end

  test "no process and no timer until one is started", %{board_id: board_id} do
    assert BoardServer.whereis(board_id) == nil
    assert BoardServer.timer(board_id) == nil
    assert BoardServer.stop_timer(board_id) == :ok
  end

  test "start_timer/2 starts the process and broadcasts the end time", %{board_id: board_id} do
    assert {:ok, %DateTime{} = ends_at} = BoardServer.start_timer(board_id, 60_000)
    assert_receive {:timer_started, ^ends_at}

    assert is_pid(BoardServer.whereis(board_id))
    assert BoardServer.timer(board_id) == ends_at
    assert DateTime.diff(ends_at, DateTime.utc_now(), :second) in 58..60
  end

  test "the timer finishes on its own and is cleared", %{board_id: board_id} do
    {:ok, _ends_at} = BoardServer.start_timer(board_id, 20)

    assert_receive :timer_finished, 1_000
    assert BoardServer.timer(board_id) == nil
  end

  test "stop_timer/1 cancels a running timer", %{board_id: board_id} do
    {:ok, _ends_at} = BoardServer.start_timer(board_id, 50)
    assert BoardServer.stop_timer(board_id) == :ok

    assert_receive :timer_stopped
    assert BoardServer.timer(board_id) == nil
    refute_receive :timer_finished, 150
  end

  test "restarting replaces the previous timer", %{board_id: board_id} do
    {:ok, _first} = BoardServer.start_timer(board_id, 30)
    {:ok, second} = BoardServer.start_timer(board_id, 60_000)

    refute_receive :timer_finished, 150
    assert BoardServer.timer(board_id) == second
  end

  test "each board has its own process", %{board_id: board_id} do
    other_id = "test-board-#{System.unique_integer([:positive])}"

    {:ok, _ends_at} = BoardServer.start_timer(board_id, 60_000)
    {:ok, _ends_at} = BoardServer.start_timer(other_id, 60_000)

    assert BoardServer.whereis(board_id) != BoardServer.whereis(other_id)

    # Killing one board's process leaves the other one untouched.
    pid = BoardServer.whereis(board_id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert %DateTime{} = BoardServer.timer(other_id)
  end

  describe "presenting" do
    @ada %{id: "ada", name: "Ada", color: "#f59e0b"}
    @grace %{id: "grace", name: "Grace", color: "#ec4899"}

    test "nobody presents until someone starts", %{board_id: board_id} do
      assert BoardServer.presenter(board_id) == nil
      assert BoardServer.stop_presenting(board_id, "ada") == :ok
    end

    test "start_presenting/3 sets the presenter and a newcomer can take over",
         %{board_id: board_id} do
      assert BoardServer.start_presenting(board_id, @ada, self()) == :ok
      assert_receive {:presenter_changed, @ada}
      assert BoardServer.presenter(board_id) == @ada

      assert BoardServer.start_presenting(board_id, @grace, self()) == :ok
      assert_receive {:presenter_changed, @grace}
      assert BoardServer.presenter(board_id) == @grace
    end

    test "stop_presenting/2 only works for the current presenter", %{board_id: board_id} do
      BoardServer.start_presenting(board_id, @ada, self())

      BoardServer.stop_presenting(board_id, "grace")
      assert BoardServer.presenter(board_id) == @ada

      BoardServer.stop_presenting(board_id, "ada")
      assert_receive {:presenter_changed, nil}
      assert BoardServer.presenter(board_id) == nil
    end

    test "presenting ends when the presenter's process exits", %{board_id: board_id} do
      pid = start_supervised!({Agent, fn -> :ok end})
      BoardServer.start_presenting(board_id, @ada, pid)
      assert_receive {:presenter_changed, @ada}

      stop_supervised!(Agent)

      assert_receive {:presenter_changed, nil}
      assert BoardServer.presenter(board_id) == nil
    end
  end
end
