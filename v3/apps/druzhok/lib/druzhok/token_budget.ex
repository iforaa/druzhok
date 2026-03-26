defmodule Druzhok.TokenBudget do
  @moduledoc "Token budget checking and runtime section for system prompt."

  alias Druzhok.I18n

  def budget_exceeded?(instance_name) do
    limit = get_limit(instance_name)
    if limit == 0 do
      false
    else
      {input, output} = Druzhok.LlmRequest.tokens_today(instance_name)
      (input + output) > limit
    end
  end

  def runtime_section(instance_name, model, sandbox_type) do
    {input, output} = Druzhok.LlmRequest.tokens_today(instance_name)
    total_used = input + output
    limit = get_limit(instance_name)
    lang = I18n.lang(instance_name)

    now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    sandbox_label = I18n.t(sandbox_key(sandbox_type), lang)
    tokens_line = tokens_line(total_used, limit, lang)
    warning = budget_warning(total_used, limit, lang)

    section = """
    ## Runtime

    - #{I18n.t(:runtime_model, lang)}: #{model}
    - #{I18n.t(:runtime_date, lang)}: #{now}
    - #{tokens_line}
    - #{I18n.t(:runtime_sandbox, lang)}: #{sandbox_label}
    """

    if warning != "", do: section <> "\n" <> warning, else: section
  end

  defp get_limit(instance_name) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
      %{daily_token_limit: l} when is_integer(l) and l > 0 -> l
      _ -> 0
    end
  end

  defp tokens_line(used, 0, lang) do
    I18n.t(:tokens_today_unlimited, lang, %{used: format_tokens(used)})
  end
  defp tokens_line(used, limit, lang) do
    remaining_pct = max(0, round((1 - used / limit) * 100))
    I18n.t(:tokens_today_limited, lang, %{used: format_tokens(used), limit: format_tokens(limit), pct: remaining_pct})
  end

  defp budget_warning(_used, 0, _lang), do: ""
  defp budget_warning(used, limit, lang) do
    pct = used / limit * 100
    cond do
      pct > 100 -> ""
      pct > 80 -> I18n.t(:token_warning_80, lang)
      true -> ""
    end
  end

  defp sandbox_key("docker"), do: :sandbox_docker
  defp sandbox_key("firecracker"), do: :sandbox_firecracker
  defp sandbox_key(_), do: :sandbox_local

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"
end
