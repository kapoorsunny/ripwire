#!/usr/bin/env bash
# forspinecheck.sh — a --for answer names who DRIVES its top seeds: the nearest proven callers (the upward spine) and the
# tables a seed is stored in, as names and file:line only, in the answer's tail.
#
#   test/forspinecheck.sh                          # uses build/ripwire on test/forcompletefix
#   RIPWIRE_BIN=asan/ripwire test/forspinecheck.sh
#   test/forspinecheck.sh build_base/ripwire       # the RED run (a pre-change binary)
#
# THE GAP. A --for answer ranks the symbols that MATCH the question and, in <hops>, what its top rows CALL. Nothing in
# it says what calls them. On a "how does X happen" question the driver is often the missing half: a scan routine is
# named but not the refresh check that runs it from the main loop; a key action is named but not the dispatcher loop
# that reaches it; draw functions are named but not the struct-array table of function pointers that selects them.
# Measured on graded answers (paraphrased here as minimal code): the gold item was the CALLER of a seed, one or two
# hops up, toward a loop or the program entry; a peer that walked call edges upward from its seeds named it.
#
# THE CONTRACT (one <spine> element in the --for answer's tail, after the ranked rows; absent when it has no row):
#   <spine seeds=N shown=N total=N capped=0|1> with rows <u n= p= of= [via=]/>:
#     * n= p=     — a caller's name and its definition's file:line (the same spelling --callers prints).
#     * of=       — the symbol it calls: a top seed (one of the answer's top 1-3 callable rows) or another <u> row's n=.
#                   A chain is at most 2 hops from a seed.
#     * PROVEN EDGES ONLY. A row with no via= is a call edge --callers lists for of=. A call bound by NAME ALONE (no
#       receiver evidence: an untyped parameter, a C function-pointer field spelled like a free function) is never a
#       plain row: it is absent, or carries via="name".
#     * via="value": n= STORES of= as a value (a table slot, an initializer, a field) — REFVAL's <vr> row: n= is the
#       <vr>'s in_id= (the enclosing definition) when it has one, else the root of its into= (the table), at= its
#       bind= file:line. Not a call. A module export (module.exports.X / exports.X) is not a table that runs X and is never such a row.
#     * NAMES ONLY: no callee claim, no body, no doc, no signature inside <spine>; no attribute outside n p of via at.
#     * a caller in a TEST file is not on the runtime path and is never a row.
#   The rows of a seed that has none are simply absent (no row says "none").
#
# ARMS (one fixture root per language under test/forcompletefix/; each indexed on its own):
#   (C)  C:  (C1) scan chain: Sampler_collectAll <- Monitor_refresh <- Monitor_loop (2 hops, the main loop), and the
#            test caller test_collect_all is never a row. (C2) dispatcher loop: Board_onKey <- Monitor_loop.
#            (C3) struct-array fn-pointer table: Gauge_drawBar/Text/Dots are stored in Gauge_modes[] -> a via="value"
#            row n=Gauge_modes at=src/gauge.c:2x. (C4) key table: actionCycleStyle is stored into keyTable[] by
#            Keys_bind -> a via="value" row n=Keys_bind (or n=keyTable) at=src/keys.c:22.
#            (C5) name-only near miss: `sink->flush( s )` (a function-pointer field) is never a plain caller row of the
#            free function flush; the bare same-file call in Monitor_flushSamples IS one (the near miss that must stay).
#   (J)  JS: (J1) runJob <- JobQueue.drain (the while loop) <- Worker.tick (a constructor-assigned field: proven).
#            (J2) relay's `target.drain()` (an untyped parameter) is never a plain row of drain.
#            (J3) resizeImage is stored in the `handlers` object literal -> via="value" n=handlers at=lib/queue.js:14;
#            runJob's module.exports binding is never a via="value" row.
#   (P)  Python: (P1) fetch_entry <- Resolver.resolve (self.cache = LookupCache(): proven) <- App.on_lookup.
#            (P2) Downloader.pull's `source.fetch_entry( url )` (an untyped parameter) is never a plain row.
#            (P3) dispatcher loop: deliver <- _drain <- run_forever.
#   (T)  TS: (T1) createContext <- Application.handle.
#   (S)  shape, on EVERY answer above: every plain row is an edge the same binary's --callers=<of> lists (n= and p=),
#        every via="value" row is a <vr> of --callers=<of> (at= == bind=); rows carry only n p of via at; no <c>,
#        <calls>, <doc>, CDATA inside <spine>; of= chains reach a non-<u> name within 2 hops; shown <= total;
#        capped == (shown < total); shown <= 6; the element sits after </sigs>.
#   (D)  dialect parity: --for --json carries the same rows (name, path:line, of, via) as the XML answer of (C1).
#   (O)  outside --for: --callers, --impact, --pack-signatures and the default map never carry <spine> / "spine".
#   (L)  legend: --legend=full defines <spine>, of=, via="value" and says what they do NOT mean (not every caller; a
#        value row is not a call).
#   (K)  the predicates can fail: a synthetic answer with a plain name-only row, an answer with a row --callers does not
#        list, and an answer with no <ctx> root are each caught; every binary run must exit 0.
#
# FLOORS — named, not gated here:
#   * loops are not detected: "toward a loop or entry" is the 2-hop bound, not a recognised loop statement.
#   * a call inside a nested closure/arrow is attributed as the extractor attributes it today (no arm).
#   * value rows exist only where REFVAL extracts a binding (its own floors: JS object literals of IMPORTED names).
#   * which caller a fan-in > row cap keeps is not pinned (capped=1 discloses the cut).
#
# Exits non-zero on any failure.

