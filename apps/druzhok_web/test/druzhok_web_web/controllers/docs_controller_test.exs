defmodule DruzhokWebWeb.DocsControllerTest.FakeRunner do
  @moduledoc "Stands in for the sandboxed wrapper: what it does is set per test."
  @behaviour Druzhok.Docs.Runner

  @impl true
  def cancel(job) do
    {_, test} = Application.get_env(:druzhok, :docs_fake)
    send(test, {:cancel, job, File.dir?(job)})
    :ok
  end

  @impl true
  def run(job, to, filter) do
    {mode, test} = Application.get_env(:druzhok, :docs_fake)
    [input] = File.ls!(Path.join(job, "in"))
    send(test, {:job, job, input, to, filter})
    out = Path.join([job, "out", "input." <> to])

    case mode do
      :ok ->
        File.write!(out, "converted:" <> File.read!(Path.join([job, "in", input])))
        {:ok, out}

      :block ->
        send(test, {:running, self()})

        receive do
          :go -> :ok
        end

        File.write!(out, "late")
        {:ok, out}

      :symlink ->
        File.ln_s!("/etc/hosts", out)
        {:ok, out}

      :other_path ->
        File.write!(Path.join(job, "elsewhere.pdf"), "x")
        {:ok, Path.join(job, "elsewhere.pdf")}

      :empty ->
        File.write!(out, "")
        {:ok, out}

      :raise ->
        raise "runner crashed"

      {:error, _} = error ->
        error
    end
  end
end

