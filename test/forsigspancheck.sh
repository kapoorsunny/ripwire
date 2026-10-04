#!/usr/bin/env bash
# forsigspancheck.sh — a --for <d> row says where its definition ENDS (e=), the one-hop slots go to top rows whose
# edges are proven, and the defining code outranks the docs that describe it.
#
#   test/forsigspancheck.sh                          # uses build/ripwire on test/forcompletefix
#   RIPWIRE_BIN=asan/ripwire test/forsigspancheck.sh
#   test/forsigspancheck.sh build_base/ripwire       # the RED run (a pre-change binary)
#
# THE GAPS (each seen in graded answers; the fixture paraphrases them as minimal code):
#   (1) SPAN. A <d> row carried only l= (the line of the definition's name). "Which body holds line N" — the question a
#       reader asks of every gold item that lives INSIDE a function — was not answerable from the row; a peer that
#       printed start-end lines got the credit.
#   (2) HOP SLOT. The compact answer hop-expands its ranked head in rank order and the first row with ANY resolved
#       callee took the slot: an off-topic getter whose one callee row was a call bound by name alone (`bag.lookup()`
#       on an untyped local) spent the slot and printed a false edge.
#   (3) DOCS FIRST. Markdown headings that repeat the question's words filled the ranked rows above the code that
#       defines the answer (on one graded answer about half of the shown rows were headings).
#
# THE CONTRACT.
#   (1) Every <d> row of a --for answer whose definition extent is KNOWN carries e="N" right after l=: the 1-based line
#       of the definition's LAST line (body-inclusive; a declaration's own last line; e == l for a one-line definition).
#       l= keeps its meaning (the NAME's line), so a definition may start above l= (a return type on the line before,
#       a decorator). e= is ABSENT — never 0, never a guess — when the extent is not known: a row flagged
#       extent_suspect=, a markdown/doc row (not a code body). Other verbs keep their bytes (no e= outside --for).
#   (2) A hop slot (<h> row) goes only to a top-ranked row with at least ONE proven callee edge; a row whose every
#       callee edge was bound by name alone gets no <h> row. Rows that keep a slot keep it in rank order.
#   (3) When the question does not name docs, no markdown row ranks above the code rows that define the answer, and
#       markdown rows are at most a quarter of the shown <d> rows. A question that names docs still gets a docs row
#       in its top five (the twin that must hold).
#
# ARMS (one fixture root per language under test/forcompletefix/; each indexed on its own):
#   (E)  e= values: C Sampler_average l=6 e=14 (return type on the line above the name), Sampler_scale l=3 e=3
#        (a one-line definition), the header prototype Sampler_collectAll l=57 e=57; TS createContext l=11 e=18 (a
#        multi-line signature), handle l=20 e=22; Python _compute l=12 e=13 (a decorator above), evict_entries l=15
#        e=20 (a multi-line signature). Oracle on EVERY row that carries e=: l <= e <= the file's line count, and
#        the e= line closes the definition (brace languages, unless e == l: the line holds `}` or ends with `;`/`)`; Python: the next
#        non-blank line is indented no deeper than the def, or EOF). e= sits right after l=.
#   (U)  unknown extent: Sampler_window and SampleWindow (extent_suspect="head") and every docs/*.md row carry NO
#        e=; every other <d> row carries one (a present e= is never dropped silently either).
#   (O)  outside --for: --pack-signatures <d> rows and the default map's rows carry no e=.
#   (H)  hop slots: TS — contextHost (only callee: a name-only `bag.lookup()`) has no <h> row; createContext keeps
#        one. Python — Downloader.pull (only callee: a name-only `source.fetch_entry()`) has no <h> row; fetch_entry
#        keeps one. C near miss — Sampler_collectAll keeps its <h> row. <h> rows follow the <d> rows' r= order.
#        The two "no <h> row" arms need the receiver-evidence hedge (a name-only row marked via="name"); on a binary
#        without it they SKIP by name ("expects FE-B"), detected on this fixture — never a silent PASS.
#   (R)  code over docs: TS "How is a per-request context created?" — createContext and the class Context, and every
#        other code row, rank above every docs/context.md row; md rows <= 25% of the shown rows unless no code row was
#        displaced (the window holds fewer than 40 rows and <sigs> is not cut); the answer carries the
#        " [docs after code: N …]" note. Twin: "Where do the docs describe the context lifecycle?" keeps a docs row in
#        its top five.
#   (J)  dialect parity: --for --json "sigs" entries carry "e" equal to the XML rows' e= (and none where XML has none).
#   (M)  the MCP `for` twin: the same e= on the C rows, none on the extent_suspect rows, and a legend clause for e=.
#   (L)  legend: --legend=full defines e= and says what it does NOT mean (absent = unknown, not 0; l= is the name's
#        line, not the definition's first line).
#   (K)  the predicates can fail: a row with e= < l=, a row with e= on an md row, a missing e= on a code row, and a
#        name-only hop row are each caught; a document with no --for root is never a pass. Every run must exit 0.
#
# FLOORS — named, not gated here:
#   * e= is the parser's span: a definition spliced by the preprocessor or a recovered parse is covered only by
#     extent_suspect= (rows with an unflagged but wrong span are not detected).
#   * the code-over-docs rule is checked on one fixture; the threshold for "names docs" is the question's wording.
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
echo "forsigspancheck: BIN=$BIN  CORPUS=$CORPUS"

