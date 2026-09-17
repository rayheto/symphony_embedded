# Records an engagement's acceptance state into the workbench store.
#
#   SHOT_WORKFLOW=/path/to/WORKFLOW.md \
#     mix run --no-start scripts/import_open_cube_acceptance.exs
#
# This is a host tool, not part of the release path. It imports one engagement —
# the ESP32-P4 EAF delivery `p4_eaf_full_pass_7b31` in the open-cube repository —
# and it writes nothing into the reviewed repository: everything lands in the
# workbench store the workflow names.
#
# What it writes, and why each part is there:
#
#   * the material it names is copied into the store as content-addressed blobs,
#     so evidence that was left in `/tmp` survives the directory it was left in;
#   * the checks the workbench can run on its own (asset digests, repository
#     state, the commit range, the published report's own bytes, the profile
#     document) are re-run here and their output is stored verbatim;
#   * what was verified, what is only self-reported and what nobody has verified
#     yet are recorded as one problem case with claims, experiments and
#     validations — a delivery nobody has independently accepted is recorded as
#     `unverified`, never as a pass;
#   * every payload is checked against priv/workbench/agent-tools.json before it
#     is written, so a record the contract would reject fails this script rather
#     than being stored.
#
# Each check must hold before anything is written: a repository that no longer
# looks the way the record says stops the import instead of leaving a stale
# acceptance in the store.
#
# It never writes a human verdict: `human_review_status` stays `unseen` and
# `agent_endorsed` stays false on everything it records, because no person has
# reviewed these records in this workbench.
#
# Re-running is safe: an entity that already has revision 1 is left alone and
# reported as such, and events are keyed by a digest of what they are about.

workflow = System.get_env("SHOT_WORKFLOW") || raise "SHOT_WORKFLOW is not set"

File.exists?(workflow) || raise "workflow file not found: #{workflow}"

:ok = SymphonyElixir.Workflow.set_workflow_file_path(workflow)
{:ok, _started} = Application.ensure_all_started(:symphony_elixir)

alias SymphonyElixir.Experience.{Project, Store}

project =
  case Project.load() do
    {:ok, project} -> project
    {:error, code, details} -> raise "workflow is not usable: #{code} #{inspect(details)}"
  end

project_id = project.project_id
store = [server: project.store]

# ---------------------------------------------------------------------------
# The engagement
# ---------------------------------------------------------------------------

issue_id = "p4_eaf_full_pass_7b31"
session_id = "01a08428-cd81-78f2-b4a4-7d58b8b19b9b"

repo = "/home/seeed/rust-emb/open-cube"
head = "353caf9a131ac47a436fe809e91d54b05c6beba8"
dispatch_head = "6da7dec"
delivery_commits = 22
result_path = "/tmp/p4_eaf_full_pass_7b31.result.md"
result_sha256 = "e1b9e6c4f65f1cd79fa4d3da655ff56fa12b631d34000c3348817a8ce50b9927"
artifact_root = "/tmp/p4_eaf_full_pass_7b31"
untracked = ["assets/Emote Pack/", "ref/agent/runs/"]
run_file_count = 62

bridge_path = Path.join("/home/seeed/.codex/agent-bridge/tasks", "b1b6d2d0e47a7d9630fe0cf26fd8b93b.json")

rollout =
  "/home/seeed/.codex/sessions/2026/09/09/rollout-2026-09-09T11-14-21-#{session_id}.jsonl"

manifest_path = Path.join(repo, "assets/emote/manifest.json")
profile_path = Path.join(repo, "tools/eaf-packer/profiles/esp32p4-xykj-aipi-p4.json")

# The coordinator's acceptance reports, oldest first. Each is both the evidence
# for a claim about that round and the place that round's verdict is written.
rounds = [
  %{
    id: "ev-open-cube-round-b72c",
    claim: "claim-round-b72c",
    task: "rust_eaf_real_gif_hw_b72c",
    path: "/tmp/rust_eaf_real_gif_hw_b72c.acceptance.md",
    verdict: "passed",
    title: "协调者验收报告：rust_eaf_real_gif_hw_b72c（通过，并修正子任务两处验收错误）",
    statement: "rust_eaf_real_gif_hw_b72c 被协调者判为通过，同时修正了子任务的两处验收错误；Lottie 只到约 50.25 FPS 被如实保留",
    criteria: "协调者对该轮的验收条件：实机 Lottie 帧率与门禁回执逐项复核",
    limitations: ["按协调者的验收报告转录；工作台没有重跑该轮的实机部分。"]
  },
  %{
    id: "ev-open-cube-round-8e2c",
    claim: "claim-round-8e2c",
    task: "p4_eaf_optimal_selector_8e2c",
    path: "/tmp/p4_eaf_optimal_selector_8e2c.acceptance.md",
    verdict: "failed",
    title: "协调者验收报告：p4_eaf_optimal_selector_8e2c（FAIL，6 条）",
    statement: "p4_eaf_optimal_selector_8e2c 被协调者判为 FAIL，共 6 条：无实机标定、几何排序反转（h16 1058 B 胜 h32 1053 B）、deadline 不感知源节奏、过早给出生产推荐、provenance 写成 workspace、JPEG/Lottie 门禁未关",
    criteria: "协调者对该轮的验收条件：几何排序须与实测一致，且无实机标定时不得给出生产推荐",
    limitations: ["按协调者的验收报告转录；工作台没有重跑该轮。"]
  },
  %{
    id: "ev-open-cube-round-c41d",
    claim: "claim-round-c41d",
    task: "p4_eaf_selector_pass_fix_c41d",
    path: "/tmp/p4_eaf_selector_pass_fix_c41d.acceptance.md",
    verdict: "failed",
    title: "协调者验收报告：p4_eaf_selector_pass_fix_c41d（FAIL，7 条）",
    statement: "p4_eaf_selector_pass_fix_c41d 被协调者判为 FAIL，共 7 条，并发现两个受保护未跟踪目录（assets/Emote Pack/、ref/agent/runs/）消失",
    criteria: "协调者对该轮的验收条件：上一轮 6 条关闭，且受保护目录必须仍在",
    limitations: ["按协调者的验收报告转录；工作台没有重跑该轮。"]
  }
]

