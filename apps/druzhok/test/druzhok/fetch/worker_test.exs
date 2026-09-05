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

  test "a windows-1251 page with a meta charset is read as text, not mojibake" do
    html = File.read!(Path.join(@fixtures, "article-cp1251.html"))
    assert {:ok, %{title: title, markdown: md}} = Worker.extract(:html, "https://koleso.example/hub", html)
    assert title =~ "Ремонт втулки"
    assert md =~ "сателлиты начинают подклинивать"
    refute md =~ "\uFFFD"
  end

  test "the Content-Type charset decodes a page that declares none itself" do
    html = File.read!(Path.join(@fixtures, "article-cp1251-nometa.html"))

    assert {:ok, %{markdown: md}} =
             Worker.extract(:html, "https://koleso.example/hub", html, charset: "windows-1251")

    assert md =~ "тормозной барабан"
    refute md =~ "\uFFFD"
  end

  test "a PDF comes back page by page with its title" do
    pdf = File.read!(Path.join(@fixtures, "report.pdf"))
    assert {:ok, %{title: "Quarterly Report Q3", markdown: md}} = Worker.extract(:pdf, "https://x.example/report.pdf", pdf)
    assert md =~ "Revenue grew twelve percent"
    assert md =~ "---"
    assert md =~ "Second page"
  end

  test "an RSS feed becomes a dated headline list with plain-text summaries" do
    rss = File.read!(Path.join(@fixtures, "feed.rss"))
    assert {:ok, %{title: title, markdown: md}} = Worker.extract(:feed, "https://koleso.example/rss", rss)

    assert title == "Колесо — новости велоспорта"
    assert md =~ "# Колесо — новости велоспорта"
    assert md =~ "[Десять ошибок при покупке первого велосипеда](https://koleso.example/articles/1)"
    assert md =~ "2026-09-05"
    assert md =~ "размер рамы, тип тормозов"
    refute md =~ "<b>"
    refute md =~ "<img"
    assert md =~ "[Зимняя резина для велосипеда: шипы или нет](https://koleso.example/articles/3)"
  end

  test "an Atom feed is read the same way" do
    atom = File.read!(Path.join(@fixtures, "feed.atom"))
    assert {:ok, %{title: "Koleso Engineering Blog", markdown: md}} = Worker.extract(:feed, "https://blog.koleso.example/atom", atom)

    assert md =~ "[Measuring spoke tension with a phone](https://blog.koleso.example/spoke-tension)"
    assert md =~ "[Why hub gears fail in the cold](https://blog.koleso.example/hub-cold)"
    assert md =~ "Old grease thickens"
    refute md =~ "<p>"
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

  test "a worker that overruns its budget is killed, not just cut off" do
    hang = Path.join(@fixtures, "hang.sh")
    {:ok, _} = Worker.start_link(bin: hang, name: :hang_worker)
    %{port: port} = :sys.get_state(:hang_worker)
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    assert {:error, :extract_failed} = Worker.extract(:text, "u", "x", server: :hang_worker, timeout: 200)
    Process.sleep(100)
    {_, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    assert status != 0, "worker os process #{os_pid} still alive after the timeout"
  end

  test "a request that spent its whole budget in the queue is dropped, not run" do
    hang = Path.join(@fixtures, "hang.sh")
    {:ok, _} = Worker.start_link(bin: hang, name: :queue_worker)
    started = System.monotonic_time(:millisecond)

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> Worker.extract(:text, "u", "x", server: :queue_worker, timeout: 300) end) end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, &match?({:error, _}, &1))
    # The second call would have cost another 300 ms had it been run.
    assert System.monotonic_time(:millisecond) - started < 550
  end
end

defmodule Druzhok.Fetch.WorkerListingTest do
  use ExUnit.Case, async: false
  @moduletag :fetch_worker

  alias Druzhok.Fetch.Worker

  @fixtures Path.expand("../../fixtures/fetch", __DIR__)

  # Article extractors drop card headlines on a listing page; the worker adds
  # them back as a linked list so "what are the top stories" can be answered.
  test "a listing page keeps its headlines as links" do
    html = File.read!(Path.join(@fixtures, "listing.html"))
    assert {:ok, %{markdown: md}} = Worker.extract(:html, "https://koleso.example/articles/", html)

    assert md =~ "[Десять ошибок при покупке первого велосипеда](https://koleso.example/articles/1)"
    assert md =~ "[Планетарная втулка против кассеты](https://koleso.example/articles/2)"
    assert md =~ "[Обзор фонарей до трёх тысяч рублей](https://koleso.example/articles/5)"
    refute md =~ "Войти"
  end

  test "an article page gets no headline appendix" do
    html = File.read!(Path.join(@fixtures, "article.html"))
    assert {:ok, %{markdown: md}} = Worker.extract(:html, "https://koleso.example/bike", html)
    refute md =~ "Заголовки на странице"
  end
end
