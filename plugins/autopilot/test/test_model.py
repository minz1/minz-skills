# Copyright (c) 2026 minz1
"""Tests for run discovery, state and parsing."""

import calendar
import time
from pathlib import Path

import model
from conftest import MakeRun

NOW = float(calendar.timegm((2026, 10, 23, 15, 0, 0, 0, 0, 0)))


def iso(t: float) -> str:
    """Format a UTC stamp as the runner does."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def live_ref(run_dir: Path) -> model.RunRef:
    """Wrap a fixture run dir as a live run."""
    return model.RunRef(run_dir.parents[2], run_dir, live=True, missing=False)


def dead_ref(run_dir: Path) -> model.RunRef:
    """Wrap a fixture run dir as a stopped run."""
    return model.RunRef(run_dir.parents[2], run_dir, live=False, missing=False)


def state(ref: model.RunRef, mtime: float | None = None, alive: set[str] | None = None) -> model.PaneState:
    """Compute a pane state at NOW."""
    files = model.load_files(ref.run_dir)
    return model.pane_state((ref, files), NOW, mtime, "main  ·  +0 unpushed", lambda p: p in (alive or set()))


def test_working_quiet_stalled(make_run: MakeRun) -> None:
    """Stream age decides working, quiet and stalled."""
    d = make_run("r", plan="session-cap: 60\n", log=f"{iso(NOW - 4000)} session=4 start mode=continue\n")
    got = [state(live_ref(d), NOW - age) for age in (60, 600, 4000)]
    assert [(s.st, s.label.split(" · active")[0]) for s in got] == [
        ("working", "WORKING s4"),
        ("quiet", "QUIET 10m · s4"),
        ("needs", "STALLED 66m silent · s4"),
    ]
    assert got[0].stream == d / "sessions" / "4.jsonl"


def test_wait_labels() -> None:
    """Every WAIT end form gets its condition-first label."""
    end = f"{iso(NOW - 300)} session=4 end exit=WAIT"

    def label(line: str, after: list[str] | None = None, alive: set[str] | None = None) -> str:
        return model.wait_label(line, after or [], NOW, lambda p: p in (alive or set()))

    assert label(f'{end} detail="20" weekly=0.2') == "WAITING next ≤15m"
    pids = f'{end} detail="190 pid=1,2,3" weekly=0.2'
    assert label(pids, alive={"1", "2", "3"}).startswith("WAITING on 3 pids (≤")
    assert label(pids, alive={"2"}).startswith("WAITING on pid 2 (≤")
    assert "wake due" in label(pids)
    acked = label(f'{end} detail="360 ack=a-14" weekly=0.2')
    assert acked == f"WAITING for ack a-14 (alert {model.hhmm(NOW - 300 + 360 * 60)}Z)"
    limit = f'{iso(NOW - 300)} session=4 end exit=limit detail="five_hour" weekly=0.2'
    assert label(limit) == "WAITING · usage limit"
    assert label(f'{end} detail="20" weekly=0.2', [f"{iso(NOW)} woke reason=note after=1s"]) == "WAITING"


def finished(make_run: MakeRun, tail: str, plan: str = "session-cap: 5\n") -> bool:
    """Decide finished for a stopped run whose log ends with tail."""
    d = make_run(
        "r", plan=plan, log=f"{iso(NOW - 60)} session=1 start\n{iso(NOW - 50)} session=1 end exit=DONE\n{tail}"
    )
    return model.is_finished(dead_ref(d), model.load_files(d))


def test_finished_table(make_run: MakeRun) -> None:
    """Only clean stop reasons with nothing left for the owner count as finished."""
    t = iso(NOW)
    for reason in ("done", "stop file", "session cap 2 reached; raise session-cap", "weekly usage 0.81"):
        assert finished(make_run, f"{t} stopped: {reason}\n"), reason
    for reason in ("owner needed: x", "two crashes"):
        assert not finished(make_run, f"{t} stopped: {reason}\n"), reason
    assert not finished(make_run, "")
    assert not finished(
        make_run, f'{t} stopped: done\n{t} session=2 start\n{t} session=2 end exit=killed detail="HUP"\n'
    )
    assert finished(make_run, f"{t} stopped: done\n{t} notify stopped: done\n")
    assert not finished(make_run, f"{t} stopped: done\n", "session-cap: 5\n## Owner\n- decide x\n")
    assert not finished(make_run, f"{t} stopped: done\n", "session-cap: 5\n- [!] 3. blocked\n")
    d = make_run("r2", log=f"{t} stopped: done\n")
    assert not model.is_finished(live_ref(d), model.load_files(d))


def test_live_run_uses_ap_rel(tmp_path: Path, make_run: MakeRun) -> None:
    """A live run targets its AP_REL dir even when a newer dir exists."""
    make_run("r", run="2026-10-22")
    make_run("r", run="2026-10-23")
    repo = tmp_path / "repos" / "r"
    refs = model.resolve_runs([repo], {"autopilot-r": repo}, {"autopilot-r": ".autopilot/runs/2026-10-22"})
    assert refs == [model.RunRef(repo, repo / ".autopilot/runs/2026-10-22", live=True, missing=False)]
    refs = model.resolve_runs([repo], {}, {})
    assert refs[0].run_dir.name == "2026-10-23"
    assert not refs[0].live


def test_unregistered_live_repo_included(tmp_path: Path, make_run: MakeRun) -> None:
    """A live session's repo shows even when it isn't registered."""
    make_run("a")
    make_run("b")
    a, b = tmp_path / "repos" / "a", tmp_path / "repos" / "b"
    refs = model.resolve_runs([a], {"autopilot-b": b}, {"autopilot-b": None})
    assert [(r.repo, r.live) for r in refs] == [(a, False), (b, True)]


def test_natural_order() -> None:
    """Digit runs compare as numbers."""
    names = ["2026-10-21-2", "2026-10-21-10", "2026-10-21"]
    assert max(names, key=model.natural_key) == "2026-10-21-10"
    assert sorted(names, key=model.natural_key) == ["2026-10-21", "2026-10-21-2", "2026-10-21-10"]


def test_missing_repo(tmp_path: Path) -> None:
    """A registered path that no longer exists is a missing run."""
    gone = tmp_path / "gone"
    refs = model.resolve_runs([gone], {}, {})
    assert len(refs) == 1
    assert refs[0].missing
    assert model.pane_state((refs[0], model.load_files(refs[0].run_dir)), NOW, None, "", bool).st == "missing"


def test_info_rows(make_run: MakeRun) -> None:
    """The four info rows carry the item, counts, history and notes."""
    plan = (
        "session-cap: 60\nowner-notes-applied: 4\nnow: 9\n## Queue\n- [x] 1. one\n- [c] 2. two\n- [p] 3. three\n"
        "- [ ] 4. four  after: 1\n- [ ] 9. nine  check: x\n## Owner\n- pick a\n- pick b\n"
    )
    log = (
        f'{iso(NOW - 3600)} session=1 end exit=NEXT detail="" weekly=0.2 peak_ctx=1000\n'
        f'{iso(NOW - 1800)} session=2 end exit=WAIT detail="5" weekly=0.2 peak_ctx=2000\n'
        f'{iso(NOW - 900)} session=3 end exit=NEXT detail="" weekly=0.2 peak_ctx=45000\n'
        f"{iso(NOW - 60)} session=4 start mode=continue\n"
    )
    d = make_run("r", plan=plan, log=log, owner_md="- a\n- b\n- c\n- d\n- e\n")
    rows = [t.plain for t in state(live_ref(d), NOW - 10).info]
    assert rows[0] == "item 9. nine"
    assert "1✓ 1c 1p 0✗ 2○" in rows[1]
    assert "work 2/60" in rows[1]
    assert "s4" in rows[1]
    assert rows[2].startswith("last N W N")
    assert "ctx 45k" in rows[2]
    assert "notes 4/5 (1 pending)" in rows[3]
    assert "owner 2" in rows[3]
    d = make_run("q", plan="- [x] 1. a\n- [ ] 2. b  waiting: c\n")
    rows = [t.plain for t in state(live_ref(d)).info]
    assert rows[0] == "item 2. b"
    assert "c " not in rows[1]
    assert "p " not in rows[1]


def test_owner_items_exact_heading() -> None:
    """Only an exact ## Owner heading holds owner items."""
    plan = "## Owner notes\n- not this\n## Owner\n- this\n\n## Handoff\n- nor this\n"
    assert model.owner_items(plan) == ["- this"]
    assert model.section(plan, "Owner") == ["- this"]


