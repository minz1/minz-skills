# Copyright (c) 2026 minz1
"""Build and run the autopilot CLI calls behind the dash's actions."""

import asyncio
import contextlib
import os
import signal
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import model

NoteMode = Literal["plain", "once"] | tuple[Literal["to"], str]
DROPPED = ("VIRTUAL_ENV", "AP_PATH", "AP_BIN", "UV", "TMUX")


def note_argv(ap_bin: str, run: str, text: str, mode: NoteMode) -> list[str]:
    """Build the argv for an owner note."""
    flags = [] if mode == "plain" else ["--once"] if mode == "once" else ["--to", mode[1]]
    return [ap_bin, "note", *flags, "--run", run, text]


def control_argv(ap_bin: str, run: str, what: Literal["start", "stop", "stop-now"]) -> list[str]:
    """Build the argv for starting or stopping a run."""
    cmd = ["stop", "--now"] if what == "stop-now" else [what]
    return [ap_bin, *cmd, "--run", run]


def action_env(env: Mapping[str, str]) -> dict[str, str]:
    """Drop uv's venv, the dash's own variables and TMUX, restoring the caller's PATH."""
    out = {k: v for k, v in env.items() if k not in DROPPED and not k.startswith("UV_")}
    if "AP_PATH" in env:
        out["PATH"] = env["AP_PATH"]
    return out


@dataclass(frozen=True)
class ActionResult:
    """What an action did, for a toast."""

    ok: bool
    message: str


def first_lines(data: bytes) -> str:
    """Keep the first three non-blank lines, cleaned."""
    lines = [ln for ln in model.clean(data.decode(errors="replace")).splitlines() if ln.strip()]
    return "\n".join(lines[:3])


async def run_action(argv: list[str], cwd: Path, env: Mapping[str, str], limit: float = 30) -> ActionResult:
    """Run a CLI call in the repo; a failure is a result, never a raise."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            cwd=cwd,
            env=action_env(env),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as e:
        return ActionResult(ok=False, message=model.clean(f"{argv[0]}: {e.strerror or e}"))
    try:
        out, err = await asyncio.wait_for(proc.communicate(), limit)
    except TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
        await proc.wait()
        return ActionResult(ok=False, message=f"timed out after {limit:g} s")
    if proc.returncode != 0:
        return ActionResult(ok=False, message=first_lines(err) or first_lines(out) or f"exit {proc.returncode}")
    return ActionResult(ok=True, message=first_lines(out) or first_lines(err) or "done")
