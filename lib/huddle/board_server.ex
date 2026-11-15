defmodule Huddle.BoardServer do
  @moduledoc """
  One lightweight process per active board, holding state that should be shared
  by everyone on the board but is not worth storing in the database: the
  shared countdown timer.

  Processes are started on demand under `Huddle.BoardSupervisor` (a
  `DynamicSupervisor`), registered by board id in `Huddle.BoardRegistry`, and
  shut themselves down after `@idle_timeout` without a running timer. If one
  crashes, only that board's timer is lost; every other board keeps running.

  Timer changes are broadcast on the board's PubSub topic as
  `{:timer_started, ends_at}`, `:timer_stopped` and `:timer_finished`.
  """
  use GenServer, restart: :transient

  alias Huddle.Boards

  @idle_timeout :timer.minutes(10)

  ## Client API

  def start_link(board_id) do
    GenServer.start_link(__MODULE__, board_id, name: via(board_id))
  end

  @doc "Returns the `DateTime` the board's timer ends at, or `nil` if none is running."
  def timer(board_id) do
    case whereis(board_id) do
      nil -> nil
      pid -> safe_call(pid, :timer, nil)
    end
  end

  @doc "Starts (or restarts) the board's timer. Returns `{:ok, ends_at}`."
  def start_timer(board_id, duration_ms) when is_integer(duration_ms) and duration_ms > 0 do
    board_id
    |> ensure_started()
    |> GenServer.call({:start_timer, duration_ms})
  end

  @doc "Stops the board's timer if one is running."
  def stop_timer(board_id) do
    case whereis(board_id) do
      nil -> :ok
      pid -> safe_call(pid, :stop_timer, :ok)
    end
  end

  @doc "Returns the pid of the board's process, or `nil` if it is not running."
  def whereis(board_id) do
    case Registry.lookup(Huddle.BoardRegistry, board_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp ensure_started(board_id) do
    case DynamicSupervisor.start_child(Huddle.BoardSupervisor, {__MODULE__, board_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp via(board_id), do: {:via, Registry, {Huddle.BoardRegistry, board_id}}

  # The process may shut down (idle timeout) between the lookup and the call.
  defp safe_call(pid, message, default) do
    GenServer.call(pid, message)
  catch
    :exit, _reason -> default
  end

  ## Server callbacks

  @impl true
  def init(board_id) do
    {:ok, %{board_id: board_id, ends_at: nil, token: nil}, @idle_timeout}
  end

  @impl true
  def handle_call(:timer, _from, state) do
    {:reply, state.ends_at, state, timeout(state)}
  end

  def handle_call({:start_timer, duration_ms}, _from, state) do
    token = make_ref()
    ends_at = DateTime.add(DateTime.utc_now(), duration_ms, :millisecond)
    Process.send_after(self(), {:timer_finished, token}, duration_ms)
    broadcast(state.board_id, {:timer_started, ends_at})

    state = %{state | ends_at: ends_at, token: token}
    {:reply, {:ok, ends_at}, state, timeout(state)}
  end

  def handle_call(:stop_timer, _from, state) do
    if state.ends_at, do: broadcast(state.board_id, :timer_stopped)

    state = %{state | ends_at: nil, token: nil}
    {:reply, :ok, state, timeout(state)}
  end

  @impl true
  def handle_info({:timer_finished, token}, %{token: token} = state) do
    broadcast(state.board_id, :timer_finished)

    state = %{state | ends_at: nil, token: nil}
    {:noreply, state, timeout(state)}
  end

  # A timer that was stopped or restarted before it fired: ignore it.
  def handle_info({:timer_finished, _stale_token}, state) do
    {:noreply, state, timeout(state)}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  # Never time out while a timer is running.
  defp timeout(%{ends_at: nil}), do: @idle_timeout
  defp timeout(_state), do: :infinity

  defp broadcast(board_id, message) do
    Phoenix.PubSub.broadcast(Huddle.PubSub, Boards.topic(board_id), message)
  end
end
