defmodule PiCore.Tools.WebFetchTest do
  use ExUnit.Case

  alias PiCore.Tools.WebFetch

  describe "validate_url/1" do
    test "accepts valid http URL" do
      assert :ok = WebFetch.validate_url("https://example.com")
    end

    test "rejects non-http scheme" do
      assert {:error, _} = WebFetch.validate_url("ftp://example.com")
    end

    test "rejects missing scheme" do
      assert {:error, _} = WebFetch.validate_url("example.com")
    end

    test "rejects empty string" do
      assert {:error, _} = WebFetch.validate_url("")
    end
  end

  describe "check_ip/1" do
    test "blocks localhost" do
      assert {:error, _} = WebFetch.check_ip({127, 0, 0, 1})
    end

    test "blocks 10.x.x.x" do
      assert {:error, _} = WebFetch.check_ip({10, 0, 0, 1})
    end

    test "blocks 192.168.x.x" do
      assert {:error, _} = WebFetch.check_ip({192, 168, 1, 1})
    end

    test "blocks 172.16-31.x.x" do
      assert {:error, _} = WebFetch.check_ip({172, 16, 0, 1})
      assert {:error, _} = WebFetch.check_ip({172, 31, 255, 255})
    end

    test "blocks 169.254.x.x (link-local)" do
      assert {:error, _} = WebFetch.check_ip({169, 254, 169, 254})
    end

    test "blocks 0.0.0.0" do
      assert {:error, _} = WebFetch.check_ip({0, 0, 0, 0})
    end

    test "allows public IP" do
      assert :ok = WebFetch.check_ip({93, 184, 216, 34})
    end
  end

  describe "parse_media_type/1" do
    test "strips charset" do
      assert "text/html" = WebFetch.parse_media_type("text/html; charset=utf-8")
    end

    test "handles no params" do
      assert "application/json" = WebFetch.parse_media_type("application/json")
    end

    test "handles nil" do
      assert "application/octet-stream" = WebFetch.parse_media_type(nil)
    end
  end
end
