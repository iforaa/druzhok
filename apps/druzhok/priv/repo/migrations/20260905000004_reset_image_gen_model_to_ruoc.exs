defmodule Druzhok.Repo.Migrations.ResetImageGenModelToRuoc do
  use Ecto.Migration

  # image_gen_model now names a ruoc catalogue entry; every stored value is
  # an OpenRouter id, and ruoc's default is the same FLUX model they all used.
  def up, do: execute("update instances set image_gen_model = null where image_gen_model is not null")
  def down, do: :ok
end
