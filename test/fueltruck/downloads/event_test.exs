defmodule Fueltruck.Downloads.EventTest do
  use ExUnit.Case, async: true

  alias Fueltruck.Downloads.Event

  test "parses a typed item milestone event" do
    e =
      Event.parse(
        ~s({"type":"item","id":450814997,"title":"CBA_A3","status":"downloaded","bytes":4840892})
      )

    assert e.type == "item"
    assert e.data["id"] == 450_814_997
    assert e.data["title"] == "CBA_A3"
    assert e.data["status"] == "downloaded"
  end

  test "parses depots_selected for the server app" do
    e = Event.parse(~s({"type":"depots_selected","bytes":5384415733,"count":2,"depots":[233781]}))
    assert e.type == "depots_selected"
    assert e.data["bytes"] == 5_384_415_733
    assert e.data["count"] == 2
  end

  test "JSON without a type is unknown" do
    assert Event.parse(~s({"foo":1})).type == "unknown"
  end

  test "non-JSON lines become log events keeping the raw text" do
    e = Event.parse("WARN could not persist refresh token")
    assert e.type == "log"
    assert e.raw == "WARN could not persist refresh token"
  end
end
