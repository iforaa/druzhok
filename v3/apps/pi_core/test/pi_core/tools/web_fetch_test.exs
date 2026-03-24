defmodule PiCore.Tools.WebFetchTest do
  use ExUnit.Case

  describe "execute/2 — URL validation" do
    test "rejects non-http scheme" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => "ftp://example.com"}, %{})
      assert msg =~ "Invalid URL"
    end

    test "rejects missing scheme" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => "example.com"}, %{})
      assert msg =~ "Invalid URL"
    end

    test "rejects empty string" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => ""}, %{})
      assert msg =~ "Invalid URL"
    end
  end

  describe "execute/2 — SSRF protection" do
    test "blocks localhost" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => "http://127.0.0.1"}, %{})
      assert msg =~ "Blocked"
    end

    test "blocks 10.x private range" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => "http://10.0.0.1"}, %{})
      assert msg =~ "Blocked"
    end

    test "blocks 192.168.x private range" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => "http://192.168.1.1"}, %{})
      assert msg =~ "Blocked"
    end

    test "blocks 172.16-31.x private range" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => "http://172.20.0.1"}, %{})
      assert msg =~ "Blocked"
    end
  end

  @tag :integration
  describe "execute/2 (integration)" do
    test "fetches and extracts text from HTML page" do
      tool = PiCore.Tools.WebFetch.new()
      {:ok, text} = tool.execute.(%{"url" => "https://example.com"}, %{})
      assert text =~ "Example Domain"
      refute text =~ "<html"
    end

    test "passes through RSS feed as-is" do
      tool = PiCore.Tools.WebFetch.new()
      {:ok, body} = tool.execute.(%{"url" => "https://feeds.bbci.co.uk/news/rss.xml"}, %{})
      assert body =~ "<" and (body =~ "rss" or body =~ "feed" or body =~ "xml")
    end
  end
end
