# Copyright (c) 2026 minz1
"""Pilot tests for the Textual dashboard."""

import calendar
import gc
import logging
import time
from collections.abc import Awaitable, Callable
from pathlib import Path

import actions
import app
import model
import probe
import pytest
from conftest import MakeRun
from rich.text import Text
from textual.command import CommandList
from textual.pilot import Pilot
from textual.widgets import (
    Button,
    ContentSwitcher,
    Input,
    Label,
    ListView,
    Markdown,
    RadioButton,
    RichLog,
    Static,
    TabbedContent,
)

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
    """Pane 1 starts focused; digits and Tab move focus."""
    a, b = repo_of(working_run(make_run, "a")), repo_of(working_run(make_run, "b"))
    register(isolated, a, b)
    d = dash(isolated, live(a, b))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        p = panes(d)
        assert p[0].has_focus_within
        await pilot.press("2")
        assert p[1].has_focus_within
        await pilot.press("shift+tab")
        assert p[0].has_focus_within
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

        gc.collect()

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
    head = app.head_line(1, "a[/b]", "x")
    assert isinstance(head, Text)
    assert head.plain == "1  a[/b] · x"


class Recorder:
    """Collects calls made in place of a Dash method."""

    def __init__(self) -> None:
        """Start with no calls."""
        self.calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

    def __call__(self, *args: object, **kwargs: object) -> None:
        """Record one call."""
        self.calls.append((args, kwargs))


async def note_setup(
    isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch, board: dict[str, str] | None = None
) -> tuple[app.Dash, Recorder, Path]:
    """Make a dash on one live run with run_argv recorded."""
    log = f"{iso(NOW - 120)} session=1 start mode=continue\n"
    run_dir = make_run("me", plan="session-cap: 9\n", log=log, board=board)
    register(isolated, repo_of(run_dir))
    d = dash(isolated, live(repo_of(run_dir)))
    rec = Recorder()
    monkeypatch.setattr(d, "run_argv", rec)
    return d, rec, run_dir


