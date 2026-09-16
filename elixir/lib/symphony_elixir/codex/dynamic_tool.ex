defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter and to the
  workbench's engineering tools.

  Engineering tools are appended to the provider's tool set, never substituted
  for it, so a turn that used `linear_graphql` before keeps using it.
  """

  alias SymphonyElixir.Experience.AgentTools
  alias SymphonyElixir.Tracker

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    case Map.get(binding, :engineering) do
      %{tool_specs: specs} = engineering when is_list(specs) ->
        if tool in Enum.map(specs, & &1["name"]) do
          AgentTools.execute(tool, arguments, engineering, opts)
        else
          Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
        end

      _absent ->
        Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
    end
  end

  @spec bind(keyword()) :: map()
  def bind(opts \\ []) do
    provider = Tracker.bind_agent_tools()
    engineering = AgentTools.bind(opts)

    Map.merge(provider, %{tool_specs: provider.tool_specs ++ engineering.tool_specs, engineering: engineering})
  end
end
