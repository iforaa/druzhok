defmodule DruzhokWebWeb.EmbedControllerTest do
  use DruzhokWebWeb.ConnCase, async: false

  alias DruzhokWebWeb.EmbedStub

  @secret "fetch-secret-for-tests"

  setup do
    EmbedStub.start()
    Druzhok.Settings.set("fetch_secret", @secret)
    :ok
  end

  defp call(conn, body, secret \\ @secret) do
    conn |> put_req_header("authorization", "Bearer " <> secret) |> post("/internal/embed", body)
  end

  test "embeds with the shared secret and reports dim and model", %{conn: conn} do
    EmbedStub.reply({:ok, %{vectors: [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]], tokens: 7}})
    conn = call(conn, %{"texts" => ["a", "b"]})

    assert json_response(conn, 200) == %{
             "vectors" => [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]],
             "tokens" => 7,
             "dim" => 3,
             "model" => "multilingual-e5-small"
           }

    assert EmbedStub.calls() == [["a", "b"]]
  end

  test "refuses a missing or wrong secret without embedding", %{conn: conn} do
    assert call(conn, %{"texts" => ["a"]}, "nope").status == 401
    assert post(conn, "/internal/embed", %{"texts" => ["a"]}).status == 401
    assert EmbedStub.calls() == []
  end

  test "rejects bad bodies and over-limit batches before the worker" do
    assert json_response(call(build_conn(), %{}), 400) == %{"error" => "bad_request"}
    assert json_response(call(build_conn(), %{"texts" => "a"}), 400) == %{"error" => "bad_request"}
    assert json_response(call(build_conn(), %{"texts" => []}), 400) == %{"error" => "bad_request"}
    assert json_response(call(build_conn(), %{"texts" => [1]}), 400) == %{"error" => "bad_request"}
    assert json_response(call(build_conn(), %{"texts" => List.duplicate("x", 65)}), 413) == %{"error" => "too_many_texts"}
    assert json_response(call(build_conn(), %{"texts" => [String.duplicate("я", 8_001)]}), 413) == %{"error" => "text_too_long"}
    assert EmbedStub.calls() == []
  end

  test "maps worker verdicts", %{conn: conn} do
    EmbedStub.reply({:error, :worker_down})
    assert json_response(call(conn, %{"texts" => ["a"]}), 503) == %{"error" => "worker_down"}
    EmbedStub.reply({:error, :embed_failed})
    assert json_response(call(build_conn(), %{"texts" => ["a"]}), 502) == %{"error" => "embed_failed"}
  end
end
