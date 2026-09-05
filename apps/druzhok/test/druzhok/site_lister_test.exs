defmodule Druzhok.SiteListerTest do
  use ExUnit.Case, async: true

  alias Druzhok.SiteLister

  @instance %{
    name: "vasya",
    workspace: nil  # filled per test with tmp_dir path
  }

  describe "list/1" do
    @tag :tmp_dir
    test "returns empty list when sites directory is missing", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)

      inst = %{@instance | workspace: workspace}
      assert SiteLister.list(inst) == []
    end

    @tag :tmp_dir
    test "returns a list entry per site subdirectory", %{tmp_dir: tmp_dir} do
      sites = Path.join([tmp_dir, "workspace", "sites"])
      File.mkdir_p!(Path.join(sites, "alpha"))
      File.mkdir_p!(Path.join(sites, "beta"))
      File.write!(Path.join([sites, "alpha", "index.html"]), "<h1>A</h1>")
      File.write!(Path.join([sites, "beta", "index.html"]), "<h1>B</h1>")

      inst = %{@instance | workspace: Path.join(tmp_dir, "workspace")}
      result = SiteLister.list(inst) |> Enum.sort_by(& &1.name)

      assert length(result) == 2
      assert [a, b] = result
      assert a.name == "alpha"
      assert b.name == "beta"
      assert a.url == "https://vasya.oldey.dev/alpha/"
      assert b.url == "https://vasya.oldey.dev/beta/"
      assert a.size > 0
      assert b.size > 0
      assert %DateTime{} = a.mtime
    end

    @tag :tmp_dir
    test "ignores files at the top of sites/ (only directories are sites)", %{tmp_dir: tmp_dir} do
      sites = Path.join([tmp_dir, "workspace", "sites"])
      File.mkdir_p!(Path.join(sites, "real-site"))
      File.write!(Path.join([sites, "real-site", "index.html"]), "ok")
      File.write!(Path.join(sites, "stray-file.txt"), "not a site")

      inst = %{@instance | workspace: Path.join(tmp_dir, "workspace")}
      result = SiteLister.list(inst)

      assert length(result) == 1
      assert hd(result).name == "real-site"
    end

    @tag :tmp_dir
    test "size is the recursive byte total of the site directory", %{tmp_dir: tmp_dir} do
      sites = Path.join([tmp_dir, "workspace", "sites"])
      File.mkdir_p!(Path.join(sites, "sized"))
      File.write!(Path.join([sites, "sized", "a.txt"]), String.duplicate("a", 100))
      File.write!(Path.join([sites, "sized", "b.txt"]), String.duplicate("b", 200))

      inst = %{@instance | workspace: Path.join(tmp_dir, "workspace")}
      [site] = SiteLister.list(inst)

      assert site.size == 300
    end
  end
end
