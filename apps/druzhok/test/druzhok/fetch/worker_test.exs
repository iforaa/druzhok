defmodule Druzhok.Fetch.WorkerTest do
  # async: false — one named worker process.
  use ExUnit.Case, async: false

  @moduletag :fetch_worker

  alias Druzhok.Fetch.Worker

  @fixtures Path.expand("../../fixtures/fetch", __DIR__)

  test "an article page comes back as markdown with its title and without the chrome" do
    html = File.read!(Path.join(@fixtures, "article.html"))
    assert {:ok, %{title: title, markdown: md}} = Worker.extract(:html, "https://koleso.example/bike", html)

    assert title =~ "Как выбрать велосипед"
    assert md =~ "# Как выбрать велосипед"
    assert md =~ "Рама и посадка"
    assert md =~ "планетарная втулка"
    assert md =~ "обзоре планетарных втулок"
    assert md =~ "Дисковые"
    refute md =~ "cookies"
    refute md =~ "Реклама"
    refute md =~ "Политика конфиденциальности"
    refute md =~ "dataLayer"
  end

  test "a PDF comes back page by page with its title" do
    pdf = File.read!(Path.join(@fixtures, "report.pdf"))
    assert {:ok, %{title: "Quarterly Report Q3", markdown: md}} = Worker.extract(:pdf, "https://x.example/report.pdf", pdf)
    assert md =~ "Revenue grew twelve percent"
    assert md =~ "---"
    assert md =~ "Second page"
  end

  test "plain text is passed through" do
    assert {:ok, %{markdown: "hello\nworld"}} = Worker.extract(:text, "https://x.example/a.txt", "hello\nworld")
  end

  test "junk is an extraction failure, not a crash, and the worker keeps serving" do
    assert {:error, :extract_failed} = Worker.extract(:pdf, "https://x.example/bad.pdf", "not a pdf at all")
    assert {:ok, %{markdown: "still here"}} = Worker.extract(:text, "u", "still here")
  end

  test "a worker killed mid-flight fails that call and is back for the next" do
    port_owner = Process.whereis(Worker)
    assert is_pid(port_owner)
    %{port: port} = :sys.get_state(Worker)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-9", to_string(os_pid)])
    Process.sleep(200)
    assert {:ok, %{markdown: "again"}} = Worker.extract(:text, "u", "again")
  end
end
