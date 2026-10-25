#!/usr/bin/env python3
"""Checks that SF Symbol names used in Swift sources exist and are available on iOS 26.

Scans `systemName:`, `systemImage:`, `systemImageName:`, and `symbolName:` string arguments,
plus every string literal in files whose name contains "Symbol". Uses the CoreGlyphs catalog
installed with macOS.

Usage: python3 scripts/check_sf_symbols.py [source_dir ...]
"""

import plistlib
import re
import sys
from pathlib import Path

CATALOG = Path("/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
CONTEXT = re.compile(r'(?:systemName|systemImage|systemImageName|symbolName)\s*:\s*"([^"\\]+)"')
LITERAL = re.compile(r'"([a-z0-9]+(?:\.[a-z0-9]+)+)"')
# SF Symbols 7 shipped with iOS 26.
LATEST_ALLOWED_RELEASE = 2025


def main() -> int:
    roots = [Path(p) for p in sys.argv[1:]] or [Path("Ledger"), Path("LedgerShared"), Path("LedgerWidgets")]
    symbols = plistlib.load(CATALOG.open("rb")).get("symbols", {})
    problems = []
    checked = 0
    for root in roots:
        for path in sorted(root.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            names = set(CONTEXT.findall(text))
            if "Symbol" in path.name:
                names |= set(LITERAL.findall(text))
            for name in sorted(names):
                checked += 1
                release = symbols.get(name)
                if release is None:
                    problems.append(f"{path}: unknown symbol '{name}'")
                elif float(str(release).split(".")[0]) > LATEST_ALLOWED_RELEASE:
                    problems.append(f"{path}: '{name}' needs SF Symbols {release} (newer than iOS 26)")
    for problem in problems:
        print(problem)
    print(f"checked {checked} symbol references, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
