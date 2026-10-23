# Copyright (c) 2026 minz1
"""Async tmux and git queries."""

import asyncio
import os
from collections.abc import Mapping
from pathlib import Path


def default_env() -> dict[str, str]:
    """Use the dash's env without TMUX, so tmux talks to the default server."""
    return {k: v for k, v in os.environ.items() if k != "TMUX"}


async def run(argv: list[str], env: Mapping[str, str] | None = None, limit: float = 10) -> tuple[int, str]:
    """Run a command and return its exit code and stdout; failures give -1."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            env=dict(env) if env is not None else default_env(),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except OSError:
        return -1, ""
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), limit)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        return -1, ""
    return proc.returncode or 0, out.decode(errors="replace")


async def tmux_sessions(env: Mapping[str, str] | None = None) -> dict[str, Path]:
    """Map each live autopilot-* tmux session to its repo path."""
    rc, out = await run(
        ["tmux", "list-sessions", "-f", "#{m:autopilot-*,#{session_name}}", "-F", "#{session_name}\t#{session_path}"],
        env,
    )
    if rc != 0:
        return {}
    pairs = (line.split("\t", 1) for line in out.splitlines() if "\t" in line)
    return {name: Path(path) for name, path in pairs}


async def tmux_run_rel(name: str, env: Mapping[str, str] | None = None) -> str | None:
    """Read the AP_REL run dir a live session was started with."""
    rc, out = await run(["tmux", "show-environment", "-t", f"={name}", "AP_REL"], env)
    line = out.strip()
    return line.removeprefix("AP_REL=") if rc == 0 and line.startswith("AP_REL=") else None


async def git_summary(repo: Path, env: Mapping[str, str] | None = None) -> str:
    """Summarise a repo's branch and unpushed commits."""
    git = ["git", "--no-optional-locks", "-C", str(repo)]
    rc, _ = await run([*git, "rev-parse", "--show-toplevel"], env)
    if rc != 0:
        return "no git"
    _, branch = await run([*git, "branch", "--show-current"], env)
    rc, up = await run([*git, "rev-list", "--count", "@{u}..HEAD"], env)
    unpushed = f"+{up.strip()} unpushed" if rc == 0 else "no upstream"
    return f"{branch.strip() or 'detached'}  ·  {unpushed}"
