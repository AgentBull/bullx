defmodule BullX.Runtime.Targets.StreamSink do
  @moduledoc false

  use GenServer

  @type chunk :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec stream(GenServer.server()) :: Enumerable.t()
  def stream(server) do
    Stream.resource(
      fn -> server end,
      &next_event/1,
      fn _server -> :ok end
    )
  end

  @spec push(GenServer.server(), chunk()) :: :ok
  def push(server, chunk) do
    GenServer.cast(server, {:push, chunk})
  end

  @spec finish(GenServer.server()) :: :ok
  def finish(server) do
    GenServer.cast(server, :finish)
  end

  @spec fail(GenServer.server(), term()) :: :ok
  def fail(server, reason) do
    GenServer.cast(server, {:fail, reason})
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @impl true
  def init(_opts) do
    {:ok, %{queue: :queue.new(), waiters: :queue.new(), done?: false, error: nil}}
  end

  @impl true
  def handle_call(:next, from, state) do
    next_response(state, from)
  end

  @impl true
  def handle_cast({:push, chunk}, state) do
    {:noreply, push_chunk(state, chunk)}
  end

  def handle_cast(:finish, state) do
    {:noreply, finish_state(state)}
  end

  def handle_cast({:fail, reason}, state) do
    {:noreply, fail_state(state, reason)}
  end

  defp next_event(server) do
    case GenServer.call(server, :next, :infinity) do
      {:chunk, chunk} -> {[chunk], server}
      :done -> {:halt, server}
      {:error, reason} -> raise RuntimeError, message: inspect(reason)
    end
  end

  defp next_response(%{queue: queue} = state, from) do
    case :queue.out(queue) do
      {{:value, chunk}, next_queue} ->
        {:reply, {:chunk, chunk}, %{state | queue: next_queue}}

      {:empty, queue} ->
        empty_next_response(%{state | queue: queue}, from)
    end
  end

  defp empty_next_response(%{error: nil, done?: true} = state, _from),
    do: {:stop, :normal, :done, state}

  defp empty_next_response(%{error: reason} = state, _from) when not is_nil(reason),
    do: {:stop, :normal, {:error, reason}, state}

  defp empty_next_response(state, from) do
    {:noreply, %{state | waiters: :queue.in(from, state.waiters)}}
  end

  defp push_chunk(%{done?: true} = state, _chunk), do: state
  defp push_chunk(%{error: reason} = state, _chunk) when not is_nil(reason), do: state

  defp push_chunk(%{waiters: waiters} = state, chunk) do
    case :queue.out(waiters) do
      {{:value, waiter}, next_waiters} ->
        GenServer.reply(waiter, {:chunk, chunk})
        %{state | waiters: next_waiters}

      {:empty, waiters} ->
        %{state | queue: :queue.in(chunk, state.queue), waiters: waiters}
    end
  end

  defp finish_state(%{done?: true} = state), do: state
  defp finish_state(%{error: reason} = state) when not is_nil(reason), do: state

  defp finish_state(state) do
    reply_waiters(state.waiters, :done)
    %{state | waiters: :queue.new(), done?: true}
  end

  defp fail_state(%{done?: true} = state, _reason), do: state
  defp fail_state(%{error: reason} = state, _reason) when not is_nil(reason), do: state

  defp fail_state(state, reason) do
    reply_waiters(state.waiters, {:error, reason})
    %{state | waiters: :queue.new(), error: reason}
  end

  defp reply_waiters(waiters, response) do
    waiters
    |> :queue.to_list()
    |> Enum.each(&GenServer.reply(&1, response))
  end
end
