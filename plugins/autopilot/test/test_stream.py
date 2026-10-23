# Copyright (c) 2026 minz1
"""Tests for the incremental session stream reader."""

import json
from pathlib import Path
from typing import Any

import model
import stream


def line(content: list[dict[str, Any]], stamp: str | None = None) -> str:
    """Make one assistant stream-json line."""
    event: dict[str, Any] = {"type": "assistant", "message": {"content": content}}
    if stamp:
        event["timestamp"] = stamp
    return json.dumps(event) + "\n"


def text(t: str) -> str:
    """Make a text event line."""
    return line([{"type": "text", "text": t}])


def test_incremental(tmp_path: Path) -> None:
    """Appended lines become new events."""
    p = tmp_path / "1.jsonl"
    p.write_text(text("a"))
    r = stream.StreamReader()
    assert r.update(p) == "reset"
    assert len(r.events) == 1
    assert r.update(p) == "same"
    with p.open("a") as f:
        f.write(text("b") + text("c"))
    assert r.update(p) == "appended"
    assert [e.text for e in r.events] == ["a", "b", "c"]


def test_partial_line(tmp_path: Path) -> None:
    """Half a line waits until it is complete."""
    p = tmp_path / "1.jsonl"
    full = text("é done")
    raw = full.encode()
    p.write_bytes(raw[:10])
    r = stream.StreamReader()
    r.update(p)
    assert r.events == []
    with p.open("ab") as f:
        f.write(raw[10:])
    assert r.update(p) == "appended"
    assert [e.text for e in r.events] == ["é done"]


def test_reset_on_new_path(tmp_path: Path) -> None:
    """A new session path starts over."""
    a, b = tmp_path / "1.jsonl", tmp_path / "2.jsonl"
    a.write_text(text("a"))
    b.write_text(text("b"))
    r = stream.StreamReader()
    r.update(a)
    assert r.update(b) == "reset"
    assert [e.text for e in r.events] == ["b"]
    assert r.path == b


def test_malformed_skipped(tmp_path: Path) -> None:
    """Bad JSON and odd shapes are skipped."""
    p = tmp_path / "1.jsonl"
    p.write_text("not json\n[1]\n" + json.dumps({"type": "assistant", "message": None}) + "\n" + text("ok"))
    r = stream.StreamReader()
    r.update(p)
    assert [e.text for e in r.events] == ["ok"]


def test_missing_file(tmp_path: Path) -> None:
    """A stream that doesn't exist yet has no events."""
    r = stream.StreamReader()
    assert r.update(tmp_path / "none.jsonl") == "reset"
    assert r.events == []


def test_event_fields(tmp_path: Path) -> None:
    """Each content kind becomes the right event."""
    p = tmp_path / "1.jsonl"
    stamp = "2026-10-23T14:01:40.782Z"
    body = (
        line(
            [
                {"type": "text", "text": "one\n\n two\x1b[31m"},
                {"type": "thinking", "thinking": "secret"},
                {"type": "tool_use", "name": "Bash", "input": {"description": "list files", "command": "ls"}},
            ],
            stamp,
        )
        + json.dumps(
            {
                "type": "user",
                "parent_tool_use_id": "toolu_1",
                "message": {
                    "content": [
                        {"type": "tool_result", "is_error": True, "content": [{"type": "text", "text": "bad\nmore"}]},
                        {"type": "tool_result", "is_error": False, "content": "fine"},
                    ]
                },
            }
        )
        + "\n"
    )
    p.write_text(body)
    r = stream.StreamReader()
    r.update(p)
    at = model.parse_stamp(stamp)
    assert r.events == [
        stream.Event("text", sub=False, text="one", at=at),
        stream.Event("text", sub=False, text=" two[31m", at=at),
        stream.Event("think", sub=False, text="· thinking", at=at),
        stream.Event("tool", sub=False, text="▸ Bash list files", at=at),
        stream.Event("error", sub=True, text="✗ bad", at=None),
    ]


def test_cap_500(tmp_path: Path) -> None:
    """Only the last 500 events are kept."""
    p = tmp_path / "1.jsonl"
    p.write_text("".join(text(str(i)) for i in range(600)))
    r = stream.StreamReader()
    r.update(p)
    assert len(r.events) == 500
    assert r.events[0].text == "100"


def test_session_result(tmp_path: Path) -> None:
    """The last result event's text is the session result."""
    p = tmp_path / "1.jsonl"
    filler = text("x" * 70000)
    results = [json.dumps({"type": "result", "result": r}) + "\n" for r in ("first", "last\x07 one\nAUTOPILOT: NEXT")]
    p.write_text(results[0] + filler + results[1] + text("after"))
    assert stream.session_result(p) == "last one\nAUTOPILOT: NEXT"
    assert stream.session_result(tmp_path / "none") == ""
