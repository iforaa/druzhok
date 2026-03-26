defmodule PiCore.Tools.WebSearch do
  @moduledoc "Web search tool with DuckDuckGo (free) and Perplexity (via OpenRouter) backends."

  alias PiCore.Tools.Tool

  @ddg_url "https://html.duckduckgo.com/html/"
  @ddg_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
  @max_results 5
  @cache_ttl_ms 900_000  # 15 minutes

  def new do
    %Tool{
      name: "web_search",
      description: "Search the web and return a list of results (title, URL, snippet). Use this to find relevant pages, then use web_fetch or bash+curl to read specific ones. Default backend: DuckDuckGo (free). Set provider=perplexity for AI-synthesized answers with source URLs.",
      parameters: %{
        query: %{type: :string, description: "Search query"},
        provider: %{type: :string, description: "Search provider: ddg (default) or perplexity", required: false}
      },
      execute: &execute/2
    }
  end

  def execute(%{"query" => query} = args, context) do
    provider = args["provider"] || "ddg"
    cached = check_cache(provider, query)
    if cached do
      {:ok, cached}
    else
      result = case provider do
        "perplexity" -> search_perplexity(query, context)
        _ -> search_ddg(query)
      end

      case result do
        {:ok, text} ->
          put_cache(provider, query, text)
          {:ok, text}
        error -> error
      end
    end
  end

  # --- DuckDuckGo (free, no API key) ---

  defp search_ddg(query) do
    url = "#{@ddg_url}?q=#{URI.encode(query)}&kl=&kp=-1"
    headers = [
      {"user-agent", @ddg_user_agent},
      {"accept", "text/html"},
      {"accept-language", "ru,en;q=0.9"}
    ]

    req = Finch.build(:get, url, headers)
    case Finch.request(req, PiCore.Finch, receive_timeout: 10_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        results = parse_ddg_html(body)
        if results == [] do
          {:ok, "No results found for: #{query}"}
        else
          formatted = format_results(query, "duckduckgo", results)
          {:ok, formatted}
        end
      {:ok, %{status: status}} ->
        {:error, "DuckDuckGo returned HTTP #{status}"}
      {:error, reason} ->
        {:error, "DuckDuckGo search failed: #{inspect(reason)}"}
    end
  end

  defp parse_ddg_html(html) do
    # Extract result links and snippets from DuckDuckGo HTML
    # Pattern: <a class="result__a" href="...">title</a> ... <a class="result__snippet">snippet</a>
    results = Regex.scan(~r/<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/s, html)
    snippets = Regex.scan(~r/<a[^>]*class="result__snippet"[^>]*>(.*?)<\/a>/s, html)

    results
    |> Enum.take(@max_results)
    |> Enum.with_index()
    |> Enum.map(fn {[_full, href, title_html], idx} ->
      url = decode_ddg_url(href)
      title = strip_html_tags(title_html)
      snippet = case Enum.at(snippets, idx) do
        [_, s] -> strip_html_tags(s)
        _ -> ""
      end
      %{title: title, url: url, snippet: snippet}
    end)
    |> Enum.reject(fn r -> r.url == "" or r.title == "" end)
  end

  defp decode_ddg_url(href) do
    # DuckDuckGo wraps URLs in redirects: //duckduckgo.com/l/?uddg=ENCODED_URL&...
    case URI.decode_query(URI.parse(href).query || "") do
      %{"uddg" => url} -> url
      _ ->
        if String.starts_with?(href, "http"), do: href, else: ""
    end
  rescue
    _ -> href
  end

  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<b>|<\/b>/, "")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#x27;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.trim()
  end

  # --- Perplexity (via OpenRouter) ---

  defp search_perplexity(query, context) do
    api_key = get_in_context(context, :openrouter_api_key) ||
              Application.get_env(:pi_core, :openrouter_api_key)

    api_url = get_in_context(context, :openrouter_api_url) ||
              Application.get_env(:pi_core, :openrouter_api_url) ||
              "https://openrouter.ai/api/v1"

    unless api_key do
      # Fall back to DuckDuckGo if no OpenRouter key
      search_ddg(query)
    else
      case PiCore.LLM.OpenAI.completion(%{
        model: "perplexity/sonar",
        api_url: api_url,
        api_key: api_key,
        provider: "openrouter",
        system_prompt: "You are a search engine. Return concise, factual search results. Include source URLs.",
        messages: [%{role: "user", content: query}],
        tools: [],
        max_tokens: 500,
        stream: false
      }) do
        {:ok, result} when result.content != "" ->
          {:ok, "Search results (Perplexity):\n\n#{result.content}"}
        {:ok, _} ->
          search_ddg(query)  # Fallback
        {:error, _reason} ->
          search_ddg(query)  # Fallback
      end
    end
  end

  defp get_in_context(context, key) when is_map(context), do: context[key]
  defp get_in_context(_, _), do: nil

  # --- Result formatting ---

  defp format_results(query, provider, results) do
    header = "Search: #{query} (#{provider}, #{length(results)} results)\n\n"
    body = results
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {r, i} ->
      "#{i}. #{r.title}\n   #{r.url}\n   #{r.snippet}"
    end)
    header <> body
  end

  # --- Simple in-memory cache (ETS) ---

  def init_cache do
    if :ets.whereis(:web_search_cache) == :undefined do
      :ets.new(:web_search_cache, [:set, :public, :named_table])
    end
  end

  defp check_cache(provider, query) do
    init_cache()
    key = {provider, String.downcase(query)}
    case :ets.lookup(:web_search_cache, key) do
      [{^key, result, expires}] ->
        if expires > System.monotonic_time(:millisecond), do: result, else: nil
      _ -> nil
    end
  end

  defp put_cache(provider, query, result) do
    init_cache()
    key = {provider, String.downcase(query)}
    expires = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :ets.insert(:web_search_cache, {key, result, expires})
  end
end
