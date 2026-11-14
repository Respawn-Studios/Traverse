#!/usr/bin/env python3
"""Compatibility entrypoint for retired qualification commands.

Ordinary builds and feature checks use tools/dev.py. Historical fixture and
execution records stay private; this entrypoint cannot reopen their limits.
"""

MESSAGE = "This historical compiler path is retired. Use python3 -B tools/dev.py."


def refuse(*args, **kwargs):
    raise RuntimeError(MESSAGE)


audit = build = motion = reserve = refuse

if __name__ == "__main__":
    raise SystemExit(MESSAGE)
