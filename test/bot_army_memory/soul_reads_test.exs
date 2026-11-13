defmodule BotArmyMemory.SoulReadsTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyMemory.{SoulChat, SoulReads}

  @now ~U[2026-11-12 17:40:00Z]

  # The live chore.task.list body, captured 2026-11-12 (ids shortened).
  @chores ~s({"correlation_id":"c1","data":{"chores":[{"assigned_to":null,"category":"chore","due_date":null,"frequency":"daily","id":"c80f","location":null,"status":"pending","title":"Put away dishes"},{"assigned_to":null,"category":"chore","due_date":null,"frequency":"daily","id":"a1b2","location":null,"status":"pending","title":"Load Dishwasher"}]},"ok":true,"schema_version":"1.0","timestamp":"2026-11-13T01:08:34Z"})

  # Reads run in async_stream tasks, so the tap reports to the test process by pid.
  defp answering(map) do
    test = self()

    fn subject, payload, _opts ->
      send(test, {:asked, subject, payload})

      case Map.fetch(map, subject) do
        {:ok, {:raw, body}} -> {:ok, Jason.decode!(body)}
        {:ok, reply} -> reply
        :error -> {:error, :no_responders}
      end
    end
  end

  test "a read is the bot's own rows, stamped, with ids and envelope noise gone" do
    config = %{
      "reads" => [
        %{
          "subject" => "chore.task.list",
          "label" => "the house's chores",
          "fields" => ["title", "frequency", "due_date"]
        }
      ]
    }

    [block] = SoulReads.take(config, answering(%{"chore.task.list" => {:raw, @chores}}), @now)

    # The tap works: a real read is seen, so the refusal test's refute is not vacuous.
    assert_received {:asked, "chore.task.list", %{}}
    assert block =~ "## the house's chores — read 2026-11-12 17:40 UTC from chore.task.list"
    assert block =~ ~s("title":"Put away dishes")
    assert block =~ ~s("title":"Load Dishwasher")
    assert block =~ ~s("frequency":"daily")
    refute block =~ "c80f"
    refute block =~ "correlation_id"
    refute block =~ "category"
  end

  test "a read that failed says so and is never an empty list" do
    config = %{"reads" => [%{"subject" => "chore.task.list", "label" => "chores"}]}

    [block] = SoulReads.take(config, answering(%{}), @now)
    assert block =~ "chores — could NOT be read"
    assert block =~ "nobody is answering"
    assert block =~ "Do not guess"
    refute block =~ "[]"

    [refused] =
      SoulReads.take(
        config,
        answering(%{"chore.task.list" => {:ok, %{"ok" => false, "error" => "db down"}}}),
        @now
      )

    assert refused =~ "could NOT be read"
    assert refused =~ "db down"
  end

  test "a write subject in a soul's config is refused before it is sent" do
    config = %{
      "reads" => [
        %{"subject" => "chore.task.complete", "payload" => %{"task_id" => "x"}},
        %{"subject" => "chore.assignment.list"}
      ]
    }

    blocks = SoulReads.take(config, answering(%{}), @now)

    assert Enum.all?(blocks, &(&1 =~ "not allowed to read"))
    refute_received {:asked, _, _}
  end

  test "a long list is cut and says how many were left out" do
    rows = for i <- 1..40, do: %{"title" => "task #{i}", "status" => "inbox", "id" => "id#{i}"}
    body = %{"ok" => true, "data" => %{"tasks" => rows, "total_count" => 119}}

    config = %{
      "reads" => [%{"subject" => "gtd.task.list", "limit" => 10, "fields" => ["title", "status"]}]
    }

    [block] = SoulReads.take(config, answering(%{"gtd.task.list" => {:ok, body}}), @now)

    assert block =~ "task 10"
    refute block =~ "task 11\""
    assert block =~ "(30 more not shown)"
    assert block =~ ~s("total_count":119)
  end

  test "a bare (un-enveloped) body is read as it is" do
    body = %{"count" => 0, "limit" => 10, "workouts" => []}
    config = %{"reads" => [%{"subject" => "fitness.workout.list", "label" => "workouts"}]}

    [block] = SoulReads.take(config, answering(%{"fitness.workout.list" => {:ok, body}}), @now)
    assert block =~ ~s("workouts":[])
    assert block =~ ~s("count":0)
  end

  test "a soul with reads has them in its prompt; one without is told it sees nothing" do
    soul = %{"bot_id" => "chore", "config" => %{"identity" => %{"name" => "Hearth"}}}

    blind = SoulChat.system_prompt(soul, [], @now)
    assert blind =~ "What you can see: nothing"

    # Every voice is told it can look and not touch, so it never offers a press it cannot make.
    assert blind =~ "you cannot change anything"
    assert blind =~ "Never offer to"

    seeing = SoulChat.system_prompt(soul, ["## chores — read …\n[]"], @now)
    assert seeing =~ "Thursday 2026-11-12 17:40"
    assert seeing =~ "Quote numbers and names exactly"
    assert seeing =~ "## chores"
    refute seeing =~ "What you can see: nothing"
  end

  test "a chat turn reads first, then asks the model with what it saw" do
    soul = %{
      "bot_id" => "chore",
      "config" => %{
        "talkable" => true,
        "identity" => %{"name" => "Hearth"},
        "reads" => [%{"subject" => "chore.task.list", "label" => "the house's chores"}]
      }
    }

    request_fn = fn
      "chore.task.list", _, _ ->
        {:ok, Jason.decode!(@chores)}

      "llm.request.chat", payload, _ ->
        send(self(), {:system, payload["system"]})
        {:ok, %{"job_id" => "j"}}

      "llm.job.status", _, _ ->
        {:ok,
         %{"status" => "completed", "result" => %{"content" => "Put away the dishes first."}}}
    end

    body = %{"bot_id" => "chore", "messages" => [%{"role" => "user", "content" => "what's on?"}]}

    assert {:ok, %{"reply" => "Put away the dishes first."}} =
             SoulChat.chat(body,
               get_fn: fn "chore", _ -> soul end,
               request_fn: request_fn,
               sleep_fn: fn _ -> :ok end,
               now: @now
             )

    assert_received {:system, system}
    assert system =~ "Put away dishes"
    assert system =~ "## the house's chores — read 2026-11-12 17:40 UTC"
  end
end
