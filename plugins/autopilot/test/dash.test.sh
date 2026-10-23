#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."
with=(--with textual==8.2.8 --with mypy==2.4.0 --with pytest==9.1.1 --with pytest-asyncio==1.4.0)
uvx ruff@0.17.2 check
uvx ruff@0.17.2 format --check
uv run --no-project "${with[@]}" mypy
uv run --no-project "${with[@]}" pytest -q
