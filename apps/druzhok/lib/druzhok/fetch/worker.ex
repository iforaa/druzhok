defmodule Druzhok.Fetch.Worker do
  @moduledoc """
  The Python extraction worker (`priv/fetch-worker/worker.py`) as an Erlang
  Port: HTML or PDF bytes in, `{title, markdown}` out. One long-lived process,
  calls serialized here, `{:packet, 4}` framing with a JSON object per message.

  The worker has no network and applies no policy; it only transforms bytes
  the fetcher already read. Without a configured Python (`fetch_worker_bin`)
  every call answers `{:error, :worker_down}` and page reading is simply off.
  """

  use GenServer
  require Logger

  @default_timeout 20_000
  @max_chars 200_000

  @type kind :: :html | :pdf | :text | :feed
  @type result :: {:ok, %{title: String.t(), markdown: String.t()}} | {:error, :extract_failed | :worker_down}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Turn a fetched body into markdown. Options: `charset` (the Content-Type's,
  nil when absent), `timeout` in ms for the whole wait, queue included
  (default #{@default_timeout}), `server`.
  """
  @spec extract(kind, String.t(), binary, keyword) :: result
  def extract(kind, url, body, opts \\ []) when kind in [:html, :pdf, :text, :feed] do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    request = %{kind: kind, url: url, body: body, charset: Keyword.get(opts, :charset)}
    GenServer.call(server, {:extract, request, deadline}, timeout + 1_000)
  catch
    :exit, reason ->
      Logger.warning("[fetch] worker call gave up: #{inspect(elem(reason, 0))}")
      {:error, :worker_down}
  end

  @impl true
  def init(opts) do
    bin = Keyword.get(opts, :bin, Application.get_env(:druzhok, :fetch_worker_bin))
    Process.flag(:trap_exit, true)
    {:ok, %{bin: bin, port: nil, warned: false} |> open()}
  end

  defp open(%{bin: nil} = state), do: state

  defp open(%{bin: bin} = state) do
    script = Path.join(Application.app_dir(:druzhok, "priv/fetch-worker"), "worker.py")

    if File.exists?(bin) and File.exists?(script) do
      port =
        Port.open({:spawn_executable, bin}, [:binary, {:packet, 4}, :exit_status, :use_stdio, args: [script]])

      %{state | port: port}
    else
      unless state.warned, do: Logger.warning("[fetch] worker not started: #{bin} or #{script} is missing")
      %{state | port: nil, warned: true}
    end
  end

  @impl true
  def handle_call({:extract, request, deadline}, from, %{port: nil} = state) do
    case open(state) do
      %{port: nil} = state -> {:reply, {:error, :worker_down}, state}
      state -> handle_call({:extract, request, deadline}, from, state)
    end
  end

  def handle_call({:extract, request, deadline}, _from, %{port: port} = state) do
    # The deadline was set when the caller enqueued; a request that waited
    # its whole budget in the mailbox is dropped, not run for nobody.
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("[fetch] dropped a request that timed out while queued")
      {:reply, {:error, :worker_down}, state}
    else
      Port.command(port, encode(request))

      receive do
        {^port, {:data, reply}} ->
          {:reply, decode(reply), state}

        {^port, {:exit_status, status}} ->
          Logger.warning("[fetch] worker exited with #{status} mid-request")
          {:reply, {:error, :extract_failed}, %{state | port: nil}}
      after
        remaining ->
          Logger.warning("[fetch] worker took longer than #{remaining} ms; killing it")
          kill(port)
          {:reply, {:error, :extract_failed}, %{state | port: nil}}
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

  defp encode(%{kind: kind, url: url, body: body, charset: charset}) do
    Jason.encode!(%{kind: kind, url: url, body_b64: Base.encode64(body), charset: charset})
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[fetch] worker exited with #{status}; it restarts on the next call")
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
      {:ok, %{"title" => title, "markdown" => markdown}} when is_binary(markdown) ->
        {:ok, %{title: to_string(title || ""), markdown: String.slice(markdown, 0, @max_chars)}}

      _ ->
        {:error, :extract_failed}
    end
  end
end
