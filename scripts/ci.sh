#!/usr/bin/env bash
#
# ci.sh — jemmet CI / release gate (RFC 012).
#
# One honest green check: it builds the core and the proofs, runs the cleanliness guard
# (no sorry/axiom/unsafe in source) AND the matrix-honesty guard (every proven theorem is
# axiom-clean in the kernel), then runs the full conformance suite and the fuzz harnesses.
# The build fails closed: any step that fails stops the gate.
#
# Usage:  scripts/ci.sh        (expects `lake`/`lean` on PATH and the toolchain installed)
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned deps (iotakt, henret) are fetched by Lake from the committed lake-manifest.json
# into .lake/packages (gitignored). `lake build` restores them; run `lake update` to re-lock.

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

step "1/7  cleanliness guard (no sorry/axiom/unsafe in source)"
python3 scripts/check-cleanliness.py

step "2/7  build core (Jemmet)"
lake build Jemmet

step "3/7  build proofs (JemmetProofs)"
lake build JemmetProofs

step "4/7  build dep bindings (JemmetIotakt + JemmetHenret)"
lake build JemmetIotakt
lake build JemmetHenret

step "5/7  matrix-honesty guard (every proven theorem axiom-clean)"
python3 scripts/check-axioms.py

step "6/7  conformance suite + fuzz harnesses (lake test)"
lake test

step "7/7  gate summary"
echo "jemmet CI gate: PASS — build clean, proofs axiom-clean, conformance + fuzz green"