run(){ local r="$1" f="$2"; shift 2; ( cd "$CORPUS/$r" && "$BIN" . --no-cache "$@" >"$f" 2>"$f.err" ); printf '%s' "$?" >"$f.rc"; }
ran_ok(){ local rc; rc="$( cat "$1.rc" 2>/dev/null )"; [ "$rc" = 0 ] && return 0; no "$2: the binary exited rc=${rc:-missing}"; return 1; }
ask(){ local f="$TMP/$1.$2.xml"; run "$1" "$f" "--for=$3"; printf '%s' "$f"; }

cat >"$TMP/rows.py" <<'PY'
import re, sys
def attrs( tag ):
    return dict( re.findall( r'\s([a-z_]+)="([^"]*)"', tag ) )
def load( path ):
    return open( path, encoding="utf-8", errors="replace" ).read()
def ctx_ok( doc ):
    return re.search( r"<ctx [^>]*>", doc ) is not None and "<sigs" in doc
def drows( doc ):
    """[(open tag, attrs)] of every <d …> row, in document order."""
    return [ ( t, attrs( t ) ) for t in re.findall( r"<d\s[^>]*>", strip_comments( doc ) ) ]
def hrows( doc ):
    return [ attrs( t ) for t in re.findall( r"<h\s[^>]*>", strip_comments( doc ) ) ]
def strip_comments( doc ):
    # legend text inside <!-- --> spells row shapes (`<d cx= ccx=>`); only real elements are rows
    return re.sub( r"<!--.*?-->", "", doc, flags=re.S )
def is_doc_row( a ):
    return a.get( "p", "" ).endswith( ( ".md", ".markdown", ".rst", ".txt" ) )
PY

# echeck ANSWER LABEL ROOTDIR SPEC… — SPEC = name:path:l:e  (a row n=name p=path l=l must carry e=e)
echeck(){
    local f="$1" label="$2" rootdir="$3"; shift 3
    python3 - "$TMP/rows.py" "$f" "$label" "$rootdir" "$@" <<'PY'
import os, re, sys
exec( open( sys.argv[ 1 ] ).read() )
path, label, rootdir = sys.argv[ 2: 5 ]
specs = sys.argv[ 5: ]
doc = load( path )
if not ctx_ok( doc ):
    print( "  FAIL  %s: NOROOT" % label ); sys.exit( 1 )
rows = drows( doc )
bad = 0
for spec in specs:
    n, p, l, e = spec.rsplit( ":", 3 )
    hit = [ ( t, a ) for t, a in rows if a.get( "n" ) == n and a.get( "p" ) == p and a.get( "l" ) == l ]
    if not hit:
        print( "  FAIL  %s: no <d n=%s p=%s l=%s> row (premise)" % ( label, n, p, l ) ); bad = 1; continue
    t, a = hit[ 0 ]
    if a.get( "e" ) != e:
        print( "  FAIL  %s: %s l=%s carries e=%r, expected %s" % ( label, n, l, a.get( "e" ), e ) ); bad = 1; continue
    if not re.match( r'<d l="[0-9]+" e="[0-9]+" ', t ):
        print( "  FAIL  %s: %s — e= does not sit right after l=: %s" % ( label, n, t[ :60 ] ) ); bad = 1; continue
    print( "  PASS  %s: %s l=%s e=%s" % ( label, n, l, e ) )
sys.exit( bad )
PY
    [ $? -eq 0 ] || { fail=1; return 1; }
}

