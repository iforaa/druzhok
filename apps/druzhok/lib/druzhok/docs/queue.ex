defmodule Druzhok.Docs.Queue do
  @moduledoc """
  One document conversion at a time for the whole box, up to `max_waiting`
  (4) waiting behind it in arrival order, and one per bot, running or
  waiting. `enter/1` blocks until the caller's turn, or answers
  `{:error, :busy}` at once. The slot goes with its holder when that process
  dies, so a request that crashed or was killed cannot hold the line.

  A bot's new request takes the place of its own request still waiting: the
  shim it came from has most likely given up (a skill's subprocess timeout),
  and the handler blocked here cannot see its client go. The old one is
  answered busy. A bot whose job is running still gets busy.

  The holder names its job dir (`started/1`). If it dies holding the slot
  (its client went away and Bandit took the handler with it), the job is
  stopped and its dir deleted (`Druzhok.Docs.cancel/1`) before the next one
  starts: the sandboxed unit does not die with the request.

  Job dirs a crash left are swept once per boot (`Druzhok.Docs.sweep/0`, an
  application task), not here: a restart of this process must not delete the
  dir of a job still converting.
  """

  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "`:ok` once the caller holds the slot; `{:error, :busy}` when the bot already has a job or the line is full."
  def enter(bot_id), do: GenServer.call(__MODULE__, {:enter, bot_id}, :infinity)

  @doc "Name the job dir the caller, holding the slot, is converting in."
  def started(job), do: GenServer.call(__MODULE__, {:started, job})

  @doc "Give the slot back (or leave the line). Safe to call more than once."
  def leave, do: GenServer.call(__MODULE__, :leave)

  @impl true
  def init(:ok) do
    {:ok, %{running: nil, job: nil, waiting: :queue.new()}}
  end

  @impl true
  def handle_call({:enter, bot}, {pid, _} = from, s) do
    s = replace_waiting(s, bot)

    cond do
      match?({_, ^bot, _}, s.running) ->
        {:reply, {:error, :busy}, s}

      s.running == nil ->
        {:reply, :ok, %{s | running: {pid, bot, Process.monitor(pid)}}}

      :queue.len(s.waiting) >= Druzhok.Docs.max_waiting() ->
        {:reply, {:error, :busy}, s}

      true ->
        {:noreply, %{s | waiting: :queue.in({from, pid, bot, Process.monitor(pid)}, s.waiting)}}
    end
  end

  def handle_call({:started, job}, {pid, _}, s) do
    case s.running do
      {^pid, _, _} -> {:reply, :ok, %{s | job: job}}
      _ -> {:reply, :ok, s}
    end
  end

  def handle_call(:leave, {pid, _}, s) do
    case s.running do
      {^pid, _, ref} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, advance(s)}

      _ ->
        {:reply, :ok, drop_waiting(s, &(elem(&1, 1) == pid))}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _}, s) do
    case s.running do
      {_, _, ^ref} ->
        if s.job, do: Druzhok.Docs.cancel(s.job)
        {:noreply, advance(s)}
      _ -> {:noreply, drop_waiting(s, &(elem(&1, 3) == ref))}
    end
  end

  defp advance(s) do
    case :queue.out(s.waiting) do
      {{:value, {from, pid, bot, ref}}, rest} ->
        GenServer.reply(from, :ok)
        %{s | running: {pid, bot, ref}, job: nil, waiting: rest}

      {:empty, _} ->
        %{s | running: nil, job: nil}
    end
  end

  defp drop_waiting(s, match?) do
    {gone, kept} = s.waiting |> :queue.to_list() |> Enum.split_with(match?)
    Enum.each(gone, fn {_, _, _, ref} -> Process.demonitor(ref, [:flush]) end)
    %{s | waiting: :queue.from_list(kept)}
  end

  defp replace_waiting(s, bot) do
    {gone, kept} = s.waiting |> :queue.to_list() |> Enum.split_with(fn {_, _, b, _} -> b == bot end)

    Enum.each(gone, fn {from, _, _, ref} ->
      Process.demonitor(ref, [:flush])
      GenServer.reply(from, {:error, :busy})
    end)

    %{s | waiting: :queue.from_list(kept)}
  end
end
