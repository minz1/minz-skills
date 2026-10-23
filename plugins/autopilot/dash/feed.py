# Copyright (c) 2026 minz1
"""The since-you-looked feed, built from runner logs, notes, log.md and boards."""

import re
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import model
import stream
from rich.text import Text

CAP = 500
LOG_LINE = re.compile(r"^(\S+Z) (.*)$")
END = re.compile(r'^session=(\d+) end exit=(\w+) detail="([^"]*)"')
RUNNER_EVENTS = ("woke ", "upgrade ", "stopped: ", "notify ", "stop --now")
RED_EXITS = ("STOP", "crash", "killed", "nowait", "limit")
NOTE = re.compile(r"^- (\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?Z?) (.*)$")
RESOLVED = re.compile(r"^(?:- )?owner item resolved (\S+Z): (.*)$")
BOARD_POST = re.compile(r"^- (\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?Z) (.*)$")
BOARD_STOP = re.compile(r"^- \S+: runner stopped (\S+Z): (.*)$")

_results: dict[Path, tuple[float, int, str]] = {}


@dataclass(frozen=True)
class FeedEvent:
    """One feed line: when, whose, and what."""

    at: float
    who: str
    body: Text


def cached_result(path: Path) -> str:
    """Return a session's result text, re-reading only when the file changed."""
    try:
        st = path.stat()
    except OSError:
        return ""
    hit = _results.get(path)
    if hit and hit[:2] == (st.st_mtime, st.st_size):
        return hit[2]
    text = stream.session_result(path)
    _results[path] = (st.st_mtime, st.st_size, text)
    return text


def first_line(text: str) -> str:
    """Return the first non-blank line, trimmed."""
    return next((ln.strip() for ln in text.splitlines() if ln.strip()), "")


def runner_events(ref: model.RunRef, log: list[str], result_of: Callable[[Path], str]) -> list[FeedEvent]:
    """Turn session ends and runner events into feed lines."""
    who = model.clean(ref.repo.name)
    out = []
    for line in log:
        m = LOG_LINE.match(line)
        at = model.parse_stamp(m.group(1)) if m else None
        if not m or at is None:
            continue
        body = model.clean(m.group(2))
        if e := END.match(body):
            summary = first_line(result_of(ref.run_dir / "sessions" / f"{e.group(1)}.jsonl"))[:140]
            head = " ".join(x for x in (f"s{e.group(1)}", e.group(2), e.group(3)) if x)
            text = f"{head}  {summary}" if summary else head
            out.append(FeedEvent(at, who, Text(text, style="red" if e.group(2) in RED_EXITS else "")))
        elif body.startswith(RUNNER_EVENTS):
            out.append(FeedEvent(at, who, Text(body, style="red" if body.startswith(("stopped", "notify")) else "dim")))
    return out


def stamped(lines: str, pattern: re.Pattern[str], who: str, label: str, style: str) -> list[FeedEvent]:
    """Turn lines whose stamp parses into feed lines with a label."""
    return [
        FeedEvent(at, who, Text(f"{label} · {model.clean(m.group(2))[:150]}", style=style))
        for line in lines.splitlines()
        if (m := pattern.match(line)) and (at := model.parse_stamp(m.group(1))) is not None
    ]


def note_events(ref: model.RunRef, files: model.RunFiles) -> list[FeedEvent]:
    """Turn owner notes and stamped resolutions into feed lines."""
    who = model.clean(ref.repo.name)
    return stamped(files.owner_md, NOTE, who, "you: note", "magenta") + stamped(
        files.log_md, RESOLVED, who, "resolved", "green"
    )


def board_events(board: Path) -> list[FeedEvent]:
    """Turn stamped board posts, answers and runner stops into feed lines."""
    out = []
    for f, lines in model.board_lines(board):
        who = model.clean(f.stem)
        for line in lines:
            if (m := BOARD_STOP.match(line)) and (at := model.parse_stamp(m.group(1))) is not None:
                out.append(FeedEvent(at, who, Text(f"board · runner stopped: {model.clean(m.group(2))}", style="red")))
            elif (m := BOARD_POST.match(line)) and not m.group(2).startswith("owner → "):
                at = model.parse_stamp(m.group(1))
                if at is not None:
                    out.append(FeedEvent(at, who, Text(f"board · {model.clean(m.group(2))[:160]}", style="cyan")))
    return out


def feed_events(
    runs: list[tuple[model.RunRef, model.RunFiles]],
    boards: list[Path],
    result_of: Callable[[Path], str],
) -> list[FeedEvent]:
    """Build the feed, oldest first, keeping the newest 500 events."""
    out: list[FeedEvent] = []
    for ref, files in runs:
        out += runner_events(ref, files.log, result_of) + note_events(ref, files)
    for board in dict.fromkeys(boards):
        out += board_events(board)
    return sorted(out, key=lambda e: e.at)[-CAP:]