# The delivery's own gate material, named by its report. These are the raw
# outputs behind the numbers it quotes; the workbench records them and their
# digests but does not re-derive them.
gate_artifacts = [
  "gate0_46_of_46_head.json",
  "inventory/protected_recovery.json",
  "inventory/git_state.txt",
  "inventory/source_hash_check.json",
  "inventory/tracked_hashes.txt",
  "g2_head_final_build/calibration.json",
  "g3_head_analysis/summary.json",
  "g4_head2/gate4.json",
  "g5_46_asset_table_head.json",
  "g5_head_figure_hashes.json"
]

imported_at = DateTime.utc_now() |> DateTime.to_iso8601()
actor = %{kind: "agent", id: "workbench-import", display_name: "工作台导入（files 模式）"}

# ---------------------------------------------------------------------------
# The checks the workbench runs itself
# ---------------------------------------------------------------------------

defmodule ImportOpenCube.Work do
  @moduledoc false

  def read!(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise "cannot read #{path}: #{inspect(reason)}"
    end
  end

  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim_trailing(out)
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status}:\n#{out}"
    end
  end

  def mtime(path) do
    path |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  def line(text), do: IO.puts(text)

  # The 46 sources the manifest names, each hashed where the manifest says it is.
  def assets(repo, manifest_bytes) do
    manifest = Jason.decode!(manifest_bytes)

    {lines, mismatches} =
      Enum.reduce(manifest["sources"], {[], 0}, fn source, {lines, bad} ->
        path = Path.join(repo, source["source"]["path"])
        expected = source["source"]["sha256"]

        case File.read(path) do
          {:ok, bytes} ->
            actual = sha256(bytes)
            ok? = actual == expected
            {["#{source["id"]}\t#{if ok?, do: "match", else: "MISMATCH"}\t#{actual}" | lines], if(ok?, do: bad, else: bad + 1)}

          {:error, reason} ->
            {["#{source["id"]}\tMISSING\t#{inspect(reason)}" | lines], bad + 1}
        end
      end)

    text = """
    assets/emote/manifest.json #{sha256(manifest_bytes)}
    sources: #{length(manifest["sources"])}, mismatches: #{mismatches}
    #{lines |> Enum.reverse() |> Enum.join("\n")}
    """

    {text, mismatches == 0}
  end

  # What the repository says about itself right now.
  def repo_state(repo, dispatch_head, head, run_file_count, commits_expected) do
    porcelain = repo |> git(["status", "--porcelain"]) |> String.split("\n", trim: true) |> Enum.sort()
    run_files = Path.wildcard(Path.join(repo, "ref/agent/runs/**"), match_dot: true) |> Enum.filter(&File.regular?/1)
    commits = git(repo, ["rev-list", "--count", "#{dispatch_head}..#{head}"])

    text = """
    git rev-parse HEAD -> #{git(repo, ["rev-parse", "HEAD"])}
    expected HEAD      -> #{head}
    git rev-list --count #{dispatch_head}..#{head} -> #{commits}
    git log -1 #{dispatch_head} -> #{git(repo, ["log", "-1", "--format=%H %ad %s", "--date=iso", dispatch_head])}
    find ref/agent/runs -type f | wc -l -> #{length(run_files)}
    git status --porcelain:
    #{Enum.join(porcelain, "\n")}
    """

    {text,
     git(repo, ["rev-parse", "HEAD"]) == head and String.to_integer(commits) == commits_expected and
       length(run_files) == run_file_count}
  end

  # The bytes the workbench read are the bytes the bridge published.
  def report_bytes(result_path, result_sha256, bridge_path) do
    file = read!(result_path)
    bridge = Jason.decode!(read!(bridge_path))
    published = bridge["result"] || ""

    text = """
    #{result_path}
      sha256 #{sha256(file)} (expected #{result_sha256})
      bytes  #{byte_size(file)}, lines #{file |> String.split("\n") |> length()}
    #{bridge_path}#result
      sha256 #{sha256(published)}
    identical: #{file == published}
    bridge status #{bridge["status"]}, claimed_by #{bridge["claimed_by"]}
    bridge created_at #{bridge["created_at"]}, updated_at #{bridge["updated_at"]}
    """

    {text, file == published and sha256(file) == result_sha256}
  end

  # The promotion the report claims, read from the profile document itself.
  def profile(profile_path) do
    bytes = read!(profile_path)
    profile = Jason.decode!(bytes)
    provenance = get_in(profile, ["device", "provenance"]) || []
    kinds = provenance |> Enum.map(& &1["kind"]) |> Enum.reject(&is_nil/1)

    text = """
    #{profile_path} sha256 #{sha256(bytes)}
    status          #{profile["status"]}
    runtime clock   #{get_in(profile, ["device", "runtime_clock", "cpu_hz"])} Hz, confidence #{get_in(profile, ["device", "runtime_clock", "confidence"])}
    provenance      #{length(provenance)} entries, #{length(kinds)} kind-tagged
    kinds           #{Enum.join(kinds, ", ")}
    """

    {text, profile["status"] == "observed" and length(kinds) == 7}
  end

  # Did the independent acceptance happen? The session's own tail answers it.
  def coordinator_tail(rollout) do
    lines = rollout |> read!() |> String.split("\n", trim: true)

    rows =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} ->
        decoded =
          case Jason.decode(line) do
            {:ok, value} -> value
            {:error, _reason} -> %{}
          end

        {number, decoded["timestamp"], decoded["payload"] || %{}}
      end)

    {start_line, _timestamp, _payload} =
      rows
      |> Enum.filter(fn {_number, _timestamp, payload} ->
        payload["type"] == "user_message" and String.contains?(payload["message"] || "", "验收")
      end)
      |> List.last()
      |> case do
        nil -> raise "no acceptance request found in #{rollout}"
        found -> found
      end

    kept = Enum.filter(rows, fn {number, _timestamp, payload} -> number >= start_line and relevant?(payload) end)
    last = kept |> Enum.map(&elem(&1, 0)) |> List.last()

    body =
      kept
      |> Enum.map(fn {number, timestamp, payload} -> "L#{number} #{timestamp} #{describe(payload)}" end)
      |> Enum.join("\n")

    {start_line, last, body, length(lines)}
  end

  defp relevant?(%{"type" => "user_message"}), do: true
  defp relevant?(%{"type" => "message"}), do: true
  defp relevant?(%{"type" => "task_complete"}), do: true
  defp relevant?(_payload), do: false

  defp describe(%{"type" => "user_message", "message" => message}), do: "用户：#{one_line(message, 120)}"

  defp describe(%{"type" => "message", "role" => role, "content" => content}) do
    text = content |> List.wrap() |> Enum.map(&(&1["text"] || "")) |> Enum.join(" ")
    "#{role}：#{one_line(text, 400)}"
  end

  defp describe(%{"type" => "task_complete"} = payload), do: "turn 结束：#{inspect(payload["error"])}"

  defp describe(payload), do: inspect(payload)

  defp one_line(text, limit), do: text |> String.replace(~r/\s+/u, " ") |> String.slice(0, limit)
