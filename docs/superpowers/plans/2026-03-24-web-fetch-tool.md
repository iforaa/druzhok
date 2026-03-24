# web_fetch Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `web_fetch` tool that fetches URLs and returns clean plain text via Readability (Rust NIF).

**Architecture:** Rust NIF (`readabilityrs` crate) for HTML→text extraction exposed as `PiCore.Native.Readability`. Elixir tool `PiCore.Tools.WebFetch` handles HTTP fetch via Finch, URL validation, SSRF protection, content-type routing, then delegates HTML to the NIF.

**Tech Stack:** Elixir, Rustler, readabilityrs, Finch

**Spec:** `docs/superpowers/specs/2026-03-24-web-fetch-tool-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `v3/apps/pi_core/native/readability/Cargo.toml` | Rust crate config |
| Create | `v3/apps/pi_core/native/readability/src/lib.rs` | NIF: extract + strip_tags |
| Create | `v3/apps/pi_core/lib/pi_core/native/readability.ex` | Elixir NIF module |
| Create | `v3/apps/pi_core/lib/pi_core/tools/web_fetch.ex` | Tool: fetch + validate + route |
| Create | `v3/apps/pi_core/test/pi_core/native/readability_test.exs` | NIF unit tests |
| Create | `v3/apps/pi_core/test/pi_core/tools/web_fetch_test.exs` | Tool unit tests |
| Modify | `v3/apps/pi_core/mix.exs` | Add rustler dep + rustler config |
| Modify | `v3/apps/pi_core/lib/pi_core/tools/schema.ex:12` | Honor `required: false` |
| Modify | `v3/apps/pi_core/test/pi_core/tools/schema_test.exs` | Test optional params |
| Modify | `v3/apps/pi_core/lib/pi_core/session.ex:296` | Register WebFetch tool |

---

### Task 1: Add Rustler dependency and scaffold Rust NIF

**Files:**
- Modify: `v3/apps/pi_core/mix.exs`
- Create: `v3/apps/pi_core/native/readability/Cargo.toml`
- Create: `v3/apps/pi_core/native/readability/src/lib.rs`
- Create: `v3/apps/pi_core/lib/pi_core/native/readability.ex`

- [ ] **Step 1: Add rustler to mix.exs deps**

In `v3/apps/pi_core/mix.exs`, add to `deps()`:

```elixir
{:rustler, "~> 0.36"}
```

And add Rustler compiler to `project()`:

```elixir
compilers: [:rustler] ++ Mix.compilers()
```

- [ ] **Step 2: Create Cargo.toml**

Create `v3/apps/pi_core/native/readability/Cargo.toml`:

```toml
[package]
name = "readability"
version = "0.1.0"
edition = "2021"

[lib]
name = "readability"
crate-type = ["cdylib"]

[dependencies]
readabilityrs = "0.1"
rustler = "0.36"
```

- [ ] **Step 3: Create Rust NIF source**

Create `v3/apps/pi_core/native/readability/src/lib.rs`:

```rust
use readabilityrs::Readability;
use std::collections::HashMap;

/// Extract readable content from HTML.
/// Returns Result<HashMap, String> which Rustler auto-encodes as {:ok, map} / {:error, string}.
#[rustler::nif]
fn extract(html: String) -> Result<HashMap<String, String>, String> {
    match Readability::new(&html, None, None) {
        Ok(mut reader) => {
            match reader.parse() {
                Some(article) => {
                    let title = article.title.clone();
                    // article.content is HTML — strip tags to get plain text
                    let text = strip_html_tags(&article.content);
                    let excerpt = article.byline.unwrap_or_default();

                    let mut map = HashMap::new();
                    map.insert("title".to_string(), title);
                    map.insert("text".to_string(), text);
                    map.insert("excerpt".to_string(), excerpt);
                    Ok(map)
                }
                None => Err("Readability extraction returned no content".to_string())
            }
        }
        Err(e) => Err(format!("Parse error: {:?}", e))
    }
}

/// Strip all HTML tags, returning plain text.
#[rustler::nif]
fn strip_tags(html: String) -> String {
    strip_html_tags(&html)
}

