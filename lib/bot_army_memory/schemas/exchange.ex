defmodule BotArmyMemory.Schemas.Exchange do
  use Ecto.Schema
  import Ecto.Changeset

  # The scaffolded schema was missing binary_id autogeneration, so every
  # insert tried to default the uuid id column from a serial — this is why
  # memory.record could never store a row.
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "memory_exchanges" do
    field :session_id, :binary_id
    field :tenant_id, :binary_id
    field :question, :string
    field :answer, :string
    field :source, :string
    field :meta, :map, default: %{}

    timestamps()
  end

  def changeset(exchange, attrs) do
    exchange
    |> cast(attrs, [:session_id, :tenant_id, :question, :answer, :source, :meta])
    |> validate_required([:session_id, :tenant_id, :question, :answer])
  end
end
