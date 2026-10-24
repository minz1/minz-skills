# Copyright (c) 2026 minz1
"""Run discovery, run files and pane state, with no Textual import."""

import calendar
import re
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from rich.text import Text

CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d)(:\d\d)?(\.\d+)?(Z)?$")
SESSION = re.compile(r"^(\S+) session=(\d+) (start|end) ")
STOPPED = re.compile(r"^\S+ stopped: (.*)$")
WAITD = re.compile(r' exit=WAIT detail="(\d+)(?: pid=([0-9,]+))?(?: ack=([A-Za-z0-9_.,-]+))?"')
EXIT = re.compile(r" exit=([A-Za-z]+)")
WEEKLY = re.compile(r"^(\S+) session=\d+ end .* weekly=([0-9.]+)")
POST = re.compile(r"^- (?:(\S+Z) )?([A-Za-z0-9_.-]+-[0-9]+)(?: \(replaces ([A-Za-z0-9_.-]+-[0-9]+)\))? → ([^:]+)")
ANSWER = re.compile(r"^- (?:\S+Z )?(?:(?:ack|nack|reject) )+([A-Za-z0-9_.-]+-[0-9]+)(?![0-9])")
TAIL_START = re.compile(r"\s{2,}(after|check|waiting|progress|model):")
STALL_AFTER = 3900
QUIET_AFTER = 300
WINDOW = 6 * 3600
MINUTE = 60
HOURS_FROM = 5400
EXIT_CHARS = {
    "NEXT": ("N", "green"),
    "WAIT": ("W", "grey50"),
    "DONE": ("D", "green"),
    "STOP": ("S", "red"),
    "limit": ("L", "red"),
    "killed": ("K", "red"),
}
CLEAN_STOPS = ("weekly usage ", "session cap ")

State = Literal["working", "waiting", "quiet", "needs", "done", "missing"]


def clean(text: str) -> str:
    """Strip control characters from untrusted text."""
    return CTRL.sub("", text)


