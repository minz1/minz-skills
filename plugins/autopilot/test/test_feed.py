# Copyright (c) 2026 minz1
"""Tests for the since-you-looked feed."""

import calendar
import time
from pathlib import Path

import feed
import model
import pytest
import stream
from conftest import MakeRun


def ref_of(run_dir: Path) -> model.RunRef:
    """Wrap a fixture run dir."""
    return model.RunRef(run_dir.parents[2], run_dir, live=False, missing=False)


def events(run_dirs: list[Path], boards: list[Path] | None = None, result: str = "") -> list[feed.FeedEvent]:
    """Build the feed for fixture runs."""
    runs = [(ref_of(d), model.load_files(d)) for d in run_dirs]
    return feed.feed_events(runs, boards or [], lambda _p: result)


def utc(stamp: str) -> float:
    """Parse a UTC stamp in seconds form."""
    return float(calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")))


def test_session_end_line(make_run: MakeRun) -> None:
    """A session end shows its exit, detail and the first result line."""
    log = (
        '2026-10-23T14:00:00Z session=7 end exit=WAIT detail="45 pid=1" weekly=0.2\n'
        '2026-10-23T14:05:00Z session=8 end exit=STOP detail="need x" weekly=0.2\n'
    )
    got = events([make_run("r", log=log)], result="\n\n  did the thing\nAUTOPILOT: WAIT 45")
    assert [(e.at, e.who, e.body.plain) for e in got] == [
        (utc("2026-10-23T14:00:00Z"), "r", "s7 WAIT 45 pid=1  did the thing"),
        (utc("2026-10-23T14:05:00Z"), "r", "s8 STOP need x  did the thing"),
    ]
    assert got[0].body.style != "red"
    assert got[1].body.style == "red"
    for word in ("crash", "killed", "nowait", "limit"):
        d = make_run(word, log=f'2026-10-23T14:00:00Z session=1 end exit={word} detail=""\n')
        assert events([d])[0].body.style == "red", word


def test_runner_lines(make_run: MakeRun) -> None:
    """Runner events show; session starts don't."""
    log = (
        "2026-10-23T14:00:00Z session=1 start mode=continue checkpoint=abc\n"
        "2026-10-23T14:01:00Z woke reason=note after=3s\n"
        "2026-10-23T14:02:00Z upgrade 1.0 -> 1.1\n"
        "2026-10-23T14:03:00Z stopped: done\n"
        "2026-10-23T14:03:00Z notify stopped: done\n"
        "2026-10-23T14:04:00Z runner start version=1.1\n"
    )
    got = [e.body for e in events([make_run("r", log=log)])]
    assert [b.plain for b in got] == [
        "woke reason=note after=3s",
        "upgrade 1.0 -> 1.1",
        "stopped: done",
        "notify stopped: done",
    ]
    assert [b.style for b in got] == ["dim", "dim", "red", "red"]


def test_timestamp_forms(tmp_path: Path, make_run: MakeRun) -> None:
    """Every stamp form lands at its time; unstamped lines stay out."""
    board = {
        "r.md": "- 2026-10-23T14:00Z r-1 → p: please\n- legacy post\n- r: runner stopped 2026-10-23T14:40:32Z: done\n",
        "p.md": "- 2026-10-23T13:59:49Z ack r-1: ok\n",
    }
    d = make_run(
        "r",
        owner_md="- 2026-10-23T02:57:41 legacy note\n- 2026-10-23T13:00:00Z new note\n",
        log_md="- owner item resolved: old\n- owner item resolved 2026-10-23T12:00:00Z: x (note 2)\n",
        board=board,
    )
    got = {e.body.plain: e for e in events([d], [tmp_path / "board"])}
    legacy = time.mktime((2026, 10, 23, 2, 57, 41, 0, 0, -1))
    assert got["you: note · legacy note"].at == legacy
    assert got["you: note · new note"].at == utc("2026-10-23T13:00:00Z")
    assert got["board · r-1 → p: please"].at == utc("2026-10-23T14:00:00Z")
    assert got["board · r-1 → p: please"].who == "r"
    assert got["board · ack r-1: ok"].at == utc("2026-10-23T13:59:49Z")
    assert got["board · runner stopped: done"].at == utc("2026-10-23T14:40:32Z")
    assert got["resolved · x (note 2)"].at == utc("2026-10-23T12:00:00Z")
    assert got["resolved · x (note 2)"].body.style == "green"
    assert len(got) == 6
    assert [e.at for e in got.values()] == sorted(e.at for e in got.values())


def test_owner_board_lines_skipped(tmp_path: Path, make_run: MakeRun) -> None:
    """A note --to shows once, from owner.md, not again from the board."""
    d = make_run(
        "r",
        owner_md="- 2026-10-23T13:59:49Z [to p] do x\n",
        board={"r.md": "- 2026-10-23T13:59:49Z owner → p: do x\n"},
    )
    got = events([d], [tmp_path / "board"])
    assert [(e.body.plain, e.body.style) for e in got] == [("you: note · [to p] do x", "magenta")]


def test_order_and_cap(make_run: MakeRun) -> None:
    """Events are oldest first and capped at the newest 500."""
    log = "".join(f"2026-10-23T{h:02}:{m:02}:00Z woke reason=t after=1s\n" for h in range(10, 20) for m in range(60))
    d1 = make_run("a", log=log)
    d2 = make_run("b", log="2026-10-23T09:00:00Z woke reason=t after=1s\n2026-10-23T23:00:00Z woke reason=t after=1s\n")
    got = events([d1, d2])
    assert len(got) == 500
    assert got[-1].who == "b"
    assert got[-1].at == utc("2026-10-23T23:00:00Z")
    assert [e.at for e in got] == sorted(e.at for e in got)


def test_result_cache(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Session results are re-read only when the file changes."""
    calls: list[Path] = []

    def fake(p: Path) -> str:
        calls.append(p)
        return "x"

    monkeypatch.setattr(stream, "session_result", fake)
    p = tmp_path / "1.jsonl"
    p.write_text("a\n")
    assert feed.cached_result(p) == "x"
    assert feed.cached_result(p) == "x"
    assert len(calls) == 1
    p.write_text("ab\n")
    feed.cached_result(p)
    assert len(calls) == 2
    assert feed.cached_result(tmp_path / "gone") == ""
