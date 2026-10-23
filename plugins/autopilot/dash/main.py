# Copyright (c) 2026 minz1
# /// script
# requires-python = ">=3.11"
# dependencies = ["textual==8.2.8"]
# ///
"""Entry point for autopilot dash."""

import importlib
import logging
import sys

if __name__ == "__main__":
    sys.dont_write_bytecode = True
    logging.raiseExceptions = False
    importlib.import_module("app").Dash().run()
