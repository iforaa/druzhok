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
    assert result["text"] =~ "main"
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
