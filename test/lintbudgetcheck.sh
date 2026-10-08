#!/usr/bin/env bash
# lintbudgetcheck.sh — §P0.2 gate: --lint must report TRUE per-rule totals, not a starved floor.
#
# Before the fix all 11 built-in AST rules shared ONE pooled astQuery budget (maxMatches=5000).
# `(number_literal)` saturated it alone, the pool was path-sorted then cut, so the scan stopped at
# ./src/ingest.cpp and never reached main.cpp / quality.h / test/ / third_party/ — ~14% of the tree.
# `--lint` then printed goto=1 (truth 2), do-while=0 (truth 1), c-style-cast=100 (truth 215), and
# false zeros for unsafe-c-fn / weak-crypto / empty-catch over ~86% of the tree.
#
# The invariant this gate freezes: a rule's count must equal what the SAME engine reports for the same
# query under --match (ground truth), and must NOT change when another rule's matches explode.
#
#   RIPWIRE_BIN=build/ripwire      bash test/lintbudgetcheck.sh
#   RIPWIRE_BIN=build_base/ripwire bash test/lintbudgetcheck.sh   # must FAIL (pre-fix binary)

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*" || { fail=1; printf '  FAIL  could not write the PASS line for: %s\n' "$*"; }; return 0; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first"; exit 2; }
echo "lintbudgetcheck: BIN=$BIN  ROOT=$ROOT"

# ── ground truth: the same engine, one query at a time (--match has always had its own full budget)
truth(){ "$BIN" "$ROOT" --match="$1" 2>/dev/null | grep -oE 'hits="[0-9]+"' | head -1 | grep -oE '[0-9]+'; }
GOTO_TRUTH="$( truth '(goto_statement) @c' )"
DOWH_TRUTH="$( truth '(do_statement) @c' )"
CAST_TRUTH="$( truth '(cast_expression) @c' )"

"$BIN" "$ROOT" --lint >"$TMP/lint.xml" 2>/dev/null
ruleCount(){ grep -oE "<rule name=\"$1\" count=\"[0-9]+\"" "$TMP/lint.xml" | grep -oE 'count="[0-9]+"' | grep -oE '[0-9]+'; }

# ── 1. per-rule counts are TRUE totals, agreeing with the single-query ground truth
GOTO_LINT="$( ruleCount goto )"
[ "${GOTO_LINT:-x}" = "${GOTO_TRUTH:-y}" ] && [ "${GOTO_LINT:-0}" -ge 2 ] \
    && ok "goto count=$GOTO_LINT == --match ground truth ($GOTO_TRUTH)" \
    || no "goto count=${GOTO_LINT:-<none>} != --match ground truth ${GOTO_TRUTH:-<none>} (expected >= 2)"

DOWH_LINT="$( ruleCount do-while )"
[ "${DOWH_LINT:-x}" = "${DOWH_TRUTH:-y}" ] && [ "${DOWH_LINT:-0}" -ge 1 ] \
    && ok "do-while count=$DOWH_LINT == --match ground truth ($DOWH_TRUTH)" \
    || no "do-while count=${DOWH_LINT:-<none>} != --match ground truth ${DOWH_TRUTH:-<none>} (expected >= 1)"

CAST_LINT="$( ruleCount c-style-cast )"
[ "${CAST_LINT:-x}" = "${CAST_TRUTH:-y}" ] && [ "${CAST_LINT:-0}" -ge 200 ] \
    && ok "c-style-cast count=$CAST_LINT == --match ground truth ($CAST_TRUTH), >= 200" \
    || no "c-style-cast count=${CAST_LINT:-<none>} != --match ground truth ${CAST_TRUTH:-<none>} (expected >= 200)"

# ── 2. saturation is DISCLOSED, never silent: (number_literal) alone exceeds any single-rule budget on
#      this repo, so magic-number must declare its count a floor and the root must say findings_capped.
grep -q '<lint[^>]* findings_capped="1"' "$TMP/lint.xml" \
    && ok 'root declares findings_capped="1" (a rule saturated its own budget)' \
    || no 'root does NOT declare findings_capped="1" while a rule saturates its budget'
grep -qE '<rule name="magic-number"[^/]* count_capped="1"' "$TMP/lint.xml" \
    && ok 'magic-number row declares count_capped="1" (count= is a floor — rule 4 of the truncation vocabulary)' \
    || no 'magic-number row does not declare count_capped="1"'

