defmodule Druzhok.Embed.WorkerTest do
  use ExUnit.Case, async: false

  alias Druzhok.Embed.Worker

  @fake Path.expand("../../support/fake_embed_worker.py", __DIR__)

  defp start_fake(name) do
    start_supervised!({Worker, name: name, bin: System.find_executable("python3"), script: @fake, model_dir: System.tmp_dir!()})
    name
  end

  test "embeds a batch and reports the token count" do
    server = start_fake(:embed_fake_1)

    assert {:ok, %{vectors: [[0.05, 0.5, 0.25, 0.125], [0.09, 0.5, 0.25, 0.125]], tokens: 3}} =
             Worker.embed(["hello", "два слова"], server: server)
  end

  test "an empty batch is an empty answer" do
    server = start_fake(:embed_fake_2)
    assert {:ok, %{vectors: [], tokens: 0}} = Worker.embed([], server: server)
  end

  test "a worker error is embed_failed" do
    server = start_fake(:embed_fake_3)
    assert {:error, :embed_failed} = Worker.embed(["BAD"], server: server)
  end

  test "a crashed worker is restarted on the next call" do
    server = start_fake(:embed_fake_4)
    assert {:error, :embed_failed} = Worker.embed(["CRASH"], server: server)
    assert {:ok, %{tokens: 1}} = Worker.embed(["again"], server: server)
  end

  test "a slow worker is killed and the call times out" do
    server = start_fake(:embed_fake_5)
    assert {:error, :embed_failed} = Worker.embed(["SLOW"], server: server, timeout: 300)
    assert {:ok, %{tokens: 1}} = Worker.embed(["after"], server: server)
  end

  test "a missing model dir is worker_down, not a worker that dies on every call" do
    start_supervised!({Worker, name: :embed_nodir, bin: System.find_executable("python3"), script: @fake, model_dir: "/nonexistent/model"})
    assert {:error, :worker_down} = Worker.embed(["x"], server: :embed_nodir)
  end

  test "a worker that exits before it is ready is worker_down" do
    dir = Path.join(System.tmp_dir!(), "die")
    File.mkdir_p!(dir)
    start_supervised!({Worker, name: :embed_die, bin: System.find_executable("python3"), script: @fake, model_dir: dir})
    assert {:error, :worker_down} = Worker.embed(["x"], server: :embed_die)
  end

  test "the model load blocks neither startup nor callers" do
    dir = Path.join(System.tmp_dir!(), "slow")
    File.mkdir_p!(dir)
    {us, _} = :timer.tc(fn -> start_supervised!({Worker, name: :embed_slow, bin: System.find_executable("python3"), script: @fake, model_dir: dir}) end)
    assert us < 500_000
    assert {:error, :worker_down} = Worker.embed(["early"], server: :embed_slow, timeout: 200)
    Process.sleep(2_500)
    assert {:ok, %{tokens: 1}} = Worker.embed(["later"], server: :embed_slow)
  end

  test "no configured python means worker_down" do
    start_supervised!({Worker, name: :embed_none, bin: nil})
    assert {:error, :worker_down} = Worker.embed(["x"], server: :embed_none)
  end

  @tag :embed_worker
  test "the real model answers 384-dim unit vectors" do
    assert {:ok, %{vectors: [v], tokens: tokens}} = Worker.embed(["query: кошка"])
    assert length(v) == 384
    assert_in_delta Enum.reduce(v, 0, &(&2 + &1 * &1)), 1.0, 0.001
    assert tokens > 0
  end
end
