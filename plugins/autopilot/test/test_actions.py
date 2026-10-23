# Copyright (c) 2026 minz1
"""Tests for tmux and git probes and the CLI actions."""

import json
import os
from pathlib import Path

import actions
import probe

DIR = Path(__file__).resolve().parent
AP = str(DIR.parent / "bin" / "autopilot")
RECORDER = """#!/usr/bin/env bash
jq -n '{argv: $ARGS.positional, pwd: env.PWD, venv: (env.VIRTUAL_ENV // null), path: env.PATH}' --args -- "$@" > "$REC"
echo "recorded $1"
"""


def recorder(tmp_path: Path) -> tuple[str, Path]:
    """Write a fake autopilot that records its argv, cwd and env."""
    bin_ = tmp_path / "fake-ap"
    bin_.write_text(RECORDER)
    bin_.chmod(0o755)
    return str(bin_), tmp_path / "rec.json"


def env_for(rec: Path) -> dict[str, str]:
    """Build an action env like the one uv gives the dash."""
    path = os.environ["PATH"]
    return {"PATH": f"/venv/bin:{path}", "AP_PATH": path, "VIRTUAL_ENV": "/venv", "REC": str(rec), "HOME": "/h"}


def test_note_argv_modes() -> None:
    """Each note mode puts its flags before --run and the text last."""
    tail = ["--run", "2026-10-22", "hi there"]
    assert actions.note_argv("ap", "2026-10-22", "hi there", "plain") == ["ap", "note", *tail]
    assert actions.note_argv("ap", "2026-10-22", "hi there", "once") == ["ap", "note", "--once", *tail]
    to = actions.note_argv("ap", "2026-10-22", "hi there", ("to", "nixfiles"))
    assert to == ["ap", "note", "--to", "nixfiles", *tail]


def test_control_argv() -> None:
    """Start, stop and stop-now target the given run."""
    assert actions.control_argv("ap", "r1", "start") == ["ap", "start", "--run", "r1"]
    assert actions.control_argv("ap", "r1", "stop") == ["ap", "stop", "--run", "r1"]
    assert actions.control_argv("ap", "r1", "stop-now") == ["ap", "stop", "--now", "--run", "r1"]


def test_env_scrubbed() -> None:
    """The venv uv made and the dash's own variables don't reach the CLI."""
    env = {
        "VIRTUAL_ENV": "x",
        "UV_RUN_RECURSION_DEPTH": "1",
        "UV": "/x/uv",
        "AP_PATH": "/usr/bin",
        "AP_BIN": "/ap",
        "PATH": "/venv/bin:/usr/bin",
        "HOME": "h",
    }
    assert actions.action_env(env) == {"PATH": "/usr/bin", "HOME": "h"}


async def test_run_action_records(tmp_path: Path) -> None:
    """The CLI gets the exact argv, the repo as cwd and a clean env."""
    ap, rec = recorder(tmp_path)
    repo = tmp_path / "repo"
    repo.mkdir()
    res = await actions.run_action([ap, "note", "--run", "r", "a b"], repo, env_for(rec))
    assert res == actions.ActionResult(ok=True, message="recorded note")
    got = json.loads(rec.read_text())
    assert got["argv"] == ["note", "--run", "r", "a b"]
    assert got["pwd"] == str(repo)
    assert got["venv"] is None
    assert not got["path"].startswith("/venv")


async def test_run_action_errors(tmp_path: Path) -> None:
    """A failing exit, a gone cwd and a timeout are errors, not raises."""
    bad = tmp_path / "bad"
    bad.write_text("#!/usr/bin/env bash\necho out\necho '[/x] broke' >&2\nexit 3\n")
    bad.chmod(0o755)
    res = await actions.run_action([str(bad)], tmp_path, {"PATH": os.environ["PATH"]})
    assert res == actions.ActionResult(ok=False, message="[/x] broke")
    res = await actions.run_action([str(bad)], tmp_path / "gone", {"PATH": os.environ["PATH"]})
    assert not res.ok
    assert res.message
    slow = tmp_path / "slow"
    slow.write_text("#!/usr/bin/env bash\nsleep 30\n")
    slow.chmod(0o755)
    res = await actions.run_action([str(slow)], tmp_path, {"PATH": os.environ["PATH"]}, limit=0.5)
    assert res == actions.ActionResult(ok=False, message="timed out after 0.5 s")
    res = await actions.run_action([str(tmp_path / "missing")], tmp_path, {"PATH": os.environ["PATH"]})
    assert not res.ok


