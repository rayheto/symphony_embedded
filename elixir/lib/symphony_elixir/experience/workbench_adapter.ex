defmodule SymphonyElixir.Experience.WorkbenchAdapter do
  @moduledoc """
  Provider-owned issue reads and writes for the workbench.

  The orchestrator keeps depending only on the read callbacks in
  `SymphonyElixir.Tracker`. Everything the workbench needs to *display* or
  *write* an issue goes through this behaviour instead, so no ticket business
  rule is copied into the scheduler and an unsupported capability is reported as
  unsupported rather than silently faked.
  """

  alias SymphonyElixir.Tracker.Issue

  @typedoc "A capability the configured provider actually offers right now."
  @type capability :: %{name: String.t(), available: boolean(), reason: String.t() | nil}

  @typedoc "One native workflow state as the provider reports it."
  @type state_option :: %{
          id: String.t(),
          name: String.t(),
          display_column: String.t(),
          active: boolean(),
          terminal: boolean()
        }

  @type metadata :: %{
          provider: String.t(),
          provider_project_id: String.t(),
          states: [state_option()],
          assignees: [%{id: String.t(), name: String.t()}],
          labels: [%{id: String.t(), name: String.t()}],
          capabilities: [capability()],
          fetched_at: String.t(),
          stale: boolean()
        }

  @type write_result :: {:ok, map()} | {:error, atom(), map()}

  @callback capabilities() :: [capability()]
  @callback metadata(keyword()) :: {:ok, metadata()} | {:error, atom(), map()}
  @callback list_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, atom(), map()}
  @callback get_issue(String.t(), keyword()) :: {:ok, Issue.t()} | {:error, atom(), map()}
  @callback create_issue(map(), keyword()) :: write_result()
  @callback transition(String.t(), String.t(), keyword()) :: write_result()
  @callback validate_metadata(keyword()) :: :ok | {:error, atom(), map()}
  @callback find_operation_marker(String.t(), keyword()) :: {:ok, map() | nil} | {:error, atom(), map()}
  @callback get_workpad(String.t(), keyword()) :: {:ok, nil | map()} | {:error, atom(), map()}
  @callback update_workpad_plan(String.t(), map(), keyword()) :: write_result()
  @callback comment(String.t(), String.t(), keyword()) :: write_result()
  @callback secret_environment_names() :: [String.t()]

  @optional_callbacks validate_metadata: 1,
                      find_operation_marker: 2,
                      get_workpad: 2,
                      update_workpad_plan: 3

  @spec capability(String.t(), boolean(), String.t() | nil) :: capability()
  def capability(name, available, reason \\ nil) do
    %{name: name, available: available, reason: reason}
  end

  @doc """
  The capability names the workbench understands. A provider that omits one is
  reported as unsupported, never as temporarily broken.
  """
  @spec known_capabilities() :: [String.t()]
  def known_capabilities do
    [
      "read",
      "create_issue",
      "comment",
      "change_state",
      "pause",
      "resume",
      "workpad",
      "native_url"
    ]
  end
end
