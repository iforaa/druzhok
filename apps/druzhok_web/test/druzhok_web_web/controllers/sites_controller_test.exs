defmodule DruzhokWebWeb.SitesControllerTest do
  use DruzhokWebWeb.RuocProxyCase

  import ExUnit.CaptureLog
  alias Druzhok.{Instance, Repo}

  setup %{instance: instance} do
    %{instance: instance |> Ecto.Changeset.change(website_hosting_enabled: true) |> Repo.update!()}
  end

  defp gzip(conn), do: put_req_header(conn, "content-type", "application/gzip")

  defp read_all(conn, acc \\ "") do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, data, conn} -> {acc <> data, conn}
      {:more, data, conn} -> read_all(conn, acc <> data)
    end
  end

  defp gateway_put(bypass, status, reply) do
    Bypass.stub(bypass, "PUT", "/v1/sites/:site", fn conn ->
      {_, conn} = read_all(conn)
      gateway_reply(conn, status, reply)
    end)
  end

  defp error(conn), do: Jason.decode!(conn.resp_body)["error"]

  defp hosting(instance, on),
    do: instance |> Ecto.Changeset.change(website_hosting_enabled: on) |> Repo.update!()

  defp forbid_put(bypass) do
    Bypass.stub(bypass, "PUT", "/v1/sites/:site", fn _conn -> flunk("reached the gateway") end)
  end

  describe "PUT" do
    test "sends the body on under the bot's key and passes the answer back", %{conn: conn, bypass: bypass} do
      test = self()
      body = :crypto.strong_rand_bytes(300_000)
      reply = %{"url" => "https://vasya.oldey.dev/cv/", "files" => 1, "bytes" => 3, "published_at" => "2026-11-01T10:00:00Z"}

      Bypass.expect_once(bypass, "PUT", "/v1/sites/cv", fn gw ->
        {got, gw} = read_all(gw)
        send(test, {:got, got, gw.req_headers})
        gateway_reply(gw, 201, reply)
      end)

      conn = conn |> gzip() |> put("/v2/sites/cv", body)

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body) == reply
      assert_received {:got, ^body, headers}
      assert {"authorization", "Bearer " <> bot_key()} in headers
      assert {"content-type", "application/gzip"} in headers
    end

    test "with hosting off answers sites_off and never calls the gateway", %{conn: conn, bypass: bypass, instance: instance} do
      hosting(instance, false)
      forbid_put(bypass)

      conn = conn |> gzip() |> put("/v2/sites/cv", "x")

      assert conn.status == 403
      assert error(conn) == "sites_off"
    end

    test "refuses a bad name itself, so it cannot reach another gateway path", %{conn: conn, bypass: bypass} do
      forbid_put(bypass)

      for name <- ["..%2Fpartner", "UP", "-x", "a_b", String.duplicate("a", 51)] do
        res = conn |> recycle() |> gzip() |> put("/v2/sites/#{name}", "x")
        assert {res.status, error(res)} == {400, "bad_name"}
      end
    end

    test "refuses a body that is not a gzip upload", %{conn: conn, bypass: bypass} do
      forbid_put(bypass)

      res = conn |> put_req_header("content-type", "application/json") |> put("/v2/sites/cv", "{}")
      assert {res.status, error(res)} == {400, "bad_archive"}
    end

    test "a declared length past the bound is refused before anything is sent", %{conn: conn, bypass: bypass} do
      forbid_put(bypass)

      res =
        conn
        |> gzip()
        |> put_req_header("content-length", Integer.to_string(60 * 1024 * 1024 + 1))
        |> put("/v2/sites/cv", "x")

      assert {res.status, error(res)} == {413, "too_large"}
    end

    test "the gateway's refusals pass through", %{conn: conn, bypass: bypass} do
      for {status, code} <- [
            {400, "bad_archive"}, {401, "invalid_api_key"}, {401, "key_revoked"}, {403, "account_suspended"},
            {403, "slug_taken"}, {403, "site_disabled"}, {408, "upload_incomplete"}, {413, "too_large"},
            {429, "rate_limited"}, {500, "internal_error"}, {503, "sites_unavailable"}
          ] do
        gateway_put(bypass, status, %{"error" => code})
        res = conn |> recycle() |> gzip() |> put("/v2/sites/cv", "x")
        assert {res.status, error(res)} == {status, code}
      end
    end

    test "an answer that is not JSON is gateway_unavailable", %{conn: conn, bypass: bypass} do
      gateway_put(bypass, 502, "<html>bad gateway</html>")

      capture_log(fn ->
        res = conn |> gzip() |> put("/v2/sites/cv", "x")
        assert {res.status, error(res)} == {502, "gateway_unavailable"}
      end)
    end

    test "an unreachable gateway is gateway_unavailable", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)

      capture_log(fn ->
        res = conn |> gzip() |> put("/v2/sites/cv", "x")
        assert {res.status, error(res)} == {502, "gateway_unavailable"}
      end)

      Bypass.up(bypass)
    end

    for {what, change} <- [
          {"hosting went off", [website_hosting_enabled: false]},
          {"the bot is being deleted", [delete_requested: true]}
        ] do
      test "if #{what} during the upload, the site is taken down again", %{conn: conn, bypass: bypass, instance: instance} do
        test = self()

        Bypass.expect_once(bypass, "PUT", "/v1/sites/cv", fn gw ->
          {_, gw} = read_all(gw)
          Repo.get!(Instance, instance.id) |> Ecto.Changeset.change(unquote(change)) |> Repo.update!()
          gateway_reply(gw, 201, %{"url" => "https://x/"})
        end)

        Bypass.expect_once(bypass, "DELETE", "/v1/sites/:site", fn gw ->
          send(test, {:deleted, gw.req_headers})
          gateway_reply(gw, 200, %{})
        end)

        res = conn |> gzip() |> put("/v2/sites/cv", "x")

        assert {res.status, error(res)} == {403, "sites_off"}
        assert_received {:deleted, headers}
        assert {"authorization", "Bearer " <> bot_key()} in headers
      end
    end
  end

  describe "PUT, when the takedown or the reply fails" do
    test "no reply from the gateway and hosting went off: the site is taken down anyway", %{conn: conn, bypass: bypass, instance: instance} do
      test = self()
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Takes the upload (the gateway committed), then drops the connection.
      {:ok, _} =
        Task.start_link(fn ->
          {:ok, sock} = :gen_tcp.accept(listen)
          {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
          Repo.get!(Instance, instance.id) |> Ecto.Changeset.change(website_hosting_enabled: false) |> Repo.update!()
          :gen_tcp.close(sock)
          # The takedown is the bot's own DELETE; it goes to the stub.
          Application.put_env(:druzhok, :ruoc_url, "http://localhost:#{bypass.port}")
        end)

      Application.put_env(:druzhok, :ruoc_url, "http://127.0.0.1:#{port}")

      Bypass.expect_once(bypass, "DELETE", "/v1/sites/:site", fn gw ->
        send(test, {:deleted, gw.request_path})
        gateway_reply(gw, 200, %{})
      end)

      capture_log(fn ->
        res = conn |> gzip() |> put("/v2/sites/cv", "x")
        assert {res.status, error(res)} == {502, "gateway_unavailable"}
      end)

      assert_received {:deleted, "/v1/sites/cv"}
    end

    test "a failed takedown is logged and still answers sites_off", %{conn: conn, bypass: bypass, instance: instance} do
      Bypass.stub(bypass, "PUT", "/v1/sites/:site", fn gw ->
        {_, gw} = read_all(gw)
        Repo.get!(Instance, instance.id) |> Ecto.Changeset.change(website_hosting_enabled: false) |> Repo.update!()
        gateway_reply(gw, 201, %{"url" => "https://x/"})
      end)

      Bypass.stub(bypass, "DELETE", "/v1/sites/:site", fn gw -> gateway_reply(gw, 500, %{"error" => "boom"}) end)

      log =
        capture_log(fn ->
          res = conn |> gzip() |> put("/v2/sites/cv", "x")
          assert {res.status, error(res)} == {403, "sites_off"}
        end)

      assert log =~ "may stay up"
    end
  end

  describe "DELETE" do
    test "works with hosting off and passes the answer back", %{conn: conn, bypass: bypass, instance: instance} do
      hosting(instance, false)

      Bypass.expect_once(bypass, "DELETE", "/v1/sites/:site", fn gw -> gateway_reply(gw, 200, %{}) end)
      res = delete(conn, "/v2/sites/cv")
      assert {res.status, Jason.decode!(res.resp_body)} == {200, %{}}
    end

    test "passes a 404 back", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/v1/sites/:site", fn gw -> gateway_reply(gw, 404, %{"error" => "not_found"}) end)
      res = delete(conn, "/v2/sites/cv")
      assert {res.status, error(res)} == {404, "not_found"}
    end

    test "refuses a bad name and survives a gateway that is down", %{conn: conn, bypass: bypass} do
      res = delete(conn, "/v2/sites/..%2Fx")
      assert {res.status, error(res)} == {400, "bad_name"}

      Bypass.down(bypass)

      capture_log(fn ->
        res = conn |> recycle() |> delete("/v2/sites/cv")
        assert {res.status, error(res)} == {502, "gateway_unavailable"}
      end)

      Bypass.up(bypass)
    end
  end

  # Over real sockets, with Bandit in front and a raw gateway behind: what the
  # test adapter cannot show is chunk-at-a-time reading and how an upload ends.
  describe "over real sockets" do
    setup %{instance: instance} do
      server = start_supervised!({Bandit, plug: DruzhokWebWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      gateway = start_gateway(self())
      Application.put_env(:druzhok, :ruoc_url, "http://127.0.0.1:#{gateway}")
      %{port: port, key: instance.tenant_key}
    end

    test "a large upload arrives whole and druzhok holds no more than a little of it", %{port: port, key: key} do
      chunk = :crypto.strong_rand_bytes(1024 * 1024)
      mb = 40

      sock = client(port, key, [{"content-length", Integer.to_string(mb * byte_size(chunk))}])
      {:ok, sampler} = Task.start_link(fn -> loop_memory(0) end)
      base = :erlang.memory(:binary)
      Enum.each(1..mb, fn _ -> :ok = :gen_tcp.send(sock, chunk) end)

      assert_receive {:gateway, :complete, received, head}, 30_000
      peak = peak_memory(sampler)

      # Chunked to the gateway; the whole body is there, in order.
      assert received == mb * byte_size(chunk)
      assert head =~ ~r/transfer-encoding: chunked/i
      assert head =~ "authorization: Bearer " <> bot_key()
      assert peak - base < 16 * 1024 * 1024, "held #{div(peak - base, 1024 * 1024)} MB of a #{mb} MB upload"

      assert {201, body} = read_response(sock)
      assert Jason.decode!(body)["url"] == "https://x/"
    end

    test "a body past the bound is cut: 413, and the gateway never sees it end", %{port: port, key: key} do
      Application.put_env(:druzhok_web, :site_max_body_bytes, 200_000)
      on_exit(fn -> Application.delete_env(:druzhok_web, :site_max_body_bytes) end)

      sock = client(port, key, [{"transfer-encoding", "chunked"}])
      chunk = :crypto.strong_rand_bytes(100_000)
      for _ <- 1..3, do: :gen_tcp.send(sock, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])

      assert_receive {:gateway, :cut, _received, _head}, 10_000
      assert {413, body} = read_response(sock)
      assert Jason.decode!(body) == %{"error" => "too_large"}
    end

    test "a client that stalls gets 408 upload_incomplete, and the gateway never sees it end", %{port: port, key: key} do
      Application.put_env(:druzhok_web, :site_read_timeout_ms, 200)
      on_exit(fn -> Application.delete_env(:druzhok_web, :site_read_timeout_ms) end)

      sock = client(port, key, [{"content-length", "1000000"}])
      :ok = :gen_tcp.send(sock, :crypto.strong_rand_bytes(1_000))

      capture_log(fn ->
        assert {408, body} = read_response(sock)
        assert Jason.decode!(body) == %{"error" => "upload_incomplete"}
        assert_receive {:gateway, :cut, _received, _head}, 15_000
      end)
    end

    test "a client that leaves mid-upload does not look finished to the gateway", %{port: port, key: key} do
      sock = client(port, key, [{"content-length", "1000000"}])
      :ok = :gen_tcp.send(sock, :crypto.strong_rand_bytes(100_000))
      Process.sleep(100)
      :gen_tcp.close(sock)

      capture_log(fn -> assert_receive {:gateway, :cut, _received, _head}, 20_000 end)
      refute_received {:gateway, :complete, _, _}
    end
  end

  defp client(port, key, headers) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    head =
      ["PUT /v2/sites/cv HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer ", key,
       "\r\ncontent-type: application/gzip\r\n"] ++
        Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end) ++ ["\r\n"]

    :ok = :gen_tcp.send(sock, head)
    sock
  end

  defp read_response(sock, acc \\ "") do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] when body != "" ->
        ["HTTP/1.1 " <> rest | _] = String.split(head, "\r\n")
        {String.to_integer(String.slice(rest, 0, 3)), body}

      _ ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 10_000)
        read_response(sock, acc <> data)
    end
  end

  defp loop_memory(peak) do
    receive do
      {:peak, from} -> send(from, {:peak, peak})
    after
      5 -> loop_memory(max(peak, :erlang.memory(:binary)))
    end
  end

  defp peak_memory(sampler) do
    send(sampler, {:peak, self()})
    assert_receive {:peak, peak}, 1_000
    peak
  end

  # One upload: decodes chunk sizes as it goes, keeping only the count, reports
  # whether the final chunk came, and answers 201 if it did.
  defp start_gateway(test) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    {:ok, _} =
      Task.start_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen)
        {head, rest} = gateway_head(sock, "")

        case gateway_body(sock, rest, 0) do
          {:complete, n} ->
            send(test, {:gateway, :complete, n, head})
            reply = Jason.encode!(%{"url" => "https://x/"})
            :gen_tcp.send(sock, "HTTP/1.1 201 Created\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(reply)}\r\n\r\n#{reply}")

          {:cut, n} ->
            send(test, {:gateway, :cut, n, head})
        end

        Process.sleep(200)
        :gen_tcp.close(sock)
      end)

    port
  end

  defp gateway_head(sock, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {head, rest}

      _ ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 10_000)
        gateway_head(sock, acc <> data)
    end
  end

  defp gateway_body(sock, buf, n) do
    case String.split(buf, "\r\n", parts: 2) do
      [size, rest] ->
        case Integer.parse(size, 16) do
          {0, _} -> {:complete, n}
          {len, _} -> gateway_chunk(sock, rest, len, n)
        end

      _ ->
        with {:ok, data} <- gateway_recv(sock), do: gateway_body(sock, buf <> data, n), else: (_ -> {:cut, n})
    end
  end

  # Skips `len` bytes and the CRLF after them, without keeping them.
  defp gateway_chunk(sock, buf, len, n) when byte_size(buf) >= len + 2 do
    <<_::binary-size(len), "\r\n", rest::binary>> = buf
    gateway_body(sock, rest, n + len)
  end

  defp gateway_chunk(sock, buf, len, n) do
    with {:ok, data} <- gateway_recv(sock), do: gateway_chunk(sock, buf <> data, len, n), else: (_ -> {:cut, n})
  end

  defp gateway_recv(sock), do: :gen_tcp.recv(sock, 0, 10_000)
end
