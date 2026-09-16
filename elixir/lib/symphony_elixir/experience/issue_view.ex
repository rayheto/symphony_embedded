defmodule SymphonyElixir.Experience.IssueView do
  @moduledoc """
  The workbench's read model of one issue.

  The orchestrator keeps its own `SymphonyElixir.Tracker.Issue`; this struct is
  the provider projection the workbench displays, including the display column
  derived from provider metadata. Keeping them separate means the board can gain
  display fields without widening the scheduler's view of an issue.
  """

  alias SymphonyElixir.Experience.DisplayMapping
  alias SymphonyElixir.Tracker.Issue

  @enforce_keys [:id, :identifier, :native_state, :display_column]
  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :native_state,
    :display_column,
    :assignee,
    :url,
    :provider,
    :provider_id,
    :provider_version,
    :revision,
    :created_at,
    :updated_at,
    capabilities: [],
    labels: []
  ]

  @type t :: %__MODULE__{}

  @doc """
  Project a tracker issue into a display view.

  `state_options` is the provider metadata state list; a state the metadata does
  not describe still produces a view, landing in the "Other" column so it stays
  visible instead of silently disappearing from the board.
  """
  @spec from_tracker(Issue.t(), [map()], keyword()) :: t()
  def from_tracker(%Issue{} = issue, state_options, opts \\ []) do
    display_states = Keyword.get(opts, :display_states, [])
    provider = Keyword.get(opts, :provider, "unknown")

    column = column_for(issue.state, state_options, display_states)

    %__MODULE__{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      native_state: issue.state,
      display_column: column,
      assignee: issue.assignee_id,
      url: issue.url,
      provider: provider,
      provider_id: issue.id,
      provider_version: provider_version(issue),
      revision: Keyword.get(opts, :revision, 1),
      created_at: issue.created_at,
      updated_at: issue.updated_at,
      labels: issue.labels || [],
      capabilities: Keyword.get(opts, :capabilities, [])
    }
  end

  @doc """
  Render the view as the wire shape defined by `contracts/openapi.yaml`.

  `revision` is the local projection revision, which only advances when a
  provider-visible field actually changed.
  """
  @spec to_wire(t(), String.t()) :: map()
  def to_wire(%__MODULE__{} = view, project_id) do
    %{
      "id" => view.id,
      "project_id" => project_id,
      "revision" => view.revision,
      "created_at" => iso(view.created_at),
      "updated_at" => iso(view.updated_at),
      "identifier" => view.identifier,
      "provider" => view.provider,
      "provider_id" => view.provider_id,
      "provider_version" => view.provider_version,
      "title" => view.title,
      "description" => view.description || "",
      "native_state" => view.native_state,
      "display_column" => view.display_column,
      "assignee" => view.assignee,
      "labels" => view.labels,
      "url" => view.url,
      "capabilities" => view.capabilities
    }
  end

  @doc "Match one issue view against the board filters."
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{} = view, filters) do
    Enum.all?(filters, fn {key, value} -> matches_filter?(view, key, value) end)
  end

  defp matches_filter?(_view, _key, value) when value in [nil, ""], do: true

  defp matches_filter?(view, :q, value) do
    needle = String.downcase(value)
    haystack = "#{view.identifier} #{view.title}" |> String.downcase()
    String.contains?(haystack, needle)
  end

  defp matches_filter?(view, :state, value), do: view.native_state == value
  defp matches_filter?(view, :column, value), do: view.display_column == value
  defp matches_filter?(view, :assignee, value), do: view.assignee == value
  defp matches_filter?(_view, _key, _value), do: true

  defp column_for(nil, _state_options, _display_states), do: DisplayMapping.other_column()

  defp column_for(state, state_options, display_states) do
    case Enum.find(state_options, fn option -> Map.get(option, :name) == state end) do
      nil ->
        DisplayMapping.column_for(state, false, false, display_states)

      option ->
        Map.get(option, :display_column) ||
          DisplayMapping.column_for(
            state,
            Map.get(option, :active, false),
            Map.get(option, :terminal, false),
            display_states
          )
    end
  end

  defp provider_version(%Issue{updated_at: nil}), do: "unknown"

  defp provider_version(%Issue{updated_at: updated_at}) do
    updated_at |> DateTime.to_unix(:microsecond) |> Integer.to_string()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(value), do: value
end
