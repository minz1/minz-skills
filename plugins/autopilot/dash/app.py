# Copyright (c) 2026 minz1
"""Textual UI for autopilot dash."""

import asyncio
import logging
import math
import os
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import ClassVar

import model
import probe
import stream
from rich.text import Text
from textual import events
from textual.app import App, ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Grid, Vertical
from textual.widgets import Footer, RichLog, Static, TabbedContent, TabPane

WIDE = 160
MIN_PANE = 12
REFRESH_S = 2
GIT_S = 10
COLORS = {
    "working": "green",
    "waiting": "blue",
    "quiet": "yellow",
    "needs": "red",
    "done": "#808080",
    "missing": "#808080",
}
KIND_STYLE = {"tool": "cyan", "error": "red", "think": "dim"}

Sessions = Callable[[], Awaitable[dict[str, Path]]]


class DashLog(logging.FileHandler):
    """A log file whose directory is made on the first error."""

    def emit(self, record: logging.LogRecord) -> None:
        """Write one record, making the directory first."""
        Path(self.baseFilename).parent.mkdir(parents=True, exist_ok=True)
        super().emit(record)


def pid_alive(pid: str) -> bool:
    """Tell whether a pid still exists."""
    return pid.isdigit() and Path(f"/proc/{pid}").exists()


def head_line(num: int, repo: str, label: str, *, focused: bool) -> Text:
    """Build a pane's header line."""
    return Text(f"{num}  {'◆ ' if focused else ''}{repo} · {label}")


@dataclass
class Shown:
    """One run as the last refresh saw it."""

    ref: model.RunRef
    files: model.RunFiles
    state: model.PaneState
    finished: bool


@dataclass
class Snapshot:
    """Everything one refresh read from disk."""

    runs: list[Shown] = field(default_factory=list)
    usage: Text = field(default_factory=Text)
    board: Text = field(default_factory=Text)


class UsageBar(Static):
    """The weekly usage burn-down line."""


class BoardStrip(Static):
    """Open board requests and each repo's latest board line."""

    def __init__(self) -> None:
        """Start empty."""
        super().__init__(markup=False)
        self.text = Text()

    def show(self, text: Text) -> None:
        """Replace the strip's text."""
        self.text = text
        self.update(text)
        self.display = bool(text.plain)


class RunGrid(Grid):
    """The pane grid, which keeps panes at least MIN_PANE rows and scrolls past that."""

    def fit(self) -> None:
        """Pick the column count and row height for the panes it holds."""
        n = len(self.children)
        self.set_class(n > 1, "multi")
        cols = 2 if n > 1 and self.app.size.width >= WIDE else 1
        rows = max(math.ceil(n / cols), 1)
        self.set_styles(f"grid-rows: {'1fr' if rows * MIN_PANE <= self.size.height else MIN_PANE};")

    def on_resize(self) -> None:
        """Refit when the grid changes size."""
        self.fit()


