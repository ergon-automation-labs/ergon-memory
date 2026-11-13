defmodule BotArmyMemory.SoulChat do
  @moduledoc """
  Talking to a bot's soul.

      soul.list   {}                                   -> [%{"bot_id", "name", "tagline"}]
      soul.chat   {"bot_id", "messages": [{role, content}, ...]}
                                                       -> %{"bot_id", "name", "reply"}

  A soul is on the cast only when its config says `"talkable": true` — the soul's owner
  decides who can be talked to, never the page.

  The conversation is the caller's: this module stores nothing. Every turn arrives whole
  (capped), the soul is read fresh, and the model is asked on `llm.request.chat` with
  `"async": true` and polled on `llm.job.status`, because a generation's length is a
  property of the model and a fixed deadline would lose the answer silently.

  A soul can not see its bot's records in this version, and the prompt says so: asked for
  a fact it does not have, it says it cannot see it rather than inventing one. A degraded
  (deterministic fallback) answer is refused as `:llm_busy`, not passed off as the soul.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher
  alias BotArmyLibraryRuntime.Tenant
  alias BotArmyMemory.SoulReads
  alias BotArmyMemory.Stores.SoulStore

  @max_turns 12
  @max_chars 2_000
  @poll_ms 2_000
  @budget_ms 90_000
  @submit_timeout_ms 10_000
  @status_timeout_ms 15_000

  @base_voice """
  You are one voice in a small household system that helps the person you are talking to
  get through her days. She has ADHD. These rules come before your own character:

  - Say what you know and what you cannot see. Never invent a task, a date, a count, a
    weight or a name. Facts come only from the "What you can see" section below, if there
    is one; anything not in it, say plainly that you cannot see it from here.
  - No shame. Never say overdue, behind, broken streak, or "you should have". Something
    stale gets "is this still true?", not an accusation.
  - Short. One next thing, not a list. If something is big, offer the smallest first step.
  - Nudge, never nag. Everything you suggest can be declined, and declining is fine.
  - You can look, but you cannot change anything: you cannot complete, add, delete, move or
    log anything. Never offer to ("want me to mark it done?"). If something should change,
    say she can do it on its own card on the panel.
  - You do not give orders and you do not claim authority over her. You are not part of
    any relationship between her and anyone else; do not speak in that register.
  - Plain text. No headings, no bullet lists unless she asks for one.
  """

  @doc "The fleet-wide voice every soul is layered on."
  def base_voice, do: @base_voice

  @doc "The talkable cast for a tenant, in name order."
  @spec cast(map(), keyword()) :: {:ok, [map()]}
  def cast(body, opts \\ []) do
    tenant_id = tenant(body)
    list_fn = Keyword.get(opts, :list_fn, &SoulStore.list/1)

    cast =
      tenant_id
      |> list_fn.()
      |> Enum.filter(&talkable?/1)
      |> Enum.map(fn soul ->
        %{
          "bot_id" => soul["bot_id"],
          "name" => name(soul),
          "tagline" => get_in(soul, ["config", "tagline"])
        }
      end)
      |> Enum.sort_by(& &1["name"])

    {:ok, cast}
  end

  @doc """
  One turn of conversation with a soul.

  Options (for tests): `:get_fn` (bot_id, tenant_id -> soul | nil), `:request_fn`
  (subject, payload, opts -> Publisher-shaped reply), `:sleep_fn`, `:poll_ms`, `:budget_ms`.
  """
  @spec chat(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(body, opts \\ []) do
    get_fn = Keyword.get(opts, :get_fn, &SoulStore.get/2)

    request_fn = Keyword.get(opts, :request_fn, &Publisher.request/3)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, bot_id} <- bot_id(body),
         {:ok, messages} <- messages(body),
         {:ok, soul} <- talkable_soul(get_fn.(bot_id, tenant(body))),
         seen = SoulReads.take(soul["config"] || %{}, request_fn, now),
         {:ok, text} <- ask(system_prompt(soul, seen, now), messages, opts) do
      {:ok, %{"bot_id" => bot_id, "name" => name(soul), "reply" => text}}
    end
  end

  @doc "The system prompt for a soul: the shared voice, then the soul's own character."
  @spec system_prompt(map(), [String.t()], DateTime.t()) :: String.t()
  def system_prompt(soul, seen \\ [], now \\ DateTime.utc_now()) do
    config = soul["config"] || %{}

    character =
      [
        {"Your name", name(soul)},
        {"Who you are", config["character"]},
        {"Your tone", config["tone"]},
        {"What you care about", join(config["priorities"])},
        {"What you will not do", join(config["refusals"])},
        {"How you sound", join(config["sample_lines"])}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

    @base_voice <> "\n" <> character <> "\n\n" <> seen_section(seen, now)
  end

  defp seen_section([], _now) do
    "What you can see: nothing. You cannot read your bot's records in this conversation. " <>
      "If she asks for a fact from them, say you cannot see it from here yet."
  end

  defp seen_section(blocks, now) do
    """
    What you can see. Read just now from the house's bots (it is #{Calendar.strftime(now, "%A %Y-%m-%d %H:%M")} UTC; every
    time below is UTC too). This is the truth for this turn. Quote numbers and names exactly as
    they are here; never add a row, a date or a count that is not here. Do not read the whole
    list back — pick the one thing that helps. A section marked "could NOT be read" means you
    do not know what is in it.

    #{Enum.join(blocks, "\n\n")}
    """
  end

  # -- validation ---------------------------------------------------------------------------

  defp bot_id(%{"bot_id" => id}) when is_binary(id) and id != "",
    do: {:ok, String.replace_prefix(id, "bot_army_", "")}

  defp bot_id(_), do: {:error, :missing_bot_id}

  defp messages(%{"messages" => list}) when is_list(list) do
    cleaned =
      list
      |> Enum.flat_map(fn
        %{"role" => role, "content" => content}
        when role in ["user", "assistant"] and is_binary(content) ->
          case String.trim(content) do
            "" -> []
            text -> [%{"role" => role, "content" => String.slice(text, 0, @max_chars)}]
          end

        _ ->
          []
      end)
      |> Enum.take(-@max_turns)

    case List.last(cleaned) do
      %{"role" => "user"} -> {:ok, cleaned}
      _ -> {:error, :last_message_must_be_hers}
    end
  end

  defp messages(_), do: {:error, :missing_messages}

  defp talkable_soul(nil), do: {:error, :no_soul}

  defp talkable_soul(soul) do
    if talkable?(soul), do: {:ok, soul}, else: {:error, :not_talkable}
  end

  defp talkable?(soul), do: get_in(soul, ["config", "talkable"]) in [true, "true"]

  defp name(soul) do
    get_in(soul, ["config", "identity", "name"]) || soul["bot_id"]
  end

  defp tenant(body), do: Map.get(body, "tenant_id") || Tenant.default_tenant_id()

  defp join(list) when is_list(list), do: Enum.join(list, "; ")
  defp join(text) when is_binary(text), do: text
  defp join(_), do: nil

  # -- the model ----------------------------------------------------------------------------

  defp ask(system, messages, opts) do
    request_fn = Keyword.get(opts, :request_fn, &Publisher.request/3)

    payload = %{
      "system" => system,
      "messages" => messages,
      "request_type" => "chat",
      "async" => true
    }

    case request_fn.("llm.request.chat", payload, timeout_ms: @submit_timeout_ms) do
      {:ok, %{"job_id" => job_id}} when is_binary(job_id) ->
        deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @budget_ms)
        poll(job_id, deadline, 0, opts)

      {:ok, other} ->
        Logger.warning("[SoulChat] llm.request.chat answered without a job: #{inspect(other)}")
        {:error, :llm_unreadable}

      {:error, reason} ->
        {:error, {:llm_unreachable, reason}}
    end
  end

  defp poll(job_id, deadline, misses, opts) do
    request_fn = Keyword.get(opts, :request_fn, &Publisher.request/3)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)

    if System.monotonic_time(:millisecond) > deadline do
      {:error, :llm_still_thinking}
    else
      sleep_fn.(Keyword.get(opts, :poll_ms, @poll_ms))

      case request_fn.("llm.job.status", %{"job_id" => job_id}, timeout_ms: @status_timeout_ms) do
        {:ok, %{"status" => "completed", "result" => result}} ->
          read_result(result)

        {:ok, %{"status" => "failed", "error" => error}} ->
          {:error, {:llm_failed, error}}

        {:ok, %{"status" => "pending"}} ->
          poll(job_id, deadline, misses, opts)

        other when misses < 2 ->
          Logger.debug("[SoulChat] unreadable status for #{job_id}: #{inspect(other)}")
          poll(job_id, deadline, misses + 1, opts)

        _other ->
          {:error, :llm_unreadable}
      end
    end
  end

  defp read_result(%{"degraded" => true}), do: {:error, :llm_busy}

  defp read_result(%{"content" => text}) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_reply}
      trimmed -> {:ok, trimmed}
    end
  end

  defp read_result(_), do: {:error, :llm_unreadable}
end