set -u
export PYTHONDONTWRITEBYTECODE=1
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
. "$ROOT/test/lib/clean-env.sh"   # a gate that indexes a repo must not inherit GIT_DIR/GIT_WORK_TREE (gitenvhermeticcheck D)
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"          # allow a repo-relative binary
CORPUS="$ROOT/test/forcompletefix"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*" || { fail=1; printf '  FAIL  could not write the PASS line for: %s\n' "$*"; }; return 0; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
[ -d "$CORPUS" ] || { echo "fixture missing: $CORPUS"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 2; }
echo "forspinecheck: BIN=$BIN  CORPUS=$CORPUS"

# run ROOT OUTFILE ARGS… — one binary run against a fixture root; stdout to OUTFILE, its exit status to OUTFILE.rc
run(){ local r="$1" f="$2"; shift 2; ( cd "$CORPUS/$r" && "$BIN" . --no-cache "$@" >"$f" 2>"$f.err" ); printf '%s' "$?" >"$f.rc"; }
# ran_ok FILE LABEL — the run behind FILE exited 0 (a non-zero exit FAILs the arm, whatever it printed)
ran_ok(){ local rc; rc="$( cat "$1.rc" 2>/dev/null )"; [ "$rc" = 0 ] && return 0; no "$2: the binary exited rc=${rc:-missing}"; return 1; }

# the predicate library — every check reads ONE answer file and prints PASS/FAIL lines itself
cat >"$TMP/spine.py" <<'PY'
import json, re, sys

def attrs( tag ):
    return dict( re.findall( r'\s([a-z_]+)="([^"]*)"', tag ) )

def load( path ):
    return open( path, encoding="utf-8", errors="replace" ).read()

def ctx_ok( doc ):
    # an answer is only judged when it is a --for document with ranked rows; anything else is NOROOT
    return re.search( r"<ctx [^>]*>", doc ) is not None and "<sigs" in doc

def spine( doc ):
    """(open-tag attrs, [row attrs], raw inner text) of the <spine> element, or None when absent."""
    m = re.search( r"<spine(\s[^>]*)?>(.*?)</spine>", doc, re.S )
    if not m:
        return None
    inner = m.group( 2 )
    rows = [ attrs( t ) for t in re.findall( r"<u\s[^>]*/>", inner ) ]
    return attrs( "<spine" + ( m.group( 1 ) or "" ) + ">" ), rows, inner

def callers_rows( path ):
    """--callers answer -> ({(n, p)}, [vr attrs]) or None when the answer has no matched root."""
    doc = load( path )
    root = re.search( r"<callers [^>]*>", doc )
    if not root or ' defs="' not in root.group( 0 ):
        return None
    rows = { ( a.get( "n" ), a.get( "p" ) ) for a in ( attrs( t ) for t in re.findall( r"<s [^>]*/>", doc ) ) }
    vrs = [ attrs( t ) for t in re.findall( r"<vr [^>]*/>", doc ) ]
    return rows, vrs
PY

