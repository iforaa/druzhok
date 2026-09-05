defmodule DruzhokWebWeb.LlmFormat do
  @moduledoc """
  Routes all LLM requests through OpenRouter. Strips images from messages
  when the target model doesn't support vision.
  """

  @non_vision_models [
    "deepseek/deepseek-v3.2",
    "deepseek/deepseek-chat",
    "deepseek/deepseek-r1",
    "minimax/minimax-m2.5",
    "minimax/minimax-m2.7",
  ]

  def provider_url do
    Application.get_env(:druzhok, :openrouter_api_url) || "https://openrouter.ai/api/v1"
  end

  # OPENROUTER_API_KEY env wins; otherwise the key entered in dashboard Settings.
  def provider_key do
    Druzhok.Settings.openrouter_api_key()
  end

  def request_url, do: provider_url() <> "/chat/completions"

  @passthrough_headers ["http-referer", "x-openrouter-title", "x-openrouter-categories"]

  def request_headers(original_headers \\ []) do
    base = [
      {"authorization", "Bearer #{provider_key()}"},
      {"content-type", "application/json"},
    ]

    # Pass through OpenRouter attribution headers from the client
    Enum.reduce(@passthrough_headers, base, fn header, acc ->
      case Enum.find(original_headers, fn {k, _v} -> String.downcase(to_string(k)) == header end) do
        {_k, v} -> [{header, v} | acc]
        nil -> acc
      end
    end)
  end

  def extract_usage(body) do
    usage = body["usage"] || %{}
    %{prompt_tokens: usage["prompt_tokens"] || 0, completion_tokens: usage["completion_tokens"] || 0}
  end

  @default_max_tokens 4096

  def prepare_body(body) do
    model = body["model"] || ""

    body =
      body
      |> Map.put_new("max_tokens", @default_max_tokens)
      |> Map.put_new("usage", %{"include" => true})
      |> apply_reasoning_override(model)

    if model in @non_vision_models do
      Map.update(body, "messages", [], &strip_images/1)
    else
      body
    end
  end

  defp apply_reasoning_override(body, model) do
    if String.starts_with?(model, "xiaomi/mimo") do
      Map.put_new(body, "reasoning", %{"enabled" => false})
    else
      body
    end
  end

  @doc "Text of the last message, capped at 500 chars, for the dashboard's request list."
  def prompt_preview(%{"messages" => [_ | _] = msgs}) do
    case msgs |> List.last() |> Map.get("content", "") do
      text when is_binary(text) ->
        String.slice(text, 0, 500)

      parts when is_list(parts) ->
        parts
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join(" ", &(&1["text"] || ""))
        |> String.slice(0, 500)

      _ ->
        nil
    end
  end

  def prompt_preview(_), do: nil

  @doc "Drop image parts and flatten the message to text, for models that cannot see."
  def strip_images(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      case msg["content"] do
        parts when is_list(parts) ->
          cleaned = Enum.reject(parts, &(&1["type"] == "image_url"))
          text = Enum.map_join(cleaned, "\n", fn
            %{"type" => "text", "text" => t} -> t
            other -> inspect(other)
          end)
          Map.put(msg, "content", text)
        _ ->
          msg
      end
    end)
  end

  def strip_images(other), do: other

  @doc """
  Extracts cost in cents from an OpenRouter response body (parsed map).

  Primary path: OpenRouter returns `usage.cost` (USD float) when
  `usage.include=true` was set in the request. Secondary path: compute
  from prompt/completion tokens using `Druzhok.ModelCatalog.price_per_million/1`
  as a fallback. Returns 0 if neither is available.

  `model` is passed separately because the response body's "model" field
  can be a resolved variant (e.g. provider-specific suffix) that misses
  the price table.
  """
  def extract_cost_cents(decoded, model) when is_map(decoded) do
    case get_in(decoded, ["usage", "cost"]) do
      nil -> fallback_cost_cents(decoded, model)
      cost when is_number(cost) -> round(cost * 100)
      _ -> fallback_cost_cents(decoded, model)
    end
  end

  def extract_cost_cents(_, _), do: 0

  defp fallback_cost_cents(decoded, model) do
    prompt = get_in(decoded, ["usage", "prompt_tokens"]) || 0
    completion = get_in(decoded, ["usage", "completion_tokens"]) || 0

    if prompt + completion == 0 do
      0
    else
      %{input: in_price, output: out_price} = Druzhok.ModelCatalog.price_per_million(model)
      round(prompt * in_price / 1_000_000 + completion * out_price / 1_000_000)
    end
  end
end
