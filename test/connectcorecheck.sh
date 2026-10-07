#!/usr/bin/env bash
# connectcorecheck.sh — gate for connectSubgraph() (src/graph.h), the graph core of --connect
# metric-closure 2-approx Steiner, undirected search, true call
# direction reported, honest unconnected partitions, pure-integer determinism).
#
# graph.h is header-only, so this gate compiles a standalone harness (test/connectcore_harness.cpp) that
# builds tiny synthetic Graphs by hand (buildGraph's exact CSR layout) and asserts:
#   A  siblings under a shared dispatch caller connect THROUGH it (which directed shortestPath misses)
#   B  an island terminal lands in its OWN unconnected component (present, never dropped)
#   C  edge direction is true caller->callee even when the search walked the edge caller-ward
#   D  MST tie-break determinism — two equal-cost joins, the (dist,minId,maxId) winner, loser absent
#   E  radius bound respected (dist-8 pair splits at R=6, reconnects at R=8); radius clamps to [1,12]
#   F  byte-determinism across two runs AND a permuted terminal order
#   G  MUTATION: flipping an edge direction in the fixture flips the reported direction (C is non-vacuous)
#   H  honest degrades: empty terminals -> empty result; out-of-range dropped; >16 clamped; dups deduped
#
# Independent of the ripwire binary and of main.cpp. Uses its OWN temp dir. Does NOT edit regression.sh.
# Usage:  bash test/connectcorecheck.sh            (compiles with c++/clang++)
#         CXX=clang++ bash test/connectcorecheck.sh

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
# The ASan/UBSan pass below builds with ASAN_CXX: an explicit CXX as given, else Homebrew llvm@22 when installed, else c++
# (scripts/asanprobe.sh: Apple clang 17 / Command Line Tools 26.3 on macOS 26.7 deadlocks every ASan binary before main).
# The plain harness keeps using CXX, so its toolchain is the one the caller asked for.
. "$ROOT/scripts/asanprobe.sh"
EXPLICIT_CXX="${CXX:-}"
CXX="${CXX:-c++}"
ASAN_CXX="$( ripwire_asan_pick_cxx "$EXPLICIT_CXX" )"

# §CI-P3: ask THIS front end how it spells C++23 rather than assuming the Clang-17 spelling — an
# AppleClang 15 (LLVM 16) macos-14 runner rejects `-std=c++23` outright and took this gate with it
# (PR #1, run 30732976779). Rationale + the CMake mapping this mirrors: scripts/cxxstd.sh.
. "$ROOT/scripts/cxxstd.sh"
CXXSTD="$( ripwire_cxx_std_flag "$CXX" )"
HARNESS="$ROOT/test/connectcore_harness.cpp"
WORK="$( mktemp -d )"; trap 'gate_bounded_reap; rm -rf "$WORK"' EXIT; gate_bounded_arm
BIN="$WORK/connectcoreharness"

echo "connectcorecheck: CXX=$CXX"

# ── compile the harness against graph.h (header-only): infra + src on the include path ────────────────────────
# diagnostics.cpp supplies Diagnostics::ConsoleLog::handleDegraded (the DISCLOSE seam) — link it exactly
# as the real ripwire target does, so any degrade path resolves at link time.
if ! "$CXX" "$CXXSTD" -O2 -g -Wall -Wextra \
        -I"$ROOT/src/infra" -I"$ROOT/third_party" -I"$ROOT/src" \
        "$HARNESS" "$ROOT/src/infra/diagnostics.cpp" -o "$BIN" 2> "$WORK/cc.log"; then
    echo "  FAIL  harness failed to compile"; sed 's/^/    /' "$WORK/cc.log"; exit 2
fi
echo "  PASS  harness compiled"

# ── run it: nonzero exit ⇒ a behavioural assertion failed ────────────────────────────────────────────────────
if ! "$BIN"; then
    echo "connectcorecheck: FAIL"
    exit 2
fi

# ── ASan/UBSan pass: the same harness under the G1 sanitizer stack (integer BFS/MST must be clean) ───────────
ASAN_BIN="$WORK/connectcoreharness_asan"
ASAN_SKIPPED=""
if ! ripwire_asan_probe "$ASAN_CXX" "$WORK"; then
    # A named, expected missing premise (checklist 14/17): a toolchain whose ASan runtime cannot start a program.
    echo "  SKIP  ASan/UBSan pass: $RIPWIRE_ASAN_PROBE_WHY. Set CXX to Homebrew llvm@22's clang++, or update the Command Line Tools/Xcode (CONTRIBUTING.md, Sanitizer build)."
    ASAN_SKIPPED=1
elif "$ASAN_CXX" "$( ripwire_cxx_std_flag "$ASAN_CXX" )" -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
        -I"$ROOT/src/infra" -I"$ROOT/third_party" -I"$ROOT/src" \
        "$HARNESS" "$ROOT/src/infra/diagnostics.cpp" -o "$ASAN_BIN" 2> "$WORK/asan_cc.log"; then
    if gate_bounded 120 "$ASAN_BIN" > /dev/null; then
        echo "  PASS  ASan/UBSan run clean ($ASAN_CXX)"
    else
        echo "  FAIL  ASan/UBSan run failed"; exit 2
    fi
else
    echo "  WARN  sanitizer build unavailable on this toolchain (skipped)"; sed 's/^/    /' "$WORK/asan_cc.log"
fi

if [ -n "$ASAN_SKIPPED" ]; then
    echo "connectcorecheck: PASS (plain harness only; the ASan/UBSan pass was skipped above)"
else
    echo "connectcorecheck: ALL PASS"
fi
exit 0