# ── 3. NO-STARVATION, the core invariant: a quiet rule's count must not change when a noisy rule is
#      added beside it. Exercised through the --lint-rules= path, which shares the same engine/pool.
mkdir -p "$TMP/quiet" "$TMP/both"
cat >"$TMP/quiet/q.yml" <<'YML'
- id: quiet-goto
  language: cpp
  severity: warn
  message: goto found
  query: |
    (goto_statement) @hit
YML
cp "$TMP/quiet/q.yml" "$TMP/both/q.yml"
cat >"$TMP/both/noisy.yml" <<'YML'
- id: noisy-number
  language: cpp
  severity: warn
  message: number literal
  query: |
    (number_literal) @hit
YML

userCount(){ "$BIN" "$ROOT" --lint-rules="$1" 2>/dev/null \
    | grep -oE "<rule name=\"quiet-goto\" sev=\"[a-z]+\" count=\"[0-9]+\"" | grep -oE 'count="[0-9]+"' | grep -oE '[0-9]+'; }
Q_ALONE="$( userCount "$TMP/quiet" )"
Q_BESIDE="$( userCount "$TMP/both" )"
[ -n "${Q_ALONE:-}" ] && [ "${Q_ALONE:-0}" -ge 2 ] \
    && ok "custom quiet rule alone: count=$Q_ALONE" \
    || no "custom quiet rule alone: count=${Q_ALONE:-<none>} (expected >= 2)"
[ "${Q_ALONE:-x}" = "${Q_BESIDE:-y}" ] \
    && ok "no starvation: quiet rule count unchanged beside a saturating rule ($Q_BESIDE)" \
    || no "STARVED: quiet rule count ${Q_ALONE:-<none>} alone vs ${Q_BESIDE:-<none>} beside a noisy rule"

# ── 4. determinism (two runs, byte-identical) — the cap must stay a pure function of the input
"$BIN" "$ROOT" --lint >"$TMP/d1" 2>/dev/null
"$BIN" "$ROOT" --lint >"$TMP/d2" 2>/dev/null
diff -q "$TMP/d1" "$TMP/d2" >/dev/null && ok "deterministic (byte-identical run-to-run)" \
    || no "non-deterministic --lint output"

# ── adversarial-round extension: cap disclosure must not leak across the built-in/user namespaces ────
# A user rule may share a built-in rule's NAME. Its saturation must never paint capped="1" onto the
# built-in row (which fabricates "my truthful count is a floor of 5000 raw captures"), nor vice versa.
COLLIDE="$( mktemp -d )"; trap 'rm -rf "$COLLIDE"' RETURN 2>/dev/null || true
printf -- '- id: goto\n  severity: warn\n  message: noisy collider\n  query: (number_literal) @hit\n' > "$COLLIDE/goto.yml"
crow_builtin="$( "$BIN" "$ROOT" --lint --lint-rules="$COLLIDE" 2>/dev/null | grep -oE '<rule name="goto"[^/]*/>' | grep -v 'sev=' )"
crow_user="$(    "$BIN" "$ROOT" --lint --lint-rules="$COLLIDE" 2>/dev/null | grep -oE '<rule name="goto"[^/]*/>' | grep    'sev=' )"
# wave-4 item 12 added a per-rule shown_rows=/rows_capped= pair (--lint's row-window disclosure) that sits
# beside this bare capped= (this rule's own MATCH-BUDGET saturation) on the same row — a plain substring
# match on "capped" now also hits "rows_capped", so the check must anchor on the bare ` capped="` spelling
# (leading space) to keep testing the fact it was written for, not the unrelated new one.
# The expected count is GOTO_TRUTH (derived above from --match), not a literal: it was pinned at 2 and a
# fixture added in a later round (test/sliceflowsensfix/disclosed.cpp, the slice's disclosed "goto is
# untracked" case) made it 3, reddening an arm that is about CAP INHERITANCE, not about how many gotos
# this tree happens to hold.
case "$crow_builtin" in
    *' count_capped='* ) no "built-in goto row inherited the colliding USER rule's cap: $crow_builtin" ;;
    *count=\"$GOTO_TRUTH\"* ) ok "built-in goto row stays a clean total ($GOTO_TRUTH) beside a saturating same-named user rule" ;;
    * ) no "built-in goto row unexpected shape: $crow_builtin" ;;