end

# A small JSON-Schema subset, enough for the record definitions in
# priv/workbench/agent-tools.json: $ref, anyOf, type, enum, pattern, minLength,
# minimum, required, additionalProperties and date-time.
defmodule ImportOpenCube.Contract do
  @moduledoc false

  def load do
    path = Path.join(:code.priv_dir(:symphony_elixir), "workbench/agent-tools.json")
    Jason.decode!(File.read!(path))["definitions"]
  end

  def check!(definitions, name, value) do
    case problems(definitions, Map.fetch!(definitions, name), value, name) do
      [] -> :ok
      found -> raise "#{name} does not satisfy the contract:\n  " <> Enum.join(found, "\n  ")
    end
  end

  defp problems(definitions, %{"$ref" => "#/$defs/" <> name}, value, path) do
    problems(definitions, Map.fetch!(definitions, name), value, path)
  end

  defp problems(definitions, %{"anyOf" => variants}, value, path) do
    if Enum.any?(variants, &(problems(definitions, &1, value, path) == [])) do
      []
    else
      ["#{path}: #{inspect(value)} matches no anyOf variant"]
    end
  end

  defp problems(definitions, schema, value, path) do
    type_problems(definitions, schema, value, path) ++
      enumeration_problems(schema, value, path) ++ length_problems(schema, value, path)
  end

  defp type_problems(definitions, %{"type" => "object"} = schema, value, path) when is_map(value) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    nested =
      for {field, field_schema} <- properties, Map.has_key?(value, field), problem <- problems(definitions, field_schema, Map.fetch!(value, field), "#{path}.#{field}"), do: problem

    missing = required |> Enum.reject(&Map.has_key?(value, &1)) |> Enum.map(&"#{path}: missing #{&1}")

    unknown =
      if Map.get(schema, "additionalProperties") == false do
        (Map.keys(value) -- Map.keys(properties)) |> Enum.map(&"#{path}: unknown field #{&1}")
      else
        []
      end

    nested ++ missing ++ unknown
  end

  defp type_problems(_definitions, %{"type" => "object"}, value, path), do: ["#{path}: expected object, got #{inspect(value)}"]

  defp type_problems(definitions, %{"type" => "array"} = schema, value, path) when is_list(value) do
    item = Map.get(schema, "items", %{})

    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, index} -> problems(definitions, item, element, "#{path}[#{index}]") end)
  end

  defp type_problems(_definitions, %{"type" => "array"}, value, path), do: ["#{path}: expected array, got #{inspect(value)}"]

  defp type_problems(_definitions, %{"type" => "string"} = schema, value, path) do
    cond do
      not is_binary(value) -> ["#{path}: expected string, got #{inspect(value)}"]
      Map.get(schema, "format") == "date-time" and not date_time?(value) -> ["#{path}: not a date-time: #{inspect(value)}"]
      true -> []
    end
  end

  defp type_problems(_definitions, %{"type" => "integer"}, value, path) when not is_integer(value),
    do: ["#{path}: expected integer, got #{inspect(value)}"]

  defp type_problems(_definitions, %{"type" => "boolean"}, value, path) when not is_boolean(value),
    do: ["#{path}: expected boolean, got #{inspect(value)}"]

  defp type_problems(_definitions, %{"type" => "null"}, value, path) when not is_nil(value),
    do: ["#{path}: expected null, got #{inspect(value)}"]

  defp type_problems(_definitions, _schema, _value, _path), do: []

  defp enumeration_problems(%{"enum" => allowed}, value, path) do
    if value in allowed, do: [], else: ["#{path}: #{inspect(value)} is not one of #{inspect(allowed)}"]
  end

  defp enumeration_problems(_schema, _value, _path), do: []

  defp length_problems(%{"minLength" => min} = schema, value, path) when is_binary(value) do
    cond do
      String.length(value) < min -> ["#{path}: shorter than #{min}"]
      Map.get(schema, "pattern") && not pat_match?(schema["pattern"], value) -> ["#{path}: #{inspect(value)} does not match #{schema["pattern"]}"]
      true -> []
    end
  end

  defp length_problems(%{"minimum" => min}, value, path) when is_integer(value) do
    if value >= min, do: [], else: ["#{path}: #{value} is below the minimum #{min}"]
  end

  defp length_problems(_schema, _value, _path), do: []

  defp pat_match?(pattern, value), do: Regex.match?(Regex.compile!(pattern), value)

  defp date_time?(value), do: match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