def test_open_requests(tmp_path: Path) -> None:
    """Open requests honour anchored answers and replaces."""
    b = tmp_path / "b"
    b.mkdir()
    (b / "a.md").write_text(
        "- a-1 → x: one\n- 2026-10-23T14:00Z a-2 → x: two\n- a-3 (replaces a-2) → x: three\n"
        "- a-4 → x: four\n- a-5 → x: five\n- a-6 → x: six\n- a-7 → x: seven\n- ack a-6: self\n"
    )
    (b / "x.md").write_text(
        "- ack a-1: ok\n- 2026-10-23T02:10Z nack a-4: no\n- still waiting on ack a-5\n- reject a-7: no\n"
    )
    got = model.open_requests(b)
    assert [r.id for r in got] == ["a-3", "a-5", "a-6"]
    assert got[0].to == "x"
    assert got[0].posted is None
    (b / "a.md").write_text("- 2026-10-23T14:00Z a-9 → x, y: hi\n")
    got = model.open_requests(b)
    assert got[0].posted == model.parse_stamp("2026-10-23T14:00Z")
    assert got[0].to == "x, y"


def test_parse_stamp_forms() -> None:
    """Every stamp form parses; no Z means local time."""
    base = calendar.timegm((2026, 10, 23, 14, 1, 40, 0, 0, 0))
    assert model.parse_stamp("2026-10-23T14:01:40.782Z") == base + 0.782
    assert model.parse_stamp("2026-10-23T14:01:37Z") == base - 3
    assert model.parse_stamp("2026-10-23T14:00Z") == base - 100
    assert model.parse_stamp("2026-10-23T02:57:41") == time.mktime((2026, 10, 23, 2, 57, 41, 0, 0, -1))
    assert model.parse_stamp("yesterday") is None
    assert model.parse_stamp("") is None