def parse_stamp(text: str) -> float | None:
    """Parse any timestamp form autopilot writes; no Z means local time."""
    m = STAMP.match(text)
    if not m:
        return None
    try:
        tm = time.strptime(m.group(1) + (m.group(2) or ":00"), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    base = calendar.timegm(tm) if m.group(4) else time.mktime(tm)
    return base + (float(m.group(3)) if m.group(3) else 0)


def ago(seconds: float) -> str:
    """Say a duration in the coarse form panes use."""
    s = int(max(seconds, 0))
    if s < MINUTE:
        return "<1m"
    return f"{s // MINUTE}m" if s < HOURS_FROM else f"{s // 3600}h"


def hhmm(t: float) -> str:
    """Format a time as UTC HH:MM."""
    return time.strftime("%H:%M", time.gmtime(t))


def natural_key(name: str) -> tuple[tuple[int, int | str], ...]:
    """Order names with digit runs compared as numbers, like sort -V."""
    return tuple((0, int(p)) if p.isdigit() else (1, p) for p in re.split(r"(\d+)", name) if p)


@dataclass(frozen=True)
class RunRef:
    """One shown run: its repo, the run dir in use, and whether it is live."""

    repo: Path
    run_dir: Path
    live: bool
    missing: bool


def newest_run(repo: Path) -> Path | None:
    """Find the newest run dir under a repo."""
    try:
        dirs = [p for p in (repo / ".autopilot" / "runs").iterdir() if p.is_dir()]
    except OSError:
        return None
    return max(dirs, key=lambda p: natural_key(p.name)) if dirs else None


def resolve_runs(registry: list[Path], sessions: dict[str, Path], rel: dict[str, str | None]) -> list[RunRef]:
    """Pick the run dir to show for every registered or live repo."""
    live = {path: name for name, path in sessions.items()}
    repos = list(dict.fromkeys([*registry, *sessions.values()]))
    out = []
    for repo in repos:
        name = live.get(repo)
        r = rel.get(name) if name else None
        try:
            missing = not repo.exists()
            run_dir = None if missing else repo / r if r else newest_run(repo)
        except OSError:
            run_dir, missing = None, True
        if missing:
            out.append(RunRef(repo, repo / ".autopilot" / "runs", live=False, missing=True))
        elif run_dir is not None:
            out.append(RunRef(repo, run_dir, live=name is not None, missing=False))
    return out


@dataclass(frozen=True)
class RunFiles:
    """The text files of one run dir."""

    plan: str
    log: list[str]
    owner_md: str
    log_md: str
    error: str | None


def read_text(path: Path) -> str:
    """Read a file, treating any failure as empty."""
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def load_files(run_dir: Path) -> RunFiles:
    """Load a run's files; missing ones are empty and an unreadable plan is an error."""
    error = None
    try:
        plan = (run_dir / "plan.md").read_text(errors="replace")
    except FileNotFoundError:
        plan = ""
    except OSError as e:
        plan, error = "", f"unreadable plan.md: {e.strerror or type(e).__name__}"
    log = read_text(run_dir / "runner.log").splitlines()
    return RunFiles(plan, log, read_text(run_dir / "owner.md"), read_text(run_dir / "log.md"), error)


def header(plan: str, key: str) -> str:
    """Read a plan header value."""
    m = re.search(rf"^{re.escape(key)}:[ \t]*(.*?)[ \t]*$", plan, re.MULTILINE)
    return m.group(1) if m else ""


def section(plan: str, name: str) -> list[str]:
    """Return the non-blank lines under an exact ## heading."""
    out, inside = [], False
    for line in plan.splitlines():
        if re.match(rf"^## {re.escape(name)}\s*$", line):
            inside = True
        elif line.startswith("## "):
            inside = False
        elif inside and line.strip():
            out.append(line)
    return out


def owner_items(plan: str) -> list[str]:
    """Return the items under ## Owner."""
    return [line for line in section(plan, "Owner") if line.startswith("- ")]


def blocked_count(plan: str) -> int:
    """Count [!] and [!!] items."""
    return len(re.findall(r"^- \[!!?\]", plan, re.MULTILINE))


def after_last_session(log: list[str]) -> tuple[str, list[str]]:
    """Split the runner log into its last session line and the lines after it."""
    for i in range(len(log) - 1, -1, -1):
        if SESSION.match(log[i]):
            return log[i], log[i + 1 :]
    return "", log


def stop_reason(log: list[str]) -> str | None:
    """Return the reason of a stop logged after the last session line."""
    _, after = after_last_session(log)
    reasons = [m.group(1) for line in after if (m := STOPPED.match(line))]
    return reasons[-1] if reasons else None


def is_finished(ref: RunRef, files: RunFiles) -> bool:
    """Tell whether a run stopped cleanly with nothing left for the owner."""
    if ref.live or ref.missing or files.error:
        return False
    reason = stop_reason(files.log)
    if reason is None or not (reason in ("done", "stop file") or reason.startswith(CLEAN_STOPS)):
        return False
    return not owner_items(files.plan) and not blocked_count(files.plan)


def wait_label(last: str, after: list[str], now: float, pid_alive: Callable[[str], bool]) -> str:
    """Label a waiting run by what it is waiting on."""
    if " exit=limit " in last:
        return "WAITING · usage limit"
    m = WAITD.search(last)
    start = parse_stamp(last.split(" ", 1)[0])
    if not m or start is None or any(re.match(r"^\S+ woke ", a) for a in after):
        return "WAITING"
    deadline = start + int(m.group(1)) * 60
    cap = f"≤{ago(deadline - now)}"
    if m.group(3):
        return f"WAITING for ack {m.group(3).replace(',', ' ')} (alert {hhmm(deadline)}Z)"
    if m.group(2):
        pids = [p for p in m.group(2).split(",") if pid_alive(p)]
        if not pids:
            return f"WAITING · wake due (its pids exited) ({cap})"
        what = f"pid {pids[0]}" if len(pids) == 1 else f"{len(pids)} pids"
        return f"WAITING on {what} ({cap})"
    return f"WAITING next {cap}"


@dataclass(frozen=True)
class PaneState:
    """What a pane shows for one run."""

    st: State
    label: str
    info: tuple[Text, Text, Text, Text]
    stream: Path | None
    session: str


def current_item(plan: str) -> str:
    """Return the now: item, else the first open item, without its tails."""
    nowid = header(plan, "now")
    lines = plan.splitlines()
    item = ""
    if nowid.isdigit():
        item = next((ln for ln in lines if re.match(rf"^- \[[^]]*\] *{nowid}\.", ln)), "")
    item = re.sub(r"^- \[[^]]*\] *", "", clean(item or next((ln for ln in lines if ln.startswith("- [ ]")), "")))
    tail = TAIL_START.search(item)
    return item[: tail.start()] if tail else item


def counts_row(plan: str, log: list[str], n: str, now: float) -> Text:
    """Build the item counts and session rate row."""

    def count(mark: str) -> int:
        return len(re.findall(rf"^- \[{mark}\]", plan, re.MULTILINE))

    ends = [ln for ln in log if (m := SESSION.match(ln)) and m.group(3) == "end"]
    work = sum(1 for e in ends if " exit=WAIT " not in e)
    stamps = [parse_stamp(e.split(" ", 1)[0]) for e in ends if " exit=NEXT " in e or " exit=DONE " in e]
    rate = len([t for t in stamps if t is not None and t > now - WINDOW]) / 6
    parts = [f"{count('x')}✓"]
    parts += [f"{k}{c}" for c in "cp" if (k := count(c))]
    parts += [f"{blocked_count(plan)}✗", f"{count(' ')}○"]
    cap = header(plan, "session-cap") or "?"
    return Text(f"{' '.join(parts)}  ·  s{n}  ·  work {work}/{clean(cap)}  ·  {rate:.1f} sessions/h")


def history_row(log: list[str]) -> Text:
    """Build the last-exits row with the peak context of the last session."""
    ends = [ln for ln in log if (m := SESSION.match(ln)) and m.group(3) == "end"]
    out = Text("last ")
    for e in ends[-12:]:
        x = EXIT.search(e)
        ch, col = EXIT_CHARS.get(x.group(1) if x else "", ("✗", "red"))
        out.append(ch + " ", style=col)
    m = re.search(r"peak_ctx=([0-9]+)", ends[-1]) if ends else None
    out.append(f" ·  ctx {int(m.group(1)) // 1000 if m else 0}k")
    return out


def notes_row(files: RunFiles, git: str) -> Text:
    """Build the git and owner notes row."""
    applied_h = header(files.plan, "owner-notes-applied")
    applied = int(applied_h) if applied_h.isdigit() else 0
    notes = len(re.findall(r"^- ", files.owner_md, re.MULTILINE))
    out = Text(f"{clean(git)}  ·  notes {applied}/{notes}")
    if notes > applied:
        out.append(f" ({notes - applied} pending)", style="yellow")
    if own := len(owner_items(files.plan)):
        out.append(f"  ·  owner {own}", style="bold red")
    return out


def session_label(n: str, age: float) -> tuple[State, str]:
    """Label a live session by how long its stream has been silent."""
    if age >= STALL_AFTER:
        return "needs", f"STALLED {ago(age)} silent · s{n}"
    if age >= QUIET_AFTER:
        return "quiet", f"QUIET {ago(age)} · s{n}"
    return "working", f"WORKING s{n}"


def run_label(
    run: tuple[RunRef, RunFiles],
    m: re.Match[str] | None,
    now: float,
    active: float | None,
    pid_alive: Callable[[str], bool],
) -> tuple[State, str]:
    """Pick a run's state and label before blocked and owner counts."""
    ref, files = run
    if ref.live and not m:
        return "working", "STARTING"
    if ref.live and m and m.group(3) == "start":
        return session_label(m.group(2), active or 0)
    if ref.live:
        last, after = after_last_session(files.log)
        return "waiting", wait_label(last, after, now, pid_alive)
    st: State = "done" if is_finished(ref, files) else "needs"
    return st, f"STOPPED: {clean(stop_reason(files.log) or 'no runner')}"


def pane_state(
    run: tuple[RunRef, RunFiles],
    now: float,
    stream_mtime: float | None,
    git: str,
    pid_alive: Callable[[str], bool],
) -> PaneState:
    """Compute what a run's pane shows."""
    ref, files = run
    empty = (Text(), Text(), Text(), Text())
    if ref.missing:
        return PaneState("missing", "missing", empty, None, "")
    if files.error:
        return PaneState("needs", files.error, empty, None, "")
    m = SESSION.match(after_last_session(files.log)[0])
    n = m.group(2) if m else "0"
    stream = ref.run_dir / "sessions" / f"{n}.jsonl" if m else None
    active = now - stream_mtime if stream_mtime is not None else None
    st, label = run_label((ref, files), m, now, active, pid_alive)
    if blk := blocked_count(files.plan):
        st, label = "needs", f"{label} · {blk} blocked"
    if own := len(owner_items(files.plan)):
        st, label = "needs", f"{label} · owner {own}"
    if ref.live and active is not None:
        label += f" · active {ago(active)} ago"
    info = (Text(f"item {current_item(files.plan) or 'none'}"), counts_row(files.plan, files.log, n, now))
    return PaneState(st, label, (*info, history_row(files.log), notes_row(files, git)), stream, n)


@dataclass(frozen=True)
class OpenRequest:
    """A board post nobody else has answered yet."""

    id: str
    to: str
    posted: float | None


def board_lines(board: Path) -> list[tuple[Path, list[str]]]:
    """Read every board file's lines, in name order."""
    try:
        files = sorted(p for p in board.glob("*.md") if p.is_file())
    except OSError:
        return []
    return [(f, read_text(f).splitlines()) for f in files]


def open_requests(board: Path) -> list[OpenRequest]:
    """List posts with no anchored answer from another file and no replacement."""
    posts: dict[str, tuple[Path, OpenRequest]] = {}
    answered: dict[str, set[Path]] = {}
    replaced: set[str] = set()
    for f, lines in board_lines(board):
        for line in lines:
            if p := POST.match(line):
                stamp = p.group(1)
                posts[p.group(2)] = (f, OpenRequest(p.group(2), clean(p.group(4)).strip(), parse_stamp(stamp or "")))
                if p.group(3):
                    replaced.add(p.group(3))
            elif a := ANSWER.match(line):
                answered.setdefault(a.group(1), set()).add(f)
    return [r for i, (f, r) in posts.items() if i not in replaced and not answered.get(i, set()) - {f}]


def board_of(plan: str, home: Path) -> Path | None:
    """Resolve a plan's board header to an existing dir."""
    b = header(plan, "board")
    if b in ("", "none"):
        return None
    path = home / b[2:] if b.startswith("~/") else Path(b)
    try:
        return path if path.is_dir() else None
    except OSError:
        return None


def burn(runs: list[tuple[RunRef, RunFiles]], global_ceiling: float | None, now: float) -> Text:
    """Build the weekly usage bar with its rate and each live run's wrap time."""
    pts = sorted(
        (t, float(m.group(2)))
        for _, files in runs
        for line in files.log
        if (m := WEEKLY.match(line)) and (t := parse_stamp(m.group(1))) is not None
    )
    if not pts:
        return Text("usage: no data yet", style="dim")
    t_last, w_last = pts[-1]
    recent = [p for p in pts if p[0] >= t_last - WINDOW]
    span = (recent[-1][0] - recent[0][0]) / 3600
    rate = (recent[-1][1] - recent[0][1]) / span if span > 0 else 0.0
    out = Text("weekly ", style="bold")
    out.append(f"{round(w_last * 100)}%")
    out.append(f" (+{rate * 100:.1f}%/h)" if rate > 0 else " (flat)", style="dim")
    for ref, files in runs:
        if not ref.live:
            continue
        try:
            ceiling = float(header(files.plan, "weekly-ceiling") or 1)
        except ValueError:
            continue
        if global_ceiling is not None:
            ceiling = min(ceiling, global_ceiling)
        if rate > 0 and w_last < ceiling:
            eta = t_last + (ceiling - w_last) / rate * 3600
            text = f"  ·  {clean(ref.repo.name)} wraps at {round(ceiling * 100)}% ~{hhmm(eta)}Z"
            out.append(text, style="yellow" if eta - now < 3 * 3600 else "")
    return out


QUEUE_ITEM = re.compile(r"^- \[(x| |c|p|!!?)\] *(\d+\.)?(.*)$")
QUEUE_MARK = {"x": "green", " ": "", "c": "yellow", "p": "blue", "!": "bold red", "!!": "bold red"}
CODE_STYLE = "bold cyan"
LOGMD_LINES = 400
BOARD_LINE = re.compile(r"^- (\S+Z )?(.*)$")
BOARD_HEAD = re.compile(
    r"^((?:ack|nack|reject|watch|done)\b[^:]*:?|owner → [^:]*:"
    r"|[A-Za-z0-9_.-]+-\d+(?: \(replaces [^)]*\))? → [^:]*:|[A-Za-z0-9_.-]+: runner stopped)"
)


def queue_text(plan: str) -> Text:
    """Style a plan's queue items and headings for the detail screen."""
    out = Text()
    for line in plan.splitlines():
        if m := QUEUE_ITEM.match(line):
            mark = m.group(1)
            out.append(f"[{mark}] ", style=QUEUE_MARK[mark])
            out.append((m.group(2) or "") + " ", style="bold")
            body = clean(m.group(3))
            tail = TAIL_START.search(body)
            out.append(body[: tail.start()] if tail else body, style="dim" if mark == "x" else "")
            if tail:
                out.append(body[tail.start() :], style="dim italic")
            out.append("\n")
        elif line.startswith("#"):
            out.append(clean(line.lstrip("# ")) + "\n", style="bold underline")
    return out


def logmd_text(log_md: str) -> Text:
    """Style the last lines of log.md as text, with headings and code spans."""
    out = Text()
    for line in clean(log_md).splitlines()[-LOGMD_LINES:]:
        if line.startswith("## "):
            out.append(line[3:], style="bold")
        else:
            for i, part in enumerate(line.split("`")):
                out.append(part, style=CODE_STYLE if i % 2 else "")
        out.append("\n")
    out.rstrip()
    return out


def board_style(head: str) -> str:
    """Pick the style of a board line's head."""
    if head.startswith("ack"):
        return "green"
    if head.startswith(("nack", "reject")) or "runner stopped" in head:
        return "bold red"
    if head.startswith("owner"):
        return "magenta"
    return "bold green" if head.startswith("done") else "cyan"


def board_text(board: Path) -> Text:
    """Style every board file, one section per file."""
    out = Text()
    for f, lines in board_lines(board):
        out.append(f"{clean(f.stem)}\n", style="bold reverse")
        for line in lines:
            if not (m := BOARD_LINE.match(line)):
                continue
            body = clean(m.group(2))
            out.append("  " + (m.group(1) or ""), style="dim")
            head = h.group(1) if (h := BOARD_HEAD.match(body)) else ""
            out.append(head, style=board_style(head) if head else "")
            out.append(body[len(head) :] + "\n")
        out.append("\n")
    out.rstrip()
    return out
