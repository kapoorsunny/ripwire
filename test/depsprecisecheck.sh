#!/usr/bin/env bash
# depsprecisecheck.sh — P3 gate: the FILE→FILE dependency graph (--deps/--arch/cycles/god-files) is
# PATH-PRECISE, not basename. graph.h::resolveIncludeAdj now resolves each quote `#include "x.h"` LEXICALLY
# relative-to-includer (resolve.h::buildPreciseIncludeAdj, the same sound machinery the call-graph
# SameInclude tier uses) instead of matching by basename. This closes the last silent-wrong-edge surface:
# a cross-directory basename collision could make --deps/--arch show a WRONG file→file edge.
#
# Fixture test/depsprecisefix has the exact collision the basename resolver could not tell apart:
#   dirA/x.h  and  dirB/x.h        BOTH exist, SAME basename `x.h`, DIFFERENT directories
#   consumer.cpp   #include "dirA/x.h"   (quote, by PATH)   → the ONE real dep
#   consumer.cpp   #include <dirB/x.h>   (angle, in-repo)   → external form → NO edge (never basename-matched)
#
# The old basename resolver reduced `dirA/x.h` to basename `x.h` and linked BOTH dirA/x.h and dirB/x.h
# (a phantom edge to the file the source never includes). Precise resolution:
#   - the edge lands on dirA/x.h ONLY  (afferent=1)                         ← path, not basename
#   - dirB/x.h gets NO incoming edge   (never appears as a resolved node)   ← the decoy is dropped
#   - the angle <dirB/x.h> contributes nothing                             ← angle → unresolved, honest
# MONOTONICITY: precise resolution can only REMOVE or REDIRECT a wrong edge, never MANUFACTURE one.
#
# Usage:  test/depsprecisecheck.sh   |   RIPWIRE_BIN=asan/ripwire test/depsprecisecheck.sh
# Exits non-zero on any failure. Does NOT edit test/regression.sh or test/golden.xml.

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
FIX="$ROOT/test/depsprecisefix"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*" || { fail=1; printf '  FAIL  could not write the PASS line for: %s\n' "$*"; }; return 0; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
echo "depsprecisecheck: BIN=$BIN  FIX=$FIX  TMP=$TMP"

# --deps: emit the file→file graph, one XML tag per line for grep-able node/edge assertions.
"$BIN" "$FIX" --deps --pack-top-n=1000 --no-cache 2>/dev/null | sed 's/</\n</g' >"$TMP/deps"

# ── the real dep resolves to dirA/x.h (afferent=1) — path, not basename ────────────────────────────
if grep -qE 'p="[^"]*dirA/x\.h"[^>]*afferent="1"' "$TMP/deps"; then
    ok "dirA/x.h has afferent=1 — the quote include \"dirA/x.h\" resolved by PATH to the right file"
else
    no "dirA/x.h afferent!=1 — the real edge was lost or mis-resolved"; grep -E 'dirA/x\.h' "$TMP/deps"
fi

# ── the decoy dirB/x.h gets NO incoming edge — it never appears as a RESOLVED node ─────────────────
# (a node line carries afferent="…"; an `<inc t="dirB/x.h">` DISPLAY line does not — assert on afferent).
if grep -qE 'p="[^"]*dirB/x\.h"[^>]*afferent="[1-9]' "$TMP/deps"; then
    no "dirB/x.h has a phantom incoming edge — basename collision leaked a WRONG file→file edge"
    grep -E 'dirB/x\.h' "$TMP/deps"
else
    ok "dirB/x.h has NO incoming edge — the same-basename decoy was NOT basename-matched (the fix)"
fi

# ── the angle include <dirB/x.h> of an in-repo file contributes NO edge (external form → unresolved) ─
# Proven by the above: consumer.cpp's ONLY quote include is dirA/x.h; the angle <dirB/x.h> is the only
# other route to dirB, and dirB has afferent 0 → the angle include added nothing. Assert it directly too:
# consumer.cpp's transitive cone is exactly 2 (self + dirA/x.h; Lakos counts self). Were the angle
# <dirB/x.h> resolved (basename-matched) it would be 3 — so transitive=2 proves the angle added no edge.
if grep -qE 'p="[^"]*consumer\.cpp"[^>]*transitive="2"' "$TMP/deps"; then
    ok "consumer.cpp cone=2 (self + dirA/x.h only) — angle <dirB/x.h> added NO edge (Lakos counts self)"