def usage_run(
    make_run: MakeRun, name: str, ceiling: str, points: list[tuple[float, float]]
) -> tuple[model.RunRef, model.RunFiles]:
    """Build a live run whose ends carry the given weekly points."""
    log = "".join(f'{iso(t)} session={i} end exit=NEXT detail="" weekly={w}\n' for i, (t, w) in enumerate(points))
    d = make_run(name, plan=f"weekly-ceiling: {ceiling}\n", log=log)
    return live_ref(d), model.load_files(d)


def test_burn(make_run: MakeRun) -> None:
    """The usage bar shows the rate and when each live run wraps."""
    assert model.burn([], None, NOW).plain == "usage: no data yet"
    runs = [usage_run(make_run, "r", "0.50", [(NOW - 7200, 0.20), (NOW, 0.26)])]
    text = model.burn(runs, None, NOW).plain
    assert "weekly 26%" in text
    assert "+3.0%/h" in text
    assert f"r wraps at 50% ~{model.hhmm(NOW + 0.24 / 0.03 * 3600)}Z" in text
    assert "r wraps at 40%" in model.burn(runs, 0.40, NOW).plain
    assert "(flat)" in model.burn([usage_run(make_run, "f", "0.5", [(NOW, 0.2)])], None, NOW).plain


def test_burn_soon_is_yellow(make_run: MakeRun) -> None:
    """A wrap under 3 h away is yellow."""
    runs = [usage_run(make_run, "r", "0.30", [(NOW - 7200, 0.20), (NOW, 0.26)])]
    text = model.burn(runs, None, NOW)
    assert any(s.style == "yellow" for s in text.spans)


def test_clean() -> None:
    """Control characters go; tab and newline stay."""
    assert model.clean("a\x1b[31mb\x07c\x9bd\te\nf\x7f") == "a[31mbcd\te\nf"


def test_unreadable_plan(make_run: MakeRun) -> None:
    """An unreadable plan.md is an error, not a crash."""
    d = make_run("r", plan="x\n")
    (d / "plan.md").unlink()
    (d / "plan.md").mkdir()
    files = model.load_files(d)
    assert files.error is not None
    assert files.error.startswith("unreadable plan.md: ")
    s = model.pane_state((dead_ref(d), files), NOW, None, "", bool)
    assert s.st == "needs"
    assert s.label.startswith("unreadable plan.md")


def test_board_of(tmp_path: Path) -> None:
    """The board header resolves ~ and only existing dirs."""
    home = tmp_path / "h"
    (home / ".autopilot" / "b").mkdir(parents=True)
    assert model.board_of("board: ~/.autopilot/b/\n", home) == home / ".autopilot" / "b"
    assert model.board_of("board: none\n", home) is None
    assert model.board_of("board: ~/nope\n", home) is None
    assert model.board_of("", home) is None