# oracle ANSWER LABEL ROOTDIR — (E) oracle + (U) on every <d> row of one answer
oracle(){
    python3 - "$TMP/rows.py" "$1" "$2" "$3" <<'PY'
import os, re, sys
exec( open( sys.argv[ 1 ] ).read() )
path, label, rootdir = sys.argv[ 2: 5 ]
doc = load( path )
if not ctx_ok( doc ):
    print( "  FAIL  %s: NOROOT" % label ); sys.exit( 1 )
bad = []
checked = 0
for t, a in drows( doc ):
    n, p = a.get( "n" ), a.get( "p", "" )
    unknown = is_doc_row( a ) or "extent_suspect" in a
    if unknown:
        if "e" in a: bad.append( "%s (%s) carries e= though its extent is unknown" % ( n, p ) )
        continue
    if "e" not in a:
        bad.append( "%s (%s:%s) has a known extent and no e=" % ( n, p, a.get( "l" ) ) ); continue
    if not ( re.fullmatch( r"[0-9]+", a[ "e" ] ) and re.fullmatch( r"[0-9]+", a.get( "l", "" ) ) ):
        bad.append( "%s: l=/e= not numeric" % n ); continue
    l, e = int( a[ "l" ] ), int( a[ "e" ] )
    try:
        lines = open( os.path.join( rootdir, p ), encoding="utf-8", errors="replace" ).read().split( "\n" )
    except OSError:
        bad.append( "%s: cannot read %s (premise)" % ( n, p ) ); continue
    if lines and lines[ -1 ] == "": lines = lines[ :-1 ]
    if not ( 1 <= l <= e <= len( lines ) ):
        bad.append( "%s: l=%d e=%d outside 1..%d or e < l" % ( n, l, e, len( lines ) ) ); continue
    last = lines[ e - 1 ].rstrip()
    if p.endswith( ".py" ):
        ind = len( lines[ l - 1 ] ) - len( lines[ l - 1 ].lstrip() )
        nxt = next( ( x for x in lines[ e: ] if x.strip() ), None )
        if not last.strip() or ( nxt is not None and len( nxt ) - len( nxt.lstrip() ) > ind ):
            bad.append( "%s: e=%d does not close the def (line %r)" % ( n, e, last ) )
    elif e != l and not ( "}" in last or last.endswith( ";" ) or last.endswith( ")" ) ):
        bad.append( "%s: e=%d line %r does not close the definition" % ( n, e, last ) )
    checked += 1
if bad:
    for b in bad: print( "  FAIL  %s: %s" % ( label, b ) )
    sys.exit( 1 )
if checked == 0:
    print( "  FAIL  %s: no row carried e= (nothing checked)" % label ); sys.exit( 1 )
print( "  PASS  %s: %d e= rows close their definitions; unknown extents carry none" % ( label, checked ) )
PY
    [ $? -eq 0 ] || { fail=1; return 1; }
}

echo "(E)/(U) e= on <d> rows"
CE="$( ask c avg 'How does the sampler compute the average reading window?' )"
if ran_ok "$CE" "E/C"; then
    echeck "$CE" "E/C" "$CORPUS/c" Sampler_average:src/window.c:6:14 Sampler_scale:src/window.c:3:3 Sampler_collectAll:src/monitor.h:57:57
    oracle "$CE" "E+U/C" "$CORPUS/c"
    python3 - "$TMP/rows.py" "$CE" <<'PY'