else
    no "consumer.cpp transitive cone != 2 — an angle include or decoy leaked an edge"
    grep -E 'consumer\.cpp' "$TMP/deps"
fi

# ── determinism: byte-identical run-to-run + warm == cold ─────────────────────────────────────────
"$BIN" "$FIX" --deps --no-cache >"$TMP/d1" 2>/dev/null
"$BIN" "$FIX" --deps --no-cache >"$TMP/d2" 2>/dev/null
if cmp -s "$TMP/d1" "$TMP/d2"; then ok "deterministic (two --deps --no-cache runs identical)"; else no "non-deterministic"; fi
"$BIN" "$FIX" --deps --cache="$TMP/c.bin" >"$TMP/cold" 2>/dev/null
"$BIN" "$FIX" --deps --cache="$TMP/c.bin" >"$TMP/warm" 2>/dev/null
if cmp -s "$TMP/cold" "$TMP/warm"; then ok "warm == cold (precise adjacency order-stable through cache)"; else no "warm != cold"; fi

# ── well-formed XML ───────────────────────────────────────────────────────────────────────────────
command -v xmllint >/dev/null 2>&1 \
  && { xmllint --noout "$TMP/d1" 2>/dev/null && ok "xml well-formed" || no "xml malformed"; } \
  || ok "xml well-formed (xmllint absent — skipped)"

# ── §P9.2: <f instab=> and <stabledeps gap=> must be the SAME Martin instability I=Ce/(Ca+Ce), so a ────
# `<stabledeps>` gap must equal (consumer's printed instab − provider's printed instab) within 0.01, from
# the document alone. Pre-fix, <f instab=> counted Ce over EVERY #include statement (system+third-party
# included) while <stabledeps gap=> counted Ce over the project-only resolved graph — two different numbers
# sharing one attribute name. Run against ripwire's OWN source (self-hosting): it is where the plan's
# worked example lives (src/mcp.h -> src/mcpverbs.h, claimed instab=0.52ish vs recomputed 0.25ish
# pre-fix) — the small depsprecisefix fixture has no stabledeps violations to check.
if command -v python3 >/dev/null 2>&1; then
    "$BIN" "$ROOT" --deps --pack-top-n=1000 --no-cache >"$TMP/deps_self.xml" 2>/dev/null
    if python3 - "$TMP/deps_self.xml" <<'PYEOF'
import re, sys
xml = open( sys.argv[1] ).read()
instab = {}
for m in re.finditer( r'<f p="([^"]*)"[^>]*\binstab="([0-9.]+)"', xml ):
    instab[ m.group(1) ] = float( m.group(2) )
checked, bad = 0, []
for m in re.finditer( r'<v from="([^"]*)" to="([^"]*)"[^>]*\bgap="([0-9.]+)"', xml ):
    frm, to, gap = m.group(1), m.group(2), float( m.group(3) )
    if frm not in instab or to not in instab:
        continue   # outside the --pack-top-n=1000 <f> window — not asserted, not a failure
    checked += 1
    recomputed = instab[to] - instab[frm]
    # tolerance is 0.01 (two independently-rounded %.2f values can compound to that much) + a tiny epsilon
    # so IEEE-754 binary representation of the decimal strings (e.g. 0.33-0.28 == 0.04999999999999999 in
    # float64) never fails a genuinely-reconciling row by 1e-16 of pure floating-point noise.
    if abs( recomputed - gap ) > 0.01 + 1e-9:
        bad.append( ( frm, to, gap, round( recomputed, 4 ) ) )
if checked == 0:
    print( "no <stabledeps> row had both endpoints in the <f> window — nothing checked" )
    sys.exit(1)
if bad:
    print( f"{len(bad)}/{checked} rows do NOT reconcile (from, to, printed_gap, recomputed_from_instab):" )
    for b in bad: print( "  ", b )
    sys.exit(1)