fn strip_html_tags(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut in_script = false;
    let mut tag_name = String::new();

    for c in html.chars() {
        if c == '<' {
            in_tag = true;
            tag_name.clear();
            continue;
        }
        if in_tag {
            if c == '>' {
                in_tag = false;
                let lower = tag_name.to_lowercase();
                if lower == "script" || lower == "style" {
                    in_script = true;
                } else if lower == "/script" || lower == "/style" {
                    in_script = false;
                }
                tag_name.clear();
            } else if c != '/' || tag_name.is_empty() {
                // Capture tag name (stop at space for attributes)
                if c != ' ' && tag_name.len() < 20 {
                    tag_name.push(c);
                }
            }
            continue;
        }
        if !in_script {
            result.push(c);
        }
    }

    // Collapse multiple whitespace/newlines
    let mut collapsed = String::with_capacity(result.len());
    let mut last_was_ws = false;
    for c in result.chars() {
        if c.is_whitespace() {
            if !last_was_ws {
                collapsed.push('\n');
                last_was_ws = true;
            }
        } else {
            collapsed.push(c);
            last_was_ws = false;
        }
    }

    collapsed.trim().to_string()
}

rustler::init!("Elixir.PiCore.Native.Readability");
```

**Important:** The `readabilityrs` API must be verified during compilation — the `Readability::new` constructor may take different arguments, and `Article` fields may have different names. Adapt the code to match the actual crate API. The key contract is: HTML in → `{:ok, %{"title" => ..., "text" => ..., "excerpt" => ...}}` or `{:error, reason}` out. Rustler auto-encodes `Result<T, String>` as `{:ok, T}` / `{:error, String}` tuples.

- [ ] **Step 4: Create Elixir NIF module**

Create `v3/apps/pi_core/lib/pi_core/native/readability.ex`:

```elixir
defmodule PiCore.Native.Readability do
  use Rustler, otp_app: :pi_core, crate: "readability"

  @doc "Extract readable content from HTML. Returns {:ok, %{title, text, excerpt}} or {:error, reason}."
  def extract(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Strip all HTML tags, returning plain text. Fallback when Readability fails."
  def strip_tags(_html), do: :erlang.nif_error(:nif_not_loaded)
end
```

- [ ] **Step 5: Verify compilation**

Run:
```bash
cd v3 && mix deps.get && mix compile
```

Expected: Rust compiles successfully, NIF loads. If `readabilityrs` API differs from above, fix the Rust code to match.

- [ ] **Step 6: Commit**

```bash
git add v3/apps/pi_core/mix.exs v3/mix.lock v3/apps/pi_core/native/ v3/apps/pi_core/lib/pi_core/native/
git commit -m "add Rust NIF for Readability HTML extraction"
```

---

### Task 2: Test the Rust NIF

**Files:**
- Create: `v3/apps/pi_core/test/pi_core/native/readability_test.exs`

- [ ] **Step 1: Write NIF tests**

Create `v3/apps/pi_core/test/pi_core/native/readability_test.exs`:

```elixir
defmodule PiCore.Native.ReadabilityTest do
  use ExUnit.Case

  @article_html """
  <html>
  <head><title>Test Article</title></head>
  <body>
    <nav>Navigation stuff</nav>
    <article>
      <h1>Test Article</h1>
      <p>This is the main content of a test article. It contains enough text
      to be recognized by the Readability algorithm as the primary content.
      The article discusses important topics and provides valuable information
      to the reader. We need several paragraphs to ensure Readability picks
      this up as the main content block.</p>
      <p>Second paragraph with more substantial content. The Readability
      algorithm looks for blocks of text that appear to be the main article
      content, filtering out navigation, sidebars, and other noise.</p>
      <p>Third paragraph to really make sure this is long enough for the
      algorithm to identify it as article content worth extracting.</p>
    </article>
    <aside>Sidebar content</aside>
    <footer>Footer stuff</footer>
  </body>
  </html>
  """

  test "extracts article content from HTML" do
    {:ok, result} = PiCore.Native.Readability.extract(@article_html)
    assert is_binary(result["title"])
    assert is_binary(result["text"])
    assert result["text"] =~ "main content"
    # Should NOT contain HTML tags
    refute result["text"] =~ "<p>"
    refute result["text"] =~ "<article>"
  end

  test "returns error for empty/minimal HTML" do
    result = PiCore.Native.Readability.extract("<html><body></body></html>")
    assert {:error, _reason} = result
  end

  test "strip_tags removes all HTML" do
    plain = PiCore.Native.Readability.strip_tags("<p>Hello <b>world</b></p>")
    assert plain =~ "Hello"
    assert plain =~ "world"
    refute plain =~ "<"
  end

  test "strip_tags handles empty input" do
    assert PiCore.Native.Readability.strip_tags("") == ""
  end
end
```

- [ ] **Step 2: Run tests**

Run:
```bash
cd v3 && mix test apps/pi_core/test/pi_core/native/readability_test.exs
```

Expected: All 4 tests pass. If the Readability algorithm doesn't extract from the test HTML (too short, wrong structure), adjust the test HTML to include more content.

- [ ] **Step 3: Commit**

```bash
git add v3/apps/pi_core/test/pi_core/native/readability_test.exs
git commit -m "add tests for Readability NIF"
```

---

### Task 3: Fix schema.ex to honor required: false

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/tools/schema.ex:12`
- Modify: `v3/apps/pi_core/test/pi_core/tools/schema_test.exs`

- [ ] **Step 1: Write failing test for optional parameters**

Add to `v3/apps/pi_core/test/pi_core/tools/schema_test.exs`:

```elixir
test "excludes optional parameters from required list" do
  tool = %Tool{
    name: "test",
    description: "Test",
    parameters: %{
      url: %{type: :string, description: "URL"},
      caption: %{type: :string, description: "Caption", required: false}
    },
    execute: fn _, _ -> {:ok, ""} end
  }
  openai = Schema.to_openai(tool)
  required = openai["function"]["parameters"]["required"]
  assert "url" in required
  refute "caption" in required
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd v3 && mix test apps/pi_core/test/pi_core/tools/schema_test.exs
```

Expected: FAIL — "caption" is currently in the required list.

- [ ] **Step 3: Fix schema.ex**

In `v3/apps/pi_core/lib/pi_core/tools/schema.ex`, replace line 12:

```elixir
# Old:
required = Map.keys(tool.parameters) |> Enum.map(&to_string/1)

# New:
required = tool.parameters
  |> Enum.reject(fn {_name, spec} -> spec[:required] == false end)
  |> Enum.map(fn {name, _spec} -> to_string(name) end)
```

- [ ] **Step 4: Run tests to verify all pass**

Run:
```bash
cd v3 && mix test apps/pi_core/test/pi_core/tools/schema_test.exs
```

Expected: All 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add v3/apps/pi_core/lib/pi_core/tools/schema.ex v3/apps/pi_core/test/pi_core/tools/schema_test.exs
git commit -m "fix schema to honor required: false on tool parameters"
```

---

### Task 4: Implement WebFetch tool — URL validation & SSRF protection

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/tools/web_fetch.ex`
- Create: `v3/apps/pi_core/test/pi_core/tools/web_fetch_test.exs`

- [ ] **Step 1: Write tests for URL validation**

Create `v3/apps/pi_core/test/pi_core/tools/web_fetch_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd v3 && mix test apps/pi_core/test/pi_core/tools/web_fetch_test.exs
```

Expected: FAIL — module doesn't exist yet.

- [ ] **Step 3: Implement URL validation and SSRF protection**

Create `v3/apps/pi_core/lib/pi_core/tools/web_fetch.ex`:

```elixir
defmodule PiCore.Tools.WebFetch do
  alias PiCore.Tools.Tool

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  @max_body_bytes 2_000_000
  @timeout_ms 10_000
  @max_redirects 3

  def new do
    %Tool{
      name: "web_fetch",
      description: "Fetch a URL and extract readable text content. Returns clean text from web pages (HTML→text via Readability), or raw content for RSS/JSON/plain text. Use this instead of curl for reading web content.",
      parameters: %{url: %{type: :string, description: "URL to fetch (http or https)"}},
      execute: &execute/2
    }
  end

  def execute(%{"url" => url}, _context) do
    with :ok <- validate_url(url),
         {:ok, host} <- extract_host(url),
         {:ok, ip} <- resolve_host(host),
         :ok <- check_ip(ip),
         {:ok, status, headers, body} <- http_get(url, @max_redirects),
         :ok <- check_status(status, url) do
      media_type = parse_media_type(get_header(headers, "content-type"))
      process_body(body, media_type)
    end
  end

  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)
    cond do
      uri.scheme not in ["http", "https"] -> {:error, "Invalid URL: must be http or https"}
      is_nil(uri.host) or uri.host == "" -> {:error, "Invalid URL: missing host"}
      true -> :ok
    end
  end
  def validate_url(_), do: {:error, "Invalid URL"}

  # IPv4 SSRF protection
  def check_ip({127, _, _, _}), do: {:error, "Blocked: private/internal address"}
  def check_ip({10, _, _, _}), do: {:error, "Blocked: private/internal address"}
  def check_ip({192, 168, _, _}), do: {:error, "Blocked: private/internal address"}
  def check_ip({172, b, _, _}) when b >= 16 and b <= 31, do: {:error, "Blocked: private/internal address"}
  def check_ip({169, 254, _, _}), do: {:error, "Blocked: private/internal address"}
  def check_ip({0, 0, 0, 0}), do: {:error, "Blocked: private/internal address"}
  # Note: resolve_host uses :inet (IPv4 only). IPv6-only hosts fail DNS resolution.
  # If IPv6 support is added later, add clauses for ::1, fe80::/10, fc00::/7.
  def check_ip(_), do: :ok

  def parse_media_type(nil), do: "application/octet-stream"
  def parse_media_type(ct) do
    ct |> String.split(";") |> hd() |> String.trim() |> String.downcase()
  end

  defp extract_host(url) do
    case URI.parse(url) do
      %{host: host} when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, "Invalid URL: cannot extract host"}
    end
  end

  defp resolve_host(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, "DNS resolution failed for #{host}"}
    end
  end

  defp check_status(status, _url) when status >= 200 and status < 300, do: :ok
  defp check_status(status, url), do: {:error, "HTTP #{status}: #{url}"}

  defp get_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  @html_types ["text/html"]
  @passthrough_types ["application/xml", "text/xml", "application/rss+xml",
                      "application/atom+xml", "application/json", "text/plain"]

  defp process_body(body, media_type) when media_type in @html_types do
    # Ensure UTF-8 — most sites are, but legacy Russian sites may use windows-1251
    body = ensure_utf8(body)
    case PiCore.Native.Readability.extract(body) do
      {:ok, %{"title" => title, "text" => text}} when text != "" ->
        {:ok, "# #{title}\n\n#{text}"}
      _ ->
        # Fallback: strip tags
        {:ok, PiCore.Native.Readability.strip_tags(body)}
    end
  end
  defp process_body(body, media_type) when media_type in @passthrough_types do
    {:ok, body}
  end
  defp process_body(_body, media_type) do
    {:error, "Unsupported content type: #{media_type}"}
  end

  # Encoding normalization — attempt UTF-8, pass through if already valid
  defp ensure_utf8(body) do
    case :unicode.characters_to_binary(body, :utf8) do
      {:error, _, _} ->
        # Try latin1 (covers windows-1251 partially)
        case :unicode.characters_to_binary(body, :latin1) do
          {:error, _, _} -> body  # Give up, pass as-is
          result when is_binary(result) -> result
          _ -> body
        end
      {:incomplete, _, _} -> body
      result when is_binary(result) -> result
      _ -> body
    end
  end

  # HTTP GET with manual redirect following and body size limit
  defp http_get(url, redirects_left) when redirects_left <= 0 do
    {:error, "Too many redirects for #{url}"}
  end
  defp http_get(url, redirects_left) do
    headers = [
      {"user-agent", @user_agent},
      {"accept-language", "ru,en;q=0.9"},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
    ]

    req = Finch.build(:get, url, headers)

    case stream_body(req) do
      {:ok, status, resp_headers, body} when status in [301, 302, 303, 307, 308] ->
        case get_header(resp_headers, "location") do
          nil -> {:error, "Redirect with no Location header"}
          location ->
            redirect_url = URI.merge(URI.parse(url), location) |> to_string()
            with :ok <- validate_url(redirect_url),
                 {:ok, host} <- extract_host(redirect_url),
                 {:ok, ip} <- resolve_host(host),
                 :ok <- check_ip(ip) do
              http_get(redirect_url, redirects_left - 1)
            end
        end

      {:ok, status, resp_headers, body} ->
        {:ok, status, resp_headers, body}

      {:error, reason} ->
        {:error, "Fetch failed: #{inspect(reason)}"}
    end
  end

  defp stream_body(req) do
    ref = make_ref()

    try do
      Finch.stream(req, PiCore.Finch, {nil, [], <<>>}, fn
        {:status, status}, {_, headers, body} ->
          {status, headers, body}

        {:headers, new_headers}, {status, headers, body} ->
          normalized = Enum.map(new_headers, fn {k, v} -> {String.downcase(k), v} end)
          {status, headers ++ normalized, body}

        {:data, data}, {status, headers, body} ->
          new_body = body <> data
          if byte_size(new_body) > @max_body_bytes do
            throw({ref, :body_too_large})
          end
          {status, headers, new_body}
      end, receive_timeout: @timeout_ms)
      |> case do
        {:ok, {status, headers, body}} -> {:ok, status, headers, body}
        {:error, reason} -> {:error, reason}
      end
    catch
      {^ref, :body_too_large} -> {:error, "Response body exceeds 2 MB limit"}
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run:
```bash
cd v3 && mix test apps/pi_core/test/pi_core/tools/web_fetch_test.exs
```

Expected: All validation/IP/media-type tests pass.

- [ ] **Step 5: Commit**

```bash
git add v3/apps/pi_core/lib/pi_core/tools/web_fetch.ex v3/apps/pi_core/test/pi_core/tools/web_fetch_test.exs
git commit -m "add web_fetch tool with URL validation and SSRF protection"
```

---

### Task 5: Integration test — end-to-end fetch

**Files:**
- Modify: `v3/apps/pi_core/test/pi_core/tools/web_fetch_test.exs`

- [ ] **Step 1: Add integration tests**

Append to `v3/apps/pi_core/test/pi_core/tools/web_fetch_test.exs`:

```elixir
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
      assert body =~ "<rss" or body =~ "<feed" or body =~ "<?xml"
    end

    test "rejects private IP" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => "http://192.168.1.1"}, %{})
      assert msg =~ "Blocked"
    end

    test "rejects non-http URL" do
      tool = PiCore.Tools.WebFetch.new()
      {:error, msg} = tool.execute.(%{"url" => "ftp://example.com"}, %{})
      assert msg =~ "Invalid URL"
    end
  end
