defmodule SymphonyElixir.Experience.DisplayMapping do
  @moduledoc """
  Maps provider-native workflow states onto the workbench display columns.

  The four board columns are a *view*, not a second workflow. Native states stay
  owned by the tracker, so a state the display mapping does not recognise is
  surfaced explicitly instead of being guessed into a column.
  """

  @other_column "Other"

  @doc """
  Choose the display column for one native state.

  `display_states` is the operator-configured column list, in board order. A
  state whose name matches a column keeps its own name; otherwise the state's
  own `active`/`terminal` flags pick the closest configured column, and anything
  that fits none of them lands in `#{@other_column}` while staying visible.
  """
  @spec column_for(String.t(), boolean(), boolean(), [String.t()]) :: String.t()
  def column_for(name, active, terminal, display_states)
      when is_binary(name) and is_boolean(active) and is_boolean(terminal) and is_list(display_states) do
    cond do
      display_states == [] ->
        @other_column

      name in display_states ->
        name

      terminal ->
        Enum.find(display_states, @other_column, &terminal_column?/1)

      not active ->
        Enum.find(display_states, @other_column, &review_column?/1)

      true ->
        # An unrecognised *active* state is already in flight, so the last
        # configured active column is the honest projection: "Todo" would claim
        # work has not started when the provider says it has.
        display_states |> Enum.reverse() |> Enum.find(@other_column, &active_column?/1)
    end
  end

  @doc """
  Order issues by the configured column order, then by identifier, so a board
  renders deterministically even before any cache is warm.
  """
  @spec sort_by_column([map()], [String.t()]) :: [map()]
  def sort_by_column(issues, display_states) do
    order = Enum.with_index(display_states ++ [@other_column], fn name, index -> {name, index} end) |> Map.new()

    Enum.sort_by(issues, fn issue ->
      {Map.get(order, Map.get(issue, :display_column), length(display_states) + 1), Map.get(issue, :identifier) || ""}
    end)
  end

  @spec other_column() :: String.t()
  def other_column, do: @other_column

  @spec count_by_column([map()], [String.t()]) :: [{String.t(), non_neg_integer()}]
  def count_by_column(issues, display_states) do
    counts = Enum.frequencies_by(issues, &Map.get(&1, :display_column, @other_column))

    columns =
      (display_states ++ [@other_column])
      |> Enum.uniq()
      |> Enum.filter(fn column -> Map.get(counts, column, 0) > 0 or column in display_states end)

    Enum.map(columns, fn column -> {column, Map.get(counts, column, 0)} end)
  end

  # The configured column list is the operator's naming, so these predicates
  # only need to be right for the conventional board; anything else falls back
  # to `@other_column` and stays visible.
  defp terminal_column?(column), do: column in ["Done", "已完成", "Closed", "完成"]
  defp review_column?(column), do: column in ["Human Review", "待审阅", "Review", "Paused", "已暂停"]
  defp active_column?(column), do: column in ["In Progress", "进行中", "Todo", "待办"]
end