print( f"all {checked} <stabledeps> rows reconcile with printed <f instab=> within 0.01" )
PYEOF
    then ok "P9.2: every <stabledeps gap=> recomputes from printed <f instab=> within 0.01"
    else no "P9.2: <stabledeps gap=> does not reconcile with <f instab=> (two instability numbers under one name)"
    fi
else
    ok "P9.2 skipped (python3 absent)"
fi

# §A10.11: --deps emits three files=-family counts (root files=, <health files=>, <health dep_files=>)
# under one attribute name in two different places — the legend must name all three denominators, the
# same disclosure --owners already carries for its own files= DEPTH collision.
# L1 (2026-09-19): the CLI default legend is compact; this arm reads the FULL legend's prose, so it asks for it.
DOUT="$( "$BIN" "$FIX" --deps --no-cache --legend=full 2>/dev/null )"
printf '%s' "$DOUT" | grep -q 'health dep_files= = the dependency-CAPABLE subset' \
    && ok "--deps legend names all three files=-family denominators (§A10.11)" \
    || no "--deps legend does not disclose the three files=-family denominators"

# ── #220 part 1: a TS/JS import that names an IN-REPO alias or workspace package but drew no edge is COUNTED ──
# --deps resolves only relative TS/JS specifiers. An import through a tsconfig/jsconfig `paths` alias, a `baseUrl`-
# relative path or a workspace package name draws no edge, so a cycle spelled through one is missing and the absent
# <cycles> element read as "acyclic": a confident wrong zero. Part 1 does not resolve them; it counts them on the
# ROOT as imports_unresolved=N, on --deps, --arch, --impact (all three dialects and the MCP twin), and in --report's
# cycle line. Its READING is graph_partial="1" on --deps/--arch — measured over resolved edges, NOT counts_floor: a
# missing edge can merge two reported cycles into one and moves instab= either way, so "every count is a floor" was
# false there (arm J proves it); --impact keeps its own counts_floor="1" (importers= only rises). Absent at zero, so a tree with no such import is byte-
# identical. A bare package that matches none of the three (react, left-pad) is never counted. Fixtures are GENERATED
# here, never committed: this repository indexes itself, and a committed tsconfig would become live evidence.
mkts() {   # mkts DIR alias|relative — issue #220's matched pair: an npm-workspaces tree; `relative` respells three specifiers
    local D="$1" SP="$2" AB AA LIB
    rm -rf "$D"; mkdir -p "$D/packages/lib/src" "$D/packages/app/src"
    if [ "$SP" = relative ]; then AB="./b"; AA="./a"; LIB="../../lib/src/index"; else AB="@app/b"; AA="@app/a"; LIB="@acme/lib"; fi
    printf '{ "name": "fixture-root", "private": true, "workspaces": ["packages/*"] }\n' >"$D/package.json"
    printf '{\n  // tsc accepts comments and trailing commas here\n  "compilerOptions": { "strict": true, },\n}\n' >"$D/tsconfig.base.json"
    printf '{ "name": "@acme/lib", "main": "src/index.ts" }\n' >"$D/packages/lib/package.json"
    printf 'export function helper(): number { return 1; }\n' >"$D/packages/lib/src/index.ts"
    printf '{ "name": "@acme/app", "dependencies": { "@acme/lib": "*" } }\n' >"$D/packages/app/package.json"
    printf '{\n  "extends": "../../tsconfig.base.json",\n  "compilerOptions": { "baseUrl": ".", "paths": { "@app/*": ["src/*"] } }\n}\n' >"$D/packages/app/tsconfig.json"
    printf "import { b } from '%s';\nimport { helper } from '%s';\nimport React from 'react';\nexport function a(): number { return b() + helper(); }\n" "$AB" "$LIB" >"$D/packages/app/src/a.ts"
    printf "import { a } from '%s';\nexport function b(): number { return typeof a === 'function' ? 1 : 0; }\n" "$AA" >"$D/packages/app/src/b.ts"
    printf "import { d } from './d';\nexport function c(): number { return d(); }\n" >"$D/packages/app/src/c.ts"
    printf "import { c } from './c';\nexport function d(): number { return typeof c === 'function' ? 1 : 0; }\n" >"$D/packages/app/src/d.ts"
}
root_of() { sed -n 's/.*\(<deps [^>]*>\).*/\1/p; s/.*\(<arch [^>]*>\).*/\1/p' "$1" | head -1; }
# partial_root N ROOT — the partial-graph pair, and NO counts_floor= (not every count on --deps/--arch is a floor)
partial_root() { case "$2" in *"imports_unresolved=\"$1\" graph_partial=\"1\""*) case "$2" in *counts_floor=*) return 1 ;; esac; return 0 ;; esac; return 1; }
TA="$TMP/ts-alias"; TR="$TMP/ts-rel"; mkts "$TA" alias; mkts "$TR" relative
"$BIN" "$TA" --deps --no-cache >"$TMP/ta.deps" 2>/dev/null
"$BIN" "$TR" --deps --no-cache >"$TMP/tr.deps" 2>/dev/null

