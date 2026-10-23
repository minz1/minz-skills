# Copyright (c) 2026 minz1
"""Incremental reading of a session's stream-json file."""

import json
from pathlib import Path
from typing import Literal, NamedTuple

import model

CAP = 500
TAIL_BYTES = 65536
TOOL_KEYS = ("description", "command", "file_path", "pattern", "prompt", "url")


class Event(NamedTuple):
    """One line a pane can show."""

    kind: Literal["text", "think", "tool", "error"]
    sub: bool
    text: str
    at: float | None


def one_line(value: object) -> str:
    """Return the first line of a value, cleaned."""
    return model.clean(str(value)).replace("\t", " ").replace("\r", " ").split("\n")[0]


def result_text(body: object) -> str:
    """Flatten a tool result's content to text."""
    if isinstance(body, list):
        return " ".join(str(x.get("text", "")) for x in body if isinstance(x, dict))
    return str(body or "")


def content_events(c: dict[str, object], *, sub: bool, at: float | None) -> list[Event]:
    """Turn one message content block into events."""
    kind = c.get("type")
    if kind == "text":
        lines = model.clean(str(c.get("text", ""))).split("\n")
        return [Event("text", sub, ln.replace("\t", "  "), at) for ln in lines if ln.strip()]
    if kind == "thinking":
        return [Event("think", sub, "· thinking", at)]
    if kind == "tool_use":
        i = c.get("input")
        args = i if isinstance(i, dict) else {}
        detail = next((args[k] for k in TOOL_KEYS if k in args), "")
        return [Event("tool", sub, f"▸ {one_line(c.get('name', ''))} {one_line(detail)}".rstrip(), at)]
    if kind == "tool_result" and c.get("is_error") is True:
        return [Event("error", sub, f"✗ {one_line(result_text(c.get('content')))}", at)]
    return []


def parse_event(line: bytes) -> list[Event]:
    """Turn one stream-json line into events; anything malformed gives none."""
    try:
        e = json.loads(line)
    except ValueError:
        return []
    if not isinstance(e, dict) or e.get("type") not in ("assistant", "user"):
        return []
    msg = e.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, list):
        return []
    stamp = e.get("timestamp")
    at = model.parse_stamp(stamp) if isinstance(stamp, str) else None
    sub = e.get("parent_tool_use_id") is not None
    return [ev for c in content if isinstance(c, dict) for ev in content_events(c, sub=sub, at=at)]


class StreamReader:
    """Keeps the last events of one stream, reading only new bytes."""

    def __init__(self) -> None:
        """Start with no stream."""
        self.path: Path | None = None
        self.events: list[Event] = []
        self.offset = 0
        self.rest = b""

    def update(self, path: Path) -> Literal["same", "appended", "reset"]:
        """Read what was added to the stream since the last call."""
        result: Literal["same", "appended", "reset"] = "same"
        if path != self.path:
            self.path, self.events, self.offset, self.rest = path, [], 0, b""
            result = "reset"
        try:
            with path.open("rb") as f:
                if f.seek(0, 2) < self.offset:
                    self.events, self.offset, self.rest, result = [], 0, b"", "reset"
                f.seek(self.offset)
                chunk = f.read()
        except OSError:
            return result
        self.offset += len(chunk)
        *lines, self.rest = (self.rest + chunk).split(b"\n")
        new = [ev for ln in lines for ev in parse_event(ln)]
        if not new:
            return result
        self.events = (self.events + new)[-CAP:]
        return "reset" if result == "reset" else "appended"


def session_result(path: Path) -> str:
    """Return the text of the session's last result event."""
    try:
        with path.open("rb") as f:
            f.seek(max(0, f.seek(0, 2) - TAIL_BYTES))
            tail = f.read().split(b"\n")
    except OSError:
        return ""
    for line in reversed(tail):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("type") == "result":
            return model.clean(str(e.get("result") or ""))
    return ""
