---
tracker:
  kind: linear
  provider:
    project_slug: REPLACE_WITH_AUTHORIZED_TEST_PROJECT
  active_states: [Todo, In Progress, Merging, Rework]
  terminal_states: [Closed, Cancelled, Canceled, Duplicate, Done]
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-target-workspaces
hooks:
  after_create: |
    test -n "$SYMPHONY_TARGET_REPO_URL" || exit 1
    git clone "$SYMPHONY_TARGET_REPO_URL" .
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
server:
  port: 4000
workbench:
  enabled: true
  mode: live
  project_id: replace-with-stable-project-id
  data_root: .symphony-data
  domain_profile: embedded-profile.yaml
  device_config: devices.yaml
  archify_root: /REPLACE_WITH_INSTALLED_ARCHIFY_SKILL_ROOT
  display_states: [Backlog, Todo, In Progress, Human Review, Paused, Merging, Rework, Done, Closed, Cancelled, Canceled, Duplicate]
---

You are working on {{ issue.identifier }}: {{ issue.title }}.
{% if attempt %}Continuation attempt {{ attempt }}. Reuse current workspace and workpad; do not repeat completed work without a concrete reason.{% endif %}

Issue description:
{{ issue.description }}

Follow the repository's existing WORKFLOW and AGENTS rules, including tracker-native transitions and single-workpad policy. This file is an integration template; merge these engineering instructions into the actual workflow, retaining its existing review/merge/retry policy.

Read the embedded domain profile. Map concrete project files to L0–L4 responsibilities; Feedback is crosscutting. Do not assume Rust, C, Zephyr or a particular chip.
Read the current immutable Decision/plan reference in the issue workpad before implementation; verify its hash and report engineering_plan_loaded. If no adopted plan exists, work under the existing issue plan and report that fact; do not invent an adoption.
Report meaningful problems with symptom, hypothesis, experiments (including failed attempts), evidence, current limits and next step. Persist raw evidence via engineering tools before declaring its validation complete. Preserve device/build/session scope.
Routine handoffs need no new human approval. If the actual workflow requires a direction decision, record options/tradeoffs/evidence and enter its configured non-active review state; do not keep a worker busy waiting or infer agreement from silence.
For architecture work, use the pinned Archify skill and prompts from this implementation pack. Generate from the actual target project revision, deliver source-linked IR/HTML plus receipts, and publish via engineering tools. Do not create a different renderer.
Follow the original completion policy; neither tool success, human adoption nor worker exit alone proves validation passed.
