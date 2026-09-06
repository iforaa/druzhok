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
    {:ok, %{bin: bin, script: script, model_dir: model_dir, port: nil, warned: false} |> open()}
  end

  defp open(%{bin: nil} = state), do: state

  defp open(%{bin: bin, script: script, model_dir: model_dir} = state) do
    if File.exists?(bin) and File.exists?(script) and is_binary(model_dir) do
      port =
        Port.open({:spawn_executable, bin}, [:binary, {:packet, 4}, :exit_status, :use_stdio, args: [script, model_dir]])

      %{state | port: port}
    else
      unless state.warned do
        Logger.warning("[embed] worker not started: #{inspect(bin)}, #{script} or model dir #{inspect(model_dir)} is missing")
      end

      %{state | port: nil, warned: true}
    end
  end

  @impl true
  def handle_call({:embed, texts, deadline}, from, %{port: nil} = state) do
    case open(state) do
      %{port: nil} = state -> {:reply, {:error, :worker_down}, state}
      state -> handle_call({:embed, texts, deadline}, from, state)
    end
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
          {:reply, {:error, :embed_failed}, %{state | port: nil}}
      after
        remaining ->
          Logger.warning("[embed] worker took longer than #{remaining} ms; killing it")
          kill(port)
          {:reply, {:error, :embed_failed}, %{state | port: nil}}
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
    Logger.warning("[embed] worker exited with #{status}; it restarts on the next call")
    {:noreply, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, %{state | port: nil}}
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