async def test_run_action_first_three_lines(tmp_path: Path) -> None:
    """Only the first three output lines are kept, cleaned."""
    many = tmp_path / "many"
    many.write_text("#!/usr/bin/env bash\nprintf 'a\\x1b[31m\\nb\\nc\\nd\\n'\n")
    many.chmod(0o755)
    res = await actions.run_action([str(many)], tmp_path, {"PATH": os.environ["PATH"]})
    assert res == actions.ActionResult(ok=True, message="a[31m\nb\nc")


async def test_injection_safe(tmp_path: Path) -> None:
    """Shell syntax in a repo name or note text stays literal."""
    ap, rec = recorder(tmp_path)
    repo = tmp_path / "it's $(touch pwned) r"
    repo.mkdir()
    text = "say $(touch pwned2) `touch pwned3` 'q\""
    await actions.run_action(actions.note_argv(ap, "r", text, "plain"), repo, env_for(rec))
    assert json.loads(rec.read_text())["argv"][-1] == text
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path), "GIT_CONFIG_GLOBAL": "/dev/null"}
    assert (await probe.run(["git", "init", "-q", str(repo)], env))[0] == 0
    run_dir = repo / ".autopilot" / "runs" / "r"
    run_dir.mkdir(parents=True)
    (run_dir / "plan.md").write_text("weekly-ceiling: 0.8\nsession-cap: 5\n")
    res = await actions.run_action(actions.note_argv(AP, "r", text, "plain"), repo, env)
    assert res.ok, res.message
    assert text in (run_dir / "owner.md").read_text()
    for d in (tmp_path, repo, Path.cwd()):
        assert not list(d.glob("pwned*"))


async def test_stop_targets_given_run(tmp_path: Path) -> None:
    """Stop goes to the run the pane shows, not the newest one."""
    ap, rec = recorder(tmp_path)
    await actions.run_action(actions.control_argv(ap, "2026-10-22", "stop-now"), tmp_path, env_for(rec))
    assert json.loads(rec.read_text())["argv"] == ["stop", "--now", "--run", "2026-10-22"]


async def test_probe_no_tmux(tmp_path: Path) -> None:
    """No tmux binary means no live sessions."""
    assert await probe.tmux_sessions(env={"PATH": str(tmp_path)}) == {}
    assert await probe.tmux_run_rel("autopilot-x", env={"PATH": str(tmp_path)}) is None
    assert await probe.tmux_sessions() == {}


async def test_probe_tmux(tmp_path: Path) -> None:
    """Live autopilot sessions map to their repo and AP_REL."""
    repo = tmp_path / "my repo"
    repo.mkdir()
    new = ["tmux", "-f", "/dev/null", "new-session", "-d", "-s", "autopilot-my_repo", "-c", str(repo)]
    try:
        assert (await probe.run([*new, "-e", "AP_REL=.autopilot/runs/r1", "sleep 60"]))[0] == 0
        assert (await probe.run(["tmux", "new-session", "-d", "-s", "other", "sleep 60"]))[0] == 0
        assert await probe.tmux_sessions() == {"autopilot-my_repo": repo}
        assert await probe.tmux_run_rel("autopilot-my_repo") == ".autopilot/runs/r1"
        assert await probe.tmux_run_rel("other") is None
    finally:
        await probe.run(["tmux", "kill-server"])


async def test_git_summary(tmp_path: Path) -> None:
    """The git row shows the branch and unpushed count, or no upstream."""
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(tmp_path),
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@t",
    }
    bare, work = tmp_path / "bare.git", tmp_path / "work"
    steps = [
        ["git", "init", "-q", "--bare", "-b", "main", str(bare)],
        ["git", "clone", "-q", str(bare), str(work)],
        ["git", "-C", str(work), "commit", "-q", "--allow-empty", "-m", "one"],
        ["git", "-C", str(work), "push", "-q", "origin", "HEAD:main"],
        ["git", "-C", str(work), "branch", "-q", "-u", "origin/main"],
        ["git", "-C", str(work), "commit", "-q", "--allow-empty", "-m", "two"],
    ]
    for argv in steps:
        assert (await probe.run(argv, env))[0] == 0, argv
    assert await probe.git_summary(work, env) == "main  ·  +1 unpushed"
    assert (await probe.run(["git", "-C", str(work), "checkout", "-q", "-b", "side"], env))[0] == 0
    assert await probe.git_summary(work, env) == "side  ·  no upstream"
    assert await probe.git_summary(tmp_path, env) == "no git"