# (220-A) the alias tree: three in-repo specifiers unresolved (@app/b, @app/a through `paths`; @acme/lib a workspace
# member's name), react NOT counted, and the partial-graph pair rides the root — base binary: counts_floor (RED).
ROOTA="$( root_of "$TMP/ta.deps" )"
partial_root 3 "$ROOTA" && ok "#220 (A) alias tree: <deps imports_unresolved=\"3\" graph_partial=\"1\">, no counts_floor (react not counted)" \
    || no "#220 (A) alias tree root lacks imports_unresolved=\"3\" graph_partial=\"1\" or still claims counts_floor — got: $ROOTA"
# the missing cycle is the reason: only c<->d is found through the alias spelling, a<->b is not
[ "$( grep -o '<cycle ' "$TMP/ta.deps" | wc -l | tr -d ' ' )" = 1 ] \
    && ok "#220 (A) the alias spelling still finds 1 cycle (a<->b is the unresolved one) — part 1 discloses, never resolves" \
    || no "#220 (A) cycle count on the alias tree moved — part 1 must not change the graph"

# (220-B) the relative control: the same tree, relative specifiers — both cycles found EXACTLY, no count, no floor.
ROOTR="$( root_of "$TMP/tr.deps" )"
{ [ "$( grep -o '<cycle ' "$TMP/tr.deps" | wc -l | tr -d ' ' )" = 2 ] && ! grep -q 'imports_unresolved=\|counts_floor=\|graph_partial=' "$TMP/tr.deps"; } \
    && ok "#220 (B) relative control: 2 cycles, exact — no imports_unresolved=, graph_partial=, counts_floor=" \
    || no "#220 (B) relative control wrong — root: $ROOTR"

# (220-C) mutation: respell @acme/lib as left-pad (names nothing here) — the count drops by exactly one.
sed -i.bak "s#'@acme/lib'#'left-pad'#" "$TA/packages/app/src/a.ts" && rm -f "$TA/packages/app/src/a.ts.bak"
if grep -q "'left-pad'" "$TA/packages/app/src/a.ts"; then
    "$BIN" "$TA" --deps --no-cache 2>/dev/null >"$TMP/ta2.deps"
    partial_root 2 "$( root_of "$TMP/ta2.deps" )" && ok "#220 (C) mutation @acme/lib -> left-pad: 3 -> 2 (a bare package is never counted)" \
        || no "#220 (C) mutation did not drop the count to 2 — got: $( root_of "$TMP/ta2.deps" )"
else
    no "#220 (C) the mutation did not take (a.ts unchanged) — nothing measured"
fi
sed -i.bak "s#'left-pad'#'@acme/lib'#" "$TA/packages/app/src/a.ts" && rm -f "$TA/packages/app/src/a.ts.bak"

