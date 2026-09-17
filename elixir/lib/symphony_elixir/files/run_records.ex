defmodule SymphonyElixir.Files.RunRecords do
  @moduledoc """
  Reads an adopting project's own engineering records off disk.

  A project that runs its own layered agent team keeps its truth in files, not
  in a hosted tracker, so the workbench reads those files instead of asking for
  a tracker account. Two families are understood, because those are what such a
  project actually keeps:

    * **run records** — `task.md` / `handoff.md` pairs, either one directory per
      task (`<root>/<task-id>/…`) or flat side by side
      (`<root>/<task-id>.task.md`, `<root>/<task-id>.handoff.md`), including the
      container case where a directory holds many flat pairs;

    * **bridge task records** — the JSON files a cross-provider task bridge
      writes, which carry the machine lifecycle (`pending`, `claimed`,
      `completed`, `failed`) rather than a verdict.

  No verdict is read out of prose. A handoff that never declares `Result:`
  becomes `delivered`, which means "this needs a person"; a `Result:` whose word
  is not one of the documented verdicts is also `delivered`, with the word the
  record actually wrote kept in the description rather than rounded to the
  nearest word this module happens to know. One record cannot be read at all
  => the `unreadable` state, not silence.
  """

  require Logger

  # The states this reader can justify from the records themselves. The first
  # five come from the records' own vocabulary (a handoff's `Result:`, a task
  # with no handoff, a bridge lifecycle); `unreadable` is this reader's own
  # honest answer for a file that exists but cannot be parsed.
  @states ["open", "claimed", "delivered", "complete", "partial", "blocked", "failed", "unreadable"]

  # `m` matters: these fields sit on their own line inside a longer document.
  @result_line ~r/^\s*[-*>]*\s*\**\s*result\**\s*:\s*\**\s*([A-Za-z_][A-Za-z_]*)/im
  @owner_line ~r/^\s*[-*>]*\s*\**\s*owner agent\**\s*:\s*\**\s*([^\n]+?)[ \t]*$/im
  @goal_line ~r/^\s*[-*>]*\s*\**\s*goal\**\s*:\s*\**\s*([^\n]+?)[ \t]*$/im
  @heading_id ~r/^#\s+(?:Task|Handoff)\s+`?([^`\s]+)`?/im
  @heading ~r/^#+\s*([^\n]+?)[ \t]*$/m

  @type record :: %{
          id: String.t(),
          state: String.t(),
          title: String.t(),
          description: String.t(),
          owner: String.t() | nil,
          sources: [String.t()],
          mtimes: [DateTime.t()],
          detail: String.t() | nil,
          bridge: map() | nil,
          bridge_only: boolean()
        }

  @doc "Every state this reader reports, for the provider to advertise."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  Read both record families under one record root.

  `:bridge_tasks` is optional: without it the run records stand alone. A
  `:bridge_marker` narrows the bridge side to the tasks that name this project
  (bridge directories are shared between projects), so an operator's shared
  bridge does not put another project's tasks on this board.
  """
  @spec read(String.t()) :: {:ok, [record()]} | {:error, atom(), map()}
  def read(root), do: read(root, [])

  @spec read(String.t(), keyword()) :: {:ok, [record()]} | {:error, atom(), map()}
  def read(root, opts) when is_binary(root) and root != "" do
    with {:ok, run_records} <- read_runs(root) do
      bridges =
        opts
        |> Keyword.get(:bridge_tasks)
        |> bridge_records(Keyword.get(opts, :bridge_marker))

      {:ok, merge(run_records, bridges)}
    end
  end

  def read(_root, _opts), do: {:error, :record_root_missing, %{reason: "no record root configured"}}

  @doc """
  Read every run record under `root`, grouped into one record per task id.

  A file that exists but cannot be parsed becomes an `unreadable` record rather
  than being skipped: a silent gap on the board is worse than a visible fault.
  """
  @spec read_runs(String.t()) :: {:ok, [record()]} | {:error, atom(), map()}
  def read_runs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(&records_in(root, &1))
        |> Enum.reject(&is_nil/1)
        |> group_by_id(root)
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, :record_root_unreadable, %{root: root, reason: reason}}
    end
  end

  @doc """
  Read the bridge's task JSON files, when a bridge directory is configured.

  A bridge directory that cannot be listed contributes nothing and says so in
  the log; the run records are the project's own record and must not be lost
  because an auxiliary directory is missing.
  """
  @spec bridge_records(String.t() | nil) :: [map()]
  def bridge_records(dir), do: bridge_records(dir, nil)

  @spec bridge_records(String.t() | nil, String.t() | nil) :: [map()]
  def bridge_records(nil, _marker), do: []

  def bridge_records(dir, marker) when is_binary(dir) and dir != "" do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&bridge_record(Path.join(dir, &1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&names_project?(&1, marker))

      {:error, reason} ->
        Logger.warning("bridge task records unavailable: #{inspect(dir)} #{inspect(reason)}")
        []
    end
  end

  def bridge_records(_dir, _marker), do: []

  # A shared bridge directory holds every project's tasks, so the operator can
  # name what identifies this project's own tasks. A bridge record that does not
  # carry the marker is another project's task, not a missing record.
  defp names_project?(_bridge, nil), do: true
  defp names_project?(bridge, marker), do: String.contains?(bridge.payload || "", marker)

  @doc """
  Merge run records with bridge lifecycle records into one record per task.

  A bridge-only task is a delivery at best: `completed` says the transport
  finished, not that the work passed, so it becomes `delivered` unless the
  bridge says the task failed or is still held. Where both families name the
  same task, the run record's verdict wins — the handoff is the project's record
  of what happened, while the bridge only knows what its transport did. A
  handoff that names no owner keeps the bridge's claimant instead, so the board
  shows who ran it rather than nobody.
  """
  @spec merge([record()], [map()]) :: [record()]
  def merge(run_records, bridge_records) do
    by_id = Map.new(run_records, &{&1.id, &1})

    merged =
      Enum.reduce(bridge_records, by_id, fn bridge, acc ->
        case Map.fetch(acc, bridge.id) do
          {:ok, record} -> Map.put(acc, bridge.id, %{record | bridge: bridge, owner: record.owner || bridge.claimed_by})
          :error -> Map.put(acc, bridge.id, from_bridge(bridge))
        end
      end)

    merged |> Map.values() |> Enum.sort_by(& &1.id)
  end

  defp from_bridge(bridge) do
    %{
      id: bridge.id,
      state: bridge_state(bridge.status),
      title: bridge.title,
      description: "只有桥接任务记录，没有 run 记录（桥接状态：#{bridge.status || "未知"}）",
      owner: bridge.claimed_by,
      sources: bridge.sources,
      mtimes: bridge.mtimes,
      detail: "桥接结果仍可从任务记录里取出；工作台没有把它当成验收结论",
      bridge: bridge,
      bridge_only: true
    }
  end

  # The bridge owns transport lifecycle, not the verdict: a completed transport
  # is a delivery awaiting review, never a pass.
  defp bridge_state("completed"), do: "delivered"
  defp bridge_state("failed"), do: "failed"
  defp bridge_state("claimed"), do: "claimed"
  defp bridge_state("pending"), do: "claimed"
  defp bridge_state(_other), do: "delivered"

  defp records_in(root, entry) do
    path = Path.join(root, entry)

    if File.dir?(path) do
      files = markdown_files(path)
      # A directory that holds a bare `task.md` / `handoff.md` is one task's own
      # directory, so it owns the id; a directory that only holds named pairs is
      # a container and each file owns its own id.
      owner = if Enum.any?(files, &bare_name?/1), do: Path.basename(path), else: nil

      Enum.map(files, &record_from_file(&1, owner))
    else
      List.wrap(record_from_file(path, nil))
    end
  end

  defp bare_name?(path) do
    path |> Path.basename() |> String.downcase() |> Kernel.in(["task.md", "handoff.md"])
  end

  defp markdown_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, reason} ->
        Logger.warning("run record directory unreadable: #{inspect(dir)} #{inspect(reason)}")
        []
    end
  end

  defp record_from_file(path, dir_name) do
    case kind(path) do
      nil ->
        nil

      kind ->
        case File.read(path) do
          {:ok, body} -> build(path, dir_name, kind, body)
          {:error, reason} -> unreadable(path, dir_name, kind, reason)
        end
    end
  end

  # `task` / `handoff` files are the records; a README beside them is not.
  defp kind(path) do
    name = path |> Path.basename() |> String.downcase()

    cond do
      String.contains?(name, "handoff") -> :handoff
      String.ends_with?(name, ".task.md") or name == "task.md" -> :task
      true -> nil
    end
  end

  defp build(path, dir_name, kind, body) do
    id = record_id(body, path, dir_name)

    %{
      id: id,
      state: nil,
      title: record_title(body, id),
      kind: kind,
      result: field(body, @result_line),
      owner: field(body, @owner_line),
      sources: [path],
      mtimes: [mtime(path)],
      bridge: nil,
      read_error: nil
    }
  end

  defp unreadable(path, dir_name, kind, reason) do
    %{
      id: record_id("", path, dir_name),
      state: "unreadable",
      title: "#{Path.basename(path)} 无法读取",
      kind: kind,
      result: nil,
      owner: nil,
      sources: [path],
      mtimes: [mtime(path)],
      bridge: nil,
      read_error: reason
    }
  end

  # The declaration inside the file wins, then the file's own name, then the
  # directory. Both orders are needed: `co5300_dcs_brightness_9f3a/` holds
  # `co5300-dcs-brightness.handoff.md` (directory owns the id, file names drift)
  # while `eaf_accel_20260909/` holds many `<task-id>.task.md` pairs (the
  # directory is a family label, the file name owns the id).
  defp record_id(body, path, dir_name) do
    from_heading(body) || dir_name || id_from_name(path) || Path.basename(path)
  end

  defp from_heading(body) do
    case Regex.run(@heading_id, body, capture: :all_but_first) do
      [id] -> empty_to_nil(String.trim(id))
      _other -> nil
    end
  end

  defp id_from_name(path) do
    path
    |> Path.basename()
    |> String.replace_suffix(".md", "")
    |> String.replace_suffix(".task", "")
    |> String.replace_suffix(".handoff", "")
    |> then(fn name -> if name in ["task", "handoff"], do: nil, else: name end)
  end

  defp record_title(body, id) do
    field(body, @goal_line) || free_heading(body, id)
  end

  # A heading that only repeats the task id adds nothing (the id is already the
  # identifier), while `# Task: close coordinator-audited …` is the project's own
  # one-line statement of what the task was.
  defp free_heading(body, id) do
    case Regex.run(@heading, body, capture: :all_but_first) do
      [title] ->
        title
        |> String.replace(~r/^\s*(task|handoff|result)\s*:?\s*/i, "")
        |> String.replace(~r/`([^`]+)`/, "\\1")
        |> strip_markup()
        |> empty_to_nil()
        |> then(&if(&1 == id, do: nil, else: &1))

      _other ->
        nil
    end
  end

  # `String.trim/2` strips a multi-character pattern, not a character set, so
  # markup on both ends is removed here in one place.
  defp strip_markup(value) do
    value
    |> String.trim()
    |> then(&Regex.replace(~r/^[`*]+|[`*]+$/, &1, ""))
    |> String.trim()
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp field(body, regex) do
    case Regex.run(regex, body, capture: :all_but_first) do
      [value] -> value |> strip_markup() |> empty_to_nil()
      _other -> nil
    end
  end

  # Grouping lets a task and its handoff become one record: the verdict comes
  # from the handoff, and a task with no handoff means the work is still open.
  defp group_by_id(candidates, root) do
    candidates
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {id, records} -> collapse(id, records, root) end)
  end

  defp collapse(id, records, root) do
    handoff = Enum.find(records, &(&1.kind == :handoff))
    task = Enum.find(records, &(&1.kind == :task))
    chosen = handoff || task
    sources = records |> Enum.flat_map(& &1.sources) |> Enum.uniq() |> Enum.sort()
    state = state_for(handoff, task)

    %{
      id: id,
      state: state,
      title: pair_title(handoff, task, id),
      description: description_for(sources, handoff, task, root, state),
      owner: chosen.owner,
      sources: sources,
      mtimes: records |> Enum.flat_map(& &1.mtimes) |> Enum.reject(&is_nil/1),
      detail: nil,
      bridge: nil,
      bridge_only: false
    }
  end

  defp pair_title(handoff, task, id) do
    (handoff && handoff.title) || (task && task.title) || id
  end

  defp state_for(nil, _task), do: "open"
  defp state_for(%{state: "unreadable"}, _task), do: "unreadable"
  defp state_for(%{result: nil}, _task), do: "delivered"
  defp state_for(%{result: result}, _task), do: verdict_state(result)

  defp verdict_state(result) do
    word = String.downcase(result)

    # A word outside the documented vocabulary is not a verdict this reader can
    # act on, so the record is delivered-for-review and the word it wrote is
    # surfaced in the description instead of being dropped.
    if word in @states, do: word, else: "delivered"
  end

  defp description_for(sources, handoff, task, root, state) do
    [
      "记录：" <> Enum.map_join(sources, "、", &Path.relative_to(&1, root)),
      missing_part(task, "没有 task 记录"),
      missing_part(handoff, "没有 handoff 记录"),
      result_part(handoff),
      unknown_verdict_part(handoff, state),
      read_error_part(handoff)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("；")
  end

  defp missing_part(record, text), do: if(record, do: nil, else: text)

  # A handoff that never wrote a verdict is not a handoff that passed: the
  # difference is exactly what a reviewer needs to see.
  defp result_part(%{result: nil, read_error: nil}), do: "handoff 没有写 Result:，判据未声明"
  defp result_part(_handoff), do: nil

  defp unknown_verdict_part(%{result: result}, state) when is_binary(result) and state == "delivered" do
    "handoff 写的 Result: #{result} 不在此表内，按待审阅处理"
  end

  defp unknown_verdict_part(_handoff, _state), do: nil

  defp read_error_part(%{read_error: reason}) when not is_nil(reason), do: "读取失败：#{inspect(reason)}"
  defp read_error_part(_handoff), do: nil

  defp bridge_record(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         name when is_binary(name) <- decoded["task_name"] || decoded["requested_task_name"] do
      %{
        id: name,
        status: decoded["status"],
        title: name,
        claimed_by: strip_agent_prefix(decoded["claimed_by"]),
        result: decoded["result"],
        error: decoded["error"],
        sources: [path],
        mtimes: [mtime(path)],
        payload: decoded["payload"],
        created_at: decode_time(decoded["created_at"]),
        updated_at: decode_time(decoded["updated_at"]),
        task_id: decoded["task_id"]
      }
    else
      _other ->
        Logger.warning("bridge task record unreadable: #{inspect(path)}")
        nil
    end
  end

  defp strip_agent_prefix(nil), do: nil

  defp strip_agent_prefix(claimed_by) do
    claimed_by |> String.split("/") |> List.last() |> empty_to_nil()
  end

  defp decode_time(nil), do: nil

  defp decode_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp decode_time(_value), do: nil

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: seconds}} -> DateTime.from_unix!(seconds)
      {:error, _reason} -> nil
    end
  end
end
