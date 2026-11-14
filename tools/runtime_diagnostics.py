"""Classify correctness diagnostics from one owned native verification log.

This is not a unified-log or Xcode Issue Navigator reader. It does not inspect
other processes, retain log text, or mistake absent stderr for full coverage.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
import re

PATTERNS = {
    "invalid_geometry": re.compile(
        r"Invalid view geometry:\s*(?:width|height) is negative\b", re.IGNORECASE),
    "invalid_collection_layout": re.compile(
        r"(?:NS|UI)CollectionViewFlowLayout.*(?:not defined|InvalidSizes)|"
        r"item (?:width|height) must be less than.*(?:NS|UI)CollectionView", re.IGNORECASE),
    "missing_asset_bundle": re.compile(
        r"CoreUI:.*CUICatalog.*unable to find a bundle", re.IGNORECASE),
    "layout_conflict": re.compile(
        r"Unable to simultaneously satisfy constraints|Conflicting constraints detected|"
        r"Will attempt to recover by breaking constraint", re.IGNORECASE),
    "disabled_collection_gestures": re.compile(r"Gesture recognizer support has been disabled"),
    "split_frame_workaround": re.compile(
        r"outer edges of the arranged view frames are supposed to line up with the split view", re.IGNORECASE),
    "uncaught_exception": re.compile(
        r"Terminating app due to uncaught exception|unrecognized selector sent to instance|"
        r"libc\+\+abi: terminating", re.IGNORECASE),
    "runtime_failure": re.compile(
        r"Swift runtime failure|SWIFT TASK CONTINUATION MISUSE|Fatal error:|Main Thread Checker:",
        re.IGNORECASE),
}

SYSTEM_OBSERVATIONS = {
    "sandbox_extension_consume": re.compile(r"sandbox_extension_consume failed:", re.IGNORECASE),
}


def classify(text: str) -> dict[str, list[int]]:
    """Keep category and line numbers, never paths, values or file contents."""
    return {name: [index for index, line in enumerate(text.splitlines(), 1)
                   if pattern.search(line)] for name, pattern in PATTERNS.items()}


def inspect(log: Path) -> dict:
    data = log.read_bytes()
    text = data.decode(errors="replace")
    categories = classify(text)
    observations = {name: [index for index, line in enumerate(text.splitlines(), 1)
                           if pattern.search(line)] for name, pattern in SYSTEM_OBSERVATIONS.items()}
    return {
        "version": 1,
        "passed": not any(categories.values()),
        "scope": "Captured stdout/stderr of this owned native verification process only",
        "notExercised": ["Unified-log-only diagnostics", "Xcode runtime issue interception"],
        "logSHA256": hashlib.sha256(data).hexdigest(),
        "diagnosticLineNumbers": categories,
        "observedSystemMessageLineNumbers": observations,
        "systemMessageInterpretation": "Recorded separately; occurrence alone does not establish a failed file operation or harmlessness.",
    }