end

defmodule ImportOpenCube.Writer do
  @moduledoc false

  alias SymphonyElixir.Experience.Store

  def blob!(project_id, bytes, media_type, store) do
    case Store.put_blob(project_id, bytes, media_type, store) do
      {:ok, %{"sha256" => digest}} -> digest
      {:error, code, details} -> raise "put_blob failed: #{code} #{inspect(details)}"
    end
  end

  def exists?(project_id, entity_type, entity_id, store) do
    match?({:ok, _record}, Store.get(project_id, entity_type, entity_id, store))
  end

  def append!(project_id, entity_type, entity_id, payload, actor, store) do
    case Store.append(project_id, entity_type, entity_id, 0, payload, actor, store) do
      {:ok, record} -> record
      {:error, code, details} -> raise "append #{entity_type}/#{entity_id} failed: #{code} #{inspect(details)}"
    end
  end

  def write_all(project_id, entity_type, payloads, actor, store) do
    Enum.each(payloads, fn payload ->
      id = payload["id"]

      if exists?(project_id, entity_type, id, store) do
        work_line("#{entity_type} #{id}: 已存在，跳过")
      else
        record = append!(project_id, entity_type, id, payload, actor, store)
        work_line("#{entity_type} #{id}: 第 #{record.entity_revision} 修订，project_seq #{record.project_seq}")
      end
    end)
  end

  def event!(project_id, type, entity_type, entity_id, detail, store, actor) do
    revision =
      case Store.get(project_id, entity_type, entity_id, store) do
        {:ok, record} -> record.entity_revision
        {:error, _code, _details} -> 0
      end

    opts = Keyword.merge(store, entity_revision: revision, actor: actor, payload: %{"detail" => detail})

    case Store.emit_event(project_id, type, entity_type, entity_id, opts) do
      {:ok, _record} -> :ok
      {:error, code, details} -> raise "emit_event #{type}/#{entity_id} failed: #{code} #{inspect(details)}"
    end
  end

  defp work_line(text), do: IO.puts(text)
end

# ---------------------------------------------------------------------------
# Checks first: nothing is written unless they hold
# ---------------------------------------------------------------------------

result_bytes = ImportOpenCube.Work.read!(result_path)
bridge_bytes = ImportOpenCube.Work.read!(bridge_path)
manifest_bytes = ImportOpenCube.Work.read!(manifest_path)
rollout_bytes = ImportOpenCube.Work.read!(rollout)

{assets_text, assets_ok?} = ImportOpenCube.Work.assets(repo, manifest_bytes)
{repo_text, repo_ok?} = ImportOpenCube.Work.repo_state(repo, dispatch_head, head, run_file_count, delivery_commits)
{report_text, report_ok?} = ImportOpenCube.Work.report_bytes(result_path, result_sha256, bridge_path)
{profile_text, profile_ok?} = ImportOpenCube.Work.profile(profile_path)
{tail_start, tail_end, tail_body, rollout_lines} = ImportOpenCube.Work.coordinator_tail(rollout)

checks_text = """
工作台侧独立复核（scripts/import_open_cube_acceptance.exs）
工程 #{repo}，HEAD #{head}，导出于 #{imported_at}

== manifest 逐项 SHA-256 ==
#{assets_text}
== 仓库状态 ==
#{repo_text}
== 交付报告原文一致性 ==
#{report_text}
== profile 文档 ==
#{profile_text}
"""

for {name, ok?, text} <- [
      {"46 资产哈希", assets_ok?, assets_text},
      {"仓库状态与提交区间", repo_ok?, repo_text},
      {"交付报告原文一致性", report_ok?, report_text},
      {"profile 文档", profile_ok?, profile_text}
    ] do
  unless ok? do
    raise "#{name} 复核未通过，导入中止（记录的结论必须与当下的事实一致）：\n#{text}"
  end
end

IO.puts(checks_text)

# ---------------------------------------------------------------------------
# Blobs
# ---------------------------------------------------------------------------

digest_blob = fn bytes, media_type -> ImportOpenCube.Writer.blob!(project_id, bytes, media_type, store) end

result_digest = digest_blob.(result_bytes, "text/markdown")
bridge_digest = digest_blob.(bridge_bytes, "application/json")
manifest_digest = digest_blob.(manifest_bytes, "application/json")
rollout_digest = ImportOpenCube.Work.sha256(rollout_bytes)

tail_bytes = """
codex 会话 #{session_id} 节选（原文件 #{rollout}，第 #{tail_start}–#{tail_end} 行）
保留：用户消息、助手消息、turn 结束原因；省略 token_count 等噪声。
原文件共 #{rollout_lines} 行，sha256 #{rollout_digest}。

#{tail_body}
"""

