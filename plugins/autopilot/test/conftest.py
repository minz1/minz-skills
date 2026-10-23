# Copyright (c) 2026 minz1
"""Shared fixtures for the dash tests."""

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any, TypedDict, Unpack

import pytest


@pytest.fixture(autouse=True)
def isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Keep every test away from the owner's home, tmux server and animations."""
    home = tmp_path / "home"
    home.mkdir()
    tmux = tmp_path / "tmux"
    tmux.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("TMUX_TMPDIR", str(tmux))
    monkeypatch.delenv("TMUX", raising=False)
    monkeypatch.setenv("TEXTUAL_ANIMATIONS", "none")
    return home


class RunSpec(TypedDict, total=False):
    """Contents of a fixture run dir."""

    run: str
    plan: str
    log: str
    owner_md: str
    log_md: str
    sessions: dict[int, list[dict[str, Any] | str]]
    board: dict[str, str]


MakeRun = Callable[..., Path]


@pytest.fixture
def make_run(tmp_path: Path) -> MakeRun:
    """Build a repo with one run dir under tmp_path and return the run dir; a board adds the board header."""

    def build(repo_name: str, **spec: Unpack[RunSpec]) -> Path:
        run_dir = tmp_path / "repos" / repo_name / ".autopilot" / "runs" / spec.get("run", "2026-10-23")
        (run_dir / "sessions").mkdir(parents=True, exist_ok=True)
        plan = spec.get("plan", "")
        board = spec.get("board")
        if board is not None:
            bdir = tmp_path / "board"
            bdir.mkdir(exist_ok=True)
            for name, text in board.items():
                (bdir / name).write_text(text)
            if "\nboard:" not in "\n" + plan:
                plan = f"board: {bdir}\n{plan}"
        files = {"plan.md": plan, "runner.log": spec.get("log", ""), "owner.md": spec.get("owner_md", "")}
        files["log.md"] = spec.get("log_md", "")
        for name, text in files.items():
            if text:
                (run_dir / name).write_text(text)
        for n, lines in spec.get("sessions", {}).items():
            body = "".join((x if isinstance(x, str) else json.dumps(x)) + "\n" for x in lines)
            (run_dir / "sessions" / f"{n}.jsonl").write_text(body)
        return run_dir

    return build
