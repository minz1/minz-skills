# Copyright (c) 2026 minz1
"""Pilot tests for the Textual dashboard."""

import calendar
import time
from collections.abc import Awaitable, Callable
from pathlib import Path

import app
import model
import pytest
from conftest import MakeRun
from rich.text import Text
from textual.pilot import Pilot
from textual.widgets import RichLog

NOW = float(calendar.timegm((2026, 10, 23, 15, 0, 0, 0, 0, 0)))
Sessions = Callable[[], Awaitable[dict[str, Path]]]


def iso(t: float) -> str:
    """Format a UTC stamp as the runner does."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def register(home: Path, *repos: Path) -> None:
    """Write the run registry."""
    reg = home / ".config" / "autopilot" / "repos"
    reg.parent.mkdir(parents=True, exist_ok=True)
    reg.write_text("".join(f"{r}\n" for r in repos))


def live(*repos: Path) -> Sessions:
    """Fake the tmux probe with these repos live."""

    async def sessions() -> dict[str, Path]:
        return {f"autopilot-{r.name}": r for r in repos}

    return sessions


def repo_of(run_dir: Path) -> Path:
    """Return a fixture run dir's repo."""
    return run_dir.parents[2]


def working_run(make_run: MakeRun, name: str, events: int = 3, plan: str = "session-cap: 9\n") -> Path:
    """Build a run whose session 1 is running with a few stream events."""
    lines = [
        {
            "type": "assistant",
            "timestamp": "2026-10-23T14:59:00Z",
            "parent_tool_use_id": "t" if i % 3 == 2 else None,
            "message": {"content": [{"type": "text", "text": f"line {i}"}]},
        }
        for i in range(events)
    ]
    log = f"{iso(NOW - 120)} session=1 start mode=continue\n"
    return make_run(name, plan=plan, log=log, sessions={1: lines})


def dash(home: Path, sessions: Sessions | None = None) -> app.Dash:
    """Make a dash with a fixed clock."""
    return app.Dash(home=home, clock=lambda: NOW, sessions=sessions or live())


async def settle(pilot: Pilot[None]) -> None:
    """Wait for the refresh worker and the redraw after it."""
    await pilot.app.workers.wait_for_complete()
    await pilot.pause()


def panes(d: app.Dash) -> list[app.RunPane]:
    """List the run panes in order."""
    return list(d.query(app.RunPane))


def log_text(pane: app.RunPane) -> list[str]:
    """Return a pane's stream lines as text."""
    return [line.text for line in pane.query_one(RichLog).lines]


async def test_app_starts_and_quits(isolated: Path) -> None:
    """Pressing q quits the app."""
    d = dash(isolated)
    async with d.run_test() as pilot:
        await pilot.press("q")
    assert not d.is_running


async def test_grid_columns(isolated: Path, make_run: MakeRun) -> None:
    """Two columns from 160 wide, one below, following resizes."""
    a, b = repo_of(working_run(make_run, "a")), repo_of(working_run(make_run, "b"))
    register(isolated, a, b)
    for width, two in ((160, True), (159, False)):
        d = dash(isolated, live(a, b))
        async with d.run_test(size=(width, 40)) as pilot:
            await settle(pilot)
            p = panes(d)
            assert (p[0].region.y == p[1].region.y) is two, width
            if not two:
                await pilot.resize_terminal(200, 40)
                await pilot.pause()
                p = panes(d)
                assert p[0].region.y == p[1].region.y


async def test_usage_bar_visible_200x50(isolated: Path, make_run: MakeRun) -> None:
    """The usage bar sits inside the screen."""
    a = repo_of(working_run(make_run, "a"))
    register(isolated, a)
    d = dash(isolated, live(a))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        bar = d.query_one(app.UsageBar)
        assert bar.region.height == 1
        assert d.screen.region.contains_region(bar.region)


async def test_focus_start_and_keys(isolated: Path, make_run: MakeRun) -> None:
    """Pane 1 starts focused; digits and Tab move focus and the marker follows at once."""
    a, b = repo_of(working_run(make_run, "a")), repo_of(working_run(make_run, "b"))
    register(isolated, a, b)
    d = dash(isolated, live(a, b))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        p = panes(d)
        assert p[0].has_focus_within
        await pilot.press("2")
        assert p[1].has_focus_within
        assert "◆" in p[1].head_text.plain
        assert "◆" not in p[0].head_text.plain
        await pilot.press("shift+tab")
        assert p[0].has_focus_within
        assert "◆" in p[0].head_text.plain
        await pilot.press("tab")
        assert p[1].has_focus_within


async def test_toggles(isolated: Path, make_run: MakeRun) -> None:
    """S hides subagent lines in the focused pane only."""
    a, b = repo_of(working_run(make_run, "a", 6)), repo_of(working_run(make_run, "b", 6))
    register(isolated, a, b)
    d = dash(isolated, live(a, b))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        p = panes(d)
        assert any("│ " in t for t in log_text(p[0]))
        await pilot.press("s")
        assert not any("│ " in t for t in log_text(p[0]))
        assert any("│ " in t for t in log_text(p[1]))
        await pilot.press("s")
        assert any("│ " in t for t in log_text(p[0]))