tail_digest = digest_blob.(tail_bytes, "text/plain")
checks_digest = digest_blob.(checks_text, "text/plain")

artifacts =
  Map.new(gate_artifacts, fn name ->
    bytes = ImportOpenCube.Work.read!(Path.join(artifact_root, name))
    media = if Path.extname(name) in [".json"], do: "application/json", else: "text/plain"
    {name, {digest_blob.(bytes, media), byte_size(bytes)}}
  end)

# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

src = fn kind, locator, line, end_line ->
  %{"kind" => kind, "locator" => locator, "repo_revision" => nil, "line" => line, "end_line" => end_line}
end

range = fn digest, bytes, seq_start, seq_end ->
  %{
    "blob_sha256" => digest,
    "start_byte" => 0,
    "end_byte_exclusive" => bytes,
    "source_seq_start" => seq_start,
    "source_seq_end" => seq_end
  }
end

binding = fn opts ->
  %{
    "repo_revision" => Keyword.get(opts, :repo_revision, head),
    "worktree_patch_sha256" => nil,
    "build_id" => nil,
    "firmware_sha256" => nil,
    "device_id" => Keyword.get(opts, :device_id),
    "hardware_revision" => Keyword.get(opts, :hardware_revision),
    "boot_id" => nil,
    "config_sha256" => nil,
    "test_profile" => Keyword.get(opts, :test_profile),
    "criteria_revision" => Keyword.get(opts, :criteria_revision)
  }
end

board_binding =
  binding.(
    device_id: "xykj-aipi-p4-rev1.3",
    hardware_revision: "rev 1.3",
    test_profile: "esp32p4-xykj-aipi-p4",
    criteria_revision: "coordinator-2026-09-17"
  )

evidence =
  [
    %{
      "id" => "ev-open-cube-p4-report",
      "project_id" => project_id,
      "revision" => 1,
      "created_at" => "2026-09-16T22:15:21.865908Z",
      "updated_at" => "2026-09-16T22:15:21.865908Z",
      "source_kind" => "agent_report",
      "title" => "子代理交付报告：#{issue_id}（自报五项门禁 PASS）",
      "raw" => [range.(result_digest, byte_size(result_bytes), nil, nil), range.(bridge_digest, byte_size(bridge_bytes), nil, nil)],
      "source_refs" => [src.("document", result_path, nil, nil), src.("document", bridge_path <> "#result", nil, nil)],
      "binding" => board_binding,
      "captured_at" => "2026-09-16T22:15:21.865908Z",
      "received_at" => imported_at,
      "capture_session_id" => session_id,
      "derivation_of" => [],
      "limitations" => [
        "自报：五项门禁的判据与全部实机数值都出自该报告，工作台没有复算实机部分。",
        "报告正文与桥接任务里的 result 字段逐字节一致（sha256 #{result_sha256}，#{byte_size(result_bytes)} 字节）。",
        "报告引用的中间素材留在 /tmp 下，导入时仍在；它们已按哈希复制进工作台。"
      ],
      "supersedes" => nil,
      "content_status" => "available",
      "review_status" => "unseen"
    },
    %{
      "id" => "ev-open-cube-gate-material",
      "project_id" => project_id,
      "revision" => 1,
      "created_at" => "2026-09-17T06:10:00Z",
      "updated_at" => "2026-09-17T06:10:00Z",
      "source_kind" => "host_test",
      "title" => "门禁原始素材：46 资产哈希、受保护目录恢复、标定、门禁 4、46 资产对比与图",
      "raw" =>
        Enum.map(gate_artifacts, fn name ->
          {digest, bytes} = Map.fetch!(artifacts, name)
          range.(digest, bytes, nil, nil)
        end),
      "source_refs" => Enum.map(gate_artifacts, &src.("document", Path.join(artifact_root, &1), nil, nil)),
      "binding" => board_binding,
      "captured_at" => "2026-09-17T06:10:00Z",
      "received_at" => imported_at,
      "capture_session_id" => session_id,
      "derivation_of" => [],
      "limitations" => [
        "这些是子代理在主机上生成的中间输出，不是工作台重跑得到的。",
        "工作台记录了它们的字节与哈希，没有重跑标定、没有重新解码图像。"
      ],
      "supersedes" => nil,
      "content_status" => "available",
      "review_status" => "unseen"
    },
    %{
      "id" => "ev-open-cube-workbench-checks",
      "project_id" => project_id,
      "revision" => 1,
      "created_at" => imported_at,
      "updated_at" => imported_at,
      "source_kind" => "host_test",
      "title" => "工作台侧独立复核输出（46 资产哈希、仓库状态、提交区间、报告原文一致性、profile 文档）",
      "raw" => [range.(checks_digest, byte_size(checks_text), nil, nil)],
      "source_refs" => [
        src.("git", "#{repo}@#{head}", nil, nil),
        src.("document", manifest_path, nil, nil),
        src.("document", profile_path, nil, nil)
      ],
      "binding" => binding.(test_profile: "host_test", criteria_revision: "workbench-2026-09-17"),
      "captured_at" => imported_at,
      "received_at" => imported_at,
      "capture_session_id" => nil,
      "derivation_of" => [],
      "limitations" => [
        "只覆盖主机上可验证的部分：资产哈希、仓库状态、提交区间、报告原文、profile 文档结构。",
        "没有实机复核：没有重跑标定、没有读原始串口日志、没有验证板卡是否已还原到 HEAD。"
      ],
      "supersedes" => nil,
      "content_status" => "available",
      "review_status" => "unseen"
    },
    %{
      "id" => "ev-open-cube-coordinator-tail",
      "project_id" => project_id,
      "revision" => 1,
      "created_at" => "2026-09-17T00:29:46Z",
      "updated_at" => "2026-09-17T00:29:46Z",
      "source_kind" => "document",
      "title" => "协调者会话节选：承诺独立验收之后的两次流失败（codex #{session_id}）",
      "raw" => [range.(tail_digest, byte_size(tail_bytes), tail_start, tail_end)],
      "source_refs" => [src.("document", rollout, tail_start, tail_end)],
      "binding" => binding.(repo_revision: nil, criteria_revision: "coordinator-2026-09-17"),
      "captured_at" => "2026-09-17T00:29:46Z",
      "received_at" => imported_at,
      "capture_session_id" => session_id,
      "derivation_of" => [],
      "limitations" => [
        "节选：只保留验收相关的用户与助手消息、以及 turn 结束原因；原文件是 #{rollout_lines} 行的完整 rollout。",
        "工作台读的是会话记录，不是协调者的判断：它只能证明验收没有发生，不能代替验收。"
      ],
      "supersedes" => nil,
      "content_status" => "available",
      "review_status" => "unseen"
    }
  ]
  |> Kernel.++(
    Enum.map(rounds, fn round ->
      bytes = ImportOpenCube.Work.read!(round.path)
      captured = ImportOpenCube.Work.mtime(round.path)

      %{
        "id" => round.id,
        "project_id" => project_id,
        "revision" => 1,
        "created_at" => captured,
        "updated_at" => captured,
        "source_kind" => "document",
        "title" => round.title,
        "raw" => [range.(digest_blob.(bytes, "text/markdown"), byte_size(bytes), nil, nil)],
        "source_refs" => [src.("document", round.path, nil, nil)],
        "binding" => board_binding,
        "captured_at" => captured,
        "received_at" => imported_at,
        "capture_session_id" => session_id,
        "derivation_of" => [],
        "limitations" => round.limitations,
        "supersedes" => nil,
        "content_status" => "available",
        "review_status" => "unseen"
      }
    end)
  )