# (220-D) pure-external control: a tsconfig WITH paths and a catch-all "*" and baseUrl, and only react/lodash/node:fs
# imported — none matches a non-catch-all pattern, none exists under baseUrl or the catch-all's target: no count.
TX="$TMP/ts-ext"; mkdir -p "$TX/src"
printf '{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["src/*"], "*": ["types/*"] } } }\n' >"$TX/tsconfig.json"
printf "import React from 'react';\nimport { x } from 'lodash/fp';\nimport fs from 'node:fs';\nimport { y } from './y';\nexport function a(): number { return y(); }\n" >"$TX/src/a.ts"
printf "import { a } from './a';\nexport function y(): number { return typeof a === 'function' ? 1 : 0; }\n" >"$TX/src/y.ts"
"$BIN" "$TX" --deps --no-cache 2>/dev/null >"$TMP/tx.deps"
{ ! grep -q 'imports_unresolved=\|counts_floor=\|graph_partial=' "$TMP/tx.deps" && [ "$( grep -o '<cycle ' "$TMP/tx.deps" | wc -l | tr -d ' ' )" = 1 ]; } \
    && ok "#220 (D) external-only imports under paths/\"*\"/baseUrl: no count, no floor; the relative cycle exact" \
    || no "#220 (D) an external package was counted as in-repo — root: $( root_of "$TMP/tx.deps" )"

# (220-E) what counts, one rule per arm: a baseUrl-relative path that EXISTS counts; a jsonc-COMMENTED paths block is
# never read; an alias inherited through a relative `extends` counts; a pnpm-workspace.yaml member's name counts.
TB="$TMP/ts-baseurl"; mkdir -p "$TB/src/lib"
printf '{ "compilerOptions": {\n    // "paths": { "@x/*": ["./*"] },\n    "baseUrl": "src" } }\n' >"$TB/tsconfig.json"
printf "import { u } from 'lib/util';\nimport { v } from '@x/lib/util';\nexport const a = u + v;\n" >"$TB/src/a.ts"
printf "export const u = 1;\n" >"$TB/src/lib/util.ts"
"$BIN" "$TB" --deps --no-cache 2>/dev/null >"$TMP/tb.deps"
partial_root 1 "$( root_of "$TMP/tb.deps" )" && ok "#220 (E1) baseUrl: 'lib/util' exists under src/ and counts; the commented-out paths key is not read (@x/… not counted)" \
    || no "#220 (E1) baseUrl/jsonc arm wrong — got: $( root_of "$TMP/tb.deps" )"
# the jsonc arm is live: uncomment the key and @x/lib/util counts too (assert the mutation took first)
sed -i.bak 's#// "paths"#"paths"#' "$TB/tsconfig.json" && rm -f "$TB/tsconfig.json.bak"
if grep -q '^    "paths"' "$TB/tsconfig.json"; then
    partial_root 2 "$( "$BIN" "$TB" --deps --no-cache 2>/dev/null | sed -n 's/.*\(<deps [^>]*>\).*/\1/p' )" \
        && ok "#220 (E1) mutation: the same key UNcommented is read (1 -> 2), so the comment arm above is live" \
        || no "#220 (E1) mutation: the uncommented paths key was not read"
else
    no "#220 (E1) the uncomment mutation did not take — nothing measured"
fi
TE="$TMP/ts-extends"; mkdir -p "$TE/app/src"
printf '{ "compilerOptions": { "paths": { "#core/*": ["./app/src/*"] } } }\n' >"$TE/tsconfig.base.json"
printf '{ "extends": "../tsconfig.base", "compilerOptions": { "strict": true } }\n' >"$TE/app/tsconfig.json"
printf "import { b } from '#core/b';\nexport const a = b;\n" >"$TE/app/src/a.ts"
printf "import { a } from '#core/a';\nexport const b = a;\n" >"$TE/app/src/b.ts"
"$BIN" "$TE" --deps --no-cache 2>/dev/null >"$TMP/te.deps"
partial_root 2 "$( root_of "$TMP/te.deps" )" && ok "#220 (E2) an alias inherited through a relative extends (no .json suffix) counts" \
    || no "#220 (E2) extends arm wrong — got: $( root_of "$TMP/te.deps" )"
