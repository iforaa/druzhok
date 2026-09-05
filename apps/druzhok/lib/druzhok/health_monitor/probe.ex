defmodule Druzhok.HealthMonitor.Probe do
  @moduledoc """
  One health probe for one bot: unit state, Telegram token, LLM path through
  the proxy, and egress lock-down. Pure given the injected functions, so it is
  unit-testable; defaults hit the real world.
  """

  @type reason :: {:unit, atom()} | {:telegram, term()} | {:llm, term()} | :egress_open
  @type result :: {:healthy, []} | {:degraded, [reason]} | {:down, reason}

  @spec run(map(), keyword()) :: result
  def run(instance, opts \\ []) do
    unit_status = Keyword.get(opts, :unit_status, &Druzhok.Host.status/1)
    get_me = Keyword.get(opts, :telegram_get_me, &Druzhok.Telegram.API.get_me/1)
    llm_ping = Keyword.get(opts, :llm_ping, &llm_ping/1)
    egress = Keyword.get(opts, :egress_check, &Druzhok.Host.egress_check/1)

    case unit_status.(instance.name) do
      :active ->
        reasons =
          [
            case get_me.(instance.telegram_token) do
              {:ok, _} -> nil
              {:error, r} -> {:telegram, r}
            end,
            case llm_ping.(instance) do
              :ok -> nil
              {:error, r} -> {:llm, r}
            end,
            case egress.(instance.name) do
              :open -> :egress_open
              _ -> nil
            end
          ]
          |> Enum.reject(&is_nil/1)

        if reasons == [], do: {:healthy, []}, else: {:degraded, reasons}

      other ->
        {:down, {:unit, other}}
    end
  end

  @doc "One 1-token completion through the proxy with the bot's tenant key."
  def llm_ping(instance) do
    url = Druzhok.Runtime.proxy_url() <> "/chat/completions"

    body =
      Jason.encode!(%{
        model: instance.model,
        max_tokens: 1,
        messages: [%{role: "user", content: "ping"}]
      })

    headers = [
      {"authorization", "Bearer #{instance.tenant_key}"},
      {"content-type", "application/json"}
    ]

    case Finch.build(:post, url, headers, body)
         |> Finch.request(Druzhok.LocalFinch, receive_timeout: 15_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, s}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end
end