claim = fn id, statement, status, supporting, missing?, limitations ->
  %{
    "id" => id,
    "statement" => statement,
    "status" => status,
    "supporting_evidence_ids" => supporting,
    "contradicting_evidence_ids" => [],
    "evidence_missing" => missing?,
    "limitations" => limitations
  }
end

claims = [
  claim.(
    "claim-five-gates-pass",
    "这一轮交付在真实板卡上把五项门禁全部推到 PASS，其中门禁 4 的判据被改写为可被证伪的面板槽上限并如实标注",
    "inconclusive",
    ["ev-open-cube-p4-report", "ev-open-cube-gate-material"],
    true,
    [
      "自报：判据与数值都出自子代理的报告，没有任何人独立复核过。",
      "改写判据本身是报告如实写明的，不构成隐瞒；但它也意味着门禁 4 不是原判据下的 PASS。"
    ]
  ),
  claim.(
    "claim-assets-46",
    "assets/Emote Pack 下 46 个源资产与 assets/emote/manifest.json 逐项 SHA-256 一致，两个受保护目录都在原地且未被跟踪",
    "supported",
    ["ev-open-cube-workbench-checks", "ev-open-cube-gate-material"],
    false,
    [
      "工作台按 manifest 复核了 46/46，没有重新解码图像或比较像素。",
      "「从 stash 对象精确恢复」只有报告与 protected_recovery.json 支持，工作台没有验证恢复来源。"
    ]
  ),
  claim.(
    "claim-repo-state",
    "交付结束时仓库停在 HEAD #{head}，git status 只有 #{Enum.join(untracked, " 与 ")} 两个有意未跟踪目录，ref/agent/runs 下 #{run_file_count} 个文件",
    "supported",
    ["ev-open-cube-workbench-checks"],
    false,
    []
  ),
  claim.(
    "claim-commits-22",
    "这一轮相对 dispatch HEAD #{dispatch_head} 增加 #{delivery_commits} 个提交",
    "supported",
    ["ev-open-cube-workbench-checks"],
    false,
    ["按 dispatch HEAD 到交付 HEAD 的提交区间计数；报告的描述与该区间一致。"]
  ),
  claim.(
    "claim-profile-observed",
    "P4 profile 已从 reasoned 提升为 observed，并带 7 条有 kind 标注的 provenance 记录",
    "supported",
    ["ev-open-cube-workbench-checks", "ev-open-cube-gate-material"],
    false,
    [
      "工作台只核对了文档：status、runtime clock confidence 与 provenance 的条数、kind。",
      "文档里的拟合系数与 MAPE 没有被重新测量。"
    ]
  ),
  claim.(
    "claim-hardware-numbers",
    "实机数值达标：12 次启动全 360 MHz、holdout median MAPE 1.003 %、p95 APE 1.554 %、348/348 会话、174/174 面板槽且无渲染超限",
    "inconclusive",
    ["ev-open-cube-p4-report", "ev-open-cube-gate-material"],
    true,
    [
      "需要重跑标定或读原始日志；工作台本轮只做了主机侧复核。",
      "「板卡已还原到 HEAD」「/dev/ttyACM0 已释放」同样只有报告支持，工作台没有读固件或刷机。"
    ]
  ),
  claim.(
    "claim-acceptance-pending",
    "这一轮交付目前的验收状态是「待独立验收」：协调者承诺的独立验收没有发生，没有人给过 PASS 或 FAIL",
    "supported",
    ["ev-open-cube-coordinator-tail"],
    false,
    [
      "该结论只说明验收没有发生，不说明交付本身有问题，也不说明没问题。",
      "工作台不是协调者的替代品：它只记录了自己能复核的部分。"
    ]
  )
]