async def test_note_dialog_returns_argv(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """N, text, Enter sends a plain note to the pane's run."""
    d, rec, run_dir = await note_setup(isolated, make_run, monkeypatch)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("n")
        assert isinstance(d.screen, app.NoteDialog)
        await pilot.press(*"hi [/x] q", "enter")
        await pilot.pause()
        assert not isinstance(d.screen, app.NoteDialog)
    assert rec.calls == [((actions.note_argv(d.ap_bin, run_dir.name, "hi [/x] q", "plain"), repo_of(run_dir)), {})]


async def test_note_dialog_escape_and_empty(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """Esc cancels and empty text does nothing."""
    d, rec, _ = await note_setup(isolated, make_run, monkeypatch)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("n", "enter")
        assert isinstance(d.screen, app.NoteDialog)
        await pilot.press("space", "enter")
        assert isinstance(d.screen, app.NoteDialog)
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(d.screen, app.NoteDialog)
    assert rec.calls == []


async def test_note_modes_offer_board_peers(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """The dialog offers --once and --to for each other board file."""
    board = {"me.md": "- me-1 → nix: x\n", "nix.md": "- ack me-1: ok\n", "p[red]q.md": ""}
    d, rec, run_dir = await note_setup(isolated, make_run, monkeypatch, board)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("n")
        buttons = list(d.screen.query(RadioButton))
        assert [str(b.label) for b in buttons][2:] == [
            "--to nix (posts to the board, wakes nix)",
            "--to p[red]q (posts to the board, wakes p[red]q)",
        ]
        buttons[2].value = True
        await pilot.press(*"go", "enter")
        await pilot.pause()
        await pilot.press("n")
        list(d.screen.query(RadioButton))[1].value = True
        await pilot.press(*"once", "enter")
        await pilot.pause()
    argvs = [c[0][0] for c in rec.calls]
    assert argvs == [
        actions.note_argv(d.ap_bin, run_dir.name, "go", ("to", "nix")),
        actions.note_argv(d.ap_bin, run_dir.name, "once", "once"),
    ]


async def test_stop_now_needs_two_presses(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """Stop now arms on the first press and sends on the second."""
    d, rec, run_dir = await note_setup(isolated, make_run, monkeypatch)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("r")
        assert isinstance(d.screen, app.RunDialog)
        await pilot.click("#now")
        assert isinstance(d.screen, app.RunDialog)
        assert "Press again" in str(d.screen.query_one("#warn", Label).content)
        assert rec.calls == []
        await pilot.pause(0.3)
        await pilot.click("#now")
        await pilot.pause()
        assert not isinstance(d.screen, app.RunDialog)
        await pilot.press("r")
        await pilot.click("#stop")
        await pilot.pause()
        await pilot.press("r", "escape")
        await pilot.pause()
    repo = repo_of(run_dir)
    assert [c[0] for c in rec.calls] == [
        (actions.control_argv(d.ap_bin, run_dir.name, "stop-now"), repo),
        (actions.control_argv(d.ap_bin, run_dir.name, "stop"), repo),
    ]


async def test_run_dialog_start_for_stopped(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """A stopped run offers Start only."""
    run_dir = make_run("me", plan="session-cap: 9\n", log=f"{iso(NOW)} stopped: two crashes\n")
    register(isolated, repo_of(run_dir))
    d = dash(isolated)
    rec = Recorder()
    monkeypatch.setattr(d, "run_argv", rec)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("r")
        ids = [b.id for b in d.screen.query(Button)]
        assert ids == ["start", "cancel"]
        await pilot.click("#start")
        await pilot.pause()
    assert rec.calls == [((actions.control_argv(d.ap_bin, run_dir.name, "start"), repo_of(run_dir)), {})]


async def toast_run(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch, ap_bin: str) -> Recorder:
    """Send a note through the real action path with AP_BIN set, recording toasts."""
    monkeypatch.setenv("AP_BIN", ap_bin)
    log = f"{iso(NOW - 120)} session=1 start mode=continue\n"
    run_dir = make_run("me", plan="session-cap: 9\n", log=log)
    register(isolated, repo_of(run_dir))
    d = dash(isolated, live(repo_of(run_dir)))
    toasts = Recorder()
    monkeypatch.setattr(d, "notify", toasts)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("n", *"hi", "enter")
        await settle(pilot)
        assert d.is_running
    return toasts


async def test_action_oserror_toast_app_stays(
    isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A missing CLI gives a red toast and the app stays up."""
    toasts = await toast_run(isolated, make_run, monkeypatch, str(isolated / "missing"))
    assert len(toasts.calls) == 1
    args, kwargs = toasts.calls[0]
    assert "missing" in str(args[0])
    assert kwargs["severity"] == "error"
    assert kwargs["markup"] is False


async def test_cli_stderr_markup_safe(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """CLI stderr that looks like markup is shown literally."""
    bad = isolated / "bad-ap"
    bad.write_text("#!/usr/bin/env bash\necho '[/x] no [bold]' >&2\nexit 1\n")
    bad.chmod(0o755)
    toasts = await toast_run(isolated, make_run, monkeypatch, str(bad))
    args, kwargs = toasts.calls[0]
    assert args[0] == "[/x] no [bold]"
    assert kwargs["severity"] == "error"
    assert kwargs["markup"] is False


def feed_run(make_run: MakeRun, name: str, stamps: list[float], plan: str = "session-cap: 9\n") -> Path:
    """Build a run whose runner log has one woke line per stamp."""
    log = "".join(f"{iso(t)} woke reason=t{i} after=1s\n" for i, t in enumerate(stamps))
    return make_run(name, plan=plan, log=log + f"{iso(NOW)} session=9 start mode=continue\n")


def seen_file(home: Path) -> Path:
    """Return the dash-seen path."""
    return home / ".config" / "autopilot" / "dash-seen"


def feed_lines(d: app.Dash) -> list[str]:
    """Return the feed's rendered lines."""
    return [line.text for line in d.query_one("#feed", RichLog).lines]


def tab_label(d: app.Dash, pane: str) -> str:
    """Return a tab's label text."""
    return d.query_one(TabbedContent).get_tab(pane).label_text


async def test_feed_order_divider_follow(isolated: Path, make_run: MakeRun) -> None:
    """Newest is last, the divider precedes the first new event, and the view follows the end."""
    stamps = [NOW - 7200 + 60 * i for i in range(80)]
    repo = repo_of(feed_run(make_run, "a", stamps))
    register(isolated, repo)
    seen_file(isolated).parent.mkdir(parents=True, exist_ok=True)
    seen_file(isolated).write_text(str(NOW - 3630))
    d = dash(isolated, live(repo))
    async with d.run_test(size=(120, 30)) as pilot:
        await settle(pilot)
        assert tab_label(d, "feed-tab") == "Feed (20 new)"
        await pilot.press("f")
        await pilot.pause()
        lines = feed_lines(d)
        div = next(i for i, t in enumerate(lines) if "new since you last looked" in t)
        assert f"({model.hhmm(NOW - 3630)}Z)" in lines[div]
        assert "reason=t59 " in lines[div - 1]
        assert "reason=t60 " in lines[div + 1]
        assert "reason=t79 " in lines[-1]
        log = d.query_one("#feed", RichLog)
        assert log.max_scroll_y > 0
        assert log.is_vertical_scroll_end


async def test_seen_advances_on_leave(isolated: Path, make_run: MakeRun) -> None:
    """Leaving the Feed tab marks everything seen."""
    repo = repo_of(feed_run(make_run, "a", [NOW - 60]))
    register(isolated, repo)
    seen_file(isolated).write_text(str(NOW - 3600))
    d = dash(isolated, live(repo))
    async with d.run_test(size=(120, 30)) as pilot:
        await settle(pilot)
        assert tab_label(d, "feed-tab") == "Feed (1 new)"
        await pilot.press("f")
        await pilot.press("g")
        await pilot.pause()
        assert abs(float(seen_file(isolated).read_text()) - NOW) < 1
        assert tab_label(d, "feed-tab") == "Feed (0 new)"


async def test_seen_written_on_quit_and_default(isolated: Path, make_run: MakeRun) -> None:
    """With no seen file the last 4 h are new, and quitting records the time."""
    repo = repo_of(feed_run(make_run, "a", [NOW - 5 * 3600, NOW - 3 * 3600]))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(120, 30)) as pilot:
        await settle(pilot)
        assert tab_label(d, "feed-tab") == "Feed (1 new)"
        await pilot.press("q")
    assert abs(float(seen_file(isolated).read_text()) - NOW) < 1


async def test_tab_and_tab_keys(isolated: Path, make_run: MakeRun) -> None:
    """G, f and o switch tabs and move focus into each tab."""
    a, b = repo_of(working_run(make_run, "a")), repo_of(working_run(make_run, "b"))
    register(isolated, a, b)
    d = dash(isolated, live(a, b))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        tabs = d.query_one(TabbedContent)
        await pilot.press("f")
        assert tabs.active == "feed-tab"
        assert d.query_one("#feed", RichLog).has_focus
        await pilot.press("o")
        assert tabs.active == "owner"
        assert d.query_one("#ownerlist", ListView).has_focus
        await pilot.press("g")
        assert tabs.active == "runs"
        assert panes(d)[0].has_focus_within


def owner_plan(*items: str) -> str:
    """Make a plan with owner items."""
    return "session-cap: 9\n## Owner\n" + "".join(f"- {i}\n" for i in items)


async def test_owner_tab_lists_finished_runs(isolated: Path, make_run: MakeRun) -> None:
    """A cleanly stopped run with Owner lines still lists them."""
    run_dir = make_run("done", plan=owner_plan("pick a colour"), log=f"{iso(NOW)} stopped: done\n")
    register(isolated, repo_of(run_dir))
    d = dash(isolated)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        assert tab_label(d, "owner") == "Owner (1 need you)"
        await pilot.press("o")
        await pilot.pause()
        items = d.query_one("#ownerlist", ListView).children
        assert len(items) == 1
        assert "pick a colour" in str(items[0].query_one(Label).content)
        assert "pick a colour" in d.query_one("#owner-text", Markdown).source


async def test_owner_answer_quotes_item(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """An answer goes to the item's run as a note quoting the item."""
    long_item = "decide whether the release [/x] should ship with the counters spec or wait for review " * 2
    a = make_run("a", plan=owner_plan("first thing"), log=f"{iso(NOW)} stopped: done\n")
    b = make_run("b", run="2026-10-21", plan=owner_plan(long_item.strip()), log=f"{iso(NOW)} stopped: done\n")
    register(isolated, repo_of(a), repo_of(b))
    d = dash(isolated)
    rec = Recorder()
    monkeypatch.setattr(d, "run_argv", rec)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("o", "down", "enter")
        await pilot.pause()
        assert d.query_one("#answer", Input).has_focus
        await pilot.press(*"ship it", "enter")
        await pilot.pause()
        assert d.query_one("#answer", Input).value == ""
    note = f'Re owner item "{long_item.strip()[:70]}": ship it'
    assert rec.calls == [((actions.note_argv(d.ap_bin, "2026-10-21", note, "plain"), repo_of(b)), {})]


async def test_owner_empty_message(isolated: Path, make_run: MakeRun) -> None:
    """With no owner items the tab says so."""
    repo = repo_of(working_run(make_run, "a"))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("o")
        await pilot.pause()
        assert tab_label(d, "owner") == "Owner (0 need you)"
        assert "nothing is waiting on you" in d.query_one("#owner-text", Markdown).source


def detail_run(make_run: MakeRun, log_md: str = "## s1\n- did `x`\n") -> Path:
    """Build a live run with a finished session, a plan and a board for the detail screen."""
    result = {"type": "result", "result": "# Done\n\nshipped **1.2**\n\nAUTOPILOT: NEXT"}
    log = f'{iso(NOW - 600)} session=1 end exit=NEXT detail="" weekly=0.2\n{iso(NOW - 60)} session=2 start\n'
    plan = "session-cap: 9\n## Queue\n- [x] 1. a\n- [ ] 2. b\n## Owner\n- choose\n## Handoff\nnext: b\n"
    return make_run("a", plan=plan, log=log, log_md=log_md, sessions={1: [result]}, board={"a.md": "- ack x-1: ok\n"})


def detail_tab(d: app.Dash) -> str:
    """Return the detail screen's shown tab."""
    assert isinstance(d.screen, app.DetailScreen)
    return d.screen.active


async def test_detail_tabs_keys(isolated: Path, make_run: MakeRun) -> None:
    """Arrows and digits switch detail tabs; Esc and q go back without quitting."""
    repo = repo_of(detail_run(make_run))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(160, 40)) as pilot:
        await settle(pilot)
        await pilot.press("enter")
        assert detail_tab(d) == "d1"
        await pilot.press("right")
        assert detail_tab(d) == "d2"
        await pilot.press("left", "left")
        assert detail_tab(d) == "d6"
        await pilot.press("3")
        assert detail_tab(d) == "d3"
        await pilot.press("g", "f", "o", "n", "r", "a", "s", "7", "enter")
        await pilot.pause()
        assert detail_tab(d) == "d3"
        assert d.is_running
        await pilot.press("escape")
        assert not isinstance(d.screen, app.DetailScreen)
        await pilot.press("enter", "q")
        assert not isinstance(d.screen, app.DetailScreen)
        assert d.is_running


async def test_detail_lazy_tabs(isolated: Path, make_run: MakeRun) -> None:
    """Only the first detail tab is built until another is shown."""
    repo = repo_of(detail_run(make_run))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(160, 40)) as pilot:
        await settle(pilot)
        await pilot.press("enter")
        await pilot.pause()
        screen = d.screen
        built = {p.id: bool(p.children) for p in screen.query_one(ContentSwitcher).children}
        assert built == {"d1": True, "d2": False, "d3": False, "d4": False, "d5": False, "d6": False}
        assert "shipped **1.2**" in screen.query_one("#d1 Markdown", Markdown).source
        await pilot.press("5")
        await pilot.pause()
        assert screen.query_one("#d5").children
        assert not screen.query_one("#d4").children


async def test_logmd_is_text(isolated: Path, make_run: MakeRun) -> None:
    """The log.md tab is styled text, not Markdown."""
    repo = repo_of(detail_run(make_run))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(160, 40)) as pilot:
        await settle(pilot)
        await pilot.press("enter", "5")
        await pilot.pause()
        tab = d.screen.query_one("#d5")
        assert not list(tab.query(Markdown))
        assert isinstance(tab.query_one(Static).content, Text)
        await pilot.press("6")
        await pilot.pause()
        assert "ack x-1" in str(d.screen.query_one("#d6").query_one(Static).content)


async def test_detail_open_budget(isolated: Path, make_run: MakeRun) -> None:
    """Opening the detail screen paints within 150 ms with a 66 KB log.md."""
    log_md = "".join(f"- line {i} with `code` and words to pad it out a bit more\n" for i in range(1200))
    assert len(log_md) > 66_000
    repo = repo_of(detail_run(make_run, log_md))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        gc.collect()
        best = base = 1e9
        for _ in range(3):
            t0 = time.perf_counter()
            await pilot.press("z")
            await pilot.pause()
            base = min(base, time.perf_counter() - t0)
            t0 = time.perf_counter()
            await pilot.press("enter")
            await pilot.pause()
            best = min(best, time.perf_counter() - t0)
            assert isinstance(d.screen, app.DetailScreen)
            await pilot.press("escape")
            await pilot.pause()
        assert best - base < 0.15


async def test_owner_answer_follows_item_after_refresh(
    isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A refresh that adds an item above the selection keeps the answer on the selected item."""
    a = make_run("a", plan=owner_plan("A first"), log=f"{iso(NOW)} stopped: done\n")
    b = make_run("b", run="2026-10-21", plan=owner_plan("B item"), log=f"{iso(NOW)} stopped: done\n")
    register(isolated, repo_of(a), repo_of(b))
    d = dash(isolated)
    rec = Recorder()
    monkeypatch.setattr(d, "run_argv", rec)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("o", "down", "enter", *"yes")
        (a / "plan.md").write_text(owner_plan("A first", "A second"))
        d.kick()
        await settle(pilot)
        assert "B item" in d.query_one("#owner-text", Markdown).source
        await pilot.press("enter")
        await pilot.pause()
    note = 'Re owner item "B item": yes'
    assert rec.calls == [((actions.note_argv(d.ap_bin, "2026-10-21", note, "plain"), repo_of(b)), {})]


async def test_unreadable_paths_contained(isolated: Path, tmp_path: Path, make_run: MakeRun) -> None:
    """A registry path or board dir under an unsearchable dir doesn't hide the other runs."""
    locked = tmp_path / "locked"
    (locked / "repo" / ".autopilot" / "runs" / "r").mkdir(parents=True)
    (locked / "board").mkdir()
    good = repo_of(working_run(make_run, "good", plan=f"session-cap: 9\nboard: {locked / 'board'}\n"))
    register(isolated, locked / "repo", good)
    locked.chmod(0)
    try:
        d = dash(isolated, live(good))
        async with d.run_test(size=(200, 50)) as pilot:
            await settle(pilot)
            assert [p.ref.repo for p in panes(d)] == [good]
            state = panes(d)[0].state
            assert state is not None
            assert state.label.startswith("WORKING s1")
    finally:
        locked.chmod(0o755)


async def test_stop_uses_ap_rel_dir(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """Stop on a live run whose AP_REL is older than the newest run dir targets the AP_REL dir."""
    old = make_run("me", run="2026-10-22", plan="session-cap: 9\n", log=f"{iso(NOW - 60)} session=1 start\n")
    make_run("me", run="2026-10-23", plan="session-cap: 9\n")
    repo = repo_of(old)
    register(isolated, repo)

    async def rel(name: str) -> str | None:
        return ".autopilot/runs/2026-10-22" if name == "autopilot-me" else None

    monkeypatch.setattr(probe, "tmux_run_rel", rel)
    d = dash(isolated, live(repo))
    rec = Recorder()
    monkeypatch.setattr(d, "run_argv", rec)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("r")
        await pilot.click("#stop")
        await pilot.pause()
    assert rec.calls == [((actions.control_argv(d.ap_bin, "2026-10-22", "stop"), repo), {})]


async def test_focus_follows_run_when_pane_hides(isolated: Path, make_run: MakeRun) -> None:
    """When an earlier pane hides, focus stays on the same run."""
    a, b, c = (repo_of(working_run(make_run, n)) for n in "abc")
    register(isolated, a, b, c)
    up = {f"autopilot-{r.name}": r for r in (a, b, c)}

    async def sessions() -> dict[str, Path]:
        return dict(up)

    d = dash(isolated, sessions)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("2")
        del up["autopilot-a"]
        (a / ".autopilot" / "runs" / "2026-10-23" / "runner.log").write_text(f"{iso(NOW)} stopped: done\n")
        d.kick()
        await settle(pilot)
        assert [p.ref.repo for p in panes(d)] == [b, c]
        assert panes(d)[0].has_focus_within
        await pilot.press("f", "g")
        assert panes(d)[0].has_focus_within


async def test_log_dir_unwritable_contained(isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch) -> None:
    """A run failure is still contained when the error log can't be written."""
    (isolated / ".cache").write_text("not a dir")
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
            msg = "boom"
            raise RuntimeError(msg)
        return real(run, now, mtime, git, alive)

    monkeypatch.setattr(model, "pane_state", flaky)
    monkeypatch.setattr(logging, "raiseExceptions", False)
    d = dash(isolated, live(good, bad))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        g, b = panes(d)
        assert g.state is not None
        assert g.state.label.startswith("WORKING s1")
        assert b.state is not None
        assert b.state.st == "needs"


async def test_owner_answer_dropped_when_item_resolves(
    isolated: Path, make_run: MakeRun, monkeypatch: pytest.MonkeyPatch
) -> None:
    """If the selected item is resolved while the owner types, Enter sends nothing."""
    a = make_run("a", plan=owner_plan("A1", "A2"), log=f"{iso(NOW)} stopped: done\n")
    register(isolated, repo_of(a))
    d = dash(isolated)
    rec = Recorder()
    monkeypatch.setattr(d, "run_argv", rec)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("o", "enter", *"yes")
        (a / "plan.md").write_text(owner_plan("A2"))
        d.kick()
        await settle(pilot)
        assert "resolved" in d.query_one("#owner-text", Markdown).source
        await pilot.press("enter")
        await pilot.pause()
    assert rec.calls == []


async def test_owner_answered_and_fyi(isolated: Path, make_run: MakeRun) -> None:
    """Answered items say so, unanswered ones count as needing you, and FYI lines get their own tab."""
    plan = owner_plan("A asked", "B open") + "owner-notes-applied: 0\n## FYI\n- ruling R, overrule with a note\n"
    owner_md = f"- {iso(NOW)} {model.answer_quote('- A asked')}go with red\n"
    run_dir = make_run("r", plan=plan, owner_md=owner_md, log=f"{iso(NOW)} stopped: done\n")
    register(isolated, repo_of(run_dir))
    d = dash(isolated)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        assert tab_label(d, "owner") == "Owner (1 need you)"
        assert tab_label(d, "fyi") == "FYI (1)"
        await pilot.press("o")
        await pilot.pause()
        rows = [str(i.query_one(Label).content) for i in d.query_one("#ownerlist", ListView).children]
        assert rows[0].startswith("✓ r A asked")
        assert "answered in note 1 (not applied yet)" in rows[0]
        assert rows[1].startswith("● r B open")
        assert "Your answer:** go with red" in d.query_one("#owner-text", Markdown).source
        await pilot.press("i")
        await pilot.pause()
        assert d.query_one(TabbedContent).active == "fyi"
        assert d.query_one("#fyi-scroll").has_focus
        assert "ruling R, overrule with a note" in str(d.query_one("#fyi-text", Static).content)


async def test_escape_leaves_answer_box(isolated: Path, make_run: MakeRun) -> None:
    """Esc in the answer box goes back to the list, so tab keys work again."""
    run_dir = make_run("r", plan=owner_plan("pick"), log=f"{iso(NOW)} stopped: done\n")
    register(isolated, repo_of(run_dir))
    d = dash(isolated)
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)
        await pilot.press("o", "enter")
        assert d.query_one("#answer", Input).has_focus
        await pilot.press("escape")
        assert d.query_one("#ownerlist", ListView).has_focus
        await pilot.press("f")
        assert d.query_one(TabbedContent).active == "feed-tab"


async def test_arrows_move_between_runs(isolated: Path, make_run: MakeRun) -> None:
    """Left and right focus the previous and next run, wrapping around."""
    repos = [repo_of(working_run(make_run, n)) for n in "abc"]
    register(isolated, *repos)
    d = dash(isolated, live(*repos))
    async with d.run_test(size=(200, 50)) as pilot:
        await settle(pilot)

        def focused() -> int:
            return next(i for i, p in enumerate(panes(d)) if p.has_focus_within)

        assert focused() == 0
        await pilot.press("right")
        assert focused() == 1
        await pilot.press("left", "left")
        assert focused() == 2


async def test_double_click_opens_detail(isolated: Path, make_run: MakeRun) -> None:
    """A click selects a run; a double click opens its details."""
    repo = repo_of(detail_run(make_run))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(160, 40)) as pilot:
        await settle(pilot)
        await pilot.click(app.RunPane)
        await pilot.pause()
        assert not isinstance(d.screen, app.DetailScreen)
        await pilot.click(app.RunPane, times=2)
        await pilot.pause()
        assert isinstance(d.screen, app.DetailScreen)


async def test_detail_mouse(isolated: Path, make_run: MakeRun) -> None:
    """Detail tabs switch on a click and take focus, and the footer's back key closes the screen."""
    repo = repo_of(detail_run(make_run))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(160, 40)) as pilot:
        await settle(pilot)
        await pilot.press("enter")
        await pilot.pause()
        assert d.screen.query_one("#d1").has_focus
        await pilot.click("#detail-tabs Tab#d3")
        await pilot.pause()
        assert detail_tab(d) == "d3"
        assert d.screen.query_one("#d3").has_focus
        await pilot.click("Footer FooterKey")
        await pilot.pause()
        assert not isinstance(d.screen, app.DetailScreen)


async def test_detail_owner_tab_shows_fyi(isolated: Path, make_run: MakeRun) -> None:
    """A run's detail Owner tab lists its FYI lines after its owner items."""
    plan = owner_plan("decide") + "## FYI\n- ruling R\n"
    run_dir = make_run("r", plan=plan, log=f"{iso(NOW - 60)} session=1 start\n")
    repo = repo_of(run_dir)
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(160, 40)) as pilot:
        await settle(pilot)
        await pilot.press("enter", "4")
        await pilot.pause()
        assert d.screen.query_one("#d4 Markdown", Markdown).source == "- decide\n\n**FYI**\n\n- ruling R"


async def until(pilot: Pilot[None], done: Callable[[], bool]) -> None:
    """Wait for a condition the palette meets after its timers fire, giving up after 2 s."""
    for _ in range(100):
        if done():
            return
        await pilot.pause(0.02)
    assert done()


def widest(log: RichLog) -> tuple[int, int]:
    """Return a log's text width and its widest line."""
    return log.scrollable_content_region.width, max(line.cell_length for line in log.lines)


async def test_lines_fit_and_rewrap(isolated: Path, make_run: MakeRun) -> None:
    """Stream and feed lines wrap to their width at 80 and 60 columns, also after a resize."""
    long = " ".join(f"word{i}" for i in range(60))
    event = {
        "type": "assistant",
        "timestamp": "2026-10-23T14:59:00Z",
        "message": {"content": [{"type": "text", "text": long}]},
    }
    log = f"{iso(NOW - 120)} session=1 start mode=continue\n"
    run_dir = make_run("a", log=log, owner_md=f"- {iso(NOW - 60)} {long}\n", sessions={1: [event]})
    register(isolated, repo_of(run_dir))
    d = dash(isolated, live(repo_of(run_dir)))
    async with d.run_test(size=(120, 30)) as pilot:
        await settle(pilot)
        await pilot.press("f")
        await pilot.pause()
        feed = d.query_one("#feed", RichLog)
        assert any("word59" in t for t in feed_lines(d))
        for size in ((80, 24), (60, 24)):
            await pilot.resize_terminal(*size)
            await pilot.pause()
            width, wide = widest(feed)
            assert wide <= width < size[0]
        await pilot.press("g")
        await pilot.pause()
        stream = panes(d)[0].stream_log
        width, wide = widest(stream)
        assert wide <= width < 60
        await pilot.resize_terminal(80, 24)
        await pilot.pause()
        assert widest(stream)[1] <= widest(stream)[0]
        assert any("word59" in t for t in log_text(panes(d)[0]))


async def test_too_small_state(isolated: Path, make_run: MakeRun) -> None:
    """Below 60x20 the dash names the size it needs, and recovers when the terminal grows."""
    register(isolated, repo_of(working_run(make_run, "a")))
    d = dash(isolated)
    async with d.run_test(size=(59, 24)) as pilot:
        await settle(pilot)
        small = d.query_one("#too-small", Static)
        assert small.region.height > 0
        assert "needs 60x20, this is 59x24" in str(small.render())
        assert d.query_one(TabbedContent).region.height == 0
        await pilot.resize_terminal(60, 19)
        await pilot.pause()
        assert "this is 60x19" in str(small.render())
        await pilot.resize_terminal(60, 20)
        await pilot.pause()
        assert small.region.height == 0
        assert d.query_one(TabbedContent).region.height > 0


async def test_palette_lists_and_runs_keys(isolated: Path, make_run: MakeRun) -> None:
    """? opens a palette of the keys that work here, and picking one runs it."""
    repo = repo_of(working_run(make_run, "a"))
    register(isolated, repo)
    d = dash(isolated, live(repo))
    async with d.run_test(size=(60, 24)) as pilot:
        await settle(pilot)
        titles = [c.title for c in d.get_system_commands(d.screen)]
        for want in ("quit  (q)", "details  (⏎)", "fyi  (i)", "compact  (x)", "next run  (→)"):
            assert want in titles
        assert len(titles) == len(set(titles))
        await pilot.press("question_mark")
        await pilot.pause()
        await pilot.press(*"compact")
        hits = d.screen.query_one(CommandList)
        await until(pilot, lambda: hits.option_count == 1)
        await pilot.press("enter")
        await until(pilot, lambda: panes(d)[0].compact)
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(d.screen, app.DetailScreen)
        titles = [c.title for c in d.get_system_commands(d.screen)]
        assert titles[:1] == ["back  (esc)"]
        assert "note  (n)" not in titles
        assert len(titles) == len(set(titles))


async def test_ctrl_c_quits(isolated: Path, make_run: MakeRun) -> None:
    """Ctrl+C quits, even from the answer box."""
    run_dir = make_run("r", plan=owner_plan("decide"), log=f"{iso(NOW - 60)} session=1 start\n")
    register(isolated, repo_of(run_dir))
    d = dash(isolated, live(repo_of(run_dir)))
    async with d.run_test(size=(120, 30)) as pilot:
        await settle(pilot)
        await pilot.press("o", "enter")
        await pilot.pause()
        assert d.focused is d.query_one("#answer", Input)
        await pilot.press("ctrl+c")
        await pilot.pause()
        assert not d.is_running