# spinecheck ANSWER LABEL MODE ARGS… — MODE has one of:
#   has N OF [P]        a plain row n=N of=OF (and p=P when given) is present
#   value N OF ATPFX    a via="value" row n=N of=OF whose at= starts with ATPFX is present
#   notplain N OF       no row n=N of=OF without via="name" (absent or hedged)
#   absent N            no row with n=N at all
#   novalue_into PFX    no via="value" row whose at=/n= came from an into= starting with PFX (module.exports, exports)
spinecheck(){
    local f="$1" label="$2"; shift 2
    python3 - "$TMP/spine.py" "$f" "$label" "$@" <<'PY'
import sys
exec( open( sys.argv[ 1 ] ).read() )
path, label, mode = sys.argv[ 2 ], sys.argv[ 3 ], sys.argv[ 4 ]
args = sys.argv[ 5: ]
doc = load( path )
if not ctx_ok( doc ):
    print( "  FAIL  %s: NOROOT (no --for <ctx>/<sigs> answer)" % label ); sys.exit( 1 )
sp = spine( doc )
rows = sp[ 1 ] if sp else []
def plain( r ): return r.get( "via" ) is None
if mode == "has":
    n, of = args[ 0 ], args[ 1 ]; p = args[ 2 ] if len( args ) > 2 else None
    hit = [ r for r in rows if r.get( "n" ) == n and r.get( "of" ) == of and plain( r ) and ( p is None or r.get( "p" ) == p ) ]
    good = bool( hit )
    why = "plain <u n=%s of=%s%s>" % ( n, of, ( " p=%s" % p ) if p else "" )
elif mode == "value":
    n, of, at = args
    hit = [ r for r in rows if r.get( "n" ) == n and r.get( "of" ) == of and r.get( "via" ) == "value" and r.get( "at", "" ).startswith( at ) ]
    good = bool( hit )
    why = "<u n=%s of=%s via=value at=%s…>" % ( n, of, at )
elif mode == "notplain":
    n, of = args
    bad = [ r for r in rows if r.get( "n" ) == n and r.get( "of" ) == of and r.get( "via" ) not in ( "name", ) ]
    good = not bad
    why = "no unhedged <u n=%s of=%s> (name-only edge)" % ( n, of )
elif mode == "absent":
    n = args[ 0 ]
    good = not [ r for r in rows if r.get( "n" ) == n ]
    why = "no <u n=%s>" % n
elif mode == "novalue_into":
    pfx = args[ 0 ]
    bad = [ r for r in rows if r.get( "via" ) == "value" and ( r.get( "n", "" ).startswith( pfx ) or r.get( "n" ) in ( "module", "exports" ) ) ]
    good = not bad
    why = "no via=value row from an %s… binding" % pfx
else:
    print( "  FAIL  %s: unknown mode %s" % ( label, mode ) ); sys.exit( 1 )
state = "PASS" if good else "FAIL"
print( "  %s  %s: %s%s" % ( state, label, why, "" if sp or good else " [no <spine> element]" ) )
sys.exit( 0 if good else 1 )
PY
    [ $? -eq 0 ] || { fail=1; return 1; }
}

