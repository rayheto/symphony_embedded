defmodule SymphonyElixir.Experience.Store do
  @moduledoc """
  Durable, append-only engineering record store.

  The store owns one data root that must live outside the workspace root. It
  keeps a single serialized writer per project so durable-before-ack holds: a
  record is fsynced to the project journal before any caller is told it
  succeeded. Blobs are content-addressed and immutable.

  Records are never mutated in place. Every change appends a new revision whose
  `expected_revision` must match the current one, which gives local compare-and-
  swap without pretending the tracker offers atomic remote CAS.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Experience.Canonical
  alias SymphonyElixir.PathSafety

  @schema_version "1.0"
  @max_payload_bytes 1_048_576
  @max_blob_bytes 67_108_864
  @journal_name "records.jsonl"
  @lock_name "store.lock"
  @default_timeout 30_000
  @max_replay_limit 500

  @type record :: %{
          required(:schema_version) => String.t(),
          required(:project_seq) => pos_integer(),
          required(:entity_type) => String.t(),
          required(:entity_id) => String.t(),
          required(:entity_revision) => pos_integer(),
          required(:actor) => map() | nil,
          required(:payload) => map(),
          required(:payload_sha256) => String.t(),
          required(:recorded_at) => String.t(),
          required(:idempotency_key) => String.t() | nil
        }

  defmodule Project do
    @moduledoc false
    defstruct [
      :project_id,
      :dir,
      :journal_path,
      :fd,
      seq: 0,
      revisions: %{},
      history: %{},
      keys: %{}
    ]
  end

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 15_000,
      type: :worker
    }
  end

  @doc """
  Append a new immutable revision of an entity.

  `expected_revision` is the revision the caller last observed; `0` means the
  entity does not exist yet. A mismatch is reported as `:revision_conflict` and
  writes nothing.
  """
  @spec append(String.t(), String.t(), String.t(), non_neg_integer(), map(), map(), keyword()) ::
          {:ok, record()} | {:error, atom(), map()}
  def append(project_id, entity_type, entity_id, expected_revision, payload, actor, opts \\ []) do
    GenServer.call(
      server(opts),
      {:append, project_id, entity_type, entity_id, expected_revision, payload, actor, opts},
      @default_timeout
    )
  end

  @doc """
  Append an engineering event.

  Events carry their journal position as `project_seq`, so a client that
  reconnects with a cursor sees every recorded fact exactly once and duplicates
  can be filtered by `event_id`.
  """
  @spec emit_event(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, record()} | {:error, atom(), map()}
  def emit_event(project_id, type, entity_type, entity_id, opts \\ []) do
    revision = Keyword.get(opts, :entity_revision, 1)
    id = "evt-" <> event_digest(project_id, type, entity_id, revision, Keyword.get(opts, :run_id))

    payload = %{
      "event_id" => id,
      "entity_type" => entity_type,
      "entity_id" => entity_id,
      "entity_revision" => revision,
      "type" => type,
      "run_id" => Keyword.get(opts, :run_id),
      "payload" => normalize_event_payload(Keyword.get(opts, :payload, %{}))
    }

    GenServer.call(
      server(opts),
      {:append, project_id, "Event", id, 0, payload, Keyword.get(opts, :actor), Keyword.take(opts, [:idempotency_key, :recorded_at]) ++ [dedupe: true]},
      @default_timeout
    )
  end

  @doc "Fetch the newest revision of one entity."
  @spec get(String.t(), String.t(), String.t(), keyword()) :: {:ok, record()} | {:error, atom(), map()}
  def get(project_id, entity_type, entity_id, opts \\ []) do
    GenServer.call(server(opts), {:get, project_id, entity_type, entity_id, nil}, @default_timeout)
  end

  @doc """
  Fetch a specific archived revision. Old revisions stay readable, so a review
  can always be replayed against the exact bytes it saw.
  """
  @spec get_revision(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, record()} | {:error, atom(), map()}
  def get_revision(project_id, entity_type, entity_id, revision, opts \\ []) do
    GenServer.call(server(opts), {:get, project_id, entity_type, entity_id, revision}, @default_timeout)
  end

  @doc """
  List the newest revision of every entity of a type, ordered by creation.

  Returns `{:error, ...}` when the project itself cannot be opened, so a caller
  can tell "this project has no records" apart from "this project is unreadable".
  """
  @spec list(String.t(), String.t(), keyword()) :: [record()] | {:error, atom(), map()}
  def list(project_id, entity_type, opts \\ []) do
    GenServer.call(server(opts), {:list, project_id, entity_type}, @default_timeout)
  end

  @doc "List every archived revision of a type in journal order."
  @spec list_revisions(String.t(), String.t(), keyword()) :: [record()] | {:error, atom(), map()}
  def list_revisions(project_id, entity_type, opts \\ []) do
    GenServer.call(server(opts), {:list_revisions, project_id, entity_type}, @default_timeout)
  end

  @doc "Replay journal records after `after_seq`, capped at #{@max_replay_limit} entries."
  @spec replay(String.t(), non_neg_integer(), pos_integer(), keyword()) :: [record()] | {:error, atom(), map()}
  def replay(project_id, after_seq, limit \\ @max_replay_limit, opts \\ []) do
    GenServer.call(server(opts), {:replay, project_id, after_seq, min(limit, @max_replay_limit)}, @default_timeout)
  end

  @spec project_seq(String.t(), keyword()) :: non_neg_integer()
  def project_seq(project_id, opts \\ []) do
    GenServer.call(server(opts), {:project_seq, project_id}, @default_timeout)
  end

  @doc """
  Store bytes in the project's content-addressed store and return their receipt.
  The write is temp + fsync + atomic rename, so a crash leaves either the old
  state or the complete blob, never a half-written one.
  """
  @spec put_blob(String.t(), iodata(), String.t(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def put_blob(project_id, bytes, media_type, opts \\ []) do
    GenServer.call(server(opts), {:put_blob, project_id, bytes, media_type}, @default_timeout)
  end

  @spec get_blob(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, atom(), map()}
  def get_blob(project_id, sha256, opts \\ []) do
    with {:ok, path} <- blob_path(data_root(server(opts)), sha256) do
      read_blob(path, project_id, sha256)
    end
  end

  defp read_blob(path, project_id, sha256) do
    case File.read(path) do
      {:ok, bytes} -> verify_blob_bytes(bytes, sha256)
      {:error, :enoent} -> {:error, :blob_missing, %{sha256: sha256, project_id: project_id}}
      {:error, reason} -> {:error, :blob_unreadable, %{sha256: sha256, reason: reason}}
    end
  end

  defp verify_blob_bytes(bytes, sha256) do
    if digest(bytes) == sha256 do
      {:ok, bytes}
    else
      {:error, :blob_corrupt, %{sha256: sha256}}
    end
  end

  @spec blob_size(String.t(), String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, atom(), map()}
  def blob_size(_project_id, sha256, opts \\ []) do
    root = data_root(server(opts))

    with {:ok, path} <- blob_path(root, sha256) do
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> {:ok, size}
        {:error, :enoent} -> {:error, :blob_missing, %{sha256: sha256}}
        {:error, reason} -> {:error, :blob_unreadable, %{sha256: sha256, reason: reason}}
      end
    end
  end

  @doc """
  Drop the derived index and rebuild it from the journal bytes. The journal is
  the only durable truth, so this must never renumber `project_seq`.
  """
  @spec rebuild_index(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, atom(), map()}
  def rebuild_index(project_id, opts \\ []) do
    GenServer.call(server(opts), {:rebuild_index, project_id}, @default_timeout)
  end

  @doc """
  Blobs no journal record in this data root references.

  Unreferenced bytes cannot be reached through the workbench: no record names
  them, so nothing can read them back. They are only *reported* here, because a
  blob may also be an original this project is required to keep, and reclamation
  is a separate explicit call.
  """
  @spec orphan_blobs(keyword()) :: {:ok, [map()]} | {:error, atom(), map()}
  def orphan_blobs(opts \\ []) do
    GenServer.call(server(opts), :orphan_blobs, @default_timeout)
  end

  @doc """
  Delete the named blobs, refusing any the journal still references.

  The reference is rebuilt from the journal files at delete time rather than
  taken from an earlier report, so a record written in between cannot have the
  bytes it names deleted underneath it. Reclaiming is therefore safe to run
  while the workbench is live, and it never touches anything the caller did not
  name.
  """
  @spec reclaim_blobs([String.t()], keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def reclaim_blobs(digests, opts \\ []) do
    GenServer.call(server(opts), {:reclaim_blobs, digests}, @default_timeout)
  end

  @spec recovery_reports(keyword()) :: [map()]
  def recovery_reports(opts \\ []) do
    GenServer.call(server(opts), :recovery_reports, @default_timeout)
  end

  @spec data_root(GenServer.server()) :: String.t()
  def data_root(server) do
    GenServer.call(server, :data_root, @default_timeout)
  end

  @doc """
  Validate a data root before the store starts: it must be absolute and must not
  sit inside the workspace root, so cleaning a workspace can never delete
  evidence.
  """
  @spec validate_data_root(String.t(), String.t() | nil) :: :ok | {:error, atom(), map()}
  def validate_data_root(data_root, workspace_root) do
    with {:ok, expanded} <- expand_root(data_root),
         {:ok, canonical} <- canonical_root(expanded),
         :ok <- outside_workspace(canonical, workspace_root) do
      writable(canonical)
    end
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    data_root = Keyword.fetch!(opts, :data_root)
    workspace_root = Keyword.get(opts, :workspace_root)
    faults = normalize_faults(Keyword.get(opts, :faults, %{}))

    with :ok <- validate_data_root(data_root, workspace_root),
         {:ok, canonical} <- canonical_root(Path.expand(data_root)),
         :ok <- acquire_lock(canonical, faults) do
      File.mkdir_p!(Path.join(canonical, "blobs/tmp"))
      File.mkdir_p!(Path.join(canonical, "projects"))
      File.mkdir_p!(Path.join(canonical, "indexes"))

      {:ok,
       %{
         root: canonical,
         projects: %{},
         reports: [],
         pubsub: Keyword.get(opts, :pubsub, SymphonyElixir.PubSub),
         faults: faults
       }}
    else
      {:error, code, details} -> {:stop, {:store_start_failed, code, details}}
    end
  end

  @impl true
  def handle_call(:data_root, _from, state), do: {:reply, state.root, state}

  def handle_call(:recovery_reports, _from, state), do: {:reply, state.reports, state}

  def handle_call({:append, project_id, entity_type, entity_id, expected_revision, payload, actor, opts}, _from, state) do
    with {:ok, project, state} <- ensure_project(state, project_id),
         :ok <- validate_entity_args(entity_type, entity_id),
         :ok <- validate_expected_revision(expected_revision),
         :ok <- validate_actor(actor),
         {:ok, payload} <- normalize_payload(payload),
         :ok <- check_idempotency(project, entity_type, entity_id, opts) do
      append_revision(project, state, %{
        project_id: project_id,
        entity_type: entity_type,
        entity_id: entity_id,
        expected_revision: expected_revision,
        payload: payload,
        actor: actor,
        opts: opts
      })
    else
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:get, project_id, entity_type, entity_id, revision}, _from, state) do
    case ensure_project(state, project_id) do
      {:ok, project, state} ->
        records = Map.get(project.history, {entity_type, entity_id}, [])

        reply =
          case revision do
            nil -> last_or_not_found(records, entity_type, entity_id)
            wanted -> Enum.find(records, &(&1.entity_revision == wanted)) |> found_or_not_found(entity_type, entity_id, wanted)
          end

        {:reply, reply, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:list, project_id, entity_type}, _from, state) do
    case ensure_project(state, project_id) do
      {:ok, project, state} ->
        records =
          project.history
          |> Enum.filter(fn {{type, _id}, _records} -> type == entity_type end)
          |> Enum.map(fn {_key, records} -> List.last(records) end)
          |> Enum.sort_by(& &1.project_seq)

        {:reply, records, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:list_revisions, project_id, entity_type}, _from, state) do
    case ensure_project(state, project_id) do
      {:ok, project, state} ->
        records =
          project.history
          |> Enum.filter(fn {{type, _id}, _records} -> type == entity_type end)
          |> Enum.flat_map(fn {_key, records} -> records end)
          |> Enum.sort_by(& &1.project_seq)

        {:reply, records, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:replay, project_id, after_seq, limit}, _from, state) do
    case ensure_project(state, project_id) do
      {:ok, project, state} ->
        records =
          project.history
          |> Enum.flat_map(fn {_key, records} -> records end)
          |> Enum.filter(&(&1.project_seq > after_seq))
          |> Enum.sort_by(& &1.project_seq)
          |> Enum.take(limit)

        {:reply, records, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:project_seq, project_id}, _from, state) do
    case ensure_project(state, project_id) do
      {:ok, project, state} -> {:reply, project.seq, state}
      {:error, _code, _details} -> {:reply, 0, state}
    end
  end

  def handle_call({:put_blob, _project_id, bytes, media_type}, _from, state) do
    with {:ok, binary} <- to_binary(bytes),
         :ok <- validate_blob_size(binary),
         :ok <- validate_media_type(media_type),
         {:ok, receipt} <- write_blob(state.root, binary, media_type, state.faults) do
      {:reply, {:ok, receipt}, state}
    else
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  def handle_call(:orphan_blobs, _from, state) do
    {:reply, orphan_receipts(state.root), state}
  end

  def handle_call({:reclaim_blobs, digests}, _from, state) do
    case normalize_digests(digests) do
      {:error, code, details} ->
        {:reply, {:error, code, details}, state}

      {:ok, wanted} ->
        case reclaim(state.root, wanted) do
          {:error, code, details} -> {:reply, {:error, code, details}, state}
          result -> {:reply, result, state}
        end
    end
  end

  defp reclaim(root, wanted) do
    case journal_digests(root) do
      {:error, code, details} ->
        {:error, code, details}

      {:ok, referenced} ->
        on_disk = blob_digests(root)

        {deleted, kept} =
          Enum.reduce(wanted, {[], []}, fn digest, acc -> classify_digest(digest, referenced, on_disk, acc) end)

        reclaimed(Enum.map(deleted, &remove_blob(root, &1)), kept, referenced)
    end
  end

  def handle_call({:rebuild_index, project_id}, _from, state) do
    case ensure_project(state, project_id) do
      {:ok, project, state} ->
        case load_project(project.dir, state.faults) do
          {:ok, reloaded, reports} ->
            reloaded = %{reloaded | project_id: project_id, fd: project.fd}
            state = %{put_project(state, reloaded) | reports: state.reports ++ reports}
            {:reply, {:ok, reloaded.seq}, state}

          {:error, code, details} ->
            {:reply, {:error, code, details}, state}
        end

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  defp reclaimed(removed, kept, referenced) do
    {:ok,
     %{
       "deleted" => removed,
       "kept" => kept,
       "freed_bytes" => removed |> Enum.map(& &1["size_bytes"]) |> Enum.sum(),
       "referenced" => MapSet.size(referenced)
     }}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.projects, fn {_id, project} ->
      if project.fd, do: :file.close(project.fd)
    end)

    File.rm(Path.join(state.root, @lock_name))
    :ok
  end

  defp append_revision(project, state, request) do
    %{
      project_id: project_id,
      entity_type: entity_type,
      entity_id: entity_id,
      expected_revision: expected_revision,
      payload: payload,
      actor: actor,
      opts: opts
    } = request

    current = current_revision(project, entity_type, entity_id)

    cond do
      Keyword.get(opts, :dedupe, false) and current > 0 ->
        # Re-reporting the same engineering fact (same event id for the same
        # entity revision) must not create a second record or a spurious
        # conflict; the client gets the record it already produced.
        existing = project.history |> Map.fetch!({entity_type, entity_id}) |> List.last()
        {:reply, {:ok, existing}, state}

      current != expected_revision ->
        details = %{
          entity_type: entity_type,
          entity_id: entity_id,
          expected: expected_revision,
          current: current
        }

        {:reply, {:error, :revision_conflict, details}, state}

      true ->
        record = build_record(project, entity_type, entity_id, expected_revision + 1, payload, actor, opts)
        reply_with_write(state, project, project_id, record)
    end
  end

  defp reply_with_write(state, project, project_id, record) do
    case write_record(project, record, state.faults) do
      {:ok, project} ->
        state = put_project(state, project)
        broadcast(state, project_id, record)
        {:reply, {:ok, record}, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  # ------------------------------------------------------------------
  # Project state
  # ------------------------------------------------------------------

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  defp put_project(state, project) do
    %{state | projects: Map.put(state.projects, project.project_id, project)}
  end

  defp ensure_project(state, project_id) do
    case safe_segment(project_id) do
      {:error, code, details} ->
        {:error, code, details}

      {:ok, segment} ->
        case Map.get(state.projects, project_id) do
          nil -> open_project(state, project_id, segment)
          project -> {:ok, project, state}
        end
    end
  end

  defp open_project(state, project_id, segment) do
    dir = Path.join([state.root, "projects", segment])

    with :ok <- File.mkdir_p(dir),
         {:ok, project, reports} <- load_project(dir, state.faults),
         {:ok, fd} <- :file.open(String.to_charlist(project.journal_path), [:append, :raw, :binary]) do
      project = %{project | project_id: project_id, fd: fd}
      state = %{put_project(state, project) | reports: state.reports ++ reports}
      {:ok, project, state}
    else
      {:error, code, details} when is_atom(code) -> {:error, code, details}
      {:error, reason} -> {:error, :journal_unreadable, %{project_id: project_id, reason: reason}}
    end
  end

  defp load_project(dir, faults) do
    journal_path = Path.join(dir, @journal_name)

    case File.read(journal_path) do
      {:error, :enoent} ->
        {:ok, %Project{dir: dir, journal_path: journal_path}, []}

      {:ok, data} ->
        parse_journal(dir, journal_path, data, faults)

      {:error, reason} ->
        {:error, :journal_unreadable, %{path: journal_path, reason: reason}}
    end
  end

  defp parse_journal(dir, journal_path, data, faults) do
    {complete, tail} = split_tail(data)
    base = %Project{dir: dir, journal_path: journal_path}

    complete
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, base}, fn line, {:ok, project} ->
      case decode_record(line) do
        {:ok, record} ->
          {:cont, {:ok, apply_record(project, record)}}

        {:error, reason} ->
          # A checksum failure in the middle of the journal is a read fault, not
          # a torn tail. Refuse to silently drop everything after it.
          {:halt, {:error, :journal_corrupt, %{path: journal_path, seq: project.seq + 1, reason: reason}}}
      end
    end)
    |> case do
      {:ok, project} ->
        case truncate_tail(journal_path, project, byte_size(complete), tail, faults) do
          {:ok, reports} -> {:ok, project, reports}
          {:error, code, details} -> {:error, code, details}
        end

      error ->
        error
    end
  end

  defp split_tail(data) do
    case :binary.matches(data, "\n") do
      [] ->
        {"", data}

      matches ->
        {last_start, _len} = List.last(matches)
        {binary_part(data, 0, last_start + 1), binary_part(data, last_start + 1, byte_size(data) - last_start - 1)}
    end
  end

  defp truncate_tail(_journal_path, _project, _kept_bytes, "", _faults), do: {:ok, []}

  defp truncate_tail(journal_path, project, kept_bytes, tail, faults) do
    with :ok <- injected_fault(faults, :journal_repair),
         {:ok, fd} <- :file.open(String.to_charlist(journal_path), [:read, :write, :raw, :binary]),
         {:ok, _} <- :file.position(fd, kept_bytes),
         :ok <- :file.truncate(fd),
         :ok <- :file.close(fd) do
      report = %{
        kind: :truncated_journal_tail,
        path: journal_path,
        kept_seq: project.seq,
        discarded_bytes: byte_size(tail)
      }

      Logger.warning("Truncated incomplete engineering journal tail: #{inspect(report)}")
      {:ok, [report]}
    else
      {:error, reason} -> {:error, :journal_repair_failed, %{path: journal_path, reason: reason}}
    end
  end

  defp decode_record(line) do
    with {:ok, decoded} <- Jason.decode(line),
         {:ok, record} <- to_record(decoded) do
      verify_checksum(record)
    end
  end

  defp to_record(decoded) when is_map(decoded) do
    case decoded do
      %{
        "schema_version" => @schema_version,
        "project_seq" => seq,
        "entity_type" => type,
        "entity_id" => id,
        "entity_revision" => revision,
        "payload" => payload,
        "payload_sha256" => checksum,
        "recorded_at" => recorded_at
      }
      when is_integer(seq) and is_integer(revision) and is_map(payload) ->
        {:ok,
         %{
           schema_version: @schema_version,
           project_seq: seq,
           entity_type: type,
           entity_id: id,
           entity_revision: revision,
           actor: Map.get(decoded, "actor"),
           payload: payload,
           payload_sha256: checksum,
           recorded_at: recorded_at,
           idempotency_key: Map.get(decoded, "idempotency_key")
         }}

      %{"schema_version" => other} when is_binary(other) ->
        {:error, {:unsupported_schema_version, other}}

      _other ->
        {:error, :malformed_record}
    end
  end

  defp to_record(_decoded), do: {:error, :malformed_record}

  defp verify_checksum(record) do
    if Canonical.sha256(record.payload) == record.payload_sha256 do
      {:ok, record}
    else
      {:error, :payload_checksum_mismatch}
    end
  end

  defp apply_record(project, record) do
    key = {record.entity_type, record.entity_id}
    history = Map.update(project.history, key, [record], &(&1 ++ [record]))

    project = %{
      project
      | seq: record.project_seq,
        history: history,
        revisions: Map.put(project.revisions, key, record.entity_revision)
    }

    case record.idempotency_key do
      nil -> project
      "" -> project
      key_value -> %{project | keys: Map.put(project.keys, {key, key_value}, record.project_seq)}
    end
  end

  # ------------------------------------------------------------------
  # Writing
  # ------------------------------------------------------------------

  defp build_record(project, entity_type, entity_id, revision, payload, actor, opts) do
    %{
      schema_version: @schema_version,
      project_seq: project.seq + 1,
      entity_type: entity_type,
      entity_id: entity_id,
      entity_revision: revision,
      actor: normalize_actor(actor),
      payload: payload,
      payload_sha256: Canonical.sha256(payload),
      recorded_at: Keyword.get(opts, :recorded_at) || DateTime.utc_now() |> DateTime.to_iso8601(),
      idempotency_key: Keyword.get(opts, :idempotency_key)
    }
  end

  defp write_record(project, record, faults) do
    line = Canonical.encode!(envelope(record)) <> "\n"

    with :ok <- injected_fault(faults, :journal_write),
         :ok <- :file.write(project.fd, line),
         :ok <- injected_fault(faults, :journal_fsync),
         :ok <- :file.sync(project.fd) do
      {:ok, apply_record(project, record)}
    else
      {:error, reason} -> {:error, :journal_write_failed, %{reason: reason}}
    end
  end

  defp injected_fault(faults, step) do
    case Map.get(faults, step) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp normalize_faults(faults) when is_map(faults), do: faults
  defp normalize_faults(_faults), do: %{}

  defp envelope(record) do
    %{
      "schema_version" => record.schema_version,
      "project_seq" => record.project_seq,
      "entity_type" => record.entity_type,
      "entity_id" => record.entity_id,
      "entity_revision" => record.entity_revision,
      "actor" => record.actor,
      "payload" => record.payload,
      "payload_sha256" => record.payload_sha256,
      "recorded_at" => record.recorded_at,
      "idempotency_key" => record.idempotency_key
    }
  end

  defp write_blob(root, binary, media_type, faults) do
    sha256 = digest(binary)

    with {:ok, target} <- blob_path(root, sha256) do
      if File.regular?(target) do
        {:ok, receipt(sha256, byte_size(binary), media_type)}
      else
        do_write_blob(root, target, binary, sha256, media_type, faults)
      end
    end
  end

  defp do_write_blob(root, target, binary, sha256, media_type, faults) do
    tmp = Path.join([root, "blobs", "tmp", "#{sha256}-#{System.unique_integer([:positive])}"])

    with :ok <- injected_fault(faults, :blob_write),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- write_temp_file(tmp, binary),
         :ok <- injected_fault(faults, :blob_rename),
         {:ok, _path} <- rename_blob(tmp, target) do
      {:ok, receipt(sha256, byte_size(binary), media_type)}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, :blob_write_failed, %{reason: reason}}
    end
  end

  defp write_temp_file(tmp, binary) do
    with {:ok, fd} <- :file.open(String.to_charlist(tmp), [:write, :raw, :binary]) do
      result = with :ok <- :file.write(fd, binary), do: :file.sync(fd)
      :ok = :file.close(fd)
      result
    end
  end

  defp rename_blob(tmp, target) do
    # POSIX rename replaces the destination atomically, so there is no
    # already-exists case to special-case here.
    case File.rename(tmp, target) do
      :ok -> {:ok, target}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receipt(sha256, size, media_type) do
    %{
      "sha256" => sha256,
      "size_bytes" => size,
      "media_type" => media_type,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # ------------------------------------------------------------------
  # Reclamation
  # ------------------------------------------------------------------

  # Every 64-hex string in every journal file under this root, including projects
  # this process has never opened: blobs are shared across the whole data root,
  # so a reference in a project that is not currently loaded still protects them.
  defp journal_digests(root) do
    Enum.reduce_while(journal_files(root), {:ok, MapSet.new()}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, bytes} -> {:cont, {:ok, MapSet.union(acc, digests_in(bytes))}}
        {:error, reason} -> {:halt, {:error, :journal_unreadable, %{path: path, reason: reason}}}
      end
    end)
  end

  # A digest is only reclaimed when nothing in the root names it *and* the bytes
  # are actually there; everything else is reported back with its reason.
  defp classify_digest(digest, referenced, on_disk, {deleted, kept}) do
    cond do
      MapSet.member?(referenced, digest) -> {deleted, kept ++ [%{"sha256" => digest, "reason" => "still_referenced"}]}
      not MapSet.member?(on_disk, digest) -> {deleted, kept ++ [%{"sha256" => digest, "reason" => "not_found"}]}
      true -> {deleted ++ [digest], kept}
    end
  end

  defp journal_files(root) do
    Path.join([root, "projects", "*", @journal_name]) |> Path.wildcard()
  end

  defp digests_in(bytes) do
    ~r/[a-f0-9]{64}/
    |> Regex.scan(bytes, return: :binary)
    |> List.flatten()
    |> MapSet.new()
  end

  defp blob_digests(root) do
    Path.join([root, "blobs", "sha256", "*", "*"])
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.basename/1)
    |> MapSet.new()
  end

  # A journal that cannot be read is an error, not an empty reference set:
  # "cannot prove unreferenced" must never be reported as "unreferenced".
  defp orphan_receipts(root) do
    with {:ok, referenced} <- journal_digests(root) do
      orphans =
        root
        |> blob_digests()
        |> MapSet.difference(referenced)
        |> Enum.sort()
        |> Enum.map(fn digest ->
          %{"sha256" => digest, "size_bytes" => blob_size_on_disk(root, digest)}
        end)

      {:ok, orphans}
    end
  end

  defp blob_size_on_disk(root, digest) do
    with {:ok, path} <- blob_path(root, digest), do: File.stat!(path).size
  end

  defp remove_blob(root, digest) do
    size = blob_size_on_disk(root, digest)

    with {:ok, path} <- blob_path(root, digest) do
      File.rm(path)
    end

    %{"sha256" => digest, "size_bytes" => size}
  end

  defp normalize_digests(digests) when is_list(digests) do
    case Enum.reject(digests, &String.match?(&1, ~r/^[a-f0-9]{64}$/)) do
      [] -> {:ok, digests}
      bad -> {:error, :invalid_blob_digest, %{sha256: List.first(bad)}}
    end
  end

  defp normalize_digests(other), do: {:error, :invalid_blob_digest, %{sha256: other}}

  defp blob_path(root, sha256) when is_binary(sha256) do
    if String.match?(sha256, ~r/^[a-f0-9]{64}$/) do
      {:ok, Path.join([root, "blobs", "sha256", String.slice(sha256, 0, 2), sha256])}
    else
      {:error, :invalid_blob_digest, %{sha256: sha256}}
    end
  end

  defp blob_path(_root, sha256), do: {:error, :invalid_blob_digest, %{sha256: sha256}}

  # ------------------------------------------------------------------
  # Validation
  # ------------------------------------------------------------------

  defp validate_entity_args(entity_type, entity_id) do
    cond do
      not is_binary(entity_type) or entity_type == "" -> {:error, :invalid_entity_type, %{entity_type: entity_type}}
      not is_binary(entity_id) or entity_id == "" -> {:error, :invalid_entity_id, %{entity_id: entity_id}}
      true -> :ok
    end
  end

  defp validate_expected_revision(revision) when is_integer(revision) and revision >= 0, do: :ok
  defp validate_expected_revision(revision), do: {:error, :invalid_expected_revision, %{expected_revision: revision}}

  defp validate_actor(nil), do: :ok

  defp validate_actor(%{kind: kind, id: id, display_name: name})
       when kind in ["human", "agent", "system"] and is_binary(id) and is_binary(name),
       do: :ok

  defp validate_actor(actor), do: {:error, :invalid_actor, %{actor: actor}}

  defp validate_blob_size(binary) when byte_size(binary) <= @max_blob_bytes, do: :ok

  defp validate_blob_size(binary) do
    {:error, :blob_too_large, %{bytes: byte_size(binary), limit: @max_blob_bytes}}
  end

  defp validate_media_type(media_type) when is_binary(media_type) and media_type != "", do: :ok
  defp validate_media_type(media_type), do: {:error, :invalid_media_type, %{media_type: media_type}}

  defp to_binary(bytes) do
    {:ok, IO.iodata_to_binary(bytes)}
  rescue
    _error -> {:error, :invalid_blob_content, %{reason: :not_iodata}}
  end

  defp check_idempotency(project, entity_type, entity_id, opts) do
    case Keyword.get(opts, :idempotency_key) do
      nil ->
        :ok

      key ->
        case Map.get(project.keys, {{entity_type, entity_id}, key}) do
          nil -> :ok
          seq -> {:error, :duplicate_idempotency_key, %{idempotency_key: key, project_seq: seq}}
        end
    end
  end

  defp normalize_payload(payload) when is_map(payload) do
    case Canonical.encode(payload) do
      {:error, reason} ->
        {:error, :invalid_payload, %{reason: reason}}

      {:ok, encoded} when byte_size(encoded) > @max_payload_bytes ->
        {:error, :payload_too_large, %{bytes: byte_size(encoded), limit: @max_payload_bytes}}

      {:ok, encoded} ->
        Jason.decode(encoded)
    end
  end

  defp normalize_payload(_payload), do: {:error, :invalid_payload, %{reason: :not_a_map}}

  defp normalize_actor(nil), do: nil

  defp normalize_actor(%{kind: kind, id: id, display_name: name}) do
    %{"kind" => kind, "id" => id, "display_name" => name}
  end

  defp normalize_event_payload(payload) do
    %{
      "plan_revision" => fetch(payload, "plan_revision"),
      "decision_id" => fetch(payload, "decision_id"),
      "decision_sha256" => fetch(payload, "decision_sha256"),
      "detail" => fetch(payload, "detail") || ""
    }
  end

  defp fetch(payload, key) when is_map(payload), do: Map.get(payload, key)

  defp event_digest(project_id, type, entity_id, revision, run_id) do
    digest = :crypto.hash(:sha256, "#{project_id}|#{type}|#{entity_id}|#{revision}|#{run_id}")
    Base.encode16(binary_part(digest, 0, 12), case: :lower)
  end

  defp current_revision(project, entity_type, entity_id) do
    Map.get(project.revisions, {entity_type, entity_id}, 0)
  end

  defp last_or_not_found([], entity_type, entity_id) do
    {:error, :not_found, %{entity_type: entity_type, entity_id: entity_id}}
  end

  defp last_or_not_found(records, _entity_type, _entity_id), do: {:ok, List.last(records)}

  defp found_or_not_found(nil, entity_type, entity_id, revision) do
    {:error, :not_found, %{entity_type: entity_type, entity_id: entity_id, revision: revision}}
  end

  defp found_or_not_found(record, _entity_type, _entity_id, _revision), do: {:ok, record}

  defp digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp safe_segment(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/) do
      {:ok, value}
    else
      {:error, :invalid_project_id, %{project_id: value}}
    end
  end

  defp safe_segment(value), do: {:error, :invalid_project_id, %{project_id: value}}

  defp broadcast(state, project_id, record) do
    case Process.whereis(state.pubsub) do
      nil ->
        :ok

      _pid ->
        Phoenix.PubSub.broadcast(
          state.pubsub,
          "experience:project:#{project_id}",
          {:experience_event, record.project_seq, record.entity_type, record.entity_id}
        )
    end
  end

  # ------------------------------------------------------------------
  # Data root validation
  # ------------------------------------------------------------------

  defp expand_root(data_root) when is_binary(data_root) and data_root != "" do
    if Path.type(data_root) == :absolute do
      {:ok, Path.expand(data_root)}
    else
      {:error, :invalid_data_root, %{data_root: data_root, reason: :not_absolute}}
    end
  end

  defp expand_root(data_root), do: {:error, :invalid_data_root, %{data_root: data_root}}

  defp canonical_root(expanded) do
    case PathSafety.canonicalize(expanded) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, :invalid_data_root, %{reason: reason}}
    end
  end

  defp outside_workspace(_canonical, nil), do: :ok

  defp outside_workspace(canonical, workspace_root) do
    case PathSafety.canonicalize(Path.expand(workspace_root)) do
      {:ok, workspace} ->
        if canonical == workspace or String.starts_with?(canonical, workspace <> "/") do
          {:error, :data_root_inside_workspace, %{data_root: canonical, workspace_root: workspace}}
        else
          :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp writable(canonical) do
    probe = Path.join(nearest_existing(canonical), ".symphony-write-probe-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, :data_root_unwritable, %{data_root: canonical, reason: reason}}
    end
  end

  defp nearest_existing(path) do
    # Absolute paths always bottom out at "/", which is a directory, so this
    # terminates without a nil case.
    if File.dir?(path), do: path, else: nearest_existing(Path.dirname(path))
  end

  defp acquire_lock(root, faults) do
    lock_path = Path.join(root, @lock_name)

    with :ok <- injected_fault(faults, :lock_write),
         :ok <- File.mkdir_p(root),
         :ok <- inspect_existing_lock(lock_path),
         :ok <- File.write(lock_path, lock_contents(), [:exclusive]) do
      :ok
    else
      # `inspect_existing_lock/1` already produces a coded error; pass it through.
      {:error, code, details} ->
        {:error, code, details}

      {:error, :eexist} ->
        {:error, :data_root_locked, %{path: lock_path}}

      {:error, reason} ->
        {:error, :data_root_unwritable, %{path: lock_path, reason: reason}}
    end
  end

  defp lock_contents do
    "#{node()}|#{System.pid()}|#{DateTime.utc_now() |> DateTime.to_iso8601()}"
  end

  defp inspect_existing_lock(lock_path) do
    case File.read(lock_path) do
      {:ok, contents} ->
        if holder_alive?(contents) do
          {:error, :data_root_locked, %{path: lock_path, holder: String.trim(contents)}}
        else
          Logger.warning("Reclaiming stale engineering store lock at #{lock_path}")
          File.rm(lock_path)
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp holder_alive?(contents) do
    case String.split(String.trim(contents), "|") do
      [_node, os_pid | _rest] -> File.exists?(Path.join("/proc", String.trim(os_pid)))
      _other -> false
    end
  end
end