async def test_finished_hidden_until_a(isolated: Path, make_run: MakeRun) -> None:
    """Finished runs show only after a."""
    a = repo_of(working_run(make_run, "a"))
    done = repo_of(make_run("done", plan="session-cap: 5\n", log=f"{iso(NOW)} stopped: done\n"))
    register(isolated, a, done)
    d = dash(isolated, live(a))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        assert [p.ref.repo.name for p in panes(d)] == ["a"]
        await pilot.press("a")
        await settle(pilot)
        assert [p.ref.repo.name for p in panes(d)] == ["a", "done"]
        state = panes(d)[1].state
        assert state is not None
        assert state.st == "done"


async def test_missing_repo_pane(isolated: Path, tmp_path: Path, make_run: MakeRun) -> None:
    """A registered repo that is gone shows as missing after a."""
    a = repo_of(working_run(make_run, "a"))
    register(isolated, a, tmp_path / "gone")
    d = dash(isolated, live(a))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        assert len(panes(d)) == 1
        await pilot.press("a")
        await settle(pilot)
        gone = panes(d)[1]
        assert gone.state is not None
        assert gone.state.st == "missing"
        assert "missing" in gone.head_text.plain


async def test_unreadable_plan_red_pane(isolated: Path, make_run: MakeRun) -> None:
    """A plan.md that can't be read gives a red pane."""
    run_dir = working_run(make_run, "a")
    (run_dir / "plan.md").unlink()
    (run_dir / "plan.md").mkdir()
    register(isolated, repo_of(run_dir))
    d = dash(isolated, live(repo_of(run_dir)))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        p = panes(d)[0]
        assert p.state is not None
        assert p.state.st == "needs"
        assert "unreadable plan.md" in p.head_text.plain


async def test_small_terminal_many_runs(isolated: Path, make_run: MakeRun) -> None:
    """Eight runs at 80x24 keep 12-row panes, scroll, and keep the usage bar."""
    repos = [repo_of(working_run(make_run, f"r{i}")) for i in range(8)]
    register(isolated, *repos)
    d = dash(isolated, live(*repos))
    async with d.run_test(size=(80, 24)) as pilot:
        await settle(pilot)
        p = panes(d)
        assert len(p) == 8
        assert all(x.outer_size.height >= 12 for x in p)
        assert d.screen.region.contains_region(d.query_one(app.UsageBar).region)
        await pilot.press("8")
        await pilot.pause()
        assert p[7].has_focus_within
        assert d.screen.region.contains_region(d.query_one(app.UsageBar).region)


async def test_markup_like_text_renders(isolated: Path, make_run: MakeRun) -> None:
    """Text that looks like markup in names and items renders literally."""
    plan = "session-cap: 9\n## Owner\n- [/bold] boom [red]\n"
    log = f"{iso(NOW)} session=1 start\n"
    run_dir = make_run("x[bold]y", plan=plan, log=log, board={"p[red]z.md": "- p-1 → x: [/q]\n"})
    register(isolated, repo_of(run_dir))
    d = dash(isolated, live(repo_of(run_dir)))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        assert d.is_running
        assert "x[bold]y" in panes(d)[0].head_text.plain
        assert "[/q]" in d.query_one(app.BoardStrip).text.plain


async def test_one_run_failure_contained(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """One run failing to refresh goes red and logs; the others still update."""
    good, bad = repo_of(working_run(make_run, "good")), repo_of(working_run(make_run, "bad"))
    register(isolated, good, bad)
    real = model.pane_state

    def flaky(
        run: tuple[model.RunRef, model.RunFiles],
        now: float,
        mtime: float | None,
        git: str,
        alive: Callable[[str], bool],
    ) -> model.PaneState:
        if run[0].repo == bad:
            msg = "boom [/x]"
            raise RuntimeError(msg)
        return real(run, now, mtime, git, alive)

    monkeypatch.setattr(model, "pane_state", flaky)
    d = dash(isolated, live(good, bad))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        g, b = panes(d)
        assert g.state is not None
        assert g.state.label.startswith("WORKING s1")
        assert b.state is not None
        assert b.state.st == "needs"
        assert "boom [/x]" in b.head_text.plain
    assert "boom [/x]" in (isolated / ".cache" / "autopilot" / "dash.log").read_text()


async def test_key_budget(isolated: Path, make_run: MakeRun) -> None:
    """A toggle redraws within 150 ms with four 500-event panes."""
    repos = [repo_of(working_run(make_run, f"r{i}", 500)) for i in range(4)]
    register(isolated, *repos)
    d = dash(isolated, live(*repos))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)

        async def timed(key: str) -> float:
            best = 1e9
            for _ in range(3):
                t0 = time.perf_counter()
                await pilot.press(key)
                await pilot.pause()
                best = min(best, time.perf_counter() - t0)
            return best

        base = await timed("z")
        assert len(log_text(panes(d)[0])) > 300
        assert await timed("s") - base < 0.15


def test_head_line_is_plain_text() -> None:
    """Header text is a Rich Text built from plain strings, never markup."""
    head = app.head_line(1, "a[/b]", "x", focused=True)
    assert isinstance(head, Text)
    assert head.plain == "1  ◆ a[/b] · x"