# shapecheck ROOT ANSWER LABEL — arm (S): every row is backed by the same binary's --callers answer for its of=; names
# only; bounded; placed after </sigs>. Runs --callers=<of> for each distinct of= (recorded, rc checked).
shapecheck(){
    local r="$1" f="$2" label="$3"
    python3 - "$TMP/spine.py" "$f" "$label" "$CORPUS/$r" "$BIN" "$TMP" <<'PY'
import os, re, subprocess, sys
exec( open( sys.argv[ 1 ] ).read() )
path, label, root, binp, tmp = sys.argv[ 2: 7 ]
doc = load( path )
bad = []
if not ctx_ok( doc ):
    print( "  FAIL  %s: NOROOT" % label ); sys.exit( 1 )
sp = spine( doc )
if sp is None:
    print( "  FAIL  %s: no <spine> element to check the shape of" % label ); sys.exit( 1 )
head, rows, inner = sp
if not rows:
    bad.append( "an empty <spine> element (it must be absent when it has no row)" )
for k in ( "shown", "total", "capped" ):
    if not re.fullmatch( r"[0-9]+", head.get( k, "" ) ):
        bad.append( "%s= missing or not numeric on <spine>" % k )
if not bad:
    shown, total, capped = int( head[ "shown" ] ), int( head[ "total" ] ), int( head[ "capped" ] )
    if shown != len( rows ): bad.append( "shown=%d but %d <u> rows" % ( shown, len( rows ) ) )
    if shown > total: bad.append( "shown=%d > total=%d" % ( shown, total ) )
    if capped != ( 1 if shown < total else 0 ): bad.append( "capped=%d disagrees with shown=%d total=%d" % ( capped, shown, total ) )
    if shown > 6: bad.append( "shown=%d > 6 rows" % shown )
for forbidden in ( "<c ", "<calls", "<doc", "CDATA", "<d ", "<h " ):
    if forbidden in inner: bad.append( "%r inside <spine> (names only)" % forbidden )
for r in rows:
    extra = set( r ) - { "n", "p", "of", "via", "at" }
    if extra: bad.append( "row %s carries %s" % ( r.get( "n" ), sorted( extra ) ) )
    if not re.fullmatch( r".+:[0-9]+", r.get( "p", "" ) ): bad.append( "row %s p=%r is not file:line" % ( r.get( "n" ), r.get( "p" ) ) )
    if r.get( "via" ) not in ( None, "value", "name" ): bad.append( "row %s via=%r" % ( r.get( "n" ), r.get( "via" ) ) )
    if r.get( "via" ) == "value" and not re.fullmatch( r".+:[0-9]+", r.get( "at", "" ) ): bad.append( "value row %s has no at=file:line" % r.get( "n" ) )
# depth: follow of= through <u> rows (plain/hedged call rows only) to a name that is not a <u> row — at most 2 hops
callerOf = {}
for r in rows:
    if r.get( "via" ) != "value":
        callerOf.setdefault( r[ "n" ], [] ).append( r[ "of" ] )
def depth( name, seen ):
    if name not in callerOf or name in seen: return 0
    return 1 + max( depth( o, seen | { name } ) for o in callerOf[ name ] )
for r in rows:
    if r.get( "via" ) != "value" and 1 + depth( r[ "of" ], { r[ "n" ] } ) > 2:
        bad.append( "row %s is more than 2 hops from a seed" % r[ "n" ] )
# placement: in the tail, after the ranked rows
if doc.find( "<spine" ) < doc.find( "</sigs>" ):
    bad.append( "<spine> precedes </sigs> (it belongs in the answer's tail)" )
# backing: every row is an edge (or value ref) the same binary's --callers lists for of=
cache = {}
for r in rows:
    of = r[ "of" ]
    if of not in cache:
        out = os.path.join( tmp, "callers.%s.%s.xml" % ( os.path.basename( root ), re.sub( r"[^A-Za-z0-9_]", "_", of ) ) )
        with open( out, "w" ) as fh:
            rc = subprocess.run( [ binp, ".", "--no-cache", "--callers=" + of ], cwd=root, stdout=fh, stderr=subprocess.DEVNULL ).returncode
        cache[ of ] = ( rc, callers_rows( out ) )
    rc, cr = cache[ of ]
    if rc != 0 or cr is None:
        bad.append( "--callers=%s did not answer (rc=%d) — row %s unverifiable" % ( of, rc, r[ "n" ] ) ); continue
    plainRows, vrs = cr
    if r.get( "via" ) == "value":
        if not [ v for v in vrs if v.get( "bind" ) == r.get( "at" ) and ( v.get( "in_id" ) == r[ "n" ] or v.get( "into", "" ).split( "[" )[ 0 ].split( "." )[ 0 ] == r[ "n" ] ) ]:
            bad.append( "value row %s of=%s at=%s is not a <vr> of --callers=%s" % ( r[ "n" ], of, r.get( "at" ), of ) )
    elif ( r[ "n" ], r.get( "p" ) ) not in plainRows:
        bad.append( "row %s p=%s is not a caller --callers=%s lists" % ( r[ "n" ], r.get( "p" ), of ) )
if bad:
    for b in bad: print( "  FAIL  %s: %s" % ( label, b ) )
    sys.exit( 1 )
print( "  PASS  %s: %d rows, every row backed by --callers, names only, <= 2 hops, after </sigs>" % ( label, len( rows ) ) )
PY
    [ $? -eq 0 ] || { fail=1; return 1; }
}

# ask ROOT TAG QUESTION — run --for and echo the answer path
ask(){ local f="$TMP/$1.$2.xml"; run "$1" "$f" "--for=$3"; printf '%s' "$f"; }

echo "(C) C: scan chain, dispatcher loop, fn-pointer tables, a name-only field call"
C1="$( ask c q1 'How does the sampler collect probe readings?' )"
if ran_ok "$C1" "C1"; then
    spinecheck "$C1" "C1 first hop"  has Monitor_refresh Sampler_collectAll src/monitor.c:4
    spinecheck "$C1" "C1 second hop" has Monitor_loop Monitor_refresh src/monitor.c:14
    spinecheck "$C1" "C1 a test caller is not on the runtime path" absent test_collect_all
    shapecheck c "$C1" "S/C1"