import sys
exec( open( sys.argv[ 1 ] ).read() )
rows = [ a for _, a in drows( load( sys.argv[ 2 ] ) ) if a.get( "n" ) in ( "Sampler_window", "SampleWindow" ) ]
if len( rows ) < 2 or any( "extent_suspect" not in a for a in rows ):
    print( "  FAIL  U/C: premise — Sampler_window and SampleWindow are not both shown with extent_suspect=" ); sys.exit( 1 )
if any( "e" in a for a in rows ):
    print( "  FAIL  U/C: an extent_suspect row carries e=" ); sys.exit( 1 )
print( "  PASS  U/C: the two extent_suspect rows carry no e=" )
PY
    [ $? -eq 0 ] || fail=1
fi
TE="$( ask ts ctx 'How is a per-request context created?' )"
if ran_ok "$TE" "E/TS"; then
    echeck "$TE" "E/TS" "$CORPUS/ts" createContext:src/application.ts:11:18 handle:src/application.ts:20:22
    oracle "$TE" "E+U/TS" "$CORPUS/ts"
fi
PE="$( ask py compute 'What does LookupCache._compute return, and how are entries evicted?' )"
if ran_ok "$PE" "E/PY"; then
    echeck "$PE" "E/PY" "$CORPUS/py" _compute:src/pump/cache.py:12:13 evict_entries:src/pump/cache.py:15:20
    oracle "$PE" "E+U/PY" "$CORPUS/py"
fi
JE="$( ask js run 'How does a queued job get run?' )"
if ran_ok "$JE" "E/JS"; then
    oracle "$JE" "E+U/JS" "$CORPUS/js"
fi

echo "(O) outside --for: no e= on other verbs' rows"
for spec in "packsig:--pack-signatures" "map:"; do
    tag="${spec%%:*}"; arg="${spec#*:}"; f="$TMP/c.out.$tag.xml"
    if [ -n "$arg" ]; then run c "$f" "$arg"; else run c "$f"; fi
    if ran_ok "$f" "O/$tag"; then
        if [ -s "$f" ] && grep -q -e '<d ' -e '<s ' "$f" && ! grep -Eq '<(d|s) [^>]* e="[0-9]' "$f"; then
            ok "O/$tag: rows present, none carries e="
        else
            no "O/$tag: no rows to check, or a row carries e= outside --for"
        fi
    fi
done

echo "(H) hop slots go to top rows with a proven callee edge"
hopcheck(){
    python3 - "$TMP/rows.py" "$@" <<'PY'
import sys
exec( open( sys.argv[ 1 ] ).read() )
path, label, mode, name = sys.argv[ 2: 6 ]
doc = load( path )
if not ctx_ok( doc ):
    print( "  FAIL  %s: NOROOT" % label ); sys.exit( 1 )
hs = hrows( doc )
names = [ h.get( "n" ) for h in hs ]
if mode == "nohop":
    good = name not in names; why = "no <h n=%s> (every callee edge name-only)" % name
elif mode == "hop":
    good = name in names; why = "<h n=%s> kept (a proven callee edge)" % name
elif mode == "order":
    rank = { ( a.get( "n" ), a.get( "p" ), a.get( "l" ) ): int( a[ "r" ] ) for _, a in drows( doc ) if a.get( "r", "" ).isdigit() }
    rs = [ rank.get( ( h.get( "n" ), h.get( "p" ), h.get( "l" ) ) ) for h in hs ]
    good = bool( rs ) and None not in rs and rs == sorted( rs ); why = "<h> rows in r= order %s" % rs
else:
    print( "  FAIL  %s: unknown mode" % label ); sys.exit( 1 )
print( "  %s  %s: %s" % ( "PASS" if good else "FAIL", label, why ) )
sys.exit( 0 if good else 1 )
PY
    [ $? -eq 0 ] || { fail=1; return 1; }
}
# CAPABILITY (checklist 17): the "only name-only edges" premise needs the receiver-evidence hedge — a binary that marks a
# call bound by name alone via="name". Detected here, on this fixture: Downloader.pull's `source.fetch_entry( url )` is
# such a call. A binary without the hedge cannot tell that edge from a proven one, so the two nohop arms SKIP BY NAME;
# every other arm (the near misses, rank order) runs either way.
FEB="$TMP/py.callers.fetch_entry.xml"; run py "$FEB" --callers=fetch_entry
FEB_ON=0
if ran_ok "$FEB" "H premise"; then
    if ! grep -q '<callers ' "$FEB" || ! grep -q 'n="pull"' "$FEB"; then
        no "H premise: --callers=fetch_entry did not answer with the pull row (cannot decide the hedge capability)"
    elif grep -Eq '<s [^>]*n="pull"[^>]*via="name"|<s [^>]*via="name"[^>]*n="pull"' "$FEB"; then
        FEB_ON=1
    fi