TP="$TMP/ts-pnpm"; mkdir -p "$TP/packages/shared/src" "$TP/packages/app/src"
printf "packages:\n  - 'packages/*'\n" >"$TP/pnpm-workspace.yaml"
printf '{ "name": "@acme/shared", "main": "dist/index.js" }\n' >"$TP/packages/shared/package.json"
printf "export function helper(): number { return 1; }\n" >"$TP/packages/shared/src/index.ts"
printf "import { helper } from '@acme/shared';\nimport { h2 } from '@acme/shared/sub';\nimport { z } from '@acme/other';\nexport const a = helper() + h2 + z;\n" >"$TP/packages/app/src/a.ts"
"$BIN" "$TP" --deps --no-cache 2>/dev/null >"$TMP/tp.deps"
partial_root 2 "$( root_of "$TMP/tp.deps" )" && ok "#220 (E3) pnpm-workspace.yaml member @acme/shared and its subpath count; @acme/other (no member) does not" \
    || no "#220 (E3) workspace arm wrong — got: $( root_of "$TMP/tp.deps" )"

# (220-F) --arch, the CI gate: the answer is partial on the alias tree — violations= can only rise, the <metrics> ratios
# move either way, so graph_partial="1" and no counts_floor (exit code unchanged — part 1 discloses; it does not change
# what a CI gate exits with). The relative control carries nothing.
printf 'layer app = packages/app\nlayer lib = packages/lib\ndeny app -> lib\n' >"$TMP/rules220.txt"
"$BIN" "$TA" --arch="$TMP/rules220.txt" --no-cache >"$TMP/ta.arch" 2>"$TMP/ta.arch.err"; RCA=$?
"$BIN" "$TR" --arch="$TMP/rules220.txt" --no-cache >"$TMP/tr.arch" 2>/dev/null
partial_root 3 "$( root_of "$TMP/ta.arch" )" && ok "#220 (F) --arch alias tree: <arch … imports_unresolved=\"3\" graph_partial=\"1\">, no counts_floor (rc=$RCA)" \
    || no "#220 (F) --arch root lacks the partial pair or still claims counts_floor — got: $( root_of "$TMP/ta.arch" )"
grep -q 'imports_unresolved=\|graph_partial=' "$TMP/tr.arch" && no "#220 (F) --arch relative control carries imports_unresolved=/graph_partial=" \
    || ok "#220 (F) --arch relative control: no count"
grep -q 'did not resolve' "$TMP/ta.arch.err" && ok "#220 (F) --arch says it on stderr too, where a CI log reads it" \
    || no "#220 (F) --arch stderr carries no floor note"

# (220-G) --report's cycle line is qualified as measured over the resolved edges (not a floor, not "acyclic") on the
# alias tree; unchanged on the control.
"$BIN" "$TA" --report --no-cache >"$TMP/ta.rep" 2>/dev/null
"$BIN" "$TR" --report --no-cache >"$TMP/tr.rep" 2>/dev/null
grep -q '^## Dependency cycles (showing 1 of 1; measured over resolved edges: 3 imports unresolved)$' "$TMP/ta.rep" \
    && ok "#220 (G) --report: '## Dependency cycles (showing 1 of 1; measured over resolved edges: 3 imports unresolved)'" \
    || no "#220 (G) --report cycle line is not qualified as partial — got: $( grep '^## Dependency cycles' "$TMP/ta.rep" )"
grep -q 'a floor' "$TMP/ta.rep" && no "#220 (G) --report still calls the cycle count a floor" \
    || ok "#220 (G) --report no longer calls the cycle count a floor"
grep -q '^## Dependency cycles (showing 2 of 2)$' "$TMP/tr.rep" \
    && ok "#220 (G) --report relative control unchanged: (showing 2 of 2)" \
    || no "#220 (G) --report relative control moved — got: $( grep '^## Dependency cycles' "$TMP/tr.rep" )"

# (220-H) --impact's import tier (importers= is a floor while imports are unresolved): XML, json, columnar, and the
# MCP twin all carry the same count.
IX="$( "$BIN" "$TA" --impact=packages/app/src/b.ts:b --no-cache 2>/dev/null )"
IJ="$( "$BIN" "$TA" --impact=packages/app/src/b.ts:b --json --no-cache 2>/dev/null )"
IC="$( "$BIN" "$TA" --impact=packages/app/src/b.ts:b --format=columnar --no-cache 2>/dev/null )"
printf '%s' "$IX" | grep -q 'importers="0" shown_importers="0" importers_capped="0" imports_unresolved="3"' \
    && ok "#220 (H) --impact XML: importers=\"0\" … imports_unresolved=\"3\"" || no "#220 (H) --impact XML lacks imports_unresolved=\"3\""
