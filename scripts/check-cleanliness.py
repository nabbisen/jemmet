#!/usr/bin/env python3
"""
check-cleanliness.py — the matrix-honesty cleanliness guard (RFC 011/012).

Asserts the RFC 011 cleanliness criterion over jemmet's own Lean sources:
*no project-local `sorry`, `axiom`, or `unsafe`* in the core/proofs. Standard Lean
toolchain axioms (propext, Classical.choice, Quot.sound) are part of the trusted
computing base and are not project-local declarations, so they are not flagged here.

Lean comments (`-- line` and `/- block -/`, nestable) are stripped before scanning,
so the doc comments that *describe* this rule (and necessarily contain the words
"sorry/axiom/unsafe") do not trip the guard.

The theorem-count-vs-matrix half of the RFC 011 guard activates once
`docs/proof-trust-test-matrix.md` exists (RFC 011, M1+); until then this guard
covers the cleanliness half only.

Exit code 0 = clean, 1 = violation(s) found.
"""
import re
import sys
from pathlib import Path

# Directories whose .lean files form the audited core (jemmet's own code only).
SCAN_DIRS = ["Jemmet", "Test"]

# Forbidden code tokens (whole-word), per RFC 011.
FORBIDDEN = [r"\bsorry\b", r"\bsorryAx\b", r"\badmit\b", r"\baxiom\b", r"\bunsafe\b"]
FORBIDDEN_RE = re.compile("|".join(FORBIDDEN))


def strip_comments(src: str) -> str:
    """Remove Lean `--` line comments and nestable `/- -/` block comments."""
    out = []
    i, n, depth = 0, len(src), 0
    while i < n:
        two = src[i:i + 2]
        if depth > 0:
            if two == "/-":
                depth += 1; i += 2
            elif two == "-/":
                depth -= 1; i += 2
            else:
                i += 1
        else:
            if two == "/-":
                depth += 1; i += 2
            elif two == "--":
                j = src.find("\n", i)
                i = n if j == -1 else j
            else:
                out.append(src[i]); i += 1
    return "".join(out)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    violations = []
    scanned = 0
    for d in SCAN_DIRS:
        for path in sorted((root / d).rglob("*.lean")):
            scanned += 1
            code = strip_comments(path.read_text(encoding="utf-8"))
            for lineno, line in enumerate(code.splitlines(), start=1):
                if FORBIDDEN_RE.search(line):
                    violations.append((path.relative_to(root), lineno, line.strip()))

    if violations:
        print(f"cleanliness guard: FAIL — {len(violations)} violation(s) in {scanned} file(s)")
        for rel, lineno, text in violations:
            print(f"  {rel}:{lineno}: {text}")
        return 1
    print(f"cleanliness guard: PASS — 0 sorry/axiom/unsafe across {scanned} Lean file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