fi
nohop_or_skip(){
    if [ "$FEB_ON" = 1 ]; then hopcheck "$@"; else printf '  SKIP  %s: expects FE-B (this binary marks no name-only row via="name")\n' "$2"; fi
}
if ran_ok "$TE" "H/TS"; then
    nohop_or_skip "$TE" "H/TS getter with a name-only edge" nohop contextHost
    hopcheck "$TE" "H/TS near miss" hop createContext
    hopcheck "$TE" "H/TS order" order -
fi
PH="$( ask py fetch 'How does the lookup cache fetch or evict an entry?' )"
if ran_ok "$PH" "H/PY"; then
    nohop_or_skip "$PH" "H/PY untyped-parameter caller" nohop pull
    hopcheck "$PH" "H/PY near miss" hop fetch_entry
    hopcheck "$PH" "H/PY order" order -
fi
CH="$( ask c collect 'How does the sampler collect probe readings?' )"
if ran_ok "$CH" "H/C"; then
    hopcheck "$CH" "H/C near miss" hop Sampler_collectAll
fi

echo "(R) the defining code outranks the docs that describe it"
if ran_ok "$TE" "R"; then
    python3 - "$TMP/rows.py" "$TE" <<'PY'
import re, sys
exec( open( sys.argv[ 1 ] ).read() )
doc = load( sys.argv[ 2 ] )
rows = [ a for _, a in drows( doc ) if a.get( "r", "" ).isdigit() ]
code = [ int( a[ "r" ] ) for a in rows if ( a.get( "n" ), a.get( "p" ) ) in ( ( "createContext", "src/application.ts" ), ( "Context", "src/context.ts" ) ) ]
docs = [ int( a[ "r" ] ) for a in rows if is_doc_row( a ) ]
bad = []
if len( code ) != 2: bad.append( "premise: createContext and class Context are not both shown (%s)" % code )
elif docs and max( code ) > min( docs ): bad.append( "a docs row r=%d ranks above defining code r=%d" % ( min( docs ), max( code ) ) )
# docs <= 25% of the shown rows — unless no code row could have been displaced: the window is not full (fewer rows than
# the 40-row lens head) and <sigs> is not cut, so every positive code row is already shown ABOVE the docs (rule 5: a doc
# row filling a slot no code row competes for is information, never a cut).
sigs = re.search( r"<sigs[^>]*>", doc )
windowOpen = len( rows ) < 40 and sigs is not None and 'capped="1"' not in sigs.group( 0 )
if code and docs and min( docs ) < max( r for r in ( int( a[ "r" ] ) for a in rows if not is_doc_row( a ) ) ):
    bad.append( "a docs row r=%d ranks above a code row" % min( docs ) )
if rows and 4 * len( docs ) > len( rows ) and not windowOpen: bad.append( "%d of %d shown rows are docs (> 25%%) in a full or cut window" % ( len( docs ), len( rows ) ) )
if docs and " [docs after code: " not in doc: bad.append( "the docs moved below code but the answer has no [docs after code: N] note" )
if bad:
    for b in bad: print( "  FAIL  R: %s" % b )
    sys.exit( 1 )