printf '%s' "$IJ" | grep -q '"imports_unresolved":3' \
    && ok "#220 (H) --impact json: \"imports_unresolved\":3" || no "#220 (H) --impact json lacks the key"
printf '%s' "$IC" | grep -q 'imports_unresolved="3"' \
    && ok "#220 (H) --impact columnar: imports_unresolved=\"3\"" || no "#220 (H) --impact columnar lacks it"
MCP220="$( printf '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"impact","arguments":{"path":"%s","symbol":"packages/app/src/b.ts:b"}}}\n' "$TA" \
            | perl -e 'alarm 60; exec @ARGV' "$BIN" --mcp 2>/dev/null | tail -1 )"
printf '%s' "$MCP220" | grep -q 'imports_unresolved=\\"3\\"' \
    && ok "#220 (H) MCP impact twin: imports_unresolved=\"3\" (same count as the CLI)" \
    || no "#220 (H) MCP impact twin lacks imports_unresolved — got: $( printf '%s' "$MCP220" | head -c 300 )"
"$BIN" "$TR" --impact=packages/app/src/b.ts:b --no-cache 2>/dev/null | grep -q 'imports_unresolved=' \
    && no "#220 (H) --impact relative control carries imports_unresolved=" || ok "#220 (H) --impact relative control: no count"

# (220-I) the definitions ride the legend exactly when the attribute does — compact and full — and the answer is
# deterministic, warm == cold, well-formed.
# graph_partial='s reading is ONE sentence in all three legends (graphlegend.h/compactlegend.h say so and point here).
READ220='measured over resolved edges; unresolved imports could add, merge or remove cycles and change ratios'
"$BIN" "$TA" --deps --no-cache --legend=full 2>/dev/null >"$TMP/ta.full"
{ grep -q 'imports_unresolved=N graph_partial=1' "$TMP/ta.full" && grep -qF "$READ220" "$TMP/ta.full"; } \
    && ok "#220 (I) full --deps legend defines imports_unresolved=/graph_partial= in the partial-graph words" || no "#220 (I) full --deps legend lacks the partial-graph definition"
{ grep -q 'imports_unresolved=N' "$TMP/ta.deps" && grep -qF "graph_partial=1: $READ220" "$TMP/ta.deps"; } \
    && ok "#220 (I) compact --deps legend defines imports_unresolved= and graph_partial= (same words)" \
    || no "#220 (I) compact --deps legend lacks the definitions"
"$BIN" "$TA" --arch="$TMP/rules220.txt" --no-cache --legend=full 2>/dev/null | grep -qF "$READ220" \
    && ok "#220 (I) full --arch legend reads graph_partial= in the same words" || no "#220 (I) full --arch legend lacks the partial-graph words"
# the old wording is gone from every legend form: the numbers are no longer called floors
grep -q 'are floors over a partial graph\|graph counts are floors\|the metrics are floors' "$TMP/ta.full" "$TMP/ta.deps" "$TMP/ta.arch" \
    && no "#220 (I) a legend still calls the partial graph's numbers floors" || ok "#220 (I) no legend calls the partial graph's numbers floors"
"$BIN" "$TR" --deps --no-cache --legend=full 2>/dev/null | grep -q 'imports_unresolved' \
    && no "#220 (I) the full legend pays for imports_unresolved= on a tree without one" || ok "#220 (I) the legend clause is absent where the attribute is"
grep -q 'graph_partial' "$TMP/tr.deps" && no "#220 (I) the compact legend pays for graph_partial= on a tree without one" \
    || ok "#220 (I) the compact graph_partial= term is absent where the attribute is"
