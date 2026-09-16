defmodule SymphonyElixir.Experience.StoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Experience.{Canonical, Store}

  @project "embedded-lab-test"
  @agent %{kind: "agent", id: "run-7", display_name: "Driver Agent"}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    name = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: name, data_root: root})

    on_exit(fn -> File.rm_rf(root) end)
    %{store: name, root: root}
  end

  defp payload(attrs) do
    Map.merge(%{"title" => "t", "limitations" => []}, attrs)
  end

  describe "append/6" do
    test "writes the first revision and reports the assigned journal position", %{store: store} do
      assert {:ok, record} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{"kind" => "serial"}), @agent, server: store)

      assert record.entity_revision == 1
      assert record.project_seq == 1
      assert record.entity_type == "Evidence"
      assert record.actor == %{"kind" => "agent", "id" => "run-7", "display_name" => "Driver Agent"}
      assert record.payload_sha256 == Canonical.sha256(record.payload)
      assert record.idempotency_key == nil
    end

    test "appends successive revisions and rejects a stale expected revision", %{store: store} do
      assert {:ok, first} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: store)
      assert first.entity_revision == 1

      assert {:ok, second} = Store.append(@project, "Evidence", "ev-1", 1, payload(%{"title" => "v2"}), @agent, server: store)
      assert second.entity_revision == 2

      assert {:error, :revision_conflict, details} =
               Store.append(@project, "Evidence", "ev-1", 1, payload(%{"title" => "stale"}), @agent, server: store)

      assert details.current == 2
      assert details.expected == 1
    end

    test "keeps every archived revision readable", %{store: store} do
      {:ok, _first} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{"title" => "v1"}), @agent, server: store)
      {:ok, _second} = Store.append(@project, "Evidence", "ev-1", 1, payload(%{"title" => "v2"}), @agent, server: store)

      assert {:ok, old} = Store.get_revision(@project, "Evidence", "ev-1", 1, server: store)
      assert old.payload["title"] == "v1"

      assert {:ok, current} = Store.get(@project, "Evidence", "ev-1", server: store)
      assert current.payload["title"] == "v2"

      assert {:error, :not_found, %{revision: 9}} =
               Store.get_revision(@project, "Evidence", "ev-1", 9, server: store)
    end

    test "reports not_found for an unknown entity", %{store: store} do
      assert {:error, :not_found, %{entity_id: "missing"}} =
               Store.get(@project, "Evidence", "missing", server: store)
    end

    test "rejects an idempotency key reused with the same entity", %{store: store} do
      assert {:ok, _record} =
               Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent,
                 server: store,
                 idempotency_key: "key-12345678"
               )

      assert {:error, :duplicate_idempotency_key, %{idempotency_key: "key-12345678"}} =
               Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent,
                 server: store,
                 idempotency_key: "key-12345678"
               )
    end

    test "rejects malformed arguments without writing", %{store: store} do
      assert {:error, :invalid_entity_type, _} = Store.append(@project, "", "ev-1", 0, payload(%{}), @agent, server: store)
      assert {:error, :invalid_entity_id, _} = Store.append(@project, "Evidence", nil, 0, payload(%{}), @agent, server: store)
      assert {:error, :invalid_expected_revision, _} = Store.append(@project, "Evidence", "ev-1", -1, payload(%{}), @agent, server: store)
      assert {:error, :invalid_payload, _} = Store.append(@project, "Evidence", "ev-1", 0, "nope", @agent, server: store)
      assert {:error, :invalid_actor, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), %{kind: "robot"}, server: store)
      assert {:error, :invalid_project_id, _} = Store.append("../escape", "Evidence", "ev-1", 0, payload(%{}), @agent, server: store)
      assert Store.project_seq(@project, server: store) == 0
    end

    test "refuses a payload above the metadata limit", %{store: store} do
      huge = %{"blob" => String.duplicate("a", 1_100_000)}

      assert {:error, :payload_too_large, %{limit: 1_048_576}} =
               Store.append(@project, "Evidence", "ev-1", 0, huge, @agent, server: store)
    end

    test "accepts a system actor and a null actor", %{store: store} do
      assert {:ok, record} =
               Store.append(@project, "Operation", "op-1", 0, payload(%{}), %{kind: "system", id: "sys", display_name: "Server"}, server: store)

      assert record.actor["kind"] == "system"

      assert {:ok, event} = Store.append(@project, "Operation", "op-2", 0, payload(%{}), nil, server: store)
      assert event.actor == nil
    end
  end

  describe "listing and replay" do
    test "lists the newest revision per entity in journal order", %{store: store} do
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{"n" => 1}), @agent, server: store)
      {:ok, _} = Store.append(@project, "Evidence", "ev-2", 0, payload(%{"n" => 2}), @agent, server: store)
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 1, payload(%{"n" => 3}), @agent, server: store)
      {:ok, _} = Store.append(@project, "ProblemCase", "pc-1", 0, payload(%{}), @agent, server: store)

      listed = Store.list(@project, "Evidence", server: store)
      assert Enum.map(listed, & &1.entity_id) == ["ev-2", "ev-1"]
      assert List.last(listed).entity_revision == 2

      revisions = Store.list_revisions(@project, "Evidence", server: store)
      assert length(revisions) == 3
      assert Enum.map(revisions, & &1.project_seq) == [1, 2, 3]

      assert Store.project_seq(@project, server: store) == 4
    end

    test "replays only records after the cursor", %{store: store} do
      for index <- 1..3 do
        {:ok, _} = Store.append(@project, "Evidence", "ev-#{index}", 0, payload(%{}), @agent, server: store)
      end

      replayed = Store.replay(@project, 1, 500, server: store)
      assert Enum.map(replayed, & &1.project_seq) == [2, 3]

      assert Store.replay(@project, 0, 2, server: store) |> Enum.map(& &1.project_seq) == [1, 2]
      assert Store.replay(@project, 99, 500, server: store) == []
    end

    test "caps the replay limit at the documented maximum", %{store: store} do
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: store)

      assert Store.replay(@project, 0, 10_000, server: store) |> length() == 1
    end
  end

  describe "events" do
    test "assigns a durable sequence and a stable event id", %{store: store} do
      assert {:ok, event} =
               Store.emit_event(@project, "evidence.registered", "Evidence", "ev-1",
                 server: store,
                 entity_revision: 1,
                 actor: @agent,
                 run_id: "run-7",
                 payload: %{"detail" => "captured"}
               )

      assert event.project_seq == 1
      assert event.payload["type"] == "evidence.registered"
      assert event.payload["run_id"] == "run-7"
      assert event.payload["payload"]["detail"] == "captured"
      assert event.payload["event_id"] == event.entity_id
      assert String.starts_with?(event.entity_id, "evt-")
    end

    test "keeps the same event id for the same fact and different ids across runs", %{store: store} do
      {:ok, first} =
        Store.emit_event(@project, "plan.loaded", "Decision", "dec-1", server: store, entity_revision: 2, run_id: "run-a")

      {:ok, again} =
        Store.emit_event(@project, "plan.loaded", "Decision", "dec-1", server: store, entity_revision: 2, run_id: "run-a")

      {:ok, other_run} =
        Store.emit_event(@project, "plan.loaded", "Decision", "dec-1", server: store, entity_revision: 2, run_id: "run-b")

      assert first.entity_id == again.entity_id
      refute first.entity_id == other_run.entity_id
      assert first.project_seq == 1
      assert again.project_seq == 1
    end

    test "normalises event payload fields", %{store: store} do
      {:ok, event} =
        Store.emit_event(@project, "decision.adopted", "Decision", "dec-1",
          server: store,
          payload: %{"decision_id" => "dec-1", "plan_revision" => "r13", "decision_sha256" => String.duplicate("a", 64)}
        )

      assert event.payload["payload"] == %{
               "decision_id" => "dec-1",
               "decision_sha256" => String.duplicate("a", 64),
               "detail" => "",
               "plan_revision" => "r13"
             }
    end
  end

  describe "blobs" do
    test "stores bytes content-addressed and reads them back", %{store: store} do
      bytes = <<0x00, 0xFF, 0x41, 0x0A>>

      assert {:ok, receipt} = Store.put_blob(@project, bytes, "application/octet-stream", server: store)
      assert receipt["size_bytes"] == 4
      assert receipt["media_type"] == "application/octet-stream"

      expected = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      assert receipt["sha256"] == expected

      assert {:ok, ^bytes} = Store.get_blob(@project, receipt["sha256"], server: store)
      assert {:ok, 4} = Store.blob_size(@project, receipt["sha256"], server: store)
    end

    test "is idempotent for identical content", %{store: store} do
      assert {:ok, first} = Store.put_blob(@project, "same", "text/plain", server: store)
      assert {:ok, second} = Store.put_blob(@project, "same", "text/plain", server: store)
      assert first["sha256"] == second["sha256"]
    end

    test "reports missing and corrupt blobs distinctly", %{store: store, root: root} do
      assert {:error, :blob_missing, _} = Store.get_blob(@project, String.duplicate("0", 64), server: store)
      assert {:error, :blob_missing, _} = Store.blob_size(@project, String.duplicate("0", 64), server: store)

      assert {:error, :invalid_blob_digest, _} = Store.get_blob(@project, "not-a-digest", server: store)
      assert {:error, :invalid_blob_digest, _} = Store.get_blob(@project, nil, server: store)

      {:ok, receipt} = Store.put_blob(@project, "payload", "text/plain", server: store)
      digest = receipt["sha256"]
      path = Path.join([root, "blobs", "sha256", String.slice(digest, 0, 2), digest])
      File.write!(path, "tampered")

      assert {:error, :blob_corrupt, %{sha256: ^digest}} = Store.get_blob(@project, digest, server: store)
    end

    test "rejects an oversized blob and a blank media type", %{store: store} do
      assert {:error, :blob_too_large, %{limit: 67_108_864}} =
               Store.put_blob(@project, :binary.copy("x", 67_108_865), "text/plain", server: store)

      assert {:error, :invalid_media_type, _} = Store.put_blob(@project, "x", "", server: store)
      assert {:error, :invalid_blob_content, _} = Store.put_blob(@project, [:not, :iodata], "text/plain", server: store)
    end
  end

  describe "restart and recovery" do
    test "rebuilds the index from journal bytes without renumbering", %{store: store, root: root} do
      {:ok, first} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{"n" => 1}), @agent, server: store)
      {:ok, second} = Store.append(@project, "Evidence", "ev-2", 0, payload(%{"n" => 2}), @agent, server: store)

      assert {:ok, seq} = Store.rebuild_index(@project, server: store)
      assert seq == second.project_seq

      assert {:ok, reloaded_first} = Store.get(@project, "Evidence", "ev-1", server: store)
      assert reloaded_first.payload_sha256 == first.payload_sha256
      assert Store.project_seq(@project, server: store) == 2
      assert File.dir?(Path.join(root, "projects"))
    end

    test "survives a restart against the same data root", %{root: parent} do
      root = Path.join(parent, "restart")
      first_name = Module.concat(__MODULE__, :RestartFirst)
      {:ok, first_pid} = Store.start_link(name: first_name, data_root: root)

      {:ok, record} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{"n" => 1}), @agent, server: first_name)
      assert record.project_seq == 1
      assert {:ok, _} = Store.append(@project, "Evidence", "ev-2", 0, payload(%{"n" => 2}), @agent, server: first_name)

      GenServer.stop(first_pid)

      second_name = Module.concat(__MODULE__, :RestartSecond)
      start_supervised!({Store, name: second_name, data_root: root})

      assert {:ok, reopened} = Store.get(@project, "Evidence", "ev-1", server: second_name)
      assert reopened.payload_sha256 == record.payload_sha256
      assert Store.project_seq(@project, server: second_name) == 2
    end

    test "truncates a torn tail and reports it", %{root: parent} do
      root = Path.join(parent, "torn")
      writer = Module.concat(__MODULE__, :TornTailWriter)
      {:ok, writer_pid} = Store.start_link(name: writer, data_root: root)
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{"n" => 1}), @agent, server: writer)

      journal = Path.join([root, "projects", @project, "records.jsonl"])
      File.write!(journal, ~s({"schema_version":"1.0","project_seq":2,"entity_), [:append])
      GenServer.stop(writer_pid)

      name = Module.concat(__MODULE__, :TornTailStore)
      start_supervised!({Store, name: name, data_root: root})

      assert Store.project_seq(@project, server: name) == 1
      assert [%{kind: :truncated_journal_tail, discarded_bytes: discarded}] = Store.recovery_reports(server: name)
      assert discarded > 0
      refute String.ends_with?(File.read!(journal), "entity_")
    end

    test "refuses to start on a corrupt journal body instead of truncating history", %{root: parent} do
      root = Path.join(parent, "corrupt")
      writer = Module.concat(__MODULE__, :CorruptWriter)
      {:ok, writer_pid} = Store.start_link(name: writer, data_root: root)
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{"n" => 1}), @agent, server: writer)

      journal = Path.join([root, "projects", @project, "records.jsonl"])
      File.write!(journal, ~s({"schema_version":"1.0","project_seq":2,"payload":{}}) <> "\n", [:append])
      GenServer.stop(writer_pid)

      before = File.read!(journal)
      name = Module.concat(__MODULE__, :CorruptStore)
      start_supervised!({Store, name: name, data_root: root})

      # The project enters a read-only fault state: no silent truncation, and
      # writes are refused rather than corrupting the library further.
      assert {:error, :journal_corrupt, %{seq: 2}} = Store.get(@project, "Evidence", "ev-1", server: name)

      assert {:error, :journal_corrupt, _} =
               Store.append(@project, "Evidence", "ev-2", 0, payload(%{}), @agent, server: name)

      assert File.read!(journal) == before
    end

    test "refuses a second writer for the same data root", %{root: root} do
      name = Module.concat(__MODULE__, :SecondWriter)
      Process.flag(:trap_exit, true)
      assert {:error, {:store_start_failed, :data_root_locked, details}} = Store.start_link(name: name, data_root: root)
      assert details.path =~ "store.lock"
      Process.flag(:trap_exit, false)
    end

    test "reclaims a stale lock whose holder is gone", %{root: root} do
      File.write!(Path.join(root, "store.lock"), "nonode@nohost|999999999|2026-01-01T00:00:00Z")

      name = Module.concat(__MODULE__, :StaleLockStore)
      start_supervised!({Store, name: name, data_root: root})

      assert Store.project_seq(@project, server: name) == 0
      assert File.read!(Path.join(root, "store.lock")) =~ System.pid()
    end
  end

  describe "project id and entity guards" do
    test "refuses a non-binary project id on every entry point", %{store: store} do
      assert {:error, :invalid_project_id, _} = Store.append(7, "Evidence", "ev-1", 0, payload(%{}), @agent, server: store)
      assert {:error, :invalid_project_id, _} = Store.get(7, "Evidence", "ev-1", server: store)
      assert {:error, :invalid_project_id, _} = Store.get_revision(7, "Evidence", "ev-1", 1, server: store)
      assert {:error, :invalid_project_id, _} = Store.list(7, "Evidence", server: store)
      assert {:error, :invalid_project_id, _} = Store.list_revisions(7, "Evidence", server: store)
      assert {:error, :invalid_project_id, _} = Store.replay(7, 0, 500, server: store)
      assert {:error, :invalid_project_id, _} = Store.rebuild_index(7, server: store)
      assert Store.project_seq(7, server: store) == 0
    end

    test "refuses an absolute or traversing project id", %{store: store} do
      assert {:error, :invalid_project_id, _} = Store.append("/etc/passwd", "Evidence", "e", 0, payload(%{}), @agent, server: store)
      assert {:error, :invalid_project_id, _} = Store.append("a/b", "Evidence", "e", 0, payload(%{}), @agent, server: store)
    end

    test "rejects a payload containing a value with no canonical form", %{store: store} do
      assert {:error, :invalid_payload, %{reason: {:canonical_encode_failed, _}}} =
               Store.append(@project, "Evidence", "ev-1", 0, %{"bad" => :atom}, @agent, server: store)

      assert Store.project_seq(@project, server: store) == 0
    end

    test "treats a blank idempotency key as no key", %{store: store} do
      assert {:ok, first} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: store, idempotency_key: "")
      assert {:ok, second} = Store.append(@project, "Evidence", "ev-1", 1, payload(%{}), @agent, server: store, idempotency_key: "")

      assert first.entity_revision == 1
      assert second.entity_revision == 2
    end

    test "records an explicit recorded_at when the caller supplies one", %{store: store} do
      assert {:ok, record} =
               Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent,
                 server: store,
                 recorded_at: "2026-09-15T10:00:00Z"
               )

      assert record.recorded_at == "2026-09-15T10:00:00Z"
    end
  end

  describe "journal integrity" do
    test "reports an unreadable journal path", %{root: parent} do
      root = Path.join(parent, "dirjournal")
      name = Module.concat(__MODULE__, :DirJournal)
      {:ok, pid} = Store.start_link(name: name, data_root: root)
      File.mkdir_p!(Path.join([root, "projects", @project, "records.jsonl"]))

      assert {:error, :journal_unreadable, %{path: path}} = Store.get(@project, "Evidence", "ev-1", server: name)
      assert path =~ "records.jsonl"
      GenServer.stop(pid)
    end

    test "reports an unwritable project journal", %{root: parent} do
      root = Path.join(parent, "readonlyjournal")
      project_dir = Path.join([root, "projects", @project])
      File.mkdir_p!(project_dir)
      File.chmod!(project_dir, 0o500)

      name = Module.concat(__MODULE__, :ReadOnlyJournal)
      {:ok, pid} = Store.start_link(name: name, data_root: root)

      assert {:error, :journal_unreadable, %{reason: :eacces}} =
               Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: name)

      File.chmod!(project_dir, 0o700)
      GenServer.stop(pid)
    end

    test "treats a non-object journal line as a mid-journal fault", %{root: parent} do
      root = Path.join(parent, "nonobject")
      name = Module.concat(__MODULE__, :NonObjectJournal)
      {:ok, pid} = Store.start_link(name: name, data_root: root)
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: name)

      journal = Path.join([root, "projects", @project, "records.jsonl"])
      File.write!(journal, "[1,2,3]\n{\"no_schema\":true}\n", [:append])
      GenServer.stop(pid)

      reopened = Module.concat(__MODULE__, :NonObjectJournal2)
      start_supervised!({Store, name: reopened, data_root: root})

      assert {:error, :journal_corrupt, %{seq: 2}} = Store.get(@project, "Evidence", "ev-1", server: reopened)
    end

    test "treats an object line with no schema version as a mid-journal fault", %{root: parent} do
      root = Path.join(parent, "noschema")
      name = Module.concat(__MODULE__, :NoSchemaJournal)
      {:ok, pid} = Store.start_link(name: name, data_root: root)
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: name)

      journal = Path.join([root, "projects", @project, "records.jsonl"])
      File.write!(journal, ~s({"no_schema":true}) <> "\n", [:append])
      GenServer.stop(pid)

      reopened = Module.concat(__MODULE__, :NoSchemaJournal2)
      start_supervised!({Store, name: reopened, data_root: root})

      assert {:error, :journal_corrupt, %{seq: 2, reason: :malformed_record}} =
               Store.get(@project, "Evidence", "ev-1", server: reopened)
    end

    test "rebuilds the index against a journal damaged while running", %{store: store, root: root} do
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: store)

      journal = Path.join([root, "projects", @project, "records.jsonl"])
      File.write!(journal, ~s({"schema_version":"1.0","project_seq":2,"payload":{}}) <> "\n", [:append])

      # The project is already open, so the rebuild is what sees the damage.
      assert {:error, :journal_corrupt, %{seq: 2}} = Store.rebuild_index(@project, server: store)
    end

    test "reports a repair failure instead of truncating silently", %{root: parent} do
      root = Path.join(parent, "repairfault")
      name = Module.concat(__MODULE__, :RepairFault)
      {:ok, pid} = Store.start_link(name: name, data_root: root, faults: %{journal_repair: :enospc})
      {:ok, _} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: name)

      journal = Path.join([root, "projects", @project, "records.jsonl"])
      File.write!(journal, "torn", [:append])
      GenServer.stop(pid)

      reopened = Module.concat(__MODULE__, :RepairFault2)
      start_supervised!({Store, name: reopened, data_root: root, faults: %{journal_repair: :enospc}})

      assert {:error, :journal_repair_failed, %{reason: :enospc}} =
               Store.get(@project, "Evidence", "ev-1", server: reopened)
    end
  end

  describe "blob fault injection" do
    test "reports a failed blob write", %{store: _store, root: parent} do
      root = Path.join(parent, "blobfault")
      name = Module.concat(__MODULE__, :BlobFault)
      start_supervised!({Store, name: name, data_root: root, faults: %{blob_write: :enospc}})

      assert {:error, :blob_write_failed, %{reason: :enospc}} = Store.put_blob(@project, "x", "text/plain", server: name)
    end

    test "reports a failed blob rename", %{root: parent} do
      root = Path.join(parent, "renamefault")
      name = Module.concat(__MODULE__, :BlobRenameFault)
      start_supervised!({Store, name: name, data_root: root, faults: %{blob_rename: :eio}})

      assert {:error, :blob_write_failed, %{reason: :eio}} = Store.put_blob(@project, "x", "text/plain", server: name)
      assert File.ls!(Path.join(root, "blobs/tmp")) == []
    end

    test "reports an unwritable content-addressed path", %{root: parent} do
      root = Path.join(parent, "blockedblob")
      name = Module.concat(__MODULE__, :BlockedBlob)
      start_supervised!({Store, name: name, data_root: root})

      digest = :crypto.hash(:sha256, "x") |> Base.encode16(case: :lower)
      File.mkdir_p!(Path.join([root, "blobs", "sha256"]))
      File.write!(Path.join([root, "blobs", "sha256", String.slice(digest, 0, 2)]), "not-a-directory")

      assert {:error, :blob_write_failed, _} = Store.put_blob(@project, "x", "text/plain", server: name)
    end

    test "reports a blob rename blocked by a directory", %{root: parent} do
      root = Path.join(parent, "renameblocked")
      name = Module.concat(__MODULE__, :RenameBlocked)
      start_supervised!({Store, name: name, data_root: root})

      digest = :crypto.hash(:sha256, "x") |> Base.encode16(case: :lower)
      File.mkdir_p!(Path.join([root, "blobs", "sha256", String.slice(digest, 0, 2), digest]))

      assert {:error, :blob_write_failed, %{reason: :eisdir}} = Store.put_blob(@project, "x", "text/plain", server: name)
    end

    test "reports an unreadable blob", %{store: store, root: root} do
      digest = :crypto.hash(:sha256, "y") |> Base.encode16(case: :lower)
      dir = Path.join([root, "blobs", "sha256", String.slice(digest, 0, 2)])
      File.mkdir_p!(Path.join(dir, digest))

      assert {:error, :blob_unreadable, %{reason: :eisdir}} = Store.get_blob(@project, digest, server: store)
    end

    test "reports a blob that cannot be stat-ed", %{store: store, root: root} do
      digest = :crypto.hash(:sha256, "z") |> Base.encode16(case: :lower)
      dir = Path.join([root, "blobs", "sha256", String.slice(digest, 0, 2)])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, digest), "bytes")
      File.chmod!(dir, 0o000)

      assert {:error, :blob_unreadable, %{reason: :eacces}} = Store.blob_size(@project, digest, server: store)

      File.chmod!(dir, 0o700)
    end
  end

  describe "journal write fault injection" do
    test "refuses to acknowledge an append whose write failed", %{root: parent} do
      root = Path.join(parent, "writefault")
      name = Module.concat(__MODULE__, :WriteFault)
      start_supervised!({Store, name: name, data_root: root, faults: %{journal_write: :enospc}})

      assert {:error, :journal_write_failed, %{reason: :enospc}} =
               Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: name)

      assert Store.get(@project, "Evidence", "ev-1", server: name) ==
               {:error, :not_found, %{entity_type: "Evidence", entity_id: "ev-1"}}
    end

    test "refuses to acknowledge an append whose fsync failed", %{root: parent} do
      root = Path.join(parent, "fsyncfault")
      name = Module.concat(__MODULE__, :FsyncFault)
      start_supervised!({Store, name: name, data_root: root, faults: %{journal_fsync: :eio}})

      assert {:error, :journal_write_failed, %{reason: :eio}} =
               Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: name)

      assert Store.project_seq(@project, server: name) == 0
    end
  end

  describe "event broadcasting" do
    test "tolerates a missing pubsub process", %{root: parent} do
      root = Path.join(parent, "nopubsub")
      name = Module.concat(__MODULE__, :NoPubSub)
      start_supervised!({Store, name: name, data_root: root, pubsub: :symphony_missing_pubsub})

      assert {:ok, record} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: name)
      assert record.project_seq == 1
    end

    test "broadcasts a structured invalidation on the project topic", %{store: store} do
      Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "experience:project:#{@project}")

      assert {:ok, record} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: store)

      assert_receive {:experience_event, seq, "Evidence", "ev-1"}
      assert seq == record.project_seq
    end
  end

  describe "configuration guards" do
    test "ignores a non-map fault configuration", %{root: parent} do
      root = Path.join(parent, "bogusfaults")
      name = Module.concat(__MODULE__, :BogusFaults)
      start_supervised!({Store, name: name, data_root: root, faults: "not-a-map"})

      assert {:ok, record} = Store.append(@project, "Evidence", "ev-1", 0, payload(%{}), @agent, server: name)
      assert record.project_seq == 1
    end

    test "reports an unwritable data root", %{root: parent} do
      root = Path.join(parent, "readonlyroot")
      File.mkdir_p!(root)
      File.chmod!(root, 0o500)

      assert {:error, :data_root_unwritable, %{reason: :eacces}} = Store.validate_data_root(root, nil)

      File.chmod!(root, 0o700)
    end
  end

  describe "lock file shapes" do
    test "reclaims a lock whose contents carry no process id", %{root: root} do
      File.write!(Path.join(root, "store.lock"), "garbage-without-separator")

      name = Module.concat(__MODULE__, :GarbageLockStore)
      start_supervised!({Store, name: name, data_root: root})

      assert Store.project_seq(@project, server: name) == 0
    end

    test "reports an unreadable lock file", %{root: parent} do
      root = Path.join(parent, "dirlock")
      File.mkdir_p!(Path.join(root, "store.lock"))

      name = Module.concat(__MODULE__, :DirLockStore)
      Process.flag(:trap_exit, true)

      assert {:error, {:store_start_failed, :data_root_unwritable, %{reason: :eisdir}}} =
               Store.start_link(name: name, data_root: root)

      Process.flag(:trap_exit, false)
    end

    test "refuses a lock path already occupied by a dangling link", %{root: parent} do
      root = Path.join(parent, "danglinglock")
      File.mkdir_p!(root)
      File.ln_s!(Path.join(root, "missing-target"), Path.join(root, "store.lock"))

      name = Module.concat(__MODULE__, :DanglingLockStore)
      Process.flag(:trap_exit, true)

      # O_EXCL cannot create through an existing link entry, so the path is
      # reported as occupied rather than silently replaced.
      assert {:error, {:store_start_failed, :data_root_locked, _}} = Store.start_link(name: name, data_root: root)

      Process.flag(:trap_exit, false)
    end

    test "refuses to acknowledge the lock when taking it fails", %{root: parent} do
      root = Path.join(parent, "lockfault")
      File.mkdir_p!(root)

      name = Module.concat(__MODULE__, :LockWriteFault)
      Process.flag(:trap_exit, true)

      assert {:error, {:store_start_failed, :data_root_unwritable, %{path: path, reason: :enospc}}} =
               Store.start_link(name: name, data_root: root, faults: %{lock_write: :enospc})

      assert path =~ "store.lock"
      Process.flag(:trap_exit, false)
    end
  end

  describe "path canonicalization" do
    test "rejects a data root below a non-directory", %{root: root} do
      file = Path.join(root, "plain-file")
      File.write!(file, "x")

      assert {:error, :invalid_data_root, _} = Store.validate_data_root(Path.join(file, "evidence"), nil)
    end

    test "treats an unresolvable workspace root as usable", %{root: root} do
      file = Path.join(root, "workspace-file")
      File.write!(file, "x")
      data_root = Path.join(root, "records")
      File.mkdir_p!(data_root)

      assert :ok = Store.validate_data_root(data_root, Path.join(file, "sub"))
    end
  end

  describe "data root rules" do
    test "rejects a data root inside the workspace root" do
      workspace = Path.join(System.tmp_dir!(), "ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)

      assert {:error, :data_root_inside_workspace, _} =
               Store.validate_data_root(Path.join(workspace, "evidence"), workspace)

      assert {:error, :data_root_inside_workspace, _} = Store.validate_data_root(workspace, workspace)

      on_exit(fn -> File.rm_rf(workspace) end)
    end

    test "rejects a relative data root" do
      assert {:error, :invalid_data_root, %{reason: :not_absolute}} = Store.validate_data_root("relative/path", nil)
      assert {:error, :invalid_data_root, _} = Store.validate_data_root(nil, nil)
    end

    test "accepts a data root outside the workspace" do
      root = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}")
      workspace = Path.join(System.tmp_dir!(), "ws2-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      assert :ok = Store.validate_data_root(root, workspace)

      on_exit(fn -> File.rm_rf(root) end)
    end
  end
end

defmodule SymphonyElixir.Experience.StoreDefaultNameTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Experience.Store

  # The production supervisor starts the store under its default registered
  # name, so the default-argument arities are the ones live callers reach. This
  # module owns that name for the duration of the test.
  @project "embedded-lab-default-name"

  test "every entry point works through its default arity" do
    root = Path.join(System.tmp_dir!(), "symphony-store-default-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    store = Process.whereis(Store)

    if is_pid(store), do: GenServer.stop(store)
    start_supervised!({Store, data_root: root})

    on_exit(fn -> File.rm_rf(root) end)

    actor = %{kind: "agent", id: "run-1", display_name: "Driver Agent"}
    payload = %{"title" => "t", "limitations" => []}

    assert {:ok, receipt} = Store.put_blob(@project, "bytes", "text/plain")
    assert {:ok, first} = Store.append(@project, "Evidence", "ev-1", 0, payload, actor)
    assert {:ok, _second} = Store.append(@project, "Evidence", "ev-1", 1, payload, actor)
    assert {:ok, event} = Store.emit_event(@project, "evidence.registered", "Evidence", "ev-1")

    assert {:ok, record} = Store.get(@project, "Evidence", "ev-1")
    assert record.entity_revision == 2
    assert {:ok, archived} = Store.get_revision(@project, "Evidence", "ev-1", 1)
    assert archived.entity_revision == 1
    assert [%{entity_id: "ev-1"}] = Store.list(@project, "Evidence")
    assert length(Store.list_revisions(@project, "Evidence")) == 2
    assert [_ | _] = Store.replay(@project, 0)
    assert Store.project_seq(@project) == 3
    assert {:ok, _} = Store.rebuild_index(@project)
    assert is_list(Store.recovery_reports())
    assert {:ok, "bytes"} = Store.get_blob(@project, receipt["sha256"])
    assert {:ok, 5} = Store.blob_size(@project, receipt["sha256"])

    assert {:ok, _} = Store.append(@project, "Operation", "op-1", 0, Map.put(payload, "action", event.payload["type"]), actor)
    assert is_binary(Store.data_root(Store))
    assert first.entity_revision == 1
  end
end
