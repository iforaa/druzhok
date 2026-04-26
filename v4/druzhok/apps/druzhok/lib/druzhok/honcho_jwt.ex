defmodule Druzhok.HonchoJwt do
  @moduledoc """
  Mints workspace-scoped JWTs for Honcho self-hosted auth.

  The shared JWT secret lives in `HONCHO_JWT_SECRET` env var and must
  match the `AUTH_JWT_SECRET` set in the Honcho stack's .env. JWTs are
  non-expiring and scoped to one workspace, matching Honcho's
  `JWTParams` shape from gateway/security.py:

      {"w": workspace_name}

  The auth middleware on the Honcho side (`require_auth(workspace_name=...)`)
  verifies that the requested workspace matches the token's `w` claim.
  """

  @doc """
  Mint a JWT scoped to the given workspace.

  Returns `{:ok, token}` on success. Raises if `HONCHO_JWT_SECRET` is unset.
  """
  @spec mint_workspace_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def mint_workspace_token(workspace_name)
      when is_binary(workspace_name) and workspace_name != "" do
    signer = Joken.Signer.create("HS256", secret!())

    case Joken.encode_and_sign(%{"w" => workspace_name}, signer) do
      {:ok, token, _claims} -> {:ok, token}
      err -> err
    end
  end

  defp secret! do
    case System.get_env("HONCHO_JWT_SECRET") do
      blank when blank in [nil, ""] ->
        raise "HONCHO_JWT_SECRET is not set — cannot mint Honcho tokens. " <>
                "Set it in /etc/druzhok.env to match ~/honcho/.env's AUTH_JWT_SECRET."

      s ->
        s
    end
  end
end
