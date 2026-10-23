# Copyright (c) 2026 minz1
"""Pilot tests for the Textual dashboard."""

import app


async def test_app_starts_and_quits() -> None:
    """Pressing q quits the app."""
    dash = app.Dash()
    async with dash.run_test() as pilot:
        await pilot.press("q")
    assert not dash.is_running