class RunPane(Vertical):
    """One run's header, info rows and session stream."""

    DEFAULT_CSS = """
    RunPane { border: round $panel-lighten-2; height: 1fr; min-height: 12; }
    RunPane:focus-within { border: heavy white; }
    RunPane .head { height: 1; text-style: bold; color: black; padding: 0 1; }
    RunPane .head, RunPane .info { text-wrap: nowrap; text-overflow: ellipsis; }
    RunPane .info { height: 4; }
    RunPane RichLog { height: 1fr; scrollbar-size-vertical: 1; }
    """

    def __init__(self, ref: model.RunRef, num: int, reader: stream.StreamReader) -> None:
        """Hold a run and the reader of its stream."""
        super().__init__()
        self.ref, self.num, self.reader = ref, num, reader
        self.show_sub, self.show_think, self.compact = True, False, False
        self.state: model.PaneState | None = None
        self.head_text = Text()
        self.seen_total = 0

    def compose(self) -> ComposeResult:
        """Lay out the pane."""
        yield Static(classes="head", markup=False)
        yield Static(classes="info", markup=False)
        yield RichLog(wrap=True, markup=False, auto_scroll=False)

    def on_mount(self) -> None:
        """Draw what is known so far."""
        self.draw_head()
        if self.state:
            self.show(self.state, "reset")

    @property
    def stream_log(self) -> RichLog:
        """Return the pane's stream widget."""
        return self.query_one(RichLog)

    def draw_head(self) -> None:
        """Redraw the header, with the focus marker."""
        st, label = (self.state.st, self.state.label) if self.state else ("waiting", "loading")
        self.head_text = head_line(self.num, model.clean(self.ref.repo.name), label, focused=self.has_focus_within)
        head = self.query_one(".head", Static)
        head.update(self.head_text)
        head.styles.background = COLORS[st]

    def on_descendant_focus(self, _: events.DescendantFocus) -> None:
        """Show the focus marker at once."""
        self.draw_head()

    def on_descendant_blur(self, _: events.DescendantBlur) -> None:
        """Drop the focus marker at once."""
        self.draw_head()

    def on_click(self) -> None:
        """Focus the pane on a click anywhere in it."""
        self.stream_log.focus()

    def styled(self, ev: stream.Event) -> Text | None:
        """Style one event, or hide it under the pane's toggles."""
        if (ev.sub and not self.show_sub) or (ev.kind == "think" and not self.show_think):
            return None
        if ev.kind == "text" and self.compact:
            return None
        out = Text(f"{model.hhmm(ev.at)} " if ev.at else "      ", style="dim")
        out.append(("│ " if ev.sub else "") + ev.text, style=KIND_STYLE.get(ev.kind, ""))
        return out

    def write_events(self, evs: list[stream.Event]) -> None:
        """Append events to the stream as one write."""
        log = self.stream_log
        follow = log.is_vertical_scroll_end or log.max_scroll_y == 0
        lines = [t for ev in evs if (t := self.styled(ev))]
        if lines:
            log.write(Text("\n").join(lines), scroll_end=follow)
        self.seen_total = self.reader.total

    def rebuild(self) -> None:
        """Redraw the whole stream from the reader's history."""
        log = self.stream_log
        follow = log.is_vertical_scroll_end or log.max_scroll_y == 0
        log.clear()
        self.write_events(self.reader.events)
        if follow:
            log.scroll_end(animate=False)

    def show(self, state: model.PaneState, change: str) -> None:
        """Show a new state and whatever the stream gained."""
        self.state = state
        if not self.is_mounted:
            return
        self.draw_head()
        self.query_one(".info", Static).update(Text("\n").join(state.info))
        new = self.reader.total - self.seen_total
        if change == "reset" or new > len(self.reader.events):
            self.rebuild()
        elif change == "appended" and new > 0:
            self.write_events(self.reader.events[-new:])


