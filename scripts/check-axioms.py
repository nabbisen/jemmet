#!/usr/bin/env python3
"""
check-axioms.py — the matrix-honesty guard (RFC 011/012).

The cleanliness guard greps source for `sorry`/`axiom`/`unsafe`. This guard is stronger:
it checks the *compiled* axiom dependency of every theorem in the proven core, catching
anything a grep cannot — e.g. `sorryAx` introduced by a tactic, or an axiom pulled in
through an import. Every proven-core theorem must depend only on the whitelisted standard
Lean axioms; anything else (especially `sorryAx`) fails the build.

This is what makes jemmet's "PROVEN" column honest: the matrix cannot claim a theorem the
kernel did not actually check axiom-cleanly.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Standard, sound Lean axioms permitted in the proven core. `sorryAx` is NEVER allowed.
WHITELIST = {"propext", "Quot.sound", "Classical.choice"}
PROOFS_DIR = "Jemmet/Proofs"
THEOREM_RE = re.compile(r"^\s*(?:theorem|lemma)\s+([A-Za-z_][A-Za-z0-9_']*)")


def collect_theorems(root: Path) -> list[str]:
    names: list[str] = []
    for path in sorted((root / PROOFS_DIR).rglob("*.lean")):
        depth = 0  # Lean `/- ... -/` block-comment nesting depth
        for line in path.read_text().splitlines():
            # only treat a line as a declaration if it starts outside any block comment
            if depth == 0:
                m = THEOREM_RE.match(line)
                if m:
                    names.append(m.group(1))
            # update comment depth from this line's `/-` / `-/` markers
            i = 0
            while i < len(line) - 1:
                pair = line[i:i + 2]
                if pair == "/-":
                    depth += 1
                    i += 2
                elif pair == "-/":
                    depth = max(0, depth - 1)
                    i += 2
                else:
                    i += 1
    return names


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    names = collect_theorems(root)
    if not names:
        print("matrix-honesty guard: FAIL — no theorems found in the proven core")
        return 1

    body = ["import Jemmet.Proofs", "open Jemmet.Proofs"]
    body += [f"#print axioms {n}" for n in names]
    checker = root / "_AxAllGuard.lean"
    checker.write_text("\n".join(body) + "\n")
    try:
        proc = subprocess.run(
            ["lake", "env", "lean", checker.name],
            cwd=root, capture_output=True, text=True,
        )
    finally:
        checker.unlink(missing_ok=True)

    out = proc.stdout + "\n" + proc.stderr
    if proc.returncode != 0 and "depends on axioms" not in out and "does not depend" not in out:
        print("matrix-honesty guard: FAIL — could not evaluate axioms")
        print(out.strip()[:2000])
        return 1

    violations: list[tuple[str, str]] = []
    seen: set[str] = set()
    for line in out.splitlines():
        m = re.search(r"'Jemmet\.Proofs\.([A-Za-z0-9_']+)'", line)
        if not m:
            continue
        name = m.group(1)
        seen.add(name)
        if "does not depend on any axioms" in line:
            continue
        am = re.search(r"depends on axioms:\s*\[([^\]]*)\]", line)
        axioms = {a.strip() for a in am.group(1).split(",") if a.strip()} if am else set()
        if "sorryAx" in axioms:
            violations.append((name, "USES sorryAx (an incomplete proof!)"))
        bad = axioms - WHITELIST
        if bad:
            violations.append((name, "non-whitelisted axioms: " + ", ".join(sorted(bad))))

    missing = [n for n in names if n not in seen]
    if missing:
        for n in missing:
            violations.append((n, "theorem not found / did not elaborate"))

    if violations:
        print(f"matrix-honesty guard: FAIL — {len(violations)} violation(s) "
              f"across {len(names)} proven theorems")
        for name, why in violations:
            print(f"  {name}: {why}")
        return 1

    print(f"matrix-honesty guard: PASS — {len(names)} proven theorems, "
          f"all axiom-clean (whitelist: {', '.join(sorted(WHITELIST))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