print( "  PASS  R: code r=%s above docs r=%s; docs %d of %d rows" % ( code, docs, len( docs ), len( rows ) ) )
PY
    [ $? -eq 0 ] || fail=1
fi
TD="$( ask ts docs 'Where do the docs describe the context lifecycle?' )"
if ran_ok "$TD" "R twin"; then
    python3 - "$TMP/rows.py" "$TD" <<'PY'
import sys
exec( open( sys.argv[ 1 ] ).read() )
rows = [ a for _, a in drows( load( sys.argv[ 2 ] ) ) if a.get( "r", "" ).isdigit() ]
top = [ a for a in rows if int( a[ "r" ] ) <= 5 and is_doc_row( a ) ]
if not rows or not top:
    print( "  FAIL  R twin: a question that names docs has no docs row in its top five" ); sys.exit( 1 )
print( "  PASS  R twin: docs row %s in the top five" % top[ 0 ].get( "n" ) )
PY
    [ $? -eq 0 ] || fail=1
fi

echo "(J) --for --json carries the same e= values"
TJ="$TMP/ts.ctx.json"; run ts "$TJ" "--for=How is a per-request context created?" --json
if ran_ok "$TJ" "J"; then
    python3 - "$TMP/rows.py" "$TE" "$TJ" <<'PY'
import json, sys
exec( open( sys.argv[ 1 ] ).read() )
x = { ( a.get( "n" ), a.get( "p" ), a.get( "l" ) ): a.get( "e" ) for _, a in drows( load( sys.argv[ 2 ] ) ) }
try:
    j = json.loads( load( sys.argv[ 3 ] ) )
except ValueError as err:
    print( "  FAIL  J: not JSON (%s)" % err ); sys.exit( 1 )
js = { ( r.get( "n" ), r.get( "p" ), str( r.get( "l" ) ) ): ( None if r.get( "e" ) is None else str( r.get( "e" ) ) ) for r in j.get( "sigs", [] ) }
common = set( x ) & set( js )
if not common or not any( x[ k ] for k in common ):
    print( "  FAIL  J: no shared row carries e= (premise)" ); sys.exit( 1 )
diff = sorted( k for k in common if x[ k ] != js[ k ] )
if diff:
    print( "  FAIL  J: XML/JSON e= differ on %s" % diff[ :4 ] ); sys.exit( 1 )
print( "  PASS  J: %d shared rows agree on e=" % len( common ) )
PY
    [ $? -eq 0 ] || fail=1
fi

echo "(M) the MCP for twin carries the same e= values, with the same exclusions"
MC="$TMP/mcp.c.json"; mkdir -p "$TMP/mcphome"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
               '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"for","arguments":{"path":"'"$CORPUS/c"'","task":"How does the sampler compute the average reading window?"}}}' \
  | ( cd "$CORPUS/c" && TMPDIR="$TMP/mcphome" "$BIN" --mcp >"$MC" 2>/dev/null ); printf '%s' "$?" >"$MC.rc"
if ran_ok "$MC" "M"; then
    python3 - "$TMP/rows.py" "$MC" "$CORPUS/c" <<'PY'
import json, os, sys
exec( open( sys.argv[ 1 ] ).read() )
lines = [ l for l in open( sys.argv[ 2 ], encoding="utf-8", errors="replace" ) if l.strip() ]
try:
    text = json.loads( lines[ -1 ] )[ "result" ][ "content" ][ 0 ][ "text" ]
except Exception as err:
    print( "  FAIL  M: no readable MCP for answer (%s)" % err ); sys.exit( 1 )
