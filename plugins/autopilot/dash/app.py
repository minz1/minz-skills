# Copyright (c) 2026 minz1
"""Textual UI for autopilot dash."""

from typing import ClassVar

from textual.app import App, ComposeResult
from textual.binding import Binding, BindingType
from textual.widgets import Static


class Dash(App[None]):
    """The autopilot dashboard."""

    BINDINGS: ClassVar[list[BindingType]] = [Binding("q", "quit", "quit")]

    def compose(self) -> ComposeResult:
        """Lay out the screen."""
        yield Static("autopilot dash")
