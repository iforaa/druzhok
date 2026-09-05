defmodule Druzhok.AllowedChat do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "allowed_chats" do
    field :instance_name, :string
    field :chat_id, :integer
    field :chat_type, :string
    field :title, :string
    field :telegram_user_id, :integer
    field :status, :string, default: "pending"
    field :info_sent, :boolean, default: false
    field :activation, :string, default: "buffer"
    field :buffer_size, :integer, default: 50
    field :system_prompt, :string
    timestamps()
  end

  def changeset(chat, attrs) do
    chat
    |> cast(attrs, [:instance_name, :chat_id, :chat_type, :title, :telegram_user_id, :status, :info_sent, :activation, :buffer_size, :system_prompt])
    |> validate_required([:instance_name, :chat_id, :chat_type])
    |> unique_constraint([:instance_name, :chat_id])
  end

  def get(instance_name, chat_id) do
    Druzhok.Repo.get_by(__MODULE__, instance_name: instance_name, chat_id: chat_id)
  end

  def upsert_pending(instance_name, chat_id, chat_type, title) do
    case get(instance_name, chat_id) do
      %{status: "removed"} = existing ->
        existing |> changeset(%{status: "pending", info_sent: false, title: title}) |> Druzhok.Repo.update()
      nil ->
        %__MODULE__{} |> changeset(%{instance_name: instance_name, chat_id: chat_id, chat_type: chat_type, title: title}) |> Druzhok.Repo.insert()
      existing ->
        {:ok, existing}
    end
  end

  def approve(instance_name, chat_id) do
    case get(instance_name, chat_id) do
      nil -> {:error, :not_found}
      chat -> chat |> changeset(%{status: "approved"}) |> Druzhok.Repo.update()
    end
  end

  def reject(instance_name, chat_id) do
    case get(instance_name, chat_id) do
      nil -> {:error, :not_found}
      chat -> chat |> changeset(%{status: "rejected"}) |> Druzhok.Repo.update()
    end
  end

  def mark_removed(instance_name, chat_id) do
    case get(instance_name, chat_id) do
      nil -> :ok
      chat -> chat |> changeset(%{status: "removed"}) |> Druzhok.Repo.update()
    end
  end

  def mark_info_sent(instance_name, chat_id) do
    case get(instance_name, chat_id) do
      nil -> :ok
      chat -> chat |> changeset(%{info_sent: true}) |> Druzhok.Repo.update()
    end
  end

  def set_activation(instance_name, chat_id, activation) when activation in ["buffer", "always"] do
    case get(instance_name, chat_id) do
      nil -> {:error, :not_found}
      chat -> chat |> changeset(%{activation: activation}) |> Druzhok.Repo.update()
    end
  end

  def groups_for_instance(instance_name) do
    from(c in __MODULE__, where: c.instance_name == ^instance_name and c.chat_type != "private", order_by: c.inserted_at)
    |> Druzhok.Repo.all()
  end
end