esac
case "$crow_user" in
    *' count_capped="1"'* ) ok "colliding user rule's own saturation still disclosed: count_capped=\"1\"" ;;
    * ) no "user goto rule saturated its budget but carries no count_capped=: $crow_user" ;;
esac
rm -rf "$COLLIDE"

# ── 5. THE FLOORED RULE NAMES ITS CALL (knob-honesty-068) ───────────────────────────────────────────────
# A rule that spends its kLintMaxPerRule budget was disclosed (count_capped="1", findings_capped="1"), but the answer
# named no call that counts the rest: the budget had no flag, so the floor was a dead end on the CLI and in the SARIF
# a CI reads. Now --lint-max-per-rule=N raises the budget (the default stays kLintMaxPerRule), and a floored answer
# carries findings_next= (SARIF: run properties findingsNext) — the floored rules only, under a 10x budget. Fixture:
# one C file with 6000 gotos (raw captures past the 5000 default). RED on 255dc199 (no findings_next=, no flag).
GF="$TMP/gotofix"; mkdir -p "$GF"
python3 -c 'import sys; open( sys.argv[1], "w" ).write( "void f( void )\n{\nL: ;\n" + "    goto L;\n" * 6000 + "}\n" )' "$GF/g.c"
python3 -c 'import sys; open( sys.argv[1], "w" ).write( "void f( void )\n{\nL: ;\n" + "    goto L;\n" * 10 + "}\n" )' "$GF/../small.c"
mkdir -p "$TMP/smallfix"; mv "$GF/../small.c" "$TMP/smallfix/s.c"
lattr(){ printf '%s' "$2" | grep -oE "<lint [^>]*" | head -1 | grep -oE "(^| )$1=\"[^\"]*\"" | head -1 | sed -E 's/^ ?[a-z_]+="//; s/"$//'; }
grow(){ printf '%s' "$1" | grep -oE "<rule name=\"$2\"[^/]*/>" | head -1; }
G1="$( "$BIN" "$GF" --lint --no-cache 2>/dev/null )"
case "$( grow "$G1" goto )" in
    *'count="5000"'*' count_capped="1"'* ) ok "goto fixture: presence guard — 6000 gotos, count=5000 count_capped=\"1\" (the default budget is unchanged)" ;;
    * ) no "goto fixture: presence guard failed: $( grow "$G1" goto )" ;;
esac
GNEXT="$( lattr findings_next "$G1" )"
[ "$GNEXT" = "--lint --lint-select=goto --lint-max-per-rule=50000" ] \
    && ok "floored: the root names its call, findings_next=\"$GNEXT\" (the floored rule only, a 10x budget)" \
    || no "floored: findings_next='$GNEXT' (want --lint --lint-select=goto --lint-max-per-rule=50000)"
# paste it: the floor becomes the total, and that answer carries no findings_next (nothing left to recover)
G2="$( [ -n "$GNEXT" ] && "$BIN" "$GF" $GNEXT --no-cache 2>/dev/null )"
case "$( grow "$G2" goto )" in
    *'count="6000"'* ) case "$( grow "$G2" goto )" in *count_capped*) no "pasted: goto still count_capped: $( grow "$G2" goto )";; *) ok "pasted: goto count=\"6000\" — the floor became the total";; esac ;;
    * ) no "pasted findings_next did not count all 6000: $( grow "$G2" goto )" ;;
esac
[ -n "$G2" ] && [ -z "$( lattr findings_next "$G2" )" ] && [ -z "$( lattr findings_capped "$G2" )" ] \
    && ok "pasted: the uncapped answer carries neither findings_capped= nor findings_next=" \
    || no "pasted: findings_capped='$( lattr findings_capped "$G2" )' findings_next='$( lattr findings_next "$G2" )' on the re-run"
# negatives: nothing floored ⇒ no findings_next; the flag only raises (an explicit budget under the default floors sooner)
[ -z "$( lattr findings_next "$( "$BIN" "$TMP/smallfix" --lint --no-cache 2>/dev/null )" )" ] \
    && ok "negative: an unfloored answer carries no findings_next=" || no "negative: findings_next= on an answer nothing floored"