fi
C2="$( ask c q2 'How does a key press reach the focused board widget?' )"
if ran_ok "$C2" "C2"; then
    spinecheck "$C2" "C2 dispatcher loop" has Monitor_loop Board_onKey src/monitor.c:14
    shapecheck c "$C2" "S/C2"
fi
C3="$( ask c q3 'How does a gauge get drawn in each display style?' )"
if ran_ok "$C3" "C3"; then
    spinecheck "$C3" "C3 struct-array table holds the bar draw fn" value Gauge_modes Gauge_drawBar src/gauge.c:
    shapecheck c "$C3" "S/C3"
fi
C4="$( ask c q4 'Which key action cycles the gauge style and how is it bound?' )"
if ran_ok "$C4" "C4"; then
    spinecheck "$C4" "C4 key table binding" value Keys_bind actionCycleStyle src/keys.c:22
    shapecheck c "$C4" "S/C4"
fi
C5="$( ask c q5 'How does the monitor flush buffered samples?' )"
if ran_ok "$C5" "C5"; then
    spinecheck "$C5" "C5 a fn-pointer field call is not a proven caller" notplain Sink_drainSamples flush
    spinecheck "$C5" "C5 near miss: the bare same-file call stays"      has Monitor_flushSamples flush src/sink.c:20
    shapecheck c "$C5" "S/C5"
fi

echo "(J) JS: a job loop, a constructed field, an untyped parameter, an object-literal handler table"
J1="$( ask js q6 'How does a queued job get run?' )"
if ran_ok "$J1" "J1"; then
    spinecheck "$J1" "J1 the drain loop"                    has drain runJob lib/queue.js:37
    spinecheck "$J1" "J1 a constructor-assigned field is proven" has tick drain lib/worker.js:10
    spinecheck "$J1" "J2 an untyped parameter is not proven"  notplain relay drain
    shapecheck js "$J1" "S/J1"
fi
J3="$( ask js q7 'How does a resize job pick its handler?' )"
if ran_ok "$J3" "J3"; then
    spinecheck "$J3" "J3 object-literal handler table" value handlers resizeImage lib/queue.js:14
    spinecheck "$J3" "J3 an export is not a dispatch table" novalue_into module.exports
    shapecheck js "$J3" "S/J3"
fi

echo "(P) Python: a constructed field, an untyped parameter, a message pump loop"
P1="$( ask py q8 'How does the lookup cache fetch an entry?' )"
if ran_ok "$P1" "P1"; then
    spinecheck "$P1" "P1 first hop (self.cache = LookupCache())" has resolve fetch_entry src/pump/resolver.py:8
    spinecheck "$P1" "P1 second hop"                           has on_lookup resolve src/pump/app.py:10
    spinecheck "$P1" "P2 an untyped parameter is not proven"   notplain pull fetch_entry
    shapecheck py "$P1" "S/P1"
fi
P3="$( ask py q9 'How does the message pump deliver queued messages?' )"
if ran_ok "$P3" "P3"; then
    spinecheck "$P3" "P3 the pump loop, hop 1" has _drain deliver src/pump/loop.py:13
    spinecheck "$P3" "P3 the pump loop, hop 2" has run_forever _drain src/pump/loop.py:9
    shapecheck py "$P3" "S/P3"
fi

echo "(T) TS"
T1="$( ask ts q10 'How is a per-request context created?' )"
if ran_ok "$T1" "T1"; then
    spinecheck "$T1" "T1 createContext's caller" has handle createContext src/application.ts:20
    shapecheck ts "$T1" "S/T1"
fi

echo "(D) dialect parity: --for --json carries the rows the XML answer of C1 carries"
DJ="$TMP/c.q1.json"; run c "$DJ" "--for=How does the sampler collect probe readings?" --json
if ran_ok "$DJ" "D"; then
    python3 - "$TMP/spine.py" "$C1" "$DJ" <<'PY'
import json, sys
exec( open( sys.argv[ 1 ] ).read() )
x = spine( load( sys.argv[ 2 ] ) )
try:
    j = json.loads( load( sys.argv[ 3 ] ) )
except ValueError as e:
    print( "  FAIL  D: --for --json is not JSON (%s)" % e ); sys.exit( 1 )
