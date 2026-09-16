defmodule SymphonyElixir.Experience.DisplayMappingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Experience.DisplayMapping

  @columns ["待办", "进行中", "待审阅", "已完成"]
  @english_columns ["Todo", "In Progress", "Human Review", "Done"]

  test "keeps a native state that is already a configured column" do
    assert DisplayMapping.column_for("进行中", true, false, @columns) == "进行中"
    assert DisplayMapping.column_for("In Progress", true, false, @english_columns) == "In Progress"
  end

  test "maps an unknown active state to the configured active column" do
    assert DisplayMapping.column_for("Rework", true, false, @english_columns) == "In Progress"
  end

  test "maps an unknown terminal state to the configured terminal column" do
    assert DisplayMapping.column_for("Cancelled", false, true, @english_columns) == "Done"
    assert DisplayMapping.column_for("已取消", false, true, @columns) == "已完成"
  end

  test "maps an unknown non-active non-terminal state to the review column" do
    assert DisplayMapping.column_for("Paused", false, false, @english_columns) == "Human Review"
    assert DisplayMapping.column_for("已暂停", false, false, @columns) == "待审阅"
  end

  test "keeps an unmappable state visible in the catch-all column" do
    assert DisplayMapping.column_for("Weird", true, false, ["Alpha", "Omega"]) == DisplayMapping.other_column()
    assert DisplayMapping.column_for("Weird", false, false, []) == DisplayMapping.other_column()
  end

  test "sorts by the configured column order then identifier" do
    issues = [
      %{display_column: "已完成", identifier: "EMB-35"},
      %{display_column: "待办", identifier: "EMB-46"},
      %{display_column: "待办", identifier: "EMB-43"},
      %{display_column: "Other", identifier: "EMB-99"}
    ]

    assert Enum.map(DisplayMapping.sort_by_column(issues, @columns), & &1.identifier) ==
             ["EMB-43", "EMB-46", "EMB-35", "EMB-99"]
  end

  test "counts only configured columns plus columns that actually hold rows" do
    issues = [
      %{display_column: "待办"},
      %{display_column: "待办"},
      %{display_column: "Other"}
    ]

    assert DisplayMapping.count_by_column(issues, @columns) == [{"待办", 2}, {"进行中", 0}, {"待审阅", 0}, {"已完成", 0}, {"Other", 1}]
  end
end
