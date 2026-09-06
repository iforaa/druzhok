defmodule Druzhok.Embed.Worker do
  @moduledoc """
  The Python embedding worker (`priv/embed-worker/worker.py`) as an Erlang
  Port: texts in, unit vectors and a token count out. One long-lived process,
  calls serialized here, `{:packet, 4}` framing with a JSON object per message.

  Limits (batch size, text length) belong to the caller. Without a configured
  Python (`embed_worker_bin`) every call answers `{:error, :worker_down}` and
  embeddings are simply off; Mnemosyne then recalls by FTS alone.
  """

  use GenServer
  require Logger

  @default_timeout 10_000
  # Loading the ONNX model (~470 MB) happens once per worker start, in this
  # process but never inside `init/1` (the app would boot late) or a caller's
  # call; the worker announces `{"ready": true}` when done. After a failed
  # start the next attempt waits `@open_cooldown`, so a broken venv does not
  # spawn a dying Python per request.
  @load_timeout 60_000
  @open_cooldown 30_000

  @type result :: {:ok, %{vectors: [[float]], tokens: non_neg_integer}} | {:error, :embed_failed | :worker_down}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Embed a batch. Options: `timeout` in ms for the whole wait, queue included
  (default #{@default_timeout}), `server`.
  """
  @spec embed([String.t()], keyword) :: result
  def embed(texts, opts \\ []) when is_list(texts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(server, {:embed, texts, deadline}, timeout + 1_000)
  catch
    :exit, reason ->
      Logger.warning("[embed] worker call gave up: #{inspect(elem(reason, 0))}")
      {:error, :worker_down}
  end

  @impl true
  def init(opts) do
    bin = Keyword.get(opts, :bin, Application.get_env(:druzhok, :embed_worker_bin))
    model_dir = Keyword.get(opts, :model_dir, Application.get_env(:druzhok, :embed_model_dir))
    script = Keyword.get(opts, :script, Path.join(Application.app_dir(:druzhok, "priv/embed-worker"), "worker.py"))
    Process.flag(:trap_exit, true)
    state = %{bin: bin, script: script, model_dir: model_dir, port: nil, warned: false, retry_at: nil}
    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: {:noreply, open(state)}

  defp open(%{bin: nil} = state), do: state
  defp open(%{port: port} = state) when is_port(port), do: state

  defp open(%{bin: bin, script: script, model_dir: model_dir} = state) do
    cond do
      # Monotonic time may be negative, so the "never tried" sentinel is nil.
      state.retry_at != nil and System.monotonic_time(:millisecond) < state.retry_at ->
        state

      File.exists?(bin) and File.exists?(script) and is_binary(model_dir) and File.dir?(model_dir) ->
        port =
          Port.open({:spawn_executable, bin}, [:binary, {:packet, 4}, :exit_status, :use_stdio, args: [script, model_dir]])

        case await_ready(port) do
          nil -> %{state | port: nil, retry_at: System.monotonic_time(:millisecond) + @open_cooldown}
          port -> %{state | port: port}
        end

      true ->
        unless state.warned do
          Logger.warning("[embed] worker not started: #{inspect(bin)}, #{script} or model dir #{inspect(model_dir)} is missing")
        end

        %{state | port: nil, warned: true}
    end
  end

  defp await_ready(port) do
    receive do
      {^port, {:data, reply}} ->
        case Jason.decode(reply) do
          {:ok, %{"ready" => true}} ->
            port

          _ ->
            Logger.warning("[embed] worker sent #{inspect(String.slice(reply, 0, 80))} instead of ready; killing it")
            kill(port)
            nil
        end

      {^port, {:exit_status, status}} ->
        Logger.warning("[embed] worker exited with #{status} before it was ready (bad model dir or venv?)")
        nil
    after
      @load_timeout ->
        Logger.warning("[embed] worker not ready after #{@load_timeout} ms; killing it")
        kill(port)
        nil
    end
  end

  # No worker: answer now and (re)start one after the reply, so the model
  # load is never charged to a caller.
  @impl true
  def handle_call({:embed, _texts, _deadline}, _from, %{port: nil} = state) do
    {:reply, {:error, :worker_down}, state, {:continue, :open}}
  end

  def handle_call({:embed, texts, deadline}, _from, %{port: port} = state) do
    # The deadline was set when the caller enqueued; a request that waited
    # its whole budget in the mailbox is dropped, not run for nobody.
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("[embed] dropped a request that timed out while queued")
      {:reply, {:error, :worker_down}, state}
    else
      Port.command(port, Jason.encode!(%{texts: texts}))

      receive do
        {^port, {:data, reply}} ->
          {:reply, decode(reply), state}

        {^port, {:exit_status, status}} ->
          Logger.warning("[embed] worker exited with #{status} mid-request")
          {:reply, {:error, :embed_failed}, %{state | port: nil}, {:continue, :open}}
      after
        remaining ->
          Logger.warning("[embed] worker took longer than #{remaining} ms; killing it")
          kill(port)
          {:reply, {:error, :embed_failed}, %{state | port: nil}, {:continue, :open}}
      end
    end
  end

  # Closing the port only closes the pipes; a worker stuck in C code would go
  # on burning CPU beside its replacement, so the OS process is killed too.
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    Port.close(port)
  catch
    _, _ -> :ok
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[embed] worker exited with #{status}; restarting it")
    {:noreply, %{state | port: nil}, {:continue, :open}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, %{state | port: nil}, {:continue, :open}}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp decode(reply) do
    case Jason.decode(reply) do
      {:ok, %{"vectors" => vectors, "tokens" => tokens}} when is_list(vectors) and is_integer(tokens) ->
        {:ok, %{vectors: vectors, tokens: tokens}}

      _ ->
        {:error, :embed_failed}
    end
  end
end
