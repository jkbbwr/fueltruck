defmodule Fueltruck.Downloads.EventTest do
  use ExUnit.Case, async: true

  alias Fueltruck.Downloads.Event

  test "parses fraction progress and workshop id aliases" do
    e = Event.parse(~s({"workshop_id": 123, "progress": 0.42, "status": "downloading"}))
    assert e.id == "123"
    assert e.progress == 42.0
    assert e.status == "downloading"
  end

  test "parses percentage progress and clamps" do
    e = Event.parse(~s({"id": "5", "percent": 150}))
    assert e.progress == 100.0
  end

  test "non-JSON lines become plain message events" do
    e = Event.parse("Update state (0x61) downloading")
    assert e.id == nil
    assert e.message == "Update state (0x61) downloading"
    assert e.raw == "Update state (0x61) downloading"
  end
end
