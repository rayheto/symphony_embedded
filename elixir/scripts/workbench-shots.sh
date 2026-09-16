#!/usr/bin/env bash
# Photograph the workbench at the Soft Glass reference viewport.
#
# Runs the real application against a demonstration workflow, waits for the
# server, and asks the environment's own headless Chrome for one PNG per page at
# 1440x900. Nothing here inspects or rewrites the pages: the pictures are what a
# browser rendered.
#
#   elixir/scripts/workbench-shots.sh [output_directory]
#
# The frames are evidence for the visual acceptance pass, not a substitute for
# looking at them.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elixir_root="$(dirname "$here")"
out_dir="${1:-$elixir_root/../docs/verification/evidence/screenshots}"

port="${SHOT_PORT:-4123}"
root="$(mktemp -d)"
workflow="$root/WORKFLOW.md"
log="$root/server.log"

mkdir -p "$out_dir"

cat > "$workflow" <<YAML
---
tracker:
  kind: "memory"
  endpoint: "https://api.linear.app/graphql"
  api_key: null
  project_slug: null
  assignee: null
  required_labels: []
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Done", "Closed"]
polling:
  interval_ms: 30000
workspace:
  root: "$root/workspaces"
agent:
  max_concurrent_agents: 4
  max_turns: 5
  max_retry_backoff_ms: 300000
  max_concurrent_agents_by_state: {}
codex:
  command: "codex app-server"
  approval_policy: {reject: {sandbox_approval: true, rules: true, mcp_elicitations: true}}
  thread_sandbox: "workspace-write"
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
hooks:
  timeout_ms: 60000
observability:
  dashboard_enabled: true
  refresh_ms: 1000
  render_interval_ms: 16
workbench:
  enabled: true
  mode: "demo"
  project_id: "embedded-lab-demo"
  data_root: "$root/data"
  display_states:
    - "待办"
    - "进行中"
    - "待审阅"
    - "已完成"
  paused_state: "待审阅"
server:
  port: $port
  host: "127.0.0.1"
---
You are an agent for this repository.
YAML

# `--no-start` matters: the workflow path must be set before the application
# boots, or WorkflowStore would read whatever WORKFLOW.md sits in the cwd.
SHOT_WORKFLOW="$workflow" mix run --no-start --no-halt "$here/workbench_server.exs" > "$log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$root"' EXIT

for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/workbench/issues" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if ! curl -fsS -o /dev/null "http://127.0.0.1:$port/workbench/issues"; then
  echo "workbench did not come up; server log:" >&2
  cat "$log" >&2
  exit 1
fi

chrome="${ARCHIFY_CHROME:-$(command -v google-chrome || command -v chromium || true)}"
if [ -z "$chrome" ]; then
  echo "no Chrome or Chromium on PATH; set ARCHIFY_CHROME" >&2
  exit 2
fi

shoot() {
  local name="$1" path="$2"
  "$chrome" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1440,900 --virtual-time-budget=4000 \
    --screenshot="$out_dir/$name.png" "http://127.0.0.1:$port$path" >/dev/null 2>&1
  printf '%s\t%s\t%s\n' "$name" "$path" "$(stat -c %s "$out_dir/$name.png")"
}

{
  printf 'page\tpath\tbytes\n'
  shoot "issues" "/workbench/issues"
  shoot "devices" "/workbench/devices"
  shoot "reviews" "/workbench/reviews"
  shoot "architecture" "/workbench/architecture"
  # The runtime dashboard is not part of the workbench; it is captured so the
  # shell can be compared against the page that predates it.
  shoot "dashboard" "/"
} | tee "$out_dir/manifest.txt"

echo "screenshots in $out_dir"