js = j.get( "spine" )
xr = sorted( ( r.get( "n" ), r.get( "p" ), r.get( "of" ), r.get( "via" ) ) for r in ( x[ 1 ] if x else [] ) )
jr = sorted( ( r.get( "n" ), r.get( "p" ), r.get( "of" ), r.get( "via" ) ) for r in ( ( js or {} ).get( "rows" ) or [] ) )
if not xr:
    print( "  FAIL  D: the XML answer has no spine rows to compare" ); sys.exit( 1 )
if xr != jr:
    print( "  FAIL  D: JSON spine rows %s != XML rows %s" % ( jr, xr ) ); sys.exit( 1 )
print( "  PASS  D: JSON \"spine\" rows equal the XML <spine> rows (%d)" % len( xr ) )
PY
    [ $? -eq 0 ] || fail=1
fi

echo "(O) outside --for nothing changes shape: no <spine> on other verbs"
for spec in "callers:--callers=Sampler_collectAll" "impact:--impact=Sampler_collectAll" "packsig:--pack-signatures" "map:"; do
    tag="${spec%%:*}"; arg="${spec#*:}"; f="$TMP/c.out.$tag.xml"
    if [ -n "$arg" ]; then run c "$f" "$arg"; else run c "$f"; fi
    if ran_ok "$f" "O/$tag"; then
        if [ -s "$f" ] && ! grep -q -e '<spine' -e '"spine"' "$f"; then ok "O/$tag: no spine element"; else no "O/$tag: empty answer or a spine element outside --for"; fi
    fi
done

echo "(L) legend: the full legend defines the spine and says what it does not mean"
LG="$TMP/c.q1.legend.xml"; run c "$LG" "--for=How does the sampler collect probe readings?" --legend=full
if ran_ok "$LG" "L"; then
    python3 - "$LG" <<'PY'
import re, sys
doc = open( sys.argv[ 1 ], encoding="utf-8", errors="replace" ).read()
legend = " ".join( re.findall( r"<!--(.*?)-->", doc, re.S ) )
need = [ ( r"<spine", "defines <spine>" ), ( r"\bof=", "defines of=" ), ( r'via="?value', "defines via=value" ),
         ( r"(?i)not (every|all|a complete)[^.;]*caller", "says the rows are not every caller" ),
         ( r"(?i)(not a (proven )?call|never a call)", "says a value row is not a call" ) ]
bad = [ what for rx, what in need if not re.search( rx, legend ) ]
if bad:
    print( "  FAIL  L: the legend does not %s" % "; ".join( bad ) ); sys.exit( 1 )
print( "  PASS  L: legend defines <spine>/of=/via=value with its NOT-meaning" )
PY
    [ $? -eq 0 ] || fail=1
fi

echo "(K) the predicates can fail"
K1="$TMP/k1.xml"
printf '<ctx task="t"><sigs></sigs><spine seeds="1" shown="1" total="1" capped="0"><u n="relay" p="lib/worker.js:22" of="drain"/></spine></ctx>' >"$K1"
if ( spinecheck "$K1" "K1 (expected FAIL)" notplain relay drain ) >/dev/null 2>&1; then no "K1: a plain name-only row was not caught"; else ok "K1: a plain name-only row is caught"; fi
K2="$TMP/k2.xml"
printf '<ctx task="t"><sigs></sigs><spine seeds="1" shown="1" total="1" capped="0"><u n="Monitor_new" p="src/monitor.c:30" of="Sampler_collectAll"/></spine></ctx>' >"$K2"
if ( shapecheck c "$K2" "K2 (expected FAIL)" ) >/dev/null 2>&1; then no "K2: a row --callers does not list was not caught"; else ok "K2: a row --callers does not list is caught"; fi
K3="$TMP/k3.xml"; printf '<callers of="x" found="0"/>' >"$K3"
if ( spinecheck "$K3" "K3 (expected FAIL)" absent anything ) >/dev/null 2>&1; then no "K3: a NOROOT document passed"; else ok "K3: a document with no --for root is never a pass"; fi
K4="$TMP/k4.xml"
printf '<ctx task="t"><sigs></sigs><spine seeds="1" shown="1" total="1" capped="0"><u n="Monitor_refresh" p="src/monitor.c:4" of="Sampler_collectAll"><calls><c n="Board_paint"/></calls></u></spine></ctx>' >"$K4"
if ( shapecheck c "$K4" "K4 (expected FAIL)" ) >/dev/null 2>&1; then no "K4: a callee claim inside <spine> was not caught"; else ok "K4: a callee claim inside <spine> is caught"; fi

if [ "$fail" -ne 0 ]; then
    echo "forspinecheck: FAIL"
    exit 1
fi
echo "forspinecheck: PASS"
exit 0