claims =
  claims ++
    Enum.map(rounds, fn round ->
      claim.(round.claim, round.statement, "supported", [round.id], false, round.limitations)
    end)

experiment = fn id, question, procedure, observation, outcome, evidence_ids, limitations ->
  %{
    "id" => id,
    "occurred_at" => imported_at,
    "question" => question,
    "procedure" => procedure,
    "observation" => observation,
    "outcome" => outcome,
    "evidence_ids" => evidence_ids,
    "limitations" => limitations
  }
end

experiments = [
  experiment.(
    "exp-assets-46",
    "manifest 里的 46 项是否与工作区文件逐项一致？",
    "读 assets/emote/manifest.json，对每一项 source.sha256 与文件实际 sha256 比对",
    "46/46 一致，没有缺失或不符",
    "supports",
    ["ev-open-cube-workbench-checks"],
    ["只比对字节，没有重新解码 23 个 GIF 与 23 个 Lottie。"]
  ),
  experiment.(
    "exp-repo-state",
    "仓库是否停在报告声称的 HEAD，工作区是否只有两个有意未跟踪目录？",
    "git rev-parse HEAD；git status --porcelain；统计 ref/agent/runs 下文件数",
    "HEAD #{head}；未跟踪目录恰好是 #{Enum.join(untracked, " 与 ")}；ref/agent/runs 下 #{run_file_count} 个文件",
    "supports",
    ["ev-open-cube-workbench-checks"],
    []
  ),
  experiment.(
    "exp-commit-range",
    "「增加 #{delivery_commits} 个提交」是否与提交图相符？",
    "git rev-list --count #{dispatch_head}..#{head}",
    "#{delivery_commits}",
    "supports",
    ["ev-open-cube-workbench-checks"],
    []
  ),
  experiment.(
    "exp-report-bytes",
    "工作台读到的报告是否就是桥接任务发布的那一份？",
    "对 #{result_path} 与桥接任务 JSON 的 result 字段分别算 sha256 并逐字节比较",
    "两者逐字节一致，sha256 #{result_sha256}，#{byte_size(result_bytes)} 字节，#{result_bytes |> String.split("\n") |> length()} 行",
    "supports",
    ["ev-open-cube-p4-report"],
    []
  ),
  experiment.(
    "exp-profile-document",
    "profile 是否真的从 reasoned 提升到 observed，并带 7 条 kind 标注的 provenance？",
    "读 tools/eaf-packer/profiles/esp32p4-xykj-aipi-p4.json：status、device.runtime_clock.confidence、device.provenance",
    "status = observed；runtime clock confidence = observed；provenance 10 条，其中 7 条带 kind",
    "supports",
    ["ev-open-cube-workbench-checks"],
    ["只核对了文档结构，没有复算系数。"]
  ),
  experiment.(
    "exp-coordinator-acceptance",
    "协调者承诺的独立验收执行了吗？",
    "读 codex 会话 rollout（#{rollout_lines} 行）尾部：从用户「验收一下」到最后的 turn 结束原因",
    "08:28:38 用户要求验收；08:28:46 协调者承诺 7 项独立核验；08:29:05 与 08:29:46 两个 turn 均以 stream disconnected…Encrypted function output content 结束，7 项一项未执行",
    "supports",
    ["ev-open-cube-coordinator-tail"],
    ["会话记录的失败是传输层的；工作台无法判断协调者之后是否在别处补做了验收。"]
  )
]

validation = fn id, claim_id, criteria, criteria_revision, result, executed_at, command_sha, evidence_ids, limitations ->
  %{
    "id" => id,
    "project_id" => project_id,
    "revision" => 1,
    "created_at" => executed_at || imported_at,
    "updated_at" => executed_at || imported_at,
    "claim_id" => claim_id,
    "evidence_ids" => evidence_ids,
    "criteria" => criteria,
    "criteria_revision" => criteria_revision,
    "binding" => binding.(test_profile: "host_test", criteria_revision: criteria_revision),
    "result" => result,
    "executed_at" => executed_at,
    "command_record_sha256" => command_sha,
    "limitations" => limitations
  }
end

validations = [
  validation.(
    "val-p4-independent-acceptance",
    "claim-acceptance-pending",
    "协调者原定的 7 项独立验收：提交、46 资产、实机日志、MAPE、JPEG 计数、Lottie 帧率、profile 状态",
    "coordinator-2026-09-17",
    "unverified",
    nil,
    nil,
    ["ev-open-cube-coordinator-tail"],
    [
      "未执行：协调者在 2026-09-17 08:29:05 与 08:29:46 的两个 turn 都以流解密失败结束。",
      "工作台不是协调者，不能代替它给出验收结论；这条记录只说明验收没有发生。"
    ]
  ),
  validation.(
    "val-assets-46",
    "claim-assets-46",
    "assets/emote/manifest.json 的 46 项逐项 SHA-256 一致",
    "manifest@#{String.slice(head, 0, 8)}",
    "passed",
    imported_at,
    checks_digest,
    ["ev-open-cube-workbench-checks", "ev-open-cube-gate-material"],
    ["工作台执行的复核；实机部分不在判据内。"]
  ),
  validation.(
    "val-repo-state",
    "claim-repo-state",
    "HEAD 为报告声称的提交，提交区间为 #{delivery_commits}，且未跟踪路径只有两个有意目录",
    "workbench-2026-09-17",
    "passed",
    imported_at,
    checks_digest,
    ["ev-open-cube-workbench-checks"],
    []
  ),
  validation.(
    "val-profile-document",
    "claim-profile-observed",
    "profile.status == observed，且存在 7 条带 kind 的 provenance 记录",
    "workbench-2026-09-17",
    "passed",
    imported_at,
    checks_digest,
    ["ev-open-cube-workbench-checks", "ev-open-cube-gate-material"],
    ["只核对文档结构与状态字段，没有复算拟合系数。"]
  ),
  validation.(
    "val-hardware-numbers",
    "claim-hardware-numbers",
    "在板卡上重跑标定并复核日志：12 次启动全 360 MHz、holdout median MAPE ≤ 10 %、348/348 会话、174/174 面板槽",
    "coordinator-2026-09-17",
    "unverified",
    nil,
    nil,
    ["ev-open-cube-p4-report", "ev-open-cube-gate-material"],
    ["本轮没有重跑标定，也没有读原始串口日志。"]
  )
]