defmodule DruzhokWebWeb.DocsControllerTest do
  use DruzhokWebWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import DruzhokWebWeb.ProxyCase, only: [create_instance: 1, authed: 2]

  alias DruzhokWebWeb.DocsControllerTest.FakeRunner

  setup do
    root = Path.join(System.tmp_dir!(), "druzhok-docs-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev_docs = Application.get_env(:druzhok, :docs)

    Application.put_env(:druzhok, :docs,
      runner: FakeRunner,
      jobs_root: root,
      min_free_mb: 900,
      meminfo_path: Path.join(root, "no-meminfo")
    )

    Application.put_env(:druzhok, :docs_fake, {:ok, self()})
    # Ids restart with the sandbox; a killed request's entry would linger.
    :ets.delete_all_objects(:druzhok_inflight)

    on_exit(fn ->
      if prev_docs, do: Application.put_env(:druzhok, :docs, prev_docs), else: Application.delete_env(:druzhok, :docs)
      Application.delete_env(:druzhok, :docs_fake)
      File.rm_rf!(root)
    end)

    %{root: root, instance: create_instance(%{})}
  end

  defp docs_env(changes),
    do: Application.put_env(:druzhok, :docs, Keyword.merge(Application.get_env(:druzhok, :docs), changes))

  defp fake(mode), do: Application.put_env(:druzhok, :docs_fake, {mode, self()})

  defp as_bot(conn, instance), do: put_req_header(conn, "x-druzhok-docs-bot", instance.name)

  @boundary "----docs-test-boundary"

  defp form(fields, file \\ {"отчёт.docx", "DOCX BYTES"}) do
    parts =
      Enum.map(fields, fn {k, v} ->
        "--#{@boundary}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n"
      end)

    file_part =
      case file do
        nil ->
          []

        {name, data} ->
          [
            "--#{@boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{name}\"\r\n" <>
              "Content-Type: application/octet-stream\r\n\r\n" <> data <> "\r\n"
          ]
      end

    IO.iodata_to_binary([parts, file_part, "--#{@boundary}--\r\n"])
  end

  defp convert(conn, body) do
    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
    |> post("/v2/docs/convert", body)
  end

  defp error(conn), do: Jason.decode!(conn.resp_body)["error"]
  defp message(conn), do: Jason.decode!(conn.resp_body)["message"]

  defp assert_no_jobs(root), do: assert(File.ls!(root) == [])

  describe "a conversion" do
    test "sends the file to the runner as in/input.<ext> and answers with the result", %{conn: conn, instance: inst, root: root} do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :info], fn ->
          conn = conn |> as_bot(inst) |> convert(form(%{"to" => "pdf"}))

          assert conn.status == 200
          assert conn.resp_body == "converted:DOCX BYTES"
          assert get_resp_header(conn, "content-type") == ["application/pdf"]
          [cd] = get_resp_header(conn, "content-disposition")
          assert cd =~ ~s(attachment; filename="_____.pdf")
          assert cd =~ "filename*=UTF-8''%D0%BE%D1%82%D1%87%D1%91%D1%82.pdf"
        end)

      assert_received {:job, job, "input.docx", "pdf", nil}
      assert Path.dirname(job) == root
      assert Path.basename(job) =~ ~r/^[A-Za-z0-9_-]{32}$/
      assert_no_jobs(root)

      assert log =~ "[docs] bot=#{inst.name} in=docx to=pdf bytes_in=10 bytes_out=20"
      assert log =~ "result=ok"
      refute log =~ "отчёт"
    end

    test "passes an allowed filter on", %{conn: conn, instance: inst} do
      conn = conn |> as_bot(inst) |> convert(form(%{"to" => "xlsx", "filter" => "Calc MS Excel 2007 XML"}, {"a.xlsx", "X"}))
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]
      assert_received {:job, _, "input.xlsx", "xlsx", "Calc MS Excel 2007 XML"}
    end

    test "a tenant key identifies the bot too", %{conn: conn, instance: inst} do
      conn = conn |> authed(inst) |> convert(form(%{"to" => "odt"}, {"a.DOC", "D"}))
      assert conn.status == 200
      assert_received {:job, _, "input.doc", "odt", nil}
    end

    test "csv out of a spreadsheet, as the xlsx skill runs it", %{conn: conn, instance: inst} do
      conn = conn |> as_bot(inst) |> convert(form(%{"to" => "csv"}, {"report.xlsx", "X"}))
      assert conn.status == 200
      assert [cd] = get_resp_header(conn, "content-disposition")
      assert cd =~ ~s(filename="report.csv")
      assert_received {:job, _, "input.xlsx", "csv", nil}
    end
  end

  describe "auth" do
    test "no key and no bot socket is 403", %{conn: conn} do
      conn = convert(conn, form(%{"to" => "pdf"}))
      assert conn.status == 403
      assert error(conn) == "forbidden"
      refute_received {:job, _, _, _, _}
    end

    test "a wrong key is 401", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer nope") |> convert(form(%{"to" => "pdf"}))
      assert conn.status == 401
      refute_received {:job, _, _, _, _}
    end

    test "the dev header names no bot unless enabled, and names only real bots", %{conn: conn, instance: inst} do
      conn2 = conn |> put_req_header("x-druzhok-docs-bot", "nobody") |> convert(form(%{"to" => "pdf"}))
      assert conn2.status == 403

      Application.put_env(:druzhok_web, :docs_dev_bot_header, false)
      on_exit(fn -> Application.put_env(:druzhok_web, :docs_dev_bot_header, true) end)

      conn3 = build_conn() |> as_bot(inst) |> convert(form(%{"to" => "pdf"}))
      assert conn3.status == 403
      refute_received {:job, _, _, _, _}
    end

    test "a bot being deleted is refused", %{conn: conn, instance: inst} do
      inst |> Ecto.Changeset.change(delete_requested: true) |> Druzhok.Repo.update!()
      assert (conn |> as_bot(inst) |> convert(form(%{"to" => "pdf"}))).status == 403
    end

    @tag :tmp_dir
    test "on the systemd host the socket's owner names the bot and the dev header is ignored", %{tmp_dir: dir, instance: inst} do
      tcp = Path.join(dir, "tcp")
      passwd = Path.join(dir, "passwd")

      File.write!(tcp, """
        sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
         0: 0100007F:D431 0100007F:0FA0 01 00000000:00000000 00:00000000 00000000  1001        0 13 1
         1: 0100007F:D432 0100007F:0FA0 01 00000000:00000000 00:00000000 00000000  1000        0 14 1
      """)

      File.write!(passwd, "ubuntu:x:1000:1000::/home/ubuntu:/bin/bash\nbot-#{inst.name}:x:1001:1001::/x:/usr/sbin/nologin\n")

      prev_host = Application.get_env(:druzhok, :host)
      Application.put_env(:druzhok, :host, Druzhok.Host.Systemd)
      Application.put_env(:druzhok, :peer_uid_tables, [tcp])
      Application.put_env(:druzhok, :peer_uid_passwd, passwd)

      on_exit(fn ->
        Application.put_env(:druzhok, :host, prev_host)
        Application.delete_env(:druzhok, :peer_uid_tables)
        Application.delete_env(:druzhok, :peer_uid_passwd)
      end)

      at = fn port ->
        build_conn()
        |> Plug.Test.put_peer_data(%{address: {127, 0, 0, 1}, port: port, ssl_cert: nil})
        |> Plug.Test.put_sock_data(%{address: {127, 0, 0, 1}, port: 4000})
      end

      ok = at.(0xD431) |> convert(form(%{"to" => "pdf"}))
      assert ok.status == 200
      assert_received {:job, _, "input.docx", "pdf", nil}

      # druzhok's own user, and a header naming a bot: both refused.
      refused = at.(0xD432) |> as_bot(inst) |> convert(form(%{"to" => "pdf"}))
      assert refused.status == 403
      refute_received {:job, _, _, _, _}
    end
  end

  describe "refusals before a job" do
    test "bad or missing fields are 400", %{conn: conn, instance: inst, root: root} do
      for body <- [
            form(%{}),
            form(%{"to" => "exe"}),
            form(%{"to" => "pdf"}, nil),
            form(%{"to" => "pdf", "filter" => "Calc MS Excel 2007 XML"}),
            form(%{"to" => "pdf", "filter" => "writer_pdf_Export:{\"x\":1}"})
          ] do
        conn = conn |> as_bot(inst) |> convert(body)
        assert conn.status == 400, inspect(body)
        assert error(conn) == "bad_request"
        assert message(conn) =~ "Неверный запрос"
      end

      plain = build_conn() |> as_bot(inst) |> put_req_header("content-type", "application/json") |> post("/v2/docs/convert", "{}")
      assert plain.status == 400

      refute_received {:job, _, _, _, _}
      assert_no_jobs(root)
    end

    test "a type not on the list, PDF included, is 415", %{conn: conn, instance: inst} do
      for name <- ["scan.pdf", "run.exe", "noext", "archive.docx.zip"] do
        conn = conn |> as_bot(inst) |> convert(form(%{"to" => "pdf"}, {name, "x"}))
        assert conn.status == 415, name
        assert error(conn) == "unsupported_type"
      end

      refute_received {:job, _, _, _, _}
    end

    test "a file at the limit passes with its framing; over it is 413, declared or not", %{conn: conn, instance: inst} do
      docs_env(max_input_bytes: 1_000)
      exact = form(%{"to" => "pdf"}, {"a.docx", String.duplicate("x", 1_000)})
      assert (build_conn() |> as_bot(inst) |> convert(exact)).status == 200
      assert_received {:job, _, _, _, _}

      over = form(%{"to" => "pdf"}, {"a.docx", String.duplicate("x", 1_001)})
      conn0 = build_conn() |> as_bot(inst) |> convert(over)
      assert conn0.status == 413

      big = form(%{"to" => "pdf"}, {"a.docx", String.duplicate("x", 200_000)})

      conn1 = conn |> as_bot(inst) |> convert(big)
      assert conn1.status == 413
      assert error(conn1) == "too_large"

      conn2 =
        build_conn()
        |> as_bot(inst)
        |> put_req_header("content-length", "5000000")
        |> convert(form(%{"to" => "pdf"}))

      assert conn2.status == 413
      refute_received {:job, _, _, _, _}
    end

    test "low memory is 503 and no job starts", %{conn: conn, instance: inst, root: root} do
      meminfo = Path.join(root, "meminfo")
      File.write!(meminfo, "MemTotal: 4000000 kB\nMemAvailable:  512000 kB\n")
      docs_env(meminfo_path: meminfo)

      conn = conn |> as_bot(inst) |> convert(form(%{"to" => "pdf"}))
      assert conn.status == 503
      assert error(conn) == "low_memory"
      refute_received {:job, _, _, _, _}
      assert File.ls!(root) == ["meminfo"]

      File.write!(meminfo, "MemAvailable:  1024000 kB\n")
      assert (build_conn() |> as_bot(inst) |> convert(form(%{"to" => "pdf"}))).status == 200
    end

    test "docs_min_free_mb comes from Settings when not configured" do
      docs_env(min_free_mb: nil)
      assert Druzhok.Docs.min_free_mb() == 900
      Druzhok.Settings.set("docs_min_free_mb", "1200")
      assert Druzhok.Docs.min_free_mb() == 1200
      Druzhok.Settings.set("docs_min_free_mb", "lots")
      assert Druzhok.Docs.min_free_mb() == 900
      assert "docs_min_free_mb" in Druzhok.Settings.keys()
    end
  end

  describe "runner outcomes, and the job dir goes every time" do
    for {mode, status, code} <- [
          {{:error, :failed}, 422, "convert_failed"},
          {{:error, :timeout}, 504, "timeout"},
          {{:error, :unavailable}, 503, "unavailable"},
          {:symlink, 422, "convert_failed"},
          {:other_path, 422, "convert_failed"},
          {:empty, 422, "convert_failed"}
        ] do
      test "#{inspect(mode)} → #{status}", %{conn: conn, instance: inst, root: root} do
        fake(unquote(Macro.escape(mode)))

        capture_log(fn ->
          conn = conn |> as_bot(inst) |> convert(form(%{"to" => "pdf"}))
          assert conn.status == unquote(status)
          assert error(conn) == unquote(code)
        end)

        assert_received {:job, _, _, _, _}
        assert_no_jobs(root)
      end
    end
  end

  test "a runner that raises leaves no job dir and frees the slot", %{conn: conn, instance: inst, root: root} do
    fake(:raise)
    assert_raise RuntimeError, ~r/runner crashed/, fn -> conn |> as_bot(inst) |> convert(form(%{"to" => "pdf"})) end
    assert_no_jobs(root)
    assert :sys.get_state(Druzhok.Docs.Queue).running == nil
  end

  describe "the line" do
    defp start_request(inst, test) do
      Task.async(fn ->
        Application.put_env(:druzhok, :docs_fake, {:block, test})
        build_conn() |> as_bot(inst) |> convert(form(%{"to" => "pdf"}))
      end)
    end

    test "one job at a time, max_waiting behind it, one per bot; the rest is 429 busy", %{instance: a, root: root} do
      docs_env(max_waiting: 1)
      fake(:block)
      b = create_instance(%{})
      c = create_instance(%{})

      t1 = start_request(a, self())
      assert_receive {:running, runner1}, 2_000

      # Same bot again while its job runs.
      same = build_conn() |> as_bot(a) |> convert(form(%{"to" => "pdf"}))
      assert same.status == 429
      assert error(same) == "busy"
      assert message(same) =~ "занят"

      t2 = start_request(b, self())
      wait_until(fn -> waiting() == 1 end)
      refute_received {:running, _}

      full = build_conn() |> as_bot(c) |> convert(form(%{"to" => "pdf"}))
      assert full.status == 429

      send(runner1, :go)
      assert Task.await(t1).status == 200
      assert_receive {:running, runner2}, 2_000
      send(runner2, :go)
      assert Task.await(t2).status == 200
      assert_no_jobs(root)
      assert inflight_clear?(a) and inflight_clear?(b)
    end

    test "a bot's new request replaces its own waiting one, which is answered busy", %{instance: a} do
      fake(:block)
      b = create_instance(%{})
      t1 = start_request(b, self())
      assert_receive {:running, runner1}, 2_000

      t2 = start_request(a, self())
      wait_until(fn -> waiting() == 1 end)
      t3 = start_request(a, self())
      assert Task.await(t2).status == 429
      assert waiting() == 1

      send(runner1, :go)
      assert Task.await(t1).status == 200
      assert_receive {:running, runner3}, 2_000
      send(runner3, :go)
      assert Task.await(t3).status == 200
    end

    test "a request that dies mid-conversion has its job stopped and deleted, and frees its place", %{instance: a, root: root} do
      fake(:block)
      t1 = start_request(a, self())
      assert_receive {:job, job, _, _, _}, 2_000
      assert_receive {:running, _runner}, 2_000

      capture_log(fn ->
        Task.shutdown(t1, :brutal_kill)
        assert_receive {:cancel, ^job, true}, 2_000
        wait_until(fn -> :sys.get_state(Druzhok.Docs.Queue).running == nil end)
      end)

      assert_no_jobs(root)

      fake(:ok)
      wait_until(fn -> :sys.get_state(Druzhok.Docs.Queue).running == nil end)
      assert (build_conn() |> as_bot(a) |> convert(form(%{"to" => "pdf"}))).status == 200
    end
  end

  test "sweep deletes job dirs a crash left; a queue restart deletes nothing", %{root: root} do
    File.mkdir_p!(Path.join([root, "leftoverjob0000000000", "in"]))

    capture_log(fn ->
      :ok = Supervisor.terminate_child(Druzhok.Supervisor, Druzhok.Docs.Queue)
      {:ok, _} = Supervisor.restart_child(Druzhok.Supervisor, Druzhok.Docs.Queue)
    end)

    assert File.ls!(root) == ["leftoverjob0000000000"]
    capture_log(fn -> Druzhok.Docs.sweep() end)
    assert_no_jobs(root)
    leftover = Path.join(root, "leftoverjob0000000000")
    assert_received {:cancel, ^leftover, true}
  end

  test "result_name keeps the upload's own name, safely" do
    assert DruzhokWebWeb.DocsController.result_name("dir/отчёт.docx", "pdf") == "отчёт.pdf"
    assert DruzhokWebWeb.DocsController.result_name("a\"b\r\n.xls", "xlsx") == "ab.xlsx"
    assert DruzhokWebWeb.DocsController.result_name(".docx", "pdf") == "document.pdf"
    assert DruzhokWebWeb.DocsController.result_name(nil, "pdf") == "document.pdf"
  end

  defp waiting, do: :queue.len(:sys.get_state(Druzhok.Docs.Queue).waiting)

  defp inflight_clear?(inst), do: not Druzhok.Inflight.busy?(inst.id)

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