rows = { a.get( "n" ) + "@" + a.get( "p", "" ) + ":" + a.get( "l", "" ): a for _, a in drows( text ) }
want = { "Sampler_average@src/window.c:6": "14", "Sampler_scale@src/window.c:3": "3" }
bad = [ "%s e=%r, expected %s" % ( k, rows[ k ].get( "e" ) if k in rows else "(row absent)", v ) for k, v in want.items() if k not in rows or rows[ k ].get( "e" ) != v ]
bad += [ "%s is extent_suspect and carries e=" % k for k, a in rows.items() if "extent_suspect" in a and "e" in a ]
if "e=" not in " ".join( __import__( "re" ).findall( r"<!--(.*?)-->", text, __import__( "re" ).S ) ):
    bad.append( "the MCP answer defines no e= in its legend" )
if bad:
    for b in bad: print( "  FAIL  M: %s" % b )
    sys.exit( 1 )
print( "  PASS  M: MCP for rows carry the CLI's e= values; suspect rows none; legend defines e=" )
PY
    [ $? -eq 0 ] || fail=1
fi

echo "(L) legend defines e= and what it does not mean"
LG="$TMP/ts.legend.xml"; run ts "$LG" "--for=How is a per-request context created?" --legend=full
if ran_ok "$LG" "L"; then
    python3 - "$LG" <<'PY'
import re, sys
legend = " ".join( re.findall( r"<!--(.*?)-->", open( sys.argv[ 1 ], encoding="utf-8", errors="replace" ).read(), re.S ) )
need = [ ( r"\be=", "defines e=" ), ( r"(?i)absent[^.;]*(unknown|not known)", "says absent = unknown" ),
         ( r"(?i)(never 0|not 0|never zero)", "says e= is never 0" ), ( r"(?i)l=[^.;]{0,60}(name's line|line of (the|its) (definition's )?name)", "says l= is the name's line" ) ]
bad = [ w for rx, w in need if not re.search( rx, legend ) ]
if bad:
    print( "  FAIL  L: the legend does not %s" % "; ".join( bad ) ); sys.exit( 1 )
print( "  PASS  L: e= defined with its NOT-meaning" )
PY
    [ $? -eq 0 ] || fail=1
fi

echo "(K) the predicates can fail"
K="$TMP/k.xml"
printf '<ctx task="t"><sigs><d l="11" e="9" n="createContext" p="src/application.ts" r="1">x</d></sigs></ctx>' >"$K"
if ( oracle "$K" "K1 (expected FAIL)" "$CORPUS/ts" ) >/dev/null 2>&1; then no "K1: e= < l= not caught"; else ok "K1: e= < l= is caught"; fi
printf '<ctx task="t"><sigs><d l="1" e="3" n="Context" p="docs/context.md" r="1">x</d><d l="11" e="18" n="createContext" p="src/application.ts" r="2">x</d></sigs></ctx>' >"$K"
if ( oracle "$K" "K2 (expected FAIL)" "$CORPUS/ts" ) >/dev/null 2>&1; then no "K2: e= on a docs row not caught"; else ok "K2: e= on a docs row is caught"; fi
printf '<ctx task="t"><sigs><d l="11" n="createContext" p="src/application.ts" r="1">x</d></sigs></ctx>' >"$K"
if ( oracle "$K" "K3 (expected FAIL)" "$CORPUS/ts" ) >/dev/null 2>&1; then no "K3: a code row without e= not caught"; else ok "K3: a code row without e= is caught"; fi
printf '<ctx task="t"><sigs><d l="7" n="contextHost" p="src/request.ts" r="1">x</d></sigs><hops><h l="7" p="src/request.ts" n="contextHost"></h></hops></ctx>' >"$K"
if ( hopcheck "$K" "K4 (expected FAIL)" nohop contextHost ) >/dev/null 2>&1; then no "K4: a name-only hop row not caught"; else ok "K4: a name-only hop row is caught"; fi
printf '<callers of="x" found="0"/>' >"$K"
if ( oracle "$K" "K5 (expected FAIL)" "$CORPUS/ts" ) >/dev/null 2>&1; then no "K5: NOROOT passed"; else ok "K5: a document with no --for root is never a pass"; fi

if [ "$fail" -ne 0 ]; then
    echo "forsigspancheck: FAIL"
    exit 1
fi
echo "forsigspancheck: PASS"
exit 0
