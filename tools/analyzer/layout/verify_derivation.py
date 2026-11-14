#!/usr/bin/env python3
"""Prove that main.swift changes only the declared layout substitutions/format."""
import hashlib
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[3]


def verify() -> None:
    baseline = REPO / "tools/analyzer/AnalyzerScanner.swift"
    if hashlib.sha256(baseline.read_bytes()).hexdigest() != "fbb4d95a7db73e5abadc381d91077301de240d13e0eeacd6861a825e639dd795":
        raise ValueError("Unexpected frozen baseline")
    text = baseline.read_text()
    substitutions = {
        "var values: [UInt64?] = [nil, nil, nil, nil]": "var values = CoreMetrics()",
        "struct ObjectObservation {let values:[UInt64?];let links:UInt64?;var edges:UInt64}": "struct ObjectObservation {let values:CoreMetrics;let links:UInt64?;var edges:UInt64}",
        "var objects=[String:ObjectObservation](); var directories=Set<String>()": "var objects=[ObjectID:ObjectObservation](); var directories=Set<ObjectID>()",
        "var totals=[UInt64](repeating:0,count:4), objectTotals=[UInt64](repeating:0,count:4), missing=[UInt64](repeating:0,count:4)": "var totals=MetricTotals(), objectTotals=MetricTotals(), missing=MetricTotals()",
        "func add(_ value:UInt64,to array:inout [UInt64],at i:Int)": "func add(_ value:UInt64,to array:inout MetricTotals,at i:Int)",
        'let key=o.dev.flatMap { dev in o.ino.map { "\\(dev):\\($0)" } }': "let key=o.dev.flatMap { dev in o.ino.map { ObjectID(device:dev,inode:$0) } }",
        'directories.insert("\\(dev):\\(ino)")': "directories.insert(ObjectID(device:dev,inode:ino))",
        "var aggregate=[UInt64.max,0,0,0]": "var aggregate=MetricTotals(dataLogical:UInt64.max)",
        'if CommandLine.arguments.dropFirst()==["--self-test"]': 'if CommandLine.arguments.dropFirst()==["--layout-self-test"] {do {try layoutSelfTest()}catch {fputs("layout_selftest_failed\\n",stderr);exit(2)}}else if CommandLine.arguments.dropFirst()==["--self-test"]',
    }
    for old, new in substitutions.items():
        if text.count(old) != 1: raise ValueError("Ambiguous layout substitution")
        text = text.replace(old, new)
    text = "// Isolated value-layout counterexperiment derived from frozen Swift scanner.\n" + text
    formatted = subprocess.run(["/usr/bin/xcrun", "swift-format", "format"], input=text,
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
    if formatted != (REPO / "tools/analyzer/layout/main.swift").read_text():
        raise ValueError("Candidate contains changes beyond the declared value-layout substitution")


if __name__ == "__main__":
    verify()
    print("Layout derivation matches the frozen baseline and declared substitutions")
