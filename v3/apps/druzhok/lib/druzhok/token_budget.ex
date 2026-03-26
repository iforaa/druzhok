defmodule Druzhok.TokenBudget do
  @moduledoc "Token budget checking and runtime section for system prompt."

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

    now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    sandbox_label = sandbox_label(sandbox_type)
    tokens_line = tokens_line(total_used, limit)
    warning = budget_warning(total_used, limit)

    section = """
    ## Runtime

    - Модель: #{model}
    - Дата: #{now}
    - #{tokens_line}
    - Sandbox: #{sandbox_label}
    """

    if warning != "", do: section <> "\n" <> warning, else: section
  end

  defp get_limit(instance_name) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
      %{daily_token_limit: l} when is_integer(l) and l > 0 -> l
      _ -> 0
    end
  end

  defp tokens_line(used, 0) do
    "Токены сегодня: #{format_tokens(used)} (без лимита)"
  end
  defp tokens_line(used, limit) do
    remaining_pct = max(0, round((1 - used / limit) * 100))
    "Токены сегодня: #{format_tokens(used)} из #{format_tokens(limit)} (#{remaining_pct}% осталось)"
  end

  defp budget_warning(_used, 0), do: ""
  defp budget_warning(used, limit) do
    pct = used / limit * 100
    cond do
      pct > 100 -> ""
      pct > 80 -> "⚠️ Экономь токены — отвечай кратко, минимум инструментов."
      true -> ""
    end
  end

  defp sandbox_label("docker"), do: "Docker (python3, node, bash)"
  defp sandbox_label("firecracker"), do: "Firecracker (isolated VM)"
  defp sandbox_label(_), do: "Local (без песочницы)"

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"
end