case "$( grow "$( "$BIN" "$TMP/smallfix" --lint --lint-max-per-rule=4 --no-cache 2>/dev/null )" goto )" in
    *'count="4"'*' count_capped="1"'* ) ok "negative: --lint-max-per-rule=4 floors 10 gotos at 4 (the flag IS the budget, both ways)" ;;
    * ) no "--lint-max-per-rule=4 not honoured on 10 gotos" ;;
esac
"$BIN" "$GF" --lint-max-per-rule=50000 --no-cache >/dev/null 2>&1; [ $? = 1 ] \
    && ok "refused: --lint-max-per-rule without --lint/--lint-rules exits 1 (never accepted and ignored)" \
    || no "--lint-max-per-rule without --lint was not refused"
"$BIN" "$GF" --lint --lint-max-per-rule=0 --no-cache >/dev/null 2>&1; [ $? = 1 ] \
    && ok "refused: --lint-max-per-rule=0 exits 1" || no "--lint-max-per-rule=0 was accepted"
# SARIF: the CI surface carries the same call (run properties), beside findingsCapped
GS="$( "$BIN" "$GF" --lint --sarif --no-cache 2>/dev/null )"
printf '%s' "$GS" | python3 -c '
import json, sys
d = json.load( sys.stdin ); p = d["runs"][0]["properties"]
sys.exit( 0 if p.get( "findingsCapped" ) is True and p.get( "findingsNext" ) == "--lint --lint-select=goto --lint-max-per-rule=50000 --sarif" else 1 )' 2>/dev/null \
    && ok "SARIF: run properties carry findingsCapped=true and the same findingsNext, --sarif kept" \
    || no "SARIF: run properties lack findingsNext (with --sarif): $( printf '%s' "$GS" | grep -oE '"properties":\{"findingsCapped"[^}]*' | head -1 )"
# …and PASTING it (shlex-split, as a CI step would) re-runs in the dialect it was read from (rv-knob-honesty-068 N4): the
# answer parses as SARIF (a native-XML answer would not), the floor is lifted and no findingsNext rides. RED on dd6e4c8e.
GSN="$( printf '%s' "$GS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["runs"][0]["properties"].get("findingsNext",""))' 2>/dev/null )"
python3 -c 'import shlex,sys; print( "\0".join( shlex.split( sys.argv[1] ) ), end = "" )' "$GSN" > "$TMP/gsn.argv"
( [ -n "$GSN" ] && xargs -0 "$BIN" "$GF" --no-cache < "$TMP/gsn.argv" 2>/dev/null ) | python3 -c '
import json, sys
p = json.load( sys.stdin )["runs"][0]["properties"]
sys.exit( 0 if p.get( "findingsCapped" ) is False and "findingsNext" not in p else 1 )' 2>/dev/null \
    && ok "SARIF: pasting findingsNext answers in SARIF, findingsCapped=false and no findingsNext" \
    || no "SARIF: pasting findingsNext ('$GSN') did not answer as SARIF with the floor lifted"
# user rules: the call keeps --lint-rules=DIR and selects the floored rule id
mkdir -p "$TMP/urules"; printf -- '- id: many-goto\n  language: c\n  severity: warn\n  message: goto\n  query: (goto_statement) @hit\n' > "$TMP/urules/g.yml"
U1="$( "$BIN" "$GF" --lint-rules="$TMP/urules" --no-cache 2>/dev/null )"
UNEXT="$( lattr findings_next "$U1" )"
[ "$UNEXT" = "--lint-rules=$TMP/urules --lint-select=many-goto --lint-max-per-rule=50000" ] \
    && ok "user rules: findings_next keeps the rules directory and selects the floored id" \
    || no "user rules: findings_next='$UNEXT'"
U2="$( [ -n "$UNEXT" ] && "$BIN" "$GF" $UNEXT --no-cache 2>/dev/null )"
URow="$( printf '%s' "$U2" | grep -oE '<rule name="many-goto"[^/]*/>' | head -1 )"
case "$URow" in *'count="6000"'*) ! printf '%s' "$URow" | grep -q 'count_capped' ;; *) false ;; esac \
    && ok "user rules: pasting it counts all 6000, and that row is no longer floored" || no "user rules: pasted run: $URow"
if printf '%s' "$G1" | xmllint --noout - 2>/dev/null; then ok "floored answer is well-formed XML"; else no "floored answer is not well-formed XML"; fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES ABOVE"
exit $fail
