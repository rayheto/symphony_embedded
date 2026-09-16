# Boots the workbench against a demonstration workflow and stays up.
#
# Used by `scripts/workbench-shots.sh` to photograph the pages with a real
# browser; it is not part of the release path and starts no scheduler of its own.
#
#   SHOT_WORKFLOW=/path/to/WORKFLOW.md mix run --no-halt scripts/workbench_server.exs
#
# The workflow is the single source of truth for the port, the data root and the
# workbench scope, so the pictures come from the same configuration a host would
# run rather than from a fixture invented for the screenshots.

workflow = System.get_env("SHOT_WORKFLOW") || raise "SHOT_WORKFLOW is not set"

File.exists?(workflow) || raise "workflow file not found: #{workflow}"

:ok = SymphonyElixir.Workflow.set_workflow_file_path(workflow)

{:ok, _started} = Application.ensure_all_started(:symphony_elixir)

case SymphonyElixir.Config.settings() do
  {:ok, settings} ->
    IO.puts("workbench ready on #{settings.server.host || "127.0.0.1"}:#{settings.server.port}")

  {:error, reason} ->
    raise "workflow is not usable: #{inspect(reason)}"
end

Process.sleep(:infinity)