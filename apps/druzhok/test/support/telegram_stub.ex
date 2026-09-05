defmodule Druzhok.TelegramStub do
  @moduledoc """
  A fake Telegram Bot API on Bypass for driving `Druzhok.ManagerBot`.

  `getUpdates` long-polls an in-memory queue: `push_update/2` makes the next
  poll return that update, otherwise the poll waits a few ms and returns `[]`
  (so the GenServer's loop stays cheap). Every call is recorded with its
  decoded params and can be waited on with `await_call/4`.

  Tokens must not contain `:` — Bypass routes go through Plug's path matcher,
  which treats it as a parameter marker.
  """

  @poll_idle_ms 30

  def start(token) do
    if String.contains?(token, ":"), do: raise(ArgumentError, "stub token must not contain ':'")

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"
    # Unlinked on purpose: a handler blocked on an agent that died with the
    # test process would exit mid-request, and Bypass reports that as a
    # failure. on_exit callbacks run LIFO, so this one runs before Bypass's
    # own verification (registered inside Bypass.open/0) and after the test
    # has stopped the bot it started.
    {:ok, calls} = Agent.start(fn -> [] end)
    {:ok, updates} = Agent.start(fn -> %{queue: [], managed_token: "999MANAGED"} end)

    prev = Application.get_env(:druzhok, :telegram_api_base)
    Application.put_env(:druzhok, :telegram_api_base, base)

    ExUnit.Callbacks.on_exit(fn ->
      Agent.stop(calls)
      Agent.stop(updates)

      if prev,
        do: Application.put_env(:druzhok, :telegram_api_base, prev),
        else: Application.delete_env(:druzhok, :telegram_api_base)
    end)

    stub = %{bypass: bypass, base: base, calls: calls, updates: updates, token: token}

    Bypass.stub(bypass, "POST", "/bot#{token}/getMe", fn conn ->
      record(stub, "getMe", conn)
      |> reply(%{"id" => 1, "is_bot" => true, "username" => "test_manager_bot"})
    end)

    Bypass.stub(bypass, "POST", "/bot#{token}/getUpdates", fn conn ->
      conn = record(stub, "getUpdates", conn)
      batch = Agent.get_and_update(updates, fn s -> {s.queue, %{s | queue: []}} end)
      if batch == [], do: Process.sleep(@poll_idle_ms)
      reply(conn, batch)
    end)

    for method <- ["sendMessage", "editMessageText"] do
      Bypass.stub(bypass, "POST", "/bot#{token}/#{method}", fn conn ->
        record(stub, method, conn)
        |> reply(%{"message_id" => System.unique_integer([:positive]), "chat" => %{"id" => 1}})
      end)
    end

    Bypass.stub(bypass, "POST", "/bot#{token}/answerCallbackQuery", fn conn ->
      record(stub, "answerCallbackQuery", conn) |> reply(true)
    end)

    Bypass.stub(bypass, "POST", "/bot#{token}/getManagedBotToken", fn conn ->
      conn = record(stub, "getManagedBotToken", conn)
      reply(conn, Agent.get(updates, & &1.managed_token))
    end)

    stub
  end

  @doc """
  Start an unlinked `Druzhok.ManagerBot` and stop it in `on_exit`. Stopping
  waits for the in-flight poll to finish, so no stub request is cut short.
  """
  def start_manager_bot do
    {:ok, pid} = GenServer.start(Druzhok.ManagerBot, [])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 10_000)
    end)

    pid
  end

  def push_update(%{updates: updates}, update) do
    Agent.update(updates, fn s -> %{s | queue: s.queue ++ [update]} end)
  end

  def set_managed_bot_token(%{updates: updates}, token) do
    Agent.update(updates, fn s -> %{s | managed_token: token} end)
  end

  @doc "Decoded params of every recorded call to `method`, oldest first."
  def calls(%{calls: calls}, method) do
    calls
    |> Agent.get(& &1)
    |> Enum.reverse()
    |> Enum.filter(&(&1.method == method))
    |> Enum.map(& &1.params)
  end

  @doc "Poll until a call to `method` satisfies `pred`; raise after `timeout_ms`."
  def await_call(stub, method, pred, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(stub, method, pred, deadline)
  end

  defp do_await(stub, method, pred, deadline) do
    case Enum.find(calls(stub, method), pred) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "no #{method} call matched within timeout; calls seen: #{inspect(calls(stub, method))}"
        end

        Process.sleep(20)
        do_await(stub, method, pred, deadline)

      params ->
        params
    end
  end

  defp record(%{calls: calls}, method, conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    params = if raw == "", do: %{}, else: Jason.decode!(raw)
    Agent.update(calls, &[%{method: method, params: params} | &1])
    conn
  end

  defp reply(conn, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => result}))
  end
end
