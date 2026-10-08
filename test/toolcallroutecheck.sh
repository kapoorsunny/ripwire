#!/usr/bin/env bash
# toolcallroutecheck.sh — gate for hooks/ripwire-claude-toolroute.sh, the second router arm
# pre-registered in docs/EVALS.md ("A second router arm — route on the agent's FIRST TOOL CALL").
# Drives the hook against the committed corpus (test/toolcallroutefix/corpus.jsonl, built by
# gen_corpus.py) and asserts the registered bar: precision >= 0.95, harmful == 0, the per-session
# recommendation cap, notification abstention, control-arm silence, and exit-0-on-malformed-input.
#
# NEVER TOUCHES THE OPERATOR'S ~/.ripwire — RIPWIRE_HOME and TMPDIR are pinned to a sandbox for the
# whole run (the same posture hooks/ripwire-nudge.sh's own §FIXTURE guard documents and
# test/routingreportcheck.sh's fixtures rely on).
#
# Usage: test/toolcallroutecheck.sh [PATH_TO_RIPWIRE]      ($1 is BIN)
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
. "$ROOT/test/lib/clean-env.sh"   # a gate that builds a repo must not inherit GIT_DIR/GIT_WORK_TREE (gitenvhermeticcheck D)
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first"; exit 2; }
HOOK="$ROOT/hooks/ripwire-claude-toolroute.sh"
CORPUS="$ROOT/test/toolcallroutefix/corpus.jsonl"
[ -x "$HOOK" ] || { echo "no $HOOK"; exit 2; }
[ -f "$CORPUS" ] || { echo "no $CORPUS — run test/toolcallroutefix/gen_corpus.py first"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "toolcallroutecheck: jq is required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "toolcallroutecheck: python3 is required"; exit 2; }

TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*" || { fail=1; printf '  FAIL  could not write the PASS line for: %s\n' "$*"; }; return 0; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

# ---- sandbox: a `ripwire` on PATH pointing at BIN (the hook shells out to the bare name), and a
#      $RIPWIRE_HOME/$TMPDIR the hook writes into instead of the operator's real ~/.ripwire. ----
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"
ln -sf "$BIN" "$BINDIR/ripwire"
export PATH="$BINDIR:$PATH"
export RIPWIRE_HOME="$TMP/home"; mkdir -p "$RIPWIRE_HOME"
export TMPDIR="$TMP/tmp"; mkdir -p "$TMPDIR"
unset RIPWIRE_METER RIPWIRE_ROUTE_METER
# The unconfigured default arm is `auto` (issue #381), so the corpus pass below pins `treatment` to score the
# classifier on every row; the default itself is asserted separately in the "default arm" section.
export RIPWIRE_METER_ARM=treatment
LOG="$RIPWIRE_HOME/routing.jsonl"

run_hook()
{
    # run_hook TOOL_NAME TOOL_INPUT_JSON SESSION [CWD] -- prints the hook's stdout.
    local tn="$1" tin="$2" sess="$3" cwd="${4:-$ROOT}"
    jq -cn --arg tn "$tn" --argjson tin "$tin" --arg sess "$sess" --arg cwd "$cwd" \
        '{session_id:$sess,cwd:$cwd,tool_name:$tn,tool_input:$tin}' | "$HOOK"
}

echo "toolcallroutecheck: HOOK=$HOOK CORPUS=$CORPUS ($( wc -l <"$CORPUS" | tr -d ' ' ) rows)"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Main corpus pass. Each row runs once; stdout + the log's newly appended row (if any) are captured.
# The log is truncated before this pass so "how many rows did THIS pass add" is exact.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
: >"$LOG"
RESULTS="$TMP/results.jsonl"
: >"$RESULTS"

while IFS= read -r row
do
    [ -n "$row" ] || continue
    tn="$( printf '%s' "$row" | jq -r '.tool_name' )"
    tin="$( printf '%s' "$row" | jq -c '.tool_input' )"
    sess="$( printf '%s' "$row" | jq -r '.session_id' )"
    beforeLines="$( wc -l <"$LOG" | tr -d ' ' )"
    out="$( run_hook "$tn" "$tin" "$sess" )"
    rc=$?
    afterLines="$( wc -l <"$LOG" | tr -d ' ' )"
    loggedRow="null"
    if [ "$afterLines" -gt "$beforeLines" ]
    then
        loggedRow="$( tail -n1 "$LOG" )"
    fi
    jq -cn --argjson expect "$row" --arg out "$out" --argjson rc "$rc" --argjson logged "$loggedRow" \
        '{expect:$expect,out:$out,rc:$rc,logged:$logged}' >>"$RESULTS"
done < "$CORPUS"

# ---- scoring, in test/toolcallroutefix/score_corpus.py -- kept as a SEPARATE committed file rather
#      than an inline heredoc: macOS's shipped bash 3.2.57 mis-parses a `<<'HEREDOC'` body containing
#      an apostrophe when the heredoc sits inside a `$(...)` command substitution (confirmed with a
#      two-line repro; see that file's header). ----
SCORE="$( python3 "$ROOT/test/toolcallroutefix/score_corpus.py" "$RESULTS" )"
SCORE_RC=$?
echo "$SCORE"
if [ "$SCORE_RC" = 0 ]; then
    ok "corpus pass: precision >= 0.95, harmful == 0, no bad rc/json"
else
    no "corpus pass failed the registered bar (see breakdown above)"
fi

# ---- the binary under test must actually be consulted (binoverridecheck arm 4). The corpus's Read rows
#      name files that do not exist, so their honest fallback is --for and a ripwire stub that fails on
#      every invocation leaves the corpus score untouched. This row reads a REAL source file whose stem is
#      a symbol on this root, so the resolved_symbols guard has to reach the binary and get --expand back;
#      a dead binary degrades it to --for and the arm goes red. ----
binOut="$( run_hook Read "$( jq -cn --arg p "$ROOT/src/svector.h" '{file_path:$p}' )" "corpus-binprobe" "$ROOT" )"
if tail -n1 "$LOG" | jq -e '.status == "recommend" and .recommended == "--expand"' >/dev/null 2>&1; then
    ok "binary probe: a Read of src/svector.h resolves svector through the binary and recommends --expand"
else
    no "binary probe: a Read of src/svector.h did not yield --expand (binary unreachable or stem svector no longer a symbol) -- last row: $( tail -n1 "$LOG" | cut -c1-200 )"
fi

# ---- train20-cr C3's shape in this hook: a Read in a NON-git cwd must abstain with reason=no-repo, also when
#      the caller exports GIT_DIR naming another repository. With it exported, `git -C "$cwd" rev-parse
#      --show-toplevel` prints the non-git cwd as its own top level, so the hook routed there. RED on the hook
#      without the inherited-variable reset. The first row is the control: no GIT_DIR, same cwd, same answer. ----
NGCWD="$TMP/nongit"; mkdir -p "$NGCWD"
NGOTHER="$TMP/othergit"; mkdir -p "$NGOTHER"; git -C "$NGOTHER" init -q
NGREAD="$( jq -cn --arg p "$NGCWD/svector.h" '{file_path:$p}' )"
for ngcase in control GIT_DIR; do
    : >"$LOG"
    if [ "$ngcase" = control ]; then
        run_hook Read "$NGREAD" "nongit-$ngcase" "$NGCWD" >/dev/null; ngrc=$?
    else
        GIT_DIR="$NGOTHER/.git" run_hook Read "$NGREAD" "nongit-$ngcase" "$NGCWD" >/dev/null; ngrc=$?
    fi
    if [ "$ngrc" = 0 ] && tail -n1 "$LOG" | jq -e '.status == "abstain" and .reason == "no-repo"' >/dev/null 2>&1; then
        ok "non-git cwd ($ngcase): a Read abstains with reason=no-repo"
    else
        no "non-git cwd ($ngcase): rc=$ngrc, last row: $( tail -n1 "$LOG" | cut -c1-200 )"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Per-session cap: the 4th recommend-worthy event in one session abstains with reason=cap, and injects
# nothing, in either arm.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
: >"$LOG"
CAPSESS="cap-session-1"
declare -a CAPOUT
for i in 1 2 3 4; do
    CAPOUT[$i]="$( run_hook Bash "$( jq -cn --arg c "grep -rn patternCap$i src/" '{command:$c}' )" "$CAPSESS" )"
done
[ -n "${CAPOUT[1]}" ] && [ -n "${CAPOUT[2]}" ] && [ -n "${CAPOUT[3]}" ] \
    && ok "cap: calls 1-3 in a session recommend" || no "cap: an early call in the session did not recommend"
if [ -z "${CAPOUT[4]}" ]; then ok "cap: the 4th call in the session injects nothing"; else no "cap: the 4th call still injected: ${CAPOUT[4]}"; fi
tail -n1 "$LOG" | jq -e '.status == "abstain" and .reason == "cap"' >/dev/null 2>&1 \
    && ok "cap: the 4th call's logged row carries status=abstain reason=cap" \
    || no "cap: 4th row wrong -- $( tail -n1 "$LOG" )"
[ "$( wc -l <"$LOG" | tr -d ' ' )" = 4 ] && ok "cap: exactly 4 decision rows for 4 routable events" \
    || no "cap: expected 4 log rows, got $( wc -l <"$LOG" | tr -d ' ' )"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Control arm: writes the identical decision row, injects nothing.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
: >"$LOG"
export RIPWIRE_METER_ARM=control
COUT="$( run_hook Bash "$( jq -cn '{command:"grep -rn controlPattern src/"}' )" "control-session-1" )"
export RIPWIRE_METER_ARM=treatment
if [ -z "$COUT" ]; then ok "control arm: injects nothing"; else no "control arm: injected anyway -- $COUT"; fi
tail -n1 "$LOG" | jq -e '.status == "recommend" and .arm == "control" and .recommended == "--grep"' >/dev/null 2>&1 \
    && ok "control arm: still logs the recommend decision (status/arm/recommended all correct)" \
    || no "control arm: logged row wrong -- $( tail -n1 "$LOG" )"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Default arm (issue #381): no RIPWIRE_METER_ARM and no meter.conf resolves to `auto`, the meter's own
# session-hash split. It used to be `treatment` for every session, so the registered treatment-minus-
# control difference could never be computed. RED on a hook whose default is treatment. An explicit
# `arm=treatment` in meter.conf is still honoured.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
DEFBAD=""; DEFCTL=0; DEFTRT=0; DEFCTLSID=""
for sid in d1 d2 d3 d4 d5 d6 d7 d8; do
    h="$( printf '%s' "$sid" | cksum | cut -d' ' -f1 )"
    if [ "$(( h % 100 ))" -lt 50 ]; then want=control; DEFCTL=$(( DEFCTL + 1 )); [ -n "$DEFCTLSID" ] || DEFCTLSID="$sid"; else want=treatment; DEFTRT=$(( DEFTRT + 1 )); fi
    : >"$LOG"
    ( unset RIPWIRE_METER_ARM; run_hook Bash "$( jq -cn --arg c "grep -rn defaultArm$sid src/" '{command:$c}' )" "$sid" >/dev/null )
    got="$( tail -n1 "$LOG" | jq -r '.arm // "<missing>"' 2>/dev/null )"
    [ "$got" = "$want" ] || DEFBAD="$DEFBAD [$sid -> $got, auto says $want]"
done
[ -z "$DEFBAD" ] && [ "$DEFCTL" -gt 0 ] && [ "$DEFTRT" -gt 0 ] \
    && ok "default arm: unconfigured toolroute follows the auto split (both arms populated: $DEFCTL control / $DEFTRT treatment of 8)" \
    || no "default arm: unconfigured toolroute did not follow the auto split:$DEFBAD (control=$DEFCTL treatment=$DEFTRT)"
: >"$LOG"; printf 'arm=treatment\n' >"$RIPWIRE_HOME/meter.conf"
( unset RIPWIRE_METER_ARM; run_hook Bash "$( jq -cn '{command:"grep -rn confTreat src/"}' )" "$DEFCTLSID" >/dev/null )
[ -n "$DEFCTLSID" ] && [ "$( tail -n1 "$LOG" | jq -r '.arm // "<missing>"' 2>/dev/null )" = "treatment" ] \
    && ok "default arm: an explicit meter.conf arm=treatment is honoured over the auto default" \
    || no "default arm: meter.conf arm=treatment gave $( tail -n1 "$LOG" | cut -c1-160 ) for control-side session [$DEFCTLSID]"
rm -f "$RIPWIRE_HOME/meter.conf"

# meter.conf PARSING (issue #381 fix round 1; same arms as A10-A18 in routehookcheck, for this copy of
# resolve_arm): a final line without a newline is not lost, a CRLF value is not read as treatment, and a
# near-miss value still reads as treatment. Each session sits on the side the buggy reading would not give.
DEFTRTSID=""
for sid in d1 d2 d3 d4 d5 d6 d7 d8; do
    h="$( printf '%s' "$sid" | cksum | cut -d' ' -f1 )"; [ "$(( h % 100 ))" -ge 50 ] && { DEFTRTSID="$sid"; break; }
done
conf_arm()   # conf_arm LABEL SESSION CONFBYTES(printf format) WANT
{
    : >"$LOG"; printf "$3" >"$RIPWIRE_HOME/meter.conf"
    ( unset RIPWIRE_METER_ARM; run_hook Bash "$( jq -cn --arg c "grep -rn confArm$1 src/" '{command:$c}' )" "$2" >/dev/null )
    got="$( tail -n1 "$LOG" | jq -r '.arm // "<missing>"' 2>/dev/null )"
    rm -f "$RIPWIRE_HOME/meter.conf"
    [ -n "$2" ] && [ "$got" = "$4" ] && ok "$1: toolroute meter.conf [$3] -> $4" \
        || no "$1: toolroute meter.conf [$3] gave arm=[$got], want $4 (session [$2])"
}
conf_arm T10 "$DEFCTLSID" 'arm=treatment' treatment
conf_arm T11 "$DEFTRTSID" 'arm=control' control
conf_arm T12 "$DEFTRTSID" 'arm=control\r\n' control
conf_arm T13 "$DEFCTLSID" 'arm=auto\r\n' control
conf_arm T14 "$DEFTRTSID" 'sweep=0\r\narm=control\r\nenabled=1\r\n' control
conf_arm T15 "$DEFTRTSID" 'sweep=0\narm=control' control
conf_arm T16 "$DEFCTLSID" 'arm=controlx\n' treatment
conf_arm T17 "$DEFCTLSID" 'arm=control\rx\n' treatment
conf_arm T18 "$DEFCTLSID" 'arm=treatment\r\n' treatment

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# This hook's notification guard matches markers INSIDE a tool input; it deliberately does NOT carry the
# prompt hooks' `<channel`/`<agent-message` wrapper prefixes (issue #381): a tool call is the agent's own
# action, never a harness-delivered event, and `<channel>` is ordinary RSS/XML text that a grep pattern
# legitimately names. A grep for it must still route.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
: >"$LOG"
CHOUT="$( run_hook Grep "$( jq -cn '{pattern:"<channel>",path:"src"}' )" "chan-tool-1" )"
tail -n1 "$LOG" | jq -e '.status == "recommend"' >/dev/null 2>&1 && [ -n "$CHOUT" ] \
    && ok "a Grep whose pattern names <channel> still routes (the guard is for prompt wrappers, not tool inputs)" \
    || no "a Grep for <channel> was suppressed: out=[$CHOUT] row=$( tail -n1 "$LOG" | cut -c1-160 )"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Malformed / degenerate input: exit 0, empty (or valid-JSON) stdout, never a crash.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
: >"$LOG"
for label_input in \
    "not-json:not json at all" \
    "empty:" \
    "missing-tool-name:{\"cwd\":\"$ROOT\"}" \
    "missing-cwd:{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"grep -rn foo src/\"}}" \
    "bad-cwd:{\"tool_name\":\"Bash\",\"cwd\":\"/no/such/dir\",\"tool_input\":{\"command\":\"grep -rn foo src/\"}}"
do
    label="${label_input%%:*}"
    payload="${label_input#*:}"
    out="$( printf '%s' "$payload" | "$HOOK" 2>"$TMP/stderr" )"; rc=$?
    if [ "$rc" != 0 ]; then
        no "malformed[$label]: exited $rc, expected 0"
        continue
    fi
    if [ -z "$out" ]; then
        ok "malformed[$label]: exit 0, empty stdout"
    elif printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        ok "malformed[$label]: exit 0, valid JSON stdout"
    else
        no "malformed[$label]: exit 0 but stdout is neither empty nor valid JSON: $out"
    fi
done
[ "$( wc -l <"$LOG" 2>/dev/null | tr -d ' ' )" = 0 ] && ok "malformed inputs write no log row" \
    || no "malformed inputs wrote a log row unexpectedly"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# No prompt/command text retained in the log: every field of every row is a fixed enum, a hash, or a
# timestamp -- never the raw command/pattern/path.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
: >"$LOG"
run_hook Bash "$( jq -cn '{command:"grep -rn ZZZ_SECRET_MARKER_ZZZ src/"}' )" "privacy-session-1" >/dev/null
if grep -q "ZZZ_SECRET_MARKER_ZZZ" "$LOG"; then
    no "privacy: the grep pattern leaked into routing.jsonl verbatim"
else
    ok "privacy: the grep pattern does not appear verbatim in the log"
fi
tail -n1 "$LOG" | jq -e 'has("session_hash") and (.session_hash | type == "string") and (has("detail_hash"))' >/dev/null 2>&1 \
    && ok "privacy: row carries session_hash/detail_hash, not raw text" \
    || no "privacy: row schema missing hash fields"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# router="toolcall" on every row -- distinguishable from hooks/ripwire-claude-route.sh's router="prompt".
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
[ "$( jq -r '.router' <"$LOG" | sort -u )" = "toolcall" ] && ok "every row carries router=\"toolcall\"" \
    || no "a row is missing router=\"toolcall\" -- $( jq -r '.router' <"$LOG" | sort -u )"

echo ""
if [ "$fail" = 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "SOME FAILED"
    exit 1
fi
