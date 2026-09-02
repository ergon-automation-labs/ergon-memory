defmodule BotArmyMemory.Schemas.Soul do
  @moduledoc """
  Ecto schema for the centralized `souls` table (ergon_memory database).

  A soul is the personality identity of a bot — character voice, tone,
  priorities, refusal rules. One row per (bot_id, tenant_id) — enforced by
  the souls_bot_tenant_unique constraint; upserts update the row in place
  and bump its version counter (same semantics as the old runtime Soul).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "souls" do
    field(:bot_id, :string)
    field(:tenant_id, :binary_id)
    field(:config, :map, default: %{})
    field(:version, :integer, default: 1)
    field(:active, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(soul, attrs) do
    soul
    |> cast(attrs, [:bot_id, :tenant_id, :config, :version, :active])
    |> validate_required([:bot_id, :tenant_id, :config])
    |> validate_jsonb_config()
  end

  # Same validation the old runtime Soul enforced: a soul must at least
  # identify itself, otherwise it is not loadable as a personality.
  defp validate_jsonb_config(changeset) do
    config =
      case fetch_field(changeset, :config) do
        {:changes, c} -> c
        {:data, c} -> c
        :error -> nil
      end

    if is_map(config) and Map.has_key?(config, "identity") do
      changeset
    else
      add_error(changeset, :config, "must contain 'identity' field")
    end
  end
end
