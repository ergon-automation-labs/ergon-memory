defmodule BotArmyMemory.SoulReads do
  @moduledoc """
  What a soul can see: the reads named in its config, taken fresh before every turn.

      "reads": [
        {"subject": "chore.task.list", "label": "the house's chores",
         "payload": {}, "fields": ["title", "frequency", "due_date"], "limit": 15}
      ]

  The soul's config names the reads; **this module decides which subjects may be named**.
  `@allowed` is read-only subjects and nothing else, so no soul config can make a voice press
  anything — a write named there is refused before it is sent, and the refusal is in the
  prompt rather than silently dropped.

  Every result goes to the model as a block stamped with the subject and the time it was read.
  A read that failed is a block that says so — "could not be read, do not guess" — and never
  an empty list, because "nothing is due" and "the chore bot did not answer" are different
  facts. The numbers are the bot's own JSON, pruned of ids and envelope noise, never
  re-worded by this module.

  `chore.assignment.list` is deliberately not allowed: it answers the bot's placeholder
  household (Alice, Bob, Charlie), and a voice that read it would introduce three strangers.
  """

  require Logger

  @allowed MapSet.new([
             "chore.task.list",
             "chore.schedule.list",
             "chore.habit.list",
             "fitness.workout.list",
             "fitness.set.list",
             "fitness.coach.today",
             "fitness.coach.last",
             "fitness.goal.progress",
             "gtd.task.list",
             "gtd.project.list",
             "gtd.goal.list"
           ])

  @max_reads 4
  @read_timeout_ms 6_000
  @default_limit 15
  @max_chars 5_000
  @noise ~w(correlation_id schema_version timestamp tenant_id user_id ok)

  @doc "The subjects a soul may read."
  def allowed, do: @allowed

  @doc """
  Take a soul's reads and return the blocks for its prompt (possibly empty).

  `request_fn` is `Publisher.request/3`-shaped; `now` is the read stamp.
  """
  @spec take(map(), function(), DateTime.t()) :: [String.t()]
  def take(config, request_fn, now \\ DateTime.utc_now()) do
    stamp = Calendar.strftime(now, "%Y-%m-%d %H:%M UTC")

    specs =
      config
      |> Map.get("reads", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_reads)

    specs
    |> Task.async_stream(&read_one(&1, request_fn, stamp),
      timeout: @read_timeout_ms + 2_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(specs)
    |> Enum.map(fn
      {{:ok, block}, _spec} -> block
      {{:exit, _}, spec} -> unread(spec, stamp, "it took too long")
    end)
  end

  defp read_one(%{"subject" => subject} = spec, request_fn, stamp) when is_binary(subject) do
    if MapSet.member?(@allowed, subject) do
      payload = if is_map(spec["payload"]), do: spec["payload"], else: %{}

      case safe_request(request_fn, subject, payload) do
        {:ok, reply} -> render(spec, reply, stamp)
        {:error, reason} -> unread(spec, stamp, describe(reason))
      end
    else
      Logger.warning("[SoulReads] refused a read of #{subject}: not on the read-only list")
      unread(spec, stamp, "this voice is not allowed to read #{subject}")
    end
  end

  defp read_one(spec, _request_fn, stamp), do: unread(spec, stamp, "the read names no subject")

  defp safe_request(request_fn, subject, payload) do
    request_fn.(subject, payload, timeout_ms: @read_timeout_ms)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp render(spec, reply, stamp) do
    case unwrap(reply) do
      {:ok, data} ->
        body = fit(data, spec, limit(spec))
        "#{heading(spec)} — read #{stamp} from #{spec["subject"]}:\n#{body}"

      {:error, reason} ->
        unread(spec, stamp, reason)
    end
  end

  defp unread(spec, stamp, why) do
    "#{heading(spec)} — could NOT be read at #{stamp} (#{why}). " <>
      "Do not guess what it contains; say you cannot see it right now."
  end

  defp heading(spec), do: "## " <> (spec["label"] || spec["subject"] || "a read")

  # The fleet envelope, or a bare body (fitness.workout.list answers bare).
  defp unwrap(%{"ok" => true, "data" => data}), do: {:ok, data}
  defp unwrap(%{"ok" => false} = r), do: {:error, "the bot refused: #{inspect(r["error"])}"}
  defp unwrap(%{} = bare), do: {:ok, bare}
  defp unwrap(other) when is_list(other), do: {:ok, other}
  defp unwrap(_), do: {:error, "the answer could not be read"}

  @doc false
  def prune(data, spec), do: prune(data, spec["fields"], limit(spec))

  defp prune(map, fields, limit) when is_map(map) do
    map
    |> Enum.reject(fn {k, _} -> k in @noise or k == "id" or String.ends_with?(k, "_id") end)
    |> Map.new(fn {k, v} -> {k, prune(v, fields, limit)} end)
  end

  defp prune([first | _] = list, fields, limit) when is_map(first) do
    shown = Enum.take(list, limit)

    rows =
      Enum.map(shown, fn row ->
        row = if is_list(fields) and is_map(row), do: Map.take(row, fields), else: row
        prune(row, nil, limit)
      end)

    if length(list) > limit,
      do: rows ++ ["(#{length(list) - limit} more not shown)"],
      else: rows
  end

  defp prune(other, _fields, _limit), do: other

  # Prune from the raw reply at a halving list limit until the block fits, so the
  # "(N more not shown)" count is always measured against what the bot sent.
  defp fit(raw, spec, limit) do
    text = raw |> prune(spec["fields"], limit) |> Jason.encode!()

    cond do
      byte_size(text) <= @max_chars -> text
      limit <= 1 -> String.slice(text, 0, @max_chars) <> " …(cut short)"
      true -> fit(raw, spec, div(limit, 2))
    end
  end

  defp limit(%{"limit" => n}) when is_integer(n) and n > 0, do: min(n, 50)
  defp limit(_), do: @default_limit

  defp describe(:timeout), do: "the bot did not answer in time"
  defp describe({:kill_switch_engaged, _}), do: "the house is paused"
  defp describe(:no_responders), do: "nobody is answering that subject"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