validations =
  validations ++
    Enum.map(rounds, fn round ->
      validation.(
        "val-#{round.task}",
        round.claim,
        round.criteria,
        "coordinator-2026-09-17",
        round.verdict,
        ImportOpenCube.Work.mtime(round.path),
        ImportOpenCube.Work.sha256(ImportOpenCube.Work.read!(round.path)),
        [round.id],
        round.limitations
      )
    end)

problem_case = %{
  "id" => "pc-#{issue_id}",
  "project_id" => project_id,
  "revision" => 1,
  "created_at" => imported_at,
  "updated_at" => imported_at,
  "issue_ids" => [issue_id],
  "component_ids" => ["tools/eaf-packer", "assets/emote", "app"],
  "symptom" => "最后一轮交付 #{issue_id} 自报五项门禁全 PASS，但协调者承诺的独立验收没有发生：工作台既不能把它写成通过，也不能写成失败。",
  "claims" => claims,
  "experiments" => experiments,
  "current_conclusion" =>
    "子代理自报五项门禁 PASS（门禁 4 的判据被改写为可被证伪的面板槽上限，报告如实标注了改写）；" <>
      "唯一的独立复核来自工作台，且只覆盖主机侧可验证的部分：46/46 资产哈希、仓库状态、提交区间、报告原文一致性、profile 文档结构。" <>
      "实机数值与固件还原状态没有任何人复核过。协调者在 2026-09-17 08:29 的两个 turn 均以流解密失败结束，其 7 项独立验收一项未执行。" <>
      "因此这一轮的结论是待独立验收，不是通过。",
  "next_step" =>
    "按原定 7 项补做独立验收：提交、46 资产、实机日志、MAPE、JPEG 计数、Lottie 帧率、profile 状态；" <>
      "工作台侧可先补做固件还原与原始日志复核，人再决定是否把 human_review_status 从 unseen 改掉。",
  "state" => %{
    "implementation_status" => "integrated",
    "verification_status" => "unverified",
    "human_review_status" => "unseen",
    "agent_endorsed" => false
  },
  "limitations" => [
    "记录的结论来自文件与提交，不来自板卡：工作台没有重跑标定，也没有读原始串口日志。",
    "交付的中间素材原本在 /tmp 下，导入时仍在；它们已按哈希复制进工作台，但工作台不能保证子代理当时的运行环境可以重建。",
    "「板卡已还原」「/dev/ttyACM1 从未打开」只有报告支持。",
    "门禁 4 的判据由子代理改写：工作台不去判定这次改写对不对，只如实记录它被改写。"
  ]
}

definitions = ImportOpenCube.Contract.load()
Enum.each(evidence, &ImportOpenCube.Contract.check!(definitions, "Evidence", &1))
Enum.each(validations, &ImportOpenCube.Contract.check!(definitions, "Validation", &1))
ImportOpenCube.Contract.check!(definitions, "ProblemCase", problem_case)

IO.puts("")
IO.puts("== 写入 ==")
ImportOpenCube.Writer.write_all(project_id, "Evidence", evidence, actor, store)
ImportOpenCube.Writer.write_all(project_id, "Validation", validations, actor, store)
ImportOpenCube.Writer.write_all(project_id, "ProblemCase", [problem_case], actor, store)

IO.puts("")
IO.puts("== 事件 ==")

ImportOpenCube.Writer.event!(
  project_id,
  "problem.updated",
  "ProblemCase",
  problem_case["id"],
  "记录了 #{issue_id} 的验收状态：子代理自报五项门禁 PASS，独立验收未执行。",
  store,
  actor
)

Enum.each(evidence, fn item ->
  ImportOpenCube.Writer.event!(
    project_id,
    "evidence.registered",
    "Evidence",
    item["id"],
    "已登记证据：#{item["title"]}",
    store,
    actor
  )
end)

Enum.each(validations, fn item ->
  ImportOpenCube.Writer.event!(
    project_id,
    "validation.recorded",
    "Validation",
    item["id"],
    "验收记录 #{item["result"]}：#{item["criteria"]}",
    store,
    actor
  )
end)

IO.puts("")
IO.puts("== 校验 ==")
IO.puts("store verify: #{inspect(Store.verify(store))}")

IO.puts("")
IO.puts("工作台 #{project.project_id} / Issue #{issue_id}")
IO.puts("证据 #{length(evidence)} 条，验收记录 #{length(validations)} 条，问题分析 1 条（#{length(claims)} 个假设，#{length(experiments)} 个实验）")
IO.puts("打开：/workbench/issues/#{issue_id}?tab=investigation")