```

- [ ] **Step 2: Run integration tests**

Run:
```bash
cd v3 && mix test apps/pi_core/test/pi_core/tools/web_fetch_test.exs --include integration
```

Expected: All tests pass. The example.com test verifies the full pipeline: Finch fetch → NIF extraction → plain text output.

- [ ] **Step 3: Commit**

```bash
git add v3/apps/pi_core/test/pi_core/tools/web_fetch_test.exs
git commit -m "add integration tests for web_fetch tool"
```

---

### Task 6: Register tool and verify end-to-end

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex:296`

- [ ] **Step 1: Add WebFetch to default tools**

In `v3/apps/pi_core/lib/pi_core/session.ex`, add to the `default_tools/0` list:

```elixir
PiCore.Tools.WebFetch.new(),
```

Place it after `SendFile.new()`.

- [ ] **Step 2: Run full test suite**

Run:
```bash
cd v3 && mix test
```

Expected: All existing tests pass, no regressions.

- [ ] **Step 3: Verify schema generation includes web_fetch**

Run in iex:
```bash
cd v3 && mix run -e '
  tool = PiCore.Tools.WebFetch.new()
  schema = PiCore.Tools.Schema.to_openai(tool)
  IO.inspect(schema, pretty: true)
'
```

Expected: OpenAI function schema with name "web_fetch", url parameter, correct description.

- [ ] **Step 4: Commit**

```bash
git add v3/apps/pi_core/lib/pi_core/session.ex
git commit -m "register web_fetch in default tools"
```

---

### Task 7: Final verification

- [ ] **Step 1: Run full test suite including integration**

Run:
```bash
cd v3 && mix test --include integration
```

Expected: All tests pass — unit tests, NIF tests, integration tests, no regressions.
