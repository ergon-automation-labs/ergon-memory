defmodule BotArmyMemory.NATS.Consumer do
  @moduledoc """
  NATS message consumer for the Memory bot.

  Serves the centralized memory + soul surface:

    memory.record   Q/A exchange recording (publish or request-reply)
    memory.list     conversation history for a session
    memory.clear    drop a session's exchanges
    memory.append   general session context note (kind/payload, trimmed)
    memory.entries  read back a session's appended entries
    soul.get        active personality config for a bot
    soul.upsert     store a new versioned personality config

  Messages WITH a reply_to get request-reply handling; messages without
  one (fire-and-forget publishes, e.g. Memory.record_exchange/4) are
  processed with errors logged — they are NOT silently dropped.
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.NATS.{Connection, Reply}
  alias BotArmyLibraryRuntime.Tenant
  alias BotArmyMemory.Stores.{ExchangeStore, MemoryEntryStore, SoulStore}

  @subjects [
    %{subject: "memory.record", type: :request_reply},
    %{subject: "memory.list", type: :request_reply},
    %{subject: "memory.clear", type: :request_reply},
    %{subject: "memory.append", type: :request_reply},
    %{subject: "memory.entries", type: :request_reply},
    %{subject: "soul.get", type: :request_reply},
    %{subject: "soul.upsert", type: :request_reply}
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscriptions: [], conn: nil}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(Connection, :get_connection, 5000) do
      {:ok, conn} ->
        {:noreply, connect_and_subscribe(conn, state)}

      {:error, reason} ->
        Logger.warning("[Memory Consumer] Connection not ready (#{inspect(reason)}), retrying")
        Process.send_after(self(), :connect_retry, 5000)
        {:noreply, state}
    end
  end

  defp connect_and_subscribe(conn, state) do
    Connection.subscribe_to_status()

    subscriptions =
      Enum.map(@subjects, fn %{subject: subject} ->
        subscribe_to_subject(conn, subject)
      end)
      |> Enum.reject(&is_nil/1)

    %{state | subscriptions: subscriptions, conn: conn}
  end

  defp subscribe_to_subject(conn, subject) do
    case Gnat.sub(conn, self(), subject) do
      {:ok, sub} ->
        sub

      {:error, reason} ->
        Logger.error("[Memory Consumer] Sub failed #{subject}: #{inspect(reason)}")
        nil
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    if msg.reply_to do
      handle_request_reply(msg)
    else
      handle_fire_and_forget(msg)
    end

    {:noreply, state}
  end

  defp handle_request_reply(msg) do
    body = decode_body(msg.body)

    result =
      safe_process(msg.topic, body)

    reply = build_reply(result)

    case GenServer.call(Connection, :get_connection, 5000) do
      {:ok, conn} -> Gnat.pub(conn, msg.reply_to, reply)
      _ -> :ok
    end
  end

  defp handle_fire_and_forget(msg) do
    body = decode_body(msg.body)

    case safe_process(msg.topic, body) do
      {:ok, _data} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Memory Consumer] #{msg.topic} (fire-and-forget) failed: #{inspect(reason)}"
        )
    end
  end

  # Store/DB exceptions must never kill the GenServer — they surface as
  # error replies (or logged failures) instead.
  defp safe_process(topic, body) do
    process_message(topic, body)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, m} -> m
      _ -> %{}
    end
  end

  defp process_message("memory.record", body), do: handle_record(body)
  defp process_message("memory.list", body), do: handle_list(body)
  defp process_message("memory.clear", body), do: handle_clear(body)
  defp process_message("memory.append", body), do: handle_append(body)
  defp process_message("memory.entries", body), do: handle_entries(body)
  defp process_message("soul.get", body), do: handle_soul_get(body)
  defp process_message("soul.upsert", body), do: handle_soul_upsert(body)
  defp process_message(_, _), do: {:error, :unknown_subject}

  defp build_reply({:ok, data}), do: Reply.ok(data)
  defp build_reply({:error, reason}), do: Reply.error(inspect(reason), :request_failed)

  defp handle_record(body) do
    opts = body["opts"] || %{}

    attrs = %{
      "session_id" => body["session_id"],
      "tenant_id" => Map.get(opts, "tenant_id"),
      "question" => body["question"],
      "answer" => body["answer"],
      "source" => Map.get(opts, "source"),
      "meta" => Map.get(opts, "meta", %{})
    }

    case ExchangeStore.record(attrs) do
      {:ok, exchange} -> {:ok, %{"id" => exchange.id}}
      other -> {:error, inspect(other)}
    end
  end

  defp handle_list(body) do
    session_id = body["session_id"]
    opts = body["opts"] || %{}

    # list/2 only returns {:ok, history}; DB failures raise and are caught
    # by safe_process above.
    {:ok, ExchangeStore.list(session_id, opts)}
  end

  defp handle_clear(body) do
    session_id = body["session_id"]
    opts = body["opts"] || %{}

    {:ok, count} = ExchangeStore.clear(session_id, opts)
    {:ok, %{"deleted" => count}}
  end

  defp handle_append(body) do
    data = body["data"] || %{}
    opts = body["opts"] || %{}
    scope = data["session_id"]

    if scope do
      attrs = [
        scope: scope,
        tenant_id: Map.get(opts, "tenant_id") || Tenant.default_tenant_id(),
        user_id: Map.get(opts, "user_id"),
        source: Map.get(opts, "source"),
        kind: Map.get(opts, "kind", "thought"),
        payload: Map.drop(data, ["session_id"])
      ]

      case MemoryEntryStore.append(attrs, Map.get(opts, "limit", 10)) do
        {:ok, id} -> {:ok, %{"id" => id}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_scope}
    end
  end

  defp handle_entries(body) do
    scope = body["scope"] || body["session_id"]
    opts = body["opts"] || %{}

    case MemoryEntryStore.list(scope, opts) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_soul_get(body) do
    bot_id = normalize_bot_id(body["bot_id"])
    tenant_id = Map.get(body, "tenant_id") || Tenant.default_tenant_id()

    case SoulStore.get(bot_id, tenant_id) do
      # Absence is not an error: reply {:ok, nil} and let the caller decide.
      nil -> {:ok, nil}
      soul -> {:ok, soul}
    end
  end

  defp handle_soul_upsert(body) do
    bot_id = normalize_bot_id(body["bot_id"])
    config = body["config"]
    tenant_id = Map.get(body, "tenant_id") || Tenant.default_tenant_id()

    case SoulStore.upsert(bot_id, config, tenant_id) do
      {:ok, soul} -> {:ok, %{"id" => soul.id, "version" => soul.version}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Old runtime semantics: souls are stored WITHOUT the "bot_army_" prefix
  # ("bot_army_gtd" -> "gtd"). Keep accepting both shapes.
  defp normalize_bot_id(bot_id) when is_atom(bot_id),
    do: bot_id |> Atom.to_string() |> String.replace_prefix("bot_army_", "")

  defp normalize_bot_id(bot_id) when is_binary(bot_id),
    do: String.replace_prefix(bot_id, "bot_army_", "")

  defp normalize_bot_id(_), do: nil
end
