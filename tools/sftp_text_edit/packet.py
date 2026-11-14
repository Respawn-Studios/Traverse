#!/usr/bin/env python3
"""Retired copied-source entrypoint; use the ordinary app/package workflow."""

_MESSAGE = "This historical SFTP copied-source packet is retired. See tools/sftp_text_edit/README.md for exact Git restoration and current development commands."

def __getattr__(name):
    raise RuntimeError(_MESSAGE)

if __name__ == "__main__":
    raise SystemExit(_MESSAGE)
