defmodule Huddle.BoardServer do
  @moduledoc """
  One lightweight process per active board, holding state that should be shared
  by everyone on the board but is not worth storing in the database: the
  shared countdown timer and who is presenting.

  Processes are started on demand under `Huddle.BoardSupervisor` (a
  `DynamicSupervisor`), registered by board id in `Huddle.BoardRegistry`, and
  shut themselves down after `@idle_timeout` without a running timer or a
  presenter. If one crashes, only that board's timer is lost; every other board
  keeps running.

  Timer changes are broadcast on the board's PubSub topic as
  `{:timer_started, ends_at}`, `:timer_stopped` and `:timer_finished`, and
  presenter changes as `{:presenter_changed, presenter_or_nil}`.
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

  @doc "Returns who is presenting as `%{id, name, color}`, or `nil`."
  def presenter(board_id) do
    case whereis(board_id) do
      nil -> nil
      pid -> safe_call(pid, :presenter, nil)
    end
  end

  @doc """
  Makes `user` the board's presenter, replacing anyone who was presenting.

  `pid` is the presenter's LiveView process. It is monitored, so presenting
  ends by itself when they close the tab or lose their connection.
  """
  def start_presenting(board_id, %{id: _, name: _, color: _} = user, pid) when is_pid(pid) do
    board_id
    |> ensure_started()
    |> GenServer.call({:start_presenting, user, pid})
  end

  @doc "Stops presenting, if `user_id` is the current presenter."
  def stop_presenting(board_id, user_id) do
    case whereis(board_id) do
      nil -> :ok
      pid -> safe_call(pid, {:stop_presenting, user_id}, :ok)
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
    state = %{board_id: board_id, ends_at: nil, token: nil, presenter: nil, presenter_ref: nil}
    {:ok, state, @idle_timeout}
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

  def handle_call(:presenter, _from, state) do
    {:reply, state.presenter, state, timeout(state)}
  end

  def handle_call({:start_presenting, user, pid}, _from, state) do
    if state.presenter_ref, do: Process.demonitor(state.presenter_ref, [:flush])
    broadcast(state.board_id, {:presenter_changed, user})

    state = %{state | presenter: user, presenter_ref: Process.monitor(pid)}
    {:reply, :ok, state, timeout(state)}
  end

  def handle_call({:stop_presenting, user_id}, _from, state) do
    state =
      case state.presenter do
        %{id: ^user_id} -> clear_presenter(state)
        _someone_else -> state
      end

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

  # The presenter's LiveView process ended.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{presenter_ref: ref} = state) do
    state = clear_presenter(state)
    {:noreply, state, timeout(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state, timeout(state)}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  defp clear_presenter(state) do
    if state.presenter_ref, do: Process.demonitor(state.presenter_ref, [:flush])
    broadcast(state.board_id, {:presenter_changed, nil})
    %{state | presenter: nil, presenter_ref: nil}
  end

  # Never time out while a timer is running or someone is presenting.
  defp timeout(%{ends_at: nil, presenter: nil}), do: @idle_timeout
  defp timeout(_state), do: :infinity

  defp broadcast(board_id, message) do
    Phoenix.PubSub.broadcast(Huddle.PubSub, Boards.topic(board_id), message)
  end
end
