defmodule DruzhokWebWeb.ProxyCase do
  @moduledoc """
  Case template for LLM proxy tests.

  Starts a Bypass server and points both OpenRouter (`:openrouter_api_url`)
  and OpenAI (`:openai_api_url`) at it, sets a fake OpenRouter key in app
  env, inserts one instance with a tenant key and returns a conn already
  carrying `Authorization: Bearer <tenant_key>`.

  Tests are `async: false` because they mutate application env.
  """
  use ExUnit.CaseTemplate

  alias Druzhok.{Instance, Repo, Usage, Budget}

  using do
    quote do
      use DruzhokWebWeb.ConnCase, async: false
      import DruzhokWebWeb.ProxyCase
      import DruzhokWebWeb.UpstreamStub

      # Registered after ConnCase's sandbox setup so the instance insert
      # happens inside the sandbox owner.
      setup :proxy_setup
    end
  end

  def proxy_setup(_context) do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}/v1"

    prev = %{
      openrouter_api_url: Application.get_env(:druzhok, :openrouter_api_url),
      openrouter_api_key: Application.get_env(:druzhok, :openrouter_api_key),
      openai_api_url: Application.get_env(:druzhok, :openai_api_url)
    }

    Application.put_env(:druzhok, :openrouter_api_url, base_url)
    Application.put_env(:druzhok, :openrouter_api_key, "test-or-key")
    Application.put_env(:druzhok, :openai_api_url, base_url)

    ExUnit.Callbacks.on_exit(fn ->
      for {k, v} <- prev do
        if v, do: Application.put_env(:druzhok, k, v), else: Application.delete_env(:druzhok, k)
      end
    end)

    instance = create_instance(%{})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    %{bypass: bypass, base_url: base_url, instance: instance, conn: conn}
  end

  @doc "Insert an instance with sensible defaults; override any field via attrs."
  def create_instance(attrs) do
    attrs = Map.new(attrs)
    name = attrs[:name] || "px-#{System.unique_integer([:positive])}"

    defaults = %{
      name: name,
      model: "z-ai/glm-5.3-flash",
      workspace: Path.join([System.tmp_dir!(), "druzhok-proxy-test", name, "workspace"]),
      tenant_key: Instance.generate_tenant_key(name),
      timezone: "UTC",
      daily_budget_cents: 0
    }

    %Instance{}
    |> Instance.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  @doc "Conn with the instance's tenant key as bearer token."
  def authed(conn, %Instance{tenant_key: key}) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{key}")
  end

  def usage_logs(%Instance{id: id}) do
    import Ecto.Query
    Repo.all(from(u in Usage, where: u.instance_id == ^id, order_by: u.id))
  end

  def spent_today(%Instance{id: id}), do: Budget.spent_today_cents(id)
end
