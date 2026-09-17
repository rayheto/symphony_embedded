defmodule SymphonyElixir.Files.RunRecordsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Files.RunRecords

  # The records name their own task id in the title heading, so the fixtures take
  # one: a body with a hard-coded id would collapse every test file into one
  # record, which is exactly the behaviour the reader is supposed to have.
  defp task_body(id) do
    """
    # Task `#{id}`

    - Owner Agent: L2 C driver
    - Goal: fix the panel brightness path
    - Acceptance checks: parser ztest 16/16
    """
  end

  defp handoff_body(id, result \\ "complete") do
    """
    # Handoff `#{id}`

    - Owner Agent: L2 C driver
    - Result: #{result} — the false PWM model is gone
    """
  end

  setup do
    root = Path.join(System.tmp_dir!(), "run-records-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp record(records, id), do: Enum.find(records, &(&1.id == id))

  test "reads a task and its handoff from the task's own directory", %{root: root} do
    write!(Path.join(root, "t1/task.md"), task_body("t1"))
    write!(Path.join(root, "t1/handoff.md"), handoff_body("t1"))

    assert {:ok, records} = RunRecords.read_runs(root)
    assert [record] = records

    assert record.id == "t1"
    assert record.state == "complete"
    assert record.title == "fix the panel brightness path"
    assert record.owner == "L2 C driver"
    assert record.sources == [Path.join(root, "t1/handoff.md"), Path.join(root, "t1/task.md")]
  end

  test "reads flat task/handoff pairs side by side", %{root: root} do
    write!(Path.join(root, "t2.task.md"), task_body("t2"))
    write!(Path.join(root, "t2.handoff.md"), handoff_body("t2"))

    assert {:ok, [record]} = RunRecords.read_runs(root)
    assert record.id == "t2"
    assert record.state == "complete"
  end

  test "a container directory lets each file own its id", %{root: root} do
    write!(Path.join(root, "family/a1.task.md"), "# Task: do the first thing\n")
    write!(Path.join(root, "family/a1.handoff.md"), handoff_body("a1"))
    write!(Path.join(root, "family/a2.handoff.md"), "- Result: partial\n")

    assert {:ok, records} = RunRecords.read_runs(root)

    assert Enum.map(records, & &1.id) == ["a1", "a2"]
    assert record(records, "a1").title == "do the first thing"
    assert record(records, "a2").state == "partial"
  end

  test "a task-named directory owns the id even when the file name drifts", %{root: root} do
    write!(Path.join(root, "co5300_dcs_brightness_9f3a/task.md"), task_body("co5300_dcs_brightness_9f3a"))

    write!(
      Path.join(root, "co5300_dcs_brightness_9f3a/co5300-dcs-brightness.handoff.md"),
      handoff_body("co5300_dcs_brightness_9f3a")
    )

    assert {:ok, [record]} = RunRecords.read_runs(root)
    assert record.id == "co5300_dcs_brightness_9f3a"
    assert record.description =~ "9f3a/co5300-dcs-brightness.handoff.md"
  end

  test "a bare file at the record root still yields a record", %{root: root} do
    write!(Path.join(root, "handoff.md"), "- Result: complete\n")
    write!(Path.join(root, "task.md"), "# Task: unmatched heading\n")

    assert {:ok, records} = RunRecords.read_runs(root)

    assert Enum.sort(Enum.map(records, & &1.id)) == ["handoff.md", "task.md"]
  end

  test "a handoff that declares no verdict is delivered, not guessed", %{root: root} do
    write!(Path.join(root, "t3/task.md"), task_body("t3"))
    write!(Path.join(root, "t3/handoff.md"), "# Handoff `t3`\n\n- Owner Agent: L2\n")

    assert {:ok, [record]} = RunRecords.read_runs(root)
    assert record.state == "delivered"
    assert record.description =~ "handoff 没有写 Result:"
  end

  test "a verdict word outside the documented set is delivered and reported", %{root: root} do
    write!(Path.join(root, "t4/handoff.md"), "# Handoff `t4`\n\n- Result: code complete; both gates PASS\n")

    assert {:ok, [record]} = RunRecords.read_runs(root)
    assert record.state == "delivered"
    assert record.description =~ "Result: code 不在此表内"
  end

  test "a task with no handoff is open", %{root: root} do
    write!(Path.join(root, "t5/task.md"), task_body("t5"))

    assert {:ok, [record]} = RunRecords.read_runs(root)
    assert record.state == "open"
    assert record.id == "t5"
    assert record.title == "fix the panel brightness path"
  end

  test "a README beside the records is not a record", %{root: root} do
    write!(Path.join(root, "README.md"), "# Task runs\n\nnot a task\n")
    write!(Path.join(root, "t6/notes.md"), "free text\n")

    assert {:ok, records} = RunRecords.read_runs(root)
    assert records == []
  end

  test "a record that cannot be read is reported as unreadable", %{root: root} do
    File.ln_s!(Path.join(root, "missing-target.md"), Path.join(root, "t7.handoff.md"))

    assert {:ok, [record]} = RunRecords.read_runs(root)
    assert record.id == "t7"
    assert record.state == "unreadable"
    assert record.title =~ "无法读取"
    assert record.description =~ "读取失败"
  end

  test "an unreadable directory contributes nothing and says so", %{root: root} do
    locked = Path.join(root, "locked")
    File.mkdir_p!(locked)
    File.write!(Path.join(locked, "task.md"), task_body("locked"))
    File.chmod!(locked, 0o000)

    on_exit(fn -> File.chmod(locked, 0o700) end)

    assert {:ok, records} =
             with_log(fn -> RunRecords.read_runs(root) end)
             |> then(fn {result, log} ->
               assert log =~ "run record directory unreadable"
               result
             end)

    assert records == []
  end

  test "a record root that cannot be listed is an error, not an empty board" do
    assert {:error, :record_root_unreadable, %{root: "/nope/nope"}} = RunRecords.read_runs("/nope/nope")
  end

  test "a missing record root is reported as such" do
    assert {:error, :record_root_missing, %{reason: reason}} = RunRecords.read(nil)
    assert reason =~ "no record root"
    assert {:error, :record_root_missing, _details} = RunRecords.read("")
  end

  test "reads bridge task records and merges them with the run records", %{root: root} do
    write!(Path.join(root, "t8/handoff.md"), "# Handoff `t8`\n\n- Result: complete\n")
    bridge = Path.join(root, "bridge")
    File.mkdir_p!(bridge)

    File.write!(Path.join(bridge, "one.json"), bridge_json("t8", "completed", "/root/t8"))
    File.write!(Path.join(bridge, "two.json"), bridge_json("only-bridge", "completed", "/root/only-bridge"))
    File.write!(Path.join(bridge, "three.json"), bridge_json("failed-one", "failed", "/root/failed-one"))
    File.write!(Path.join(bridge, "four.json"), bridge_json("held-one", "claimed", "/root/held-one"))
    File.write!(Path.join(bridge, "five.json"), bridge_json("pending-one", "pending", "/root/pending-one"))
    File.write!(Path.join(bridge, "six.json"), bridge_json("odd-one", "queued", "/root/odd-one"))
    # The bridge also keeps a lock file beside every task; it is not a record.
    File.write!(Path.join(bridge, "one.lock"), "")

    assert {:ok, records} = RunRecords.read(root, bridge_tasks: bridge)

    assert record(records, "t8").state == "complete"
    assert record(records, "t8").bridge.status == "completed"

    assert record(records, "only-bridge").state == "delivered"
    assert record(records, "only-bridge").owner == "only-bridge"
    assert record(records, "only-bridge").description =~ "completed"

    assert record(records, "failed-one").state == "failed"
    assert record(records, "held-one").state == "claimed"
    assert record(records, "pending-one").state == "claimed"
    assert record(records, "odd-one").state == "delivered"
    assert length(records) == 6
  end

  test "a bridge carrier belongs to this project only when it names it", %{root: root} do
    bridge = Path.join(root, "bridge")
    File.mkdir_p!(bridge)

    File.write!(
      Path.join(bridge, "mine.json"),
      bridge_json("mine", "completed", "/root/mine", payload: "work in /repo/this-project")
    )

    File.write!(
      Path.join(bridge, "theirs.json"),
      bridge_json("theirs", "completed", "/root/theirs", payload: "work in /repo/other-project")
    )

    assert {:ok, records} = RunRecords.read(root, bridge_tasks: bridge, bridge_marker: "this-project")
    assert Enum.map(records, & &1.id) == ["mine"]
  end

  test "a bridge handoff keeps its own verdict and only gains the claimant", %{root: root} do
    write!(Path.join(root, "t9/handoff.md"), "# Handoff `t9`\n\n- Result: partial\n")
    bridge = Path.join(root, "bridge")
    File.mkdir_p!(bridge)
    File.write!(Path.join(bridge, "t9.json"), bridge_json("t9", "failed", "/root/t9"))

    assert {:ok, [record]} = RunRecords.read(root, bridge_tasks: bridge)

    # The transport says "failed"; the project's own handoff says partial. The
    # handoff wins, and the bridge fills in who ran it.
    assert record.state == "partial"
    assert record.owner == "t9"
    assert record.bridge.status == "failed"
  end

  test "a bridge directory that cannot be listed is reported and does not lose the run records", %{root: root} do
    write!(Path.join(root, "t10/handoff.md"), "# Handoff `t10`\n\n- Result: complete\n")

    {records, log} =
      with_log(fn -> RunRecords.read(root, bridge_tasks: Path.join(root, "absent")) end)

    assert log =~ "bridge task records unavailable"
    assert {:ok, [record]} = records
    assert record.id == "t10"
  end

  test "a bridge record that cannot be parsed is skipped with a warning", %{root: root} do
    bridge = Path.join(root, "bridge")
    File.mkdir_p!(bridge)
    File.write!(Path.join(bridge, "broken.json"), "{not json")
    File.write!(Path.join(bridge, "nameless.json"), ~s({"status":"completed"}))
    File.write!(Path.join(bridge, "unreadable.json"), bridge_json("u", "completed", "/root/u"))
    File.chmod!(Path.join(bridge, "unreadable.json"), 0o000)

    on_exit(fn -> File.chmod(Path.join(bridge, "unreadable.json"), 0o600) end)

    {result, log} = with_log(fn -> RunRecords.read(root, bridge_tasks: bridge) end)

    assert log =~ "bridge task record unreadable"
    assert {:ok, []} = result
  end

  test "requested names, absent payloads and odd timestamps are tolerated", %{root: root} do
    bridge = Path.join(root, "bridge")
    File.mkdir_p!(bridge)

    File.write!(
      Path.join(bridge, "a.json"),
      Jason.encode!(%{
        "requested_task_name" => "requested-only",
        "status" => "completed",
        "claimed_by" => "/root/",
        "created_at" => 1_760_000_000,
        "updated_at" => "not-a-time"
      })
    )

    assert {:ok, [record]} = RunRecords.read(root, bridge_tasks: bridge)

    assert record.id == "requested-only"
    assert record.owner == nil
    assert record.bridge.created_at == nil
    assert record.bridge.updated_at == nil
  end

  test "a bridge record without a claimant and an empty bridge path are handled", %{root: root} do
    bridge = Path.join(root, "bridge")
    File.mkdir_p!(bridge)
    File.write!(Path.join(bridge, "anon.json"), Jason.encode!(%{"task_name" => "anon", "status" => "completed"}))

    assert {:ok, [record]} = RunRecords.read(root, bridge_tasks: bridge)
    assert record.id == "anon"
    assert record.owner == nil
    assert record.bridge.created_at == nil

    assert RunRecords.bridge_records("") == []
    assert RunRecords.bridge_records(nil) == []
  end

  test "no bridge directory means the run records stand alone", %{root: root} do
    write!(Path.join(root, "t11/handoff.md"), "# Handoff `t11`\n\n- Result: complete\n")

    assert {:ok, [record]} = RunRecords.read(root)
    assert record.bridge == nil
    assert record.bridge_only == false
  end

  test "the reader advertises the vocabulary it can justify", %{root: root} do
    write!(Path.join(root, "t12/handoff.md"), "# Handoff `t12`\n\n- Result: complete\n")
    assert {:ok, [record]} = RunRecords.read(root)
    assert record.state == "complete"

    assert RunRecords.states() == [
             "open",
             "claimed",
             "delivered",
             "complete",
             "partial",
             "blocked",
             "failed",
             "unreadable"
           ]
  end

  defp bridge_json(name, status, claimed_by, opts \\ []) do
    Jason.encode!(%{
      "task_name" => name,
      "status" => status,
      "claimed_by" => claimed_by,
      "payload" => Keyword.get(opts, :payload, "task for #{name}"),
      "created_at" => "2026-09-16T03:36:39.876464Z",
      "updated_at" => "2026-09-16T22:15:21.865908Z"
    })
  end
end