class Dash(App[None]):
    """The autopilot dashboard."""

    TITLE = "autopilot dash"
    ENABLE_COMMAND_PALETTE = False
    CSS = """
    Screen { overflow: hidden; }
    UsageBar { height: 1; padding: 0 1; background: $panel; }
    #tabs { height: 1fr; }
    #tabs > ContentSwitcher { height: 1fr; }
    TabPane { height: 1fr; padding: 0; }
    RunGrid { grid-size: 1; grid-gutter: 0 1; height: 1fr; overflow-y: auto; }
    Screen.-wide RunGrid.multi { grid-size: 2; }
    BoardStrip { height: auto; max-height: 6; padding: 0 1; text-wrap: nowrap; text-overflow: ellipsis; }
    """
    BINDINGS: ClassVar[list[BindingType]] = [
        Binding("q", "quit", "quit"),
        Binding("a", "show_all", "finished runs"),
        Binding("s", "flip('show_sub')", "subagents", show=False),
        Binding("t", "flip('show_think')", "thinking", show=False),
        Binding("x", "flip('compact')", "compact", show=False),
        Binding("G,end", "follow", "follow", show=False),
        *[Binding(str(i), f"pane({i})", show=False) for i in range(1, 10)],
    ]

    def __init__(
        self,
        home: Path | None = None,
        clock: Callable[[], float] = time.time,
        sessions: Sessions | None = None,
    ) -> None:
        """Set up the dash; tests inject home, clock and the tmux probe."""
        super().__init__()
        self.HORIZONTAL_BREAKPOINTS = [(0, "-narrow"), (WIDE, "-wide")]
        self.home = home or Path.home()
        self.clock = clock
        self.sessions_probe = sessions or probe.tmux_sessions
        self.ap_bin = os.environ.get("AP_BIN") or str(Path(__file__).resolve().parent.parent / "bin" / "autopilot")
        self.show_all = False
        self.snapshot = Snapshot()
        self.readers: dict[Path, stream.StreamReader] = {}
        self.git: dict[Path, tuple[float, str]] = {}
        self.busy = False
        self.again = False
        self.mounted_once = False
        self.logger = logging.getLogger(f"autopilot.dash.{id(self)}")
        self.logger.propagate = False
        self.logger.addHandler(DashLog(self.home / ".cache" / "autopilot" / "dash.log", delay=True))

    def compose(self) -> ComposeResult:
        """Lay out the screen."""
        yield UsageBar(Text("usage: no data yet", style="dim"))
        with TabbedContent(initial="runs", id="tabs"), TabPane("Runs", id="runs"):
            yield RunGrid()
            yield BoardStrip()
        yield Footer()

    def on_mount(self) -> None:
        """Start refreshing."""
        self.kick()
        self.set_interval(REFRESH_S, self.kick)

    def on_unmount(self) -> None:
        """Close the error log."""
        for h in list(self.logger.handlers):
            h.close()
            self.logger.removeHandler(h)

    def kick(self) -> None:
        """Start a refresh, or ask the running one to go again."""
        if self.busy:
            self.again = True
            return
        self.busy = True
        self.run_worker(self.refresh_runs(), group="refresh", exit_on_error=False)

    async def refresh_runs(self) -> None:
        """Reload every run from disk and redraw."""
        try:
            while True:
                self.again = False
                await self.refresh_once()
                if not self.again:
                    break
        except Exception:
            self.logger.exception("refresh failed")
        finally:
            self.busy = False

    def registry(self) -> list[Path]:
        """Read the registered repos."""
        text = model.read_text(self.home / ".config" / "autopilot" / "repos")
        return [Path(p) for p in (ln.strip() for ln in text.splitlines()) if p.startswith("/")]

    def global_ceiling(self) -> float | None:
        """Read the account-wide weekly ceiling, if set."""
        first = model.read_text(self.home / ".config" / "autopilot" / "weekly-ceiling").split("\n", 1)[0]
        try:
            return float(first)
        except ValueError:
            return None

    async def refresh_git(self, refs: list[model.RunRef], now: float) -> None:
        """Refresh the git summary of repos not checked in the last GIT_S seconds."""
        due = [r.repo for r in refs if not r.missing and now - self.git.get(r.repo, (-1e18, ""))[0] >= GIT_S]
        for repo, summary in zip(due, await asyncio.gather(*map(probe.git_summary, due)), strict=True):
            self.git[repo] = (now, summary)

    async def refresh_once(self) -> None:
        """Run one refresh: probe, read, mount, stream, draw."""
        sessions = await self.sessions_probe()
        rels = await asyncio.gather(*(probe.tmux_run_rel(n) for n in sessions))
        rel = dict(zip(sessions, rels, strict=True))
        refs = await asyncio.to_thread(lambda: model.resolve_runs(self.registry(), sessions, rel))
        now = self.clock()
        await self.refresh_git(refs, now)
        snap = await asyncio.to_thread(self.load, refs, now)
        self.snapshot = snap
        await self.sync_panes([s for s in snap.runs if self.show_all or not (s.finished or s.ref.missing)])
        panes = list(self.query(RunPane))
        changes = await asyncio.to_thread(
            lambda: [p.reader.update(p.state.stream) if p.state and p.state.stream else "same" for p in panes]
        )
        for p, change in zip(panes, changes, strict=True):
            if p.state:
                p.show(p.state, change)
        self.query_one(UsageBar).update(snap.usage)
        self.query_one(BoardStrip).show(snap.board)

    def load(self, refs: list[model.RunRef], now: float) -> Snapshot:
        """Read every run's files and work out its state; runs in a thread."""
        snap = Snapshot()
        for ref in refs:
            files = model.load_files(ref.run_dir)
            try:
                mtime = None
                last = model.after_last_session(files.log)[0]
                if m := model.SESSION.match(last):
                    stream_path = ref.run_dir / "sessions" / f"{m.group(2)}.jsonl"
                    mtime = stream_path.stat().st_mtime if stream_path.exists() else None
                git = self.git.get(ref.repo, (0, ""))[1]
                state = model.pane_state((ref, files), now, mtime, git, pid_alive)
                finished = model.is_finished(ref, files)
            except Exception as e:
                self.logger.exception("refresh of %s failed", ref.repo)
                empty = (Text(), Text(), Text(), Text())
                state, finished = model.PaneState("needs", model.clean(f"error: {e}"), empty, None, ""), False
            snap.runs.append(Shown(ref, files, state, finished))
        shown = [(s.ref, s.files) for s in snap.runs if self.show_all or not (s.finished or s.ref.missing)]
        snap.usage = model.burn(shown, self.global_ceiling(), now)
        boards = [b for _, f in shown if (b := model.board_of(f.plan, self.home))]
        snap.board = board_strip(list(dict.fromkeys(boards)), now)
        return snap

    async def sync_panes(self, shown: list[Shown]) -> None:
        """Mount panes when the shown runs change, then hand each its state."""
        grid = self.query_one(RunGrid)
        panes = list(self.query(RunPane))
        keys = [(s.ref.repo, s.ref.run_dir) for s in shown]
        if keys != [(p.ref.repo, p.ref.run_dir) for p in panes]:
            had = next((i for i, p in enumerate(panes) if p.has_focus_within), None)
            take_focus = had is not None or self.focused is None or not self.mounted_once
            await grid.remove_children()
            for s in shown:
                self.readers.setdefault(s.ref.run_dir, stream.StreamReader())
            new = [RunPane(s.ref, i + 1, self.readers[s.ref.run_dir]) for i, s in enumerate(shown)]
            for p, s in zip(new, shown, strict=True):
                p.state = s.state
            await grid.mount_all(new)
            grid.fit()
            self.mounted_once = self.mounted_once or bool(new)
            if take_focus and new:
                new[min(had or 0, len(new) - 1)].stream_log.focus()
            return
        for p, s in zip(panes, shown, strict=True):
            p.ref, p.state = s.ref, s.state

    def focused_pane(self) -> RunPane | None:
        """Return the pane holding focus."""
        return next((p for p in self.query(RunPane) if p.has_focus_within), None)

    def action_pane(self, n: int) -> None:
        """Focus pane n."""
        panes = list(self.query(RunPane))
        if 0 < n <= len(panes):
            panes[n - 1].stream_log.focus()

    def action_show_all(self) -> None:
        """Show or hide finished and missing runs."""
        self.show_all = not self.show_all
        self.kick()

    def action_flip(self, what: str) -> None:
        """Flip one of the focused pane's stream toggles."""
        if (p := self.focused_pane()) and what in ("show_sub", "show_think", "compact"):
            setattr(p, what, not getattr(p, what))
            p.rebuild()

    def action_follow(self) -> None:
        """Follow the end of the focused pane's stream."""
        if p := self.focused_pane():
            p.stream_log.scroll_end(animate=False)


def board_strip(boards: list[Path], now: float) -> Text:
    """Build the board strip: open requests per board, then each file's latest line."""
    out = Text()
    for board in boards:
        if out:
            out.append("\n")
        out.append(f" BOARD {model.clean(board.name)} ", style="reverse bold")
        out.append("  open: ")
        reqs = model.open_requests(board)
        for r in reqs:
            age = f"posted {model.ago(now - r.posted)} ago" if r.posted is not None else "age unknown"
            out.append(f"{model.clean(r.id)} → {r.to}", style="yellow")
            out.append(f" ({age}, no answer)   ", style="dim")
        if not reqs:
            out.append("none", style="dim")
        for f, lines in model.board_lines(board):
            last = next((ln for ln in reversed(lines) if ln.startswith("- ")), "")
            out.append(f"\n  {model.clean(f.stem)}  ", style="bold")
            out.append(model.clean(last[2:])[:160])
    return out
