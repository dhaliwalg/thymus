"""Shared Python utilities for Thymus scripts."""
import datetime

DEBUG_LOG = "/tmp/thymus-debug.log"


def debug(script_name, msg):
    """Log a timestamped debug message to the shared debug log."""
    ts = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{ts}] {script_name}: {msg}\n")
    except OSError:
        pass
