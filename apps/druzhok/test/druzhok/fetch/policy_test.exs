defmodule Druzhok.Fetch.PolicyTest do
  use ExUnit.Case, async: true

  alias Druzhok.Fetch.Policy

  @resolver %{
    "example.com" => {93, 184, 216, 34},
    "v6.example.com" => {0x2606, 0x2800, 0x220, 0x1, 0x248, 0x1893, 0x25C8, 0x1946},
    "evil.example" => {127, 0, 0, 1},
    "meta.example" => {169, 254, 169, 254},
    "lan.example" => {10, 0, 0, 5},
    "mapped.example" => {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0005},
    "ula.example" => {0xFD00, 0, 0, 0, 0, 0, 0, 1}
  }

  defp resolve(host) do
    case Map.fetch(@resolver, host) do
      {:ok, ip} -> {:ok, ip}
      :error -> :error
    end
  end

  defp check(url), do: Policy.check(url, &resolve/1)

  test "a public http or https URL passes with its resolved address" do
    assert {:ok, %{scheme: :https, host: "example.com", port: 443, ip: {93, 184, 216, 34}, path: "/a?b=1"}} =
             check("https://example.com/a?b=1")

    assert {:ok, %{scheme: :http, port: 80, path: "/"}} = check("http://example.com")
    assert {:ok, %{port: 8080}} = check("http://example.com:8080/x")
    assert {:ok, %{ip: {0x2606, _, _, _, _, _, _, _}}} = check("https://v6.example.com/")
  end

  test "only http and https, with a host and without userinfo" do
    assert {:error, :bad_url} = check("ftp://example.com/x")
    assert {:error, :bad_url} = check("file:///etc/passwd")
    assert {:error, :bad_url} = check("example.com/x")
    assert {:error, :bad_url} = check("https://user:pw@example.com/")
    assert {:error, :bad_url} = check("https://example.com:70000/")
    assert {:error, :bad_url} = check("https://example.com:22/")
    assert {:error, :bad_url} = check("")
    assert {:error, :bad_url} = check("https://")
  end

  test "hosts that resolve to private, loopback, link-local or metadata addresses are unsafe" do
    for host <- ~w(evil.example meta.example lan.example mapped.example ula.example) do
      assert {:error, :unsafe_url} = check("https://#{host}/"), host
    end
  end

  test "IP literals are judged without resolving" do
    for ip <- ~w(127.0.0.1 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 169.254.1.1 100.64.0.1 0.0.0.0 224.0.0.1 255.255.255.255) do
      assert {:error, :unsafe_url} = check("http://#{ip}/"), ip
    end

    for ip <- ~w([::1] [::] [fe80::1] [fc00::1] [ff02::1] [::ffff:127.0.0.1] [::ffff:10.0.0.1]) do
      assert {:error, :unsafe_url} = check("http://#{ip}/"), ip
    end

    assert {:ok, %{ip: {8, 8, 8, 8}}} = check("http://8.8.8.8/")
    assert {:ok, %{ip: {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}}} = check("http://[2001:4860:4860::8888]/")
    # 172.32.0.0 is just outside 172.16.0.0/12.
    assert {:ok, _} = check("http://172.32.0.1/")
  end

  test "local names are refused before any lookup" do
    for host <- ~w(localhost LOCALHOST foo.localhost printer.local db.internal) do
      assert {:error, :unsafe_url} = check("http://#{host}/"), host
    end
  end

  test "a name that does not resolve is unreachable" do
    assert {:error, :unreachable} = check("https://nope.example/")
  end
end