"$BIN" "$TA" --deps --cache="$TMP/c220.bin" >"$TMP/ta.cold" 2>/dev/null
"$BIN" "$TA" --deps --cache="$TMP/c220.bin" >"$TMP/ta.warm" 2>/dev/null
cmp -s "$TMP/ta.cold" "$TMP/ta.warm" && cmp -s "$TMP/ta.cold" "$TMP/ta.deps" \
    && ok "#220 (I) deterministic, warm == cold" || no "#220 (I) warm != cold or non-deterministic"

# (220-J) WHY it is not a floor — CodeRabbit on PR #336. Two cycles c<->d and e<->f; d imports e (relative, resolved)
# and f imports c. Spelled `./c` the graph is complete: ONE cycle {c,d,e,f}, c.ts instab=0.33. Spelled through the
# `@m/*` alias the f->c edge is missing: TWO cycles, c.ts instab=0.50 — both ABOVE the complete answer, so a
# counts_floor="1" on that root claimed a lower bound that is false. The root must say partial, and nothing floor.
mkmerge() {   # mkmerge DIR SPEC — SPEC is how f.ts spells its import of c.ts
    rm -rf "$1"; mkdir -p "$1/src"
    printf '{ "compilerOptions": { "baseUrl": ".", "paths": { "@m/*": ["src/*"] } } }\n' >"$1/tsconfig.json"
    printf "import { d } from './d';\nexport function c(): number { return d(); }\n" >"$1/src/c.ts"
    printf "import { c } from './c';\nimport { e } from './e';\nexport function d(): number { return typeof c === 'function' ? e() : 0; }\n" >"$1/src/d.ts"
    printf "import { f } from './f';\nexport function e(): number { return f(); }\n" >"$1/src/e.ts"
    printf "import { e } from './e';\nimport { c } from '%s';\nexport function f(): number { return typeof e === 'function' ? 1 : 0; }\n" "$2" >"$1/src/f.ts"
}
TMA="$TMP/ts-merge-alias"; TMR="$TMP/ts-merge-rel"; mkmerge "$TMA" '@m/c'; mkmerge "$TMR" './c'
"$BIN" "$TMA" --deps --no-cache >"$TMP/tma.deps" 2>/dev/null
"$BIN" "$TMR" --deps --no-cache >"$TMP/tmr.deps" 2>/dev/null
CYA="$( grep -o '<cycle ' "$TMP/tma.deps" | wc -l | tr -d ' ' )"; CYR="$( grep -o '<cycle ' "$TMP/tmr.deps" | wc -l | tr -d ' ' )"
IA="$( sed -n 's/.*<f p="src\/c.ts" [^>]*instab="\([0-9.]*\)".*/\1/p' "$TMP/tma.deps" )"
IR="$( sed -n 's/.*<f p="src\/c.ts" [^>]*instab="\([0-9.]*\)".*/\1/p' "$TMP/tmr.deps" )"
{ [ "$CYA" = 2 ] && [ "$CYR" = 1 ] && [ "$IA" = 0.50 ] && [ "$IR" = 0.33 ]; } \
    && ok "#220 (J) the missing edge MERGES: 2 cycles over resolved edges vs 1 complete; c.ts instab 0.50 vs 0.33 — neither a floor" \
    || no "#220 (J) merge fixture did not reproduce (cycles alias=$CYA rel=$CYR, instab alias=$IA rel=$IR) — nothing measured"
partial_root 1 "$( root_of "$TMP/tma.deps" )" \
    && ok "#220 (J) so its root says graph_partial=\"1\" and claims no counts_floor" \
    || no "#220 (J) merge tree root claims a floor it does not have — got: $( root_of "$TMP/tma.deps" )"
grep -q 'imports_unresolved=\|graph_partial=\|counts_floor=' "$TMP/tmr.deps" && no "#220 (J) the complete (relative) spelling carries a disclosure" \
    || ok "#220 (J) the complete (relative) spelling carries none"
command -v xmllint >/dev/null 2>&1 \
  && { xmllint --noout "$TMP/ta.deps" 2>/dev/null && xmllint --noout "$TMP/ta.arch" 2>/dev/null && ok "#220 (I) xml well-formed" || no "#220 (I) xml malformed"; } \
  || ok "#220 (I) xml well-formed (xmllint absent — skipped)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
