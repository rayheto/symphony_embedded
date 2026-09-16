defmodule SymphonyElixir.Experience.IssueViewTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Experience.{Cursor, IssueView}
  alias SymphonyElixir.Tracker.Issue

  @columns ["待办", "进行中", "待审阅", "已完成"]

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-1",
        native_ref: %{"linear" => "issue-1"},
        identifier: "EMB-42",
        title: "修复显示画面偶发撕裂",
        description: "连续切换画面时出现局部撕裂。",
        state: "In Progress",
        url: "https://example.invalid/EMB-42",
        assignee_id: "Driver Agent",
        labels: ["调查中"],
        created_at: ~U[2026-09-14 10:00:00Z],
        updated_at: ~U[2026-09-14 10:36:00Z]
      },
      attrs
    )
  end

  defp option(name, column, active, terminal) do
    %{name: name, display_column: column, active: active, terminal: terminal}
  end

  test "projects a tracker issue into a display view" do
    view =
      IssueView.from_tracker(issue(), [option("In Progress", "进行中", true, false)],
        display_states: @columns,
        provider: "linear"
      )

    assert view.id == "issue-1"
    assert view.identifier == "EMB-42"
    assert view.native_state == "In Progress"
    assert view.display_column == "进行中"
    assert view.assignee == "Driver Agent"
    assert view.provider == "linear"
    assert view.provider_version == "1789382160000000"
    assert view.labels == ["调查中"]
    assert view.revision == 1
  end

  test "maps a state the metadata omits by its own flags rather than dropping it" do
    view = IssueView.from_tracker(issue(%{state: "Mystery"}), [], display_states: @columns)

    # Metadata does not describe "Mystery", so it cannot be active or terminal;
    # the review column keeps it visible instead of inventing a board column.
    assert view.display_column == "待审阅"
  end

  test "keeps a state visible when no configured column can hold it" do
    view = IssueView.from_tracker(issue(%{state: "Mystery"}), [], display_states: ["Alpha", "Omega"])

    assert view.display_column == "Other"
  end

  test "handles an issue with no native state at all" do
    view = IssueView.from_tracker(issue(%{state: nil}), [], display_states: @columns)

    assert view.display_column == "Other"
  end

  test "reports an unknown provider version when the provider gave no timestamp" do
    view = IssueView.from_tracker(issue(%{updated_at: nil}), [], display_states: @columns)

    assert view.provider_version == "unknown"
  end

  test "renders the wire shape required by the openapi contract" do
    view = IssueView.from_tracker(issue(), [option("In Progress", "进行中", true, false)], display_states: @columns)
    wire = IssueView.to_wire(view, "embedded-lab")

    assert wire["project_id"] == "embedded-lab"
    assert wire["provider_id"] == "issue-1"
    assert wire["created_at"] == "2026-09-14T10:00:00Z"
    assert wire["description"] == "连续切换画面时出现局部撕裂。"
    assert wire["display_column"] == "进行中"
    assert wire["labels"] == ["调查中"]
    assert wire["capabilities"] == []

    assert Map.keys(wire) |> Enum.sort() ==
             ~w(assignee capabilities created_at description display_column id identifier labels native_state project_id provider provider_id provider_version revision title updated_at url)
             |> Enum.sort()
  end

  test "keeps a null description as an empty string on the wire" do
    view = IssueView.from_tracker(issue(%{description: nil}), [], display_states: @columns)

    assert IssueView.to_wire(view, "p")["description"] == ""
  end

  test "matches the board filters" do
    view = IssueView.from_tracker(issue(), [option("In Progress", "进行中", true, false)], display_states: @columns)

    assert IssueView.matches?(view, %{})
    assert IssueView.matches?(view, %{q: "EMB-42"})
    assert IssueView.matches?(view, %{q: "偶发撕裂"})
    refute IssueView.matches?(view, %{q: "EMB-99"})
    assert IssueView.matches?(view, %{state: "In Progress"})
    refute IssueView.matches?(view, %{state: "Todo"})
    assert IssueView.matches?(view, %{column: "进行中"})
    refute IssueView.matches?(view, %{column: "待办"})
    assert IssueView.matches?(view, %{assignee: "Driver Agent"})
    refute IssueView.matches?(view, %{assignee: "Someone"})
    assert IssueView.matches?(view, %{unknown_filter: "anything"})
    assert IssueView.matches?(view, %{q: nil, state: ""})
  end

  test "derives the display column from the state flags when metadata omits one" do
    view = IssueView.from_tracker(issue(), [%{name: "In Progress", active: true, terminal: false}], display_states: @columns)

    assert view.display_column == "进行中"

    plain = IssueView.from_tracker(issue(), [])
    assert plain.display_column == "Other"
  end

  test "passes through a timestamp the provider already formatted" do
    view = IssueView.from_tracker(issue(%{created_at: "2026-09-14T10:00:00Z"}), [])

    assert IssueView.to_wire(view, "p")["created_at"] == "2026-09-14T10:00:00Z"
  end

  test "cursor round-trips and expires when the query changes" do
    encoded = Cursor.encode(%{"project_id" => "p", "filters" => "abc", "offset" => 50})

    assert {:ok, decoded} = Cursor.decode(encoded)
    assert decoded["offset"] == 50
    assert :ok = Cursor.validate(decoded, %{"project_id" => "p", "filters" => "abc"})

    assert {:error, :cursor_expired, %{changed: ["filters"]}} =
             Cursor.validate(decoded, %{"project_id" => "p", "filters" => "other"})
  end

  test "decodes an absent cursor as the first page" do
    assert Cursor.decode(nil) == {:ok, %{}}
  end

  test "rejects a cursor that is not a decodable object" do
    assert {:error, :invalid_cursor, _} = Cursor.decode("not-base64!!")
    assert {:error, :invalid_cursor, _} = Cursor.decode(Base.url_encode64("[1,2,3]", padding: false))
    assert {:error, :invalid_cursor, _} = Cursor.decode(1234)
  end

  test "fingerprints a filter set independently of key order" do
    assert Cursor.fingerprint(%{q: "a", state: nil}) == Cursor.fingerprint(%{state: "", q: "a"})
    refute Cursor.fingerprint(%{q: "a"}) == Cursor.fingerprint(%{q: "b"})
  end
end
