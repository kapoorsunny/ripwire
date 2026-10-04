#!/usr/bin/env bash
# receiverevidencecheck.sh — a call matched to a definition by NAME ALONE never presents as a single proven edge.
#
#   test/receiverevidencecheck.sh                          # uses build/ripwire on test/receiverevidencefix
#   RIPWIRE_BIN=asan/ripwire test/receiverevidencecheck.sh
#   test/receiverevidencecheck.sh build_base/ripwire       # the RED run (a pre-change binary)
#
# THE DEFECT. A member call `x.m()` (or, in a language with an implicit receiver, a bare `m()`) was bound to an
# in-repo definition of `m` because the NAME matched, with nothing proving the receiver is that definition's
# class. The answer then showed one confident row — and agents adopt a confident wrong row. Each shape below was
# a graded false row (paraphrased; the code is minimal and never built):
#   (Bm) a dynamic receiver bound to the wrong in-repo class: a request context's `ctx.onerror()` drawn to the
#        Application.onerror its file defines; an item's typed text field `item.text.Get()` drawn to Merger.Get;
#        a stored ASGI callable `self._send()` drawn to another class's nested `_send`; a constructor-assigned
#        field `this.bucket.listSchemas()` drawn to the caller's own class; a loop variable over inner routers
#        drawn to SmartRouter.add; `ctx.req.raw.headers.get()` drawn to Context.get because the file imports
#        Context; a member call `context.handler()` drawn to a same-named FREE function.
#   (Bd) a builtin/library object behind a variable, in a file that names the class: WeakMap `.set/.get` → the
#        same file's accessors, Promise `.then` → Reply.prototype.then, a stream's `.on` → a TEST double,
#        `dict.get/keys/items` → StylesBase in a file that imports Styles, `list.append`/`str.split` →
#        Content.append/split, URLSearchParams `.append`, Set `.delete`, an outside router's `.all`, an asyncio
#        handle's `.cancel`, an outside parser's `.write`, an outside tcell screen's `.Size`.
#   (Bp) a parameter or local callable bound to a def elsewhere: `done()` (a parameter) → another file's
#        closure `done`; `read = os.read; read( fd )` → Stylesheet.read and `feed = parser.feed` → the base
#        class's feed when the parser is a constructed XTermParser (the rows FE-A's local-Keep rule restored);
#        `add_widget = widgets.append; add_widget( n )` → another class's nested add_widget.
#   (Bi) an implicit receiver (Java, Kotlin, C#, C++, Swift, Ruby): a bare `render()` / `flush()` inside a class
#        bound to an UNRELATED class's method, though the language reaches only the class's own members, its
#        superclasses and mixins, a free/top-level function, or an import.
#
# THE CONTRACT. Such a call either (a) RESOLVES WITH EVIDENCE — the receiver is `this`/`self`/`cls` inside the
# class or its cone, a construction in scope (`x = new Cls()`, `x = Cls()`, `m := &Merger{}`), a constructor-
# assigned field, a type annotation or declaration on the parameter/local (Go struct field, embedded field,
# aliased import), an import — and then shows one plain row; or (b) KEEPS ITS ROW WITH AN ON-ROW HEDGE:
# `via="name"` on the row itself (XML) / `"via":"name"` on the entry (MCP JSON), listing the by-name candidates
# — never a legend-only hedge, never a silent drop. Every surface shows the same row with the same hedge:
# --callees, --callers, --impact, --path, --connect, --expand <calls>, --for <calls>, and MCP find_symbol /
# find_referencing_symbols. A wrong candidate may also disappear (resolved elsewhere, or counted external/
# unresolved), but a TRUE target must stay visible, hedged or not.
#
# PREDICATES (each over one answer; an answer about no symbol is NOROOT and never a pass; rows compare
# (kind, name, file[:line]) — the line only where a spec carries one):
#   notproven  — the named row is absent, or present WITH the hedge (the positive arms: red when unhedged)
#   proven     — the named row is present WITHOUT the hedge (evidence: a near miss a new rule could kill)
#   exactproven— the set of unhedged rows is exactly the given set (no false candidate rides along unhedged)
#   visible    — the named row is present, hedged or not (a true target is never dropped)
#   marked     — the named row is present WITH the hedge (a name-only true edge is kept and labelled)
#
# ARMS (one fixture root per language under test/receiverevidencefix/; each root is indexed on its own).
#   (J) JS:  Bm ctx.onerror (plain, optional-chained), constructor-assigned field, member call → free function;
#            Bd WeakMap/Promise/stream/router/Set/URLSearchParams; Bp a `done` parameter. Near misses: this.onerror,
#            same-file bare call, relative module receiver, a closure called in its own function, construction in
#            scope (`new Application()` / `new Schemas()` decide between same-named methods), a chained name-only
#            call kept visible; the name-only `reply.send()` on a parameter is kept and marked.
#   (T) TS:  Bm a loop variable over Router<T>[] → SmartRouter.add; WHATWG Headers.get → Context.get/Cache.get.
#            Near misses: an annotated parameter, construction through an import alias, a constructed local.
#   (P) Python: Bd dict/set/list/str in a file that imports the class; an argument's .animate; asyncio handle;
#            an outside package's parser; Bm self._send → a nested _send, a non-self receiver in the class's own
#            file (mode_screen.refresh, self.screen.refresh); Bp read = os.read, feed = parser.feed (base class),
#            add_widget = widgets.append. Near misses: self.update, a constructor-assigned field (+ cone),
#            a typed parameter (+ cone), construction, an import alias, an imported function beside same-named
#            methods, cls.method(), the XTermParser.feed the alias really reaches; a name-only parameter call
#            kept and marked.
#   (G) Go:  Bm typed struct field → Merger.Get/Length (the true util.Chars rows visible), a typed parameter, a
#            typed local through an aliased import, an embedded field's promoted method; Bd an outside screen's
#            Size, an outside value's Runes. Near misses: a pointer-literal local, the method receiver itself.
#   (I) implicit receiver: Java, Kotlin, C#, C++, Swift, Ruby — a bare call inside a class whose base is OUTSIDE
#            the tree (or that imports the name from outside) never proves an unrelated class's method. Near
#            misses: own members (private too), an in-repo superclass's member (the cone), a free / top-level
#            function, a Ruby included module and a Ruby top-level def.
#   (H) propagation and parity: the name-only witness `respondWith → reply.send()` is marked in --callees,
#            --callers, --impact (d=1), --path, --connect, --expand <calls>, --for <calls>, MCP find_symbol and
#            find_referencing_symbols; the false witness `respond → ctx.onerror()` is absent-or-marked on every
#            one of them; and the hedge bit is VALUE-EQUAL between CLI --callees and MCP calls, CLI --callers and
#            MCP calledBy, and --callees and --expand <calls>, over a set of selectors.
#   (C) conservation: each root's census dispositions still sum to calls= with unaccounted=0 (no silent drop).
#   (K) the predicates can fail: a planted unhedged false row fails notproven, a planted hedged row passes it and
#            fails proven, marked rejects an unhedged row, a rootless or not-found answer is NOROOT, the MCP reader
#            reads the hedge, and a non-zero or missing exit status fails the arm.
#
# FLOORS — named, not gated here:
#   * Objective-C (a method is only ever sent `[recv msg]`; a bare call is a C function — FE-A's ladder), PHP, Lua,
#     Zig, Dart, Elixir: no arm.
#   * a computed member `ctx['onerror']()` records no call at all (pinned notproven, trivially).
#   * return-type inference (`mode_screen = self.get_screen(); mode_screen.refresh()` → Screen.refresh) is not
#     required: only the false single row is gated.
#   * --impact rows at d>=2 reached only through a hedged edge: presence is gated, their hedge is not.
#   * --uses / --dead-code / --safe-delete and F2's --for hop expansion beyond the <calls> block: not gated here.
#   * a Python `cls()` construction inside a classmethod is polymorphic (a subclass's override is a legitimate
#     candidate): no arm.
#
# Exits non-zero on any failure.

set -u
export PYTHONDONTWRITEBYTECODE=1
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
. "$ROOT/test/lib/clean-env.sh"   # a gate that indexes a repo must not inherit GIT_DIR/GIT_WORK_TREE (gitenvhermeticcheck D)
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"          # allow a repo-relative binary
CORPUS="$ROOT/test/receiverevidencefix"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*" || { fail=1; printf '  FAIL  could not write the PASS line for: %s\n' "$*"; }; return 0; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
[ -d "$CORPUS" ] || { echo "fixture missing: $CORPUS"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 2; }
echo "receiverevidencecheck: BIN=$BIN  CORPUS=$CORPUS"

# rw ROOT ARGS… — run against one fixture root (every selector below is relative to that root's `.`)
rw(){ local r="$1"; shift; ( cd "$CORPUS/$r" && "$BIN" . --no-cache "$@" 2>/dev/null ); }

# ── the one reader every predicate shares ─────────────────────────────────────────────────────────────────────
# parse.py MODE FILE [ARGS] — prints one line per row; NOROOT when the document has no answer about a symbol.
#   rows    <s> rows of a callees/callers/impact/path answer: "t n path line H d" (H = name | -, d = depth or -)
#   ecalls  <c> rows inside <calls> (all of them, or only those inside the <b>/<d> body named ARG for --for):
#           "n line H"
#   edges   <e> rows of a connect answer: "f t H"
#   mcp     the entries of one array (ARG) of an MCP tools/call result: "name file line H"
cat >"$TMP/parse.py" <<'PY'
import json, re, sys
mode, path = sys.argv[ 1 ], sys.argv[ 2 ]
arg = sys.argv[ 3 ] if len( sys.argv ) > 3 else ""
doc = open( path, encoding="utf-8", errors="replace" ).read()
def attr( tag, name ):
    m = re.search( r'\s' + name + r'="([^"]*)"', tag )
    return m.group( 1 ) if m else None
def hedge( tag ):
    return "name" if attr( tag, "via" ) == "name" else "-"
if mode == "rows":
    root = re.search( r"<(callees|callers|impact|path) [^>]*>", doc )
    if not root:
        print( "NOROOT" ); sys.exit( 0 )
    head = root.group( 0 )
    found = attr( head, "defs" ) or attr( head, "to_defs" )
    if root.group( 1 ) != "path" and ( not found or int( found ) < 1 ):
        print( "NOROOT" ); sys.exit( 0 )
    depth = "-"
    for s in re.findall( r"<s [^>]*/>", doc[ root.start(): ] ):
        t, n, p = attr( s, "t" ), attr( s, "n" ), attr( s, "p" )
        if not ( t and n and p ):
            continue
        if attr( s, "d" ):
            depth = attr( s, "d" )
        f, _, l = p.rpartition( ":" )
        print( t, n, f, l, hedge( s ), depth )
elif mode == "ecalls":
    scope = doc
    if arg:
        m = re.search( r'<b\b[^>]*\sn="' + re.escape( arg ) + r'"[^>]*>(.*?)</b>', doc, re.S )
        if not m:
            print( "NOROOT" ); sys.exit( 0 )
        scope = m.group( 1 )
    blocks = re.findall( r"<calls[ >].*?</calls>", scope, re.S )
    if not blocks:
        print( "NOROOT" ); sys.exit( 0 )
    for b in blocks:
        for c in re.findall( r"<c [^>]*>", b ):
            print( attr( c, "n" ), attr( c, "l" ) or "-", hedge( c ) )
elif mode == "edges":
    root = re.search( r"<connect [^>]*>", doc )
    if not root:
        print( "NOROOT" ); sys.exit( 0 )
    for e in re.findall( r"<e [^>]*/>", doc[ root.start(): ] ):
        print( attr( e, "f" ), attr( e, "t" ), hedge( e ) )
elif mode == "mcp":
    try:
        r = json.loads( doc.strip().splitlines()[ -1 ] )
        d = json.loads( r[ "result" ][ "content" ][ 0 ][ "text" ] )
    except Exception:
        print( "NOROOT" ); sys.exit( 0 )
    if d.get( arg ) is None:
        print( "NOROOT" ); sys.exit( 0 )
    for e in d[ arg ]:
        print( e.get( "name" ), e.get( "file" ), e.get( "line" ), "name" if e.get( "via" ) == "name" else "-" )
PY
parse(){ python3 "$TMP/parse.py" "$@"; }

# answer ROOT VERB SEL [EXTRA…] — write the verb's answer to a per-call file, its exit status beside it (FILE.rc)
answer(){
    local r="$1" v="$2" s="$3"; shift 3
    local f; f="$TMP/$r.$v.$( printf '%s' "$s$*" | tr '/:.,= ' '______' ).xml"
    rw "$r" "--$v=$s" "$@" >"$f"; printf '%s' "$?" >"$f.rc"
    printf '%s' "$f"
}
# ran_ok LABEL FILE — the run behind FILE exited 0 (a non-zero or missing exit status FAILs the arm)
ran_ok(){
    local rc; rc="$( cat "$2.rc" 2>/dev/null )"
    if [ "$rc" = "0" ]; then return 0; fi
    no "$1 exited rc=${rc:-unknown}"; return 1
}
# getrows ROOT VERB SEL — rows of the verb's answer into $GOT ("" on a failed run, NOROOT when about no symbol)
getrows(){
    local f; f="$( answer "$1" "$2" "$3" )"; GOT=""
    ran_ok "($1) --$2=$3" "$f" || return 1
    GOT="$( parse rows "$f" )"
    if [ "$GOT" = "NOROOT" ]; then no "($1) --$2=$3 produced no <$2> answer about a symbol"; return 1; fi
    return 0
}
# match SPEC — the awk condition for "n path[:line]" over a rows line "t n path line H d"
specmatch(){   # prints the matching rows of $GOT for SPEC
    local n="${1%% *}" p="${1#* }" l=""
    case "$p" in *:[0-9]*) l="${p##*:}"; p="${p%:*}";; esac
    printf '%s\n' "$GOT" | awk -v n="$n" -v p="$p" -v l="$l" 'NF >= 5 && $2 == n && $3 == p && ( l == "" || $4 == l )'
}
show(){ printf '%s' "$GOT" | awk 'NF >= 5 { printf "%s %s %s:%s%s; ", $1, $2, $3, $4, ( $5 == "name" ? " via=name" : "" ) }'; }

notproven(){
    local r="$1" v="$2" s="$3"; shift 3
    getrows "$r" "$v" "$s" || return
    local spec hits
    for spec in "$@"; do
        hits="$( specmatch "$spec" | awk '$5 != "name"' )"
        if [ -n "$hits" ]; then no "($r) --$v=$s shows [$spec] as a PROVEN edge (no receiver evidence, no via=\"name\"): $( show )"
        else ok "($r) --$v=$s never proves [$spec] (absent or hedged)"; fi
    done
}
proven(){
    local r="$1" v="$2" s="$3"; shift 3
    getrows "$r" "$v" "$s" || return
    local spec t hits
    for spec in "$@"; do
        t="${spec%% *}"; hits="$( specmatch "${spec#* }" | awk -v t="$t" '$1 == t && $5 != "name"' )"
        if [ -n "$hits" ]; then ok "($r) --$v=$s keeps the proven row [$spec]"
        else no "($r) --$v=$s lost or hedged the proven row [$spec]: $( show )"; fi
    done
}
exactproven(){
    local r="$1" v="$2" s="$3" want="$4" got
    getrows "$r" "$v" "$s" || return
    got="$( printf '%s\n' "$GOT" | awk 'NF >= 5 && $5 != "name" { print $1 " " $2 " " $3 }' | sort -u | tr '\n' ';' | sed 's/;$//' )"
    want="$( printf '%s' "$want" | tr ';' '\n' | sort -u | tr '\n' ';' | sed 's/;$//' )"
    if [ "$got" = "$want" ]; then ok "($r) --$v=$s unhedged rows are exactly [${want:-none}]"
    else no "($r) --$v=$s unhedged rows are [${got:-none}], want [${want:-none}]"; fi
}
visible(){
    local r="$1" v="$2" s="$3"; shift 3
    getrows "$r" "$v" "$s" || return
    local spec
    for spec in "$@"; do
        if [ -n "$( specmatch "$spec" )" ]; then ok "($r) --$v=$s shows the true target [$spec] (hedged or not)"
        else no "($r) --$v=$s does not show the true target [$spec]: $( show )"; fi
    done
}
marked(){
    local r="$1" v="$2" s="$3"; shift 3
    getrows "$r" "$v" "$s" || return
    local spec
    for spec in "$@"; do
        if [ -n "$( specmatch "$spec" | awk '$5 == "name"' )" ]; then ok "($r) --$v=$s keeps [$spec] marked via=\"name\""
        elif [ -n "$( specmatch "$spec" )" ]; then no "($r) --$v=$s shows the name-only [$spec] with no via=\"name\": $( show )"
        else no "($r) --$v=$s dropped the name-only true edge [$spec]: $( show )"; fi
    done
}

echo "=== (J) JS: receivers with no evidence never prove a same-named method ==="
notproven js callees lib/application.js:respond "onerror lib/application.js"
visible   js callees lib/application.js:respond "onerror lib/context.js"
notproven js callees lib/application.js:respondSafely "onerror lib/application.js"
notproven js callees lib/application.js:respondComputed "onerror lib/application.js"
notproven js callees lib/application.js:schemas "listSchemas lib/application.js"
visible   js callees lib/application.js:schemas "listSchemas lib/schemas.js"
notproven js callees lib/handle.js:run "handler lib/handle.js"
notproven js callees lib/request.js:compile "get lib/request.js" "set lib/request.js"
notproven js callees lib/reply.js:awaitResult "then lib/reply.js"
notproven js callees lib/reply.js:pipePayload "on test/server.test.js"
notproven js callees lib/routes.js:fallback "all lib/routes.js"
notproven js callees lib/routes.js:forget "delete lib/routes.js"
notproven js callees lib/search.js:encode "append lib/response.js"
notproven js callees lib/reply.js:writePayload "done lib/parser.js"
echo "--- (J) evidence decides between same-named methods"
exactproven js callees lib/uses.js:build "cls Application lib/application.js;method onerror lib/application.js;cls Schemas lib/schemas.js;method listSchemas lib/schemas.js"
echo "--- (J) near misses: true edges kept"
exactproven js callees lib/application.js:handle "method onerror lib/application.js;fn respond lib/application.js"
exactproven js callees lib/handle.js:wrapped "fn handler lib/handle.js"
exactproven js callees lib/uses.js:viaModule "fn respondWith lib/reply.js"
exactproven js callees lib/trailer.js:sendTrailer "fn send lib/trailer.js"
notproven js callees lib/reply.js:notFound "send lib/trailer.js"
visible   js callees lib/reply.js:notFound "send lib/reply.js" "code lib/reply.js"
marked    js callees lib/reply.js:respondWith "send lib/reply.js"

echo "=== (T) TS ==="
notproven ts callees src/router/smart.ts:match "add src/router/smart.ts"
notproven ts callees src/middleware/auth.ts:bearer "get src/context.ts" "get src/cache.ts"
echo "--- (T) near misses: annotation, alias construction, constructed local"
exactproven ts callees src/middleware/auth.ts:readUser "method get src/context.ts"
exactproven ts callees src/middleware/alias.ts:remember "cls Context src/context.ts;method set src/context.ts"
exactproven ts callees src/middleware/alias.ts:single "cls TrieRouter src/router/trie.ts;method add src/router/trie.ts;method match src/router/trie.ts"

echo "=== (P) Python ==="
notproven py callees src/tui/css/stylesheet.py:reparse "get src/tui/css/styles.py" "keys src/tui/css/styles.py" "items src/tui/css/styles.py" "update src/tui/css/stylesheet.py"
notproven py callees src/tui/css/stylesheet.py:refresh_rules "animate src/tui/css/styles.py"
notproven py callees src/tui/reactive.py:watch "append src/tui/content.py"
notproven py callees src/tui/reactive.py:toggle "split src/tui/content.py" "split src/tui/geometry.py"
notproven py callees src/tui/callback.py:invoke "call_later src/tui/message_pump.py" "cancel src/tui/worker.py"
notproven py callees src/web/formparsers.py:parse_form "write src/web/datastructures.py"
notproven py callees src/web/requests.py:send_json "_send src/web/errors.py"
notproven py callees src/tui/app.py:switch_mode "refresh src/tui/app.py"
notproven py callees src/tui/app.py:repaint_screen "refresh src/tui/app.py"
visible   py callees src/tui/app.py:repaint_screen "refresh src/tui/screen.py"
notproven py callees src/tui/drivers/linux.py:process_events "read src/tui/css/stylesheet.py" "feed src/tui/xterm_parser.py:2"
notproven py callees src/tui/screen.py:collect "add_widget src/tui/compositor.py"
echo "--- (P) near misses: self, constructor-assigned field, typed parameter, construction, alias, import, cls"
proven    py callees src/tui/drivers/linux.py:process_events "fn feed src/tui/xterm_parser.py:7"
exactproven py callees src/tui/css/stylesheet.py:own "fn update src/tui/css/stylesheet.py;fn get src/tui/css/styles.py"
exactproven py callees src/tui/app.py:repaint "fn refresh src/tui/app.py"
exactproven py callees src/tui/uses.py:sync "fn update src/tui/css/stylesheet.py"
exactproven py callees src/tui/uses.py:apply "fn animate src/tui/css/styles.py"
exactproven py callees src/tui/uses.py:build "cls Stylesheet src/tui/css/stylesheet.py;fn update src/tui/css/stylesheet.py;fn read src/tui/css/stylesheet.py"
exactproven py callees src/tui/css/stylesheet.py:parse_rules "fn parse src/tui/css/parse.py"
exactproven py callees src/tui/css/stylesheet.py:blank "fn default_rules src/tui/css/stylesheet.py"
marked    py callees src/tui/callback.py:schedule "call_later src/tui/message_pump.py"

echo "=== (G) Go ==="
notproven go callees src/result.go:buildResult "Get src/merger.go" "Length src/merger.go"
visible   go callees src/result.go:buildResult "Get src/util/chars.go" "Length src/util/chars.go"
exactproven go callees src/result.go:fromValue "method Get src/util/chars.go"
exactproven go callees src/embed.go:aliased "method Length src/util/chars.go"
notproven go callees src/embed.go:firstRune "Get src/merger.go"
visible   go callees src/embed.go:firstRune "Get src/util/chars.go"
notproven go callees src/tui/tcell.go:MaxY "Size src/tui/tcell.go"
notproven go callees src/tui/tcell.go:Graphemes "Runes src/tui/tcell.go"
echo "--- (G) near misses: a pointer-literal local, the method receiver itself"
exactproven go callees src/result.go:merged "method Length src/merger.go"
exactproven go callees src/merger.go:First "method Get src/merger.go"
exactproven go callees src/tui/tcell.go:Lines "method Size src/tui/tcell.go"

echo "=== (I) implicit receiver: a bare call never proves an unrelated class's method ==="
notproven java callees src/main/java/app/Logger.java:line "render src/main/java/app/Exporter.java"
notproven java callees src/main/java/app/Logger.java:close "flush src/main/java/app/Buffer.java" "flush src/main/java/app/Exporter.java"
notproven java callees src/main/java/app/FileBuffer.java:sync "flush src/main/java/app/Exporter.java"
notproven kt callees src/app/Plain.kt:finish "flush src/app/Exporter.kt" "flush src/app/Logger.kt"
notproven cs callees App/Logger.cs:Line "Render App/Exporter.cs"
notproven cs callees App/Logger.cs:Finish "Flush App/Logger.cs" "Flush App/Exporter.cs"
notproven cpp callees src/plain.cpp:finish "flush src/exporter.cpp" "flush src/logger.cpp"
notproven swift callees Sources/App/Plain.swift:finish "flush Sources/App/Exporter.swift" "flush Sources/App/Logger.swift"
notproven rb callees lib/app/plain.rb:finish "render lib/app/exporter.rb" "flush lib/app/logger.rb"
echo "--- (I) near misses: own members, the in-repo superclass (cone), free/top-level functions, mixins"
proven    java callees src/main/java/app/Logger.java:close "method reset src/main/java/app/Logger.java"
proven    java callees src/main/java/app/FileBuffer.java:sync "method flush src/main/java/app/Buffer.java"
exactproven java callees src/main/java/app/Buffer.java:write "method flush src/main/java/app/Buffer.java"
exactproven kt callees src/app/Logger.kt:line "fn render src/app/Logger.kt"
exactproven kt callees src/app/Logger.kt:close "fn flush src/app/Logger.kt;fn reset src/app/Logger.kt"
exactproven cs callees App/Logger.cs:Close "method Flush App/Logger.cs;method Reset App/Logger.cs"
exactproven cpp callees src/logger.cpp:line "fn render src/logger.cpp"
exactproven cpp callees src/logger.cpp:close "method flush src/logger.cpp;method reset src/logger.cpp"
exactproven swift callees Sources/App/Logger.swift:line "fn render Sources/App/Logger.swift"
exactproven swift callees Sources/App/Logger.swift:close "fn flush Sources/App/Logger.swift;fn reset Sources/App/Logger.swift"
exactproven rb callees lib/app/logger.rb:line "method stamp lib/app/helpers.rb"
exactproven rb callees lib/app/logger.rb:close "method flush lib/app/logger.rb;method reset lib/app/logger.rb;method top_level_note lib/app/notes.rb"

echo "=== (H) propagation: one hedge, every surface ==="
# the name-only TRUE witness respondWith → reply.send(): kept and marked everywhere
marked js callers lib/reply.js:send "respondWith lib/reply.js"
f="$( answer js impact lib/reply.js:send )"
if ran_ok "(js) --impact=lib/reply.js:send" "$f"; then
    GOT="$( parse rows "$f" )"
    if [ "$GOT" = "NOROOT" ]; then no "(H) --impact=lib/reply.js:send produced no answer about a symbol"
    else
        d1="$( printf '%s\n' "$GOT" | awk '$2 == "respondWith" && $6 == "1" { print $5 }' )"
        if [ "$d1" = "name" ]; then ok "(H) --impact=lib/reply.js:send: the d=1 row respondWith is marked via=\"name\""
        else no "(H) --impact=lib/reply.js:send: the d=1 row respondWith is [${d1:-absent}], want via=\"name\": $( show )"; fi
        if [ -n "$( printf '%s\n' "$GOT" | awk '$2 == "viaModule"' )" ]; then ok "(H) --impact=lib/reply.js:send keeps viaModule (reached through the hedged edge)"
        else no "(H) --impact=lib/reply.js:send dropped viaModule: $( show )"; fi
    fi
fi
f="$( answer js path lib/uses.js:viaModule,lib/reply.js:send )"
if ran_ok "(js) --path=viaModule,send" "$f"; then
    GOT="$( parse rows "$f" )"
    last="$( printf '%s\n' "$GOT" | awk 'NF >= 5' | tail -1 )"
    case "$last" in
        "method send lib/reply.js 7 name"*) ok "(H) --path=viaModule,send: the hop into Reply.prototype.send is marked via=\"name\"";;
        *) no "(H) --path=viaModule,send: last hop is [${last:-none}], want Reply.prototype.send marked via=\"name\": $( show )";;
    esac
fi
f="$( answer js connect lib/reply.js:respondWith,lib/reply.js:send )"
if ran_ok "(js) --connect=respondWith,send" "$f"; then
    e="$( parse edges "$f" | awk '$1 == "respondWith" && $2 == "send" { print $3 }' )"
    if [ "$e" = "name" ]; then ok "(H) --connect: the edge respondWith → send is marked via=\"name\""
    else no "(H) --connect: the edge respondWith → send is [${e:-absent}], want via=\"name\": $( parse edges "$f" | tr '\n' ';' )"; fi
fi
f="$( answer js expand lib/reply.js:respondWith --top-k=0 --legend=full )"
if ran_ok "(js) --expand=respondWith" "$f"; then
    c="$( parse ecalls "$f" | awk '$1 == "send" { print $3 }' )"
    if [ "$c" = "name" ]; then ok "(H) --expand=respondWith: <calls> row send is marked via=\"name\""
    else no "(H) --expand=respondWith: <calls> row send is [${c:-absent}], want via=\"name\": $( parse ecalls "$f" | tr '\n' ';' )"; fi
fi
f="$( answer js for "how does respondWith send the reply" --legend=full )"
if ran_ok "(js) --for=respondWith" "$f"; then
    c="$( parse ecalls "$f" respondWith | awk '$1 == "send" { print $3 }' )"
    if [ "$c" = "name" ]; then ok "(H) --for: respondWith's body <calls> row send is marked via=\"name\""
    else no "(H) --for: respondWith's body <calls> row send is [${c:-absent}], want via=\"name\": $( parse ecalls "$f" respondWith | tr '\n' ';' )"; fi
fi
# the FALSE witness respond → ctx.onerror(): absent or marked on every surface
notproven js callers lib/application.js:onerror "respond lib/application.js" "respondSafely lib/application.js"
f="$( answer js impact lib/application.js:onerror )"
if ran_ok "(js) --impact=lib/application.js:onerror" "$f"; then
    GOT="$( parse rows "$f" )"
    if [ "$GOT" = "NOROOT" ]; then no "(H) --impact=lib/application.js:onerror produced no answer about a symbol"
    elif [ -n "$( printf '%s\n' "$GOT" | awk '$2 == "respond" && $6 == "1" && $5 != "name"' )" ]; then
        no "(H) --impact=lib/application.js:onerror proves respond at d=1: $( show )"
    else ok "(H) --impact=lib/application.js:onerror never proves respond at d=1"; fi
fi
f="$( answer js path lib/application.js:respond,lib/application.js:onerror )"
if ran_ok "(js) --path=respond,onerror" "$f"; then
    GOT="$( parse rows "$f" )"
    last="$( printf '%s\n' "$GOT" | awk 'NF >= 5' | tail -1 )"
    reach="$( grep -oE '<path [^>]*>' "$f" | grep -oE ' reachable="[0-9]+"' | grep -oE '[0-9]+' )"
    if [ -z "$reach" ]; then no "(H) --path=respond,onerror carries no reachable= (no answer)"
    elif [ "$reach" = "0" ]; then ok "(H) --path=respond,onerror: unreachable (the false edge is gone)"
    else case "$last" in
        *" name "*|*" name") ok "(H) --path=respond,onerror: the hop into Application.onerror is marked via=\"name\"";;
        *) no "(H) --path=respond,onerror proves the hop into Application.onerror: [$last]";;
    esac; fi
fi
f="$( answer js expand lib/application.js:respond --top-k=0 --legend=full )"
if ran_ok "(js) --expand=respond" "$f"; then
    rows="$( parse ecalls "$f" )"
    if [ "$rows" = "NOROOT" ]; then no "(H) --expand=respond emitted no <calls> block"
    elif [ -n "$( printf '%s\n' "$rows" | awk '$1 == "onerror" && $2 == "12" && $3 != "name"' )" ]; then
        no "(H) --expand=respond: <calls> proves onerror at application.js:12: $( printf '%s' "$rows" | tr '\n' ';' )"
    else ok "(H) --expand=respond: <calls> never proves Application.onerror"; fi
fi

echo "--- (H) MCP twins (fresh TMPDIR: the MCP cache lives there)"
mkdir -p "$TMP/mcp"
# mcp ROOT TOOL SELECTOR OUT — one tools/call; the raw stream into OUT, the server's exit status into OUT.rc
mcp(){
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
        "$( printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":{"path":"%s","symbol":"%s"}}}' "$2" "$CORPUS/$1" "$3" )" \
        | TMPDIR="$TMP/mcp" "$BIN" --mcp >"$4" 2>/dev/null
    printf '%s' "$?" >"$4.rc"
}
# mcp_hedge ROOT TOOL SEL FIELD NAME FILE WANT — WANT = name (marked) | notproven (absent or marked)
mcp_hedge(){
    local r="$1" tool="$2" sel="$3" field="$4" n="$5" file="$6" want="$7" out h
    out="$TMP/mcp.$r.$tool.$( printf '%s' "$sel" | tr '/:.' '___' )"
    mcp "$r" "$tool" "$sel" "$out"
    ran_ok "(H) MCP $tool $sel" "$out" || return
    if [ "$( parse mcp "$out" "$field" )" = "NOROOT" ]; then no "(H) MCP $tool $sel: no JSON answer with $field"; return; fi
    h="$( parse mcp "$out" "$field" | awk -v n="$n" -v f="$file" '$1 == n && $2 == f { print $4 }' | sort -u | tr '\n' ' ' | sed 's/ $//' )"
    if [ "$want" = "name" ]; then
        if [ "$h" = "name" ]; then ok "(H) MCP $tool $sel: $field entry $n@$file is marked via=name"
        else no "(H) MCP $tool $sel: $field entry $n@$file is [${h:-absent}], want via=name"; fi
    else
        case " $h " in *" - "*) no "(H) MCP $tool $sel: $field entry $n@$file is PROVEN (no via=name)";;
                       *) ok "(H) MCP $tool $sel: $field entry $n@$file is absent or marked";; esac
    fi
}
mcp_hedge js find_symbol lib/reply.js:respondWith calls send lib/reply.js name
mcp_hedge js find_referencing_symbols lib/reply.js:send calledBy respondWith lib/reply.js name
mcp_hedge js find_symbol lib/application.js:respond calls onerror lib/application.js notproven
mcp_hedge js find_referencing_symbols lib/application.js:onerror calledBy respond lib/application.js notproven
mcp_hedge py find_symbol src/tui/callback.py:schedule calls call_later src/tui/message_pump.py name

echo "--- (H) parity: the hedge bit is value-equal across CLI and MCP, and across --callees and --expand"
# cli_set ROOT VERB SEL — "name@file#H" lines of the CLI answer; mcp_set ROOT TOOL SEL FIELD — the same from MCP
cli_set(){ local f rc; f="$( answer "$1" "$2" "$3" )"; rc="$( cat "$f.rc" 2>/dev/null )"
           if [ "$rc" != "0" ]; then echo "RUNFAIL --$2=$3 rc=${rc:-unknown}"; return; fi
           parse rows "$f" | awk 'NF >= 5 { print $2 "@" $3 "#" $5 } $0 == "NOROOT" { print }' | sort -u; }
mcp_set(){ local out rc; out="$TMP/mcpset.$1.$2.$( printf '%s' "$3" | tr '/:.' '___' )"; mcp "$1" "$2" "$3" "$out"
           rc="$( cat "$out.rc" 2>/dev/null )"
           if [ "$rc" != "0" ]; then echo "RUNFAIL MCP $2 $3 rc=${rc:-unknown}"; return; fi
           parse mcp "$out" "$4" | awk 'NF >= 4 { print $1 "@" $2 "#" $4 } $0 == "NOROOT" { print }' | sort -u; }
parity(){
    local label="$1" a="$2" b="$3"
    case "$a$b" in *RUNFAIL*) no "(H) parity $label: a run exited non-zero ([$a] [$b])"; return;; esac
    if [ -z "$a" ] || [ "$a" = "NOROOT" ] || [ "$b" = "NOROOT" ]; then no "(H) parity $label: an empty or rootless side ([$a] vs [$b])"; return; fi
    if [ "$a" = "$b" ]; then ok "(H) parity $label: $( printf '%s' "$a" | tr '\n' ' ' )"
    else no "(H) parity $label: CLI [$( printf '%s' "$a" | tr '\n' ' ' )] vs [$( printf '%s' "$b" | tr '\n' ' ' )]"; fi
}
for sel in lib/application.js:respond lib/reply.js:respondWith lib/reply.js:notFound lib/request.js:compile lib/uses.js:build lib/application.js:handle; do
    parity "callees/find_symbol.calls $sel" "$( cli_set js callees "$sel" )" "$( mcp_set js find_symbol "$sel" calls )"
done
for sel in lib/reply.js:send lib/application.js:onerror lib/schemas.js:listSchemas; do
    parity "callers/find_referencing_symbols.calledBy $sel" "$( cli_set js callers "$sel" )" "$( mcp_set js find_referencing_symbols "$sel" calledBy )"
done
# --callees vs --expand <calls>: compared by name + hedge (a <c> row names no file)
for sel in lib/reply.js:respondWith lib/reply.js:notFound lib/request.js:compile; do
    fc="$( answer js callees "$sel" )"; fe="$( answer js expand "$sel" --top-k=0 --legend=full )"
    if ran_ok "(H) --callees=$sel" "$fc" && ran_ok "(H) --expand=$sel" "$fe"; then
        a="$( parse rows "$fc" | awk 'NF >= 5 { print $2 "#" $5 }' | sort -u )"
        b="$( parse ecalls "$fe" | awk 'NF >= 3 { print $1 "#" $3 }' | sort -u )"
        parity "callees/expand-calls $sel" "$a" "$b"
    fi
done

echo "=== (C) conservation: no call silently disappears ==="
ROOTS="js ts py go java kt cs cpp swift rb"
for r in $ROOTS; do
    if ! rw "$r" --pin-census="$TMP/$r.tsv" >"$TMP/$r.map.xml"; then no "(C) ($r) the census run exited non-zero"; continue; fi
    DL="$( grep -m1 '^# dispositions ' "$TMP/$r.tsv" 2>/dev/null )"
    if [ -z "$DL" ]; then no "(C) ($r) the census carries no '# dispositions' line"; continue; fi
    if python3 - "$DL" <<'PY'
import re, sys
kv = dict( ( k, int( v ) ) for k, v in re.findall( r"(\w+)=(\d+)", sys.argv[ 1 ] ) )
if "calls" not in kv or "unaccounted" not in kv or kv[ "calls" ] < 1:
    sys.exit( 1 )
total = kv.pop( "calls" )
sys.exit( 0 if kv[ "unaccounted" ] == 0 and sum( kv.values() ) == total else 1 )
PY
    then ok "(C) ($r) dispositions sum to calls= with unaccounted=0"
    else no "(C) ($r) conservation broken: $DL"; fi
done

echo "=== (K) the predicates can fail ==="
GOT="$( printf '<callees of="x" defs="1"><s t="method" n="onerror" p="lib/application.js:12"/></callees>' >"$TMP/k1.xml"; parse rows "$TMP/k1.xml" )"
if [ -n "$( specmatch "onerror lib/application.js" | awk '$5 != "name"' )" ]; then ok "(K) an unhedged planted row reads as PROVEN (notproven would fail it)"
else no "(K) the reader missed an unhedged planted row: [$GOT]"; fi
GOT="$( printf '<callees of="x" defs="1"><s t="method" n="onerror" p="lib/application.js:12" via="name"/></callees>' >"$TMP/k2.xml"; parse rows "$TMP/k2.xml" )"
if [ -n "$( specmatch "onerror lib/application.js" | awk '$5 == "name"' )" ] && [ -z "$( specmatch "onerror lib/application.js" | awk '$5 != "name"' )" ]; then
    ok "(K) a hedged planted row reads as marked (notproven passes it, proven fails it)"
else no "(K) the reader did not read via=\"name\": [$GOT]"; fi
GOT="$( printf '<callees of="x" defs="1"><s t="method" n="onerror" p="lib/application.js:12" via="import"/></callees>' >"$TMP/k3.xml"; parse rows "$TMP/k3.xml" )"
if [ -n "$( specmatch "onerror lib/application.js" | awk '$5 != "name"' )" ]; then ok "(K) via=\"import\" is not the hedge"
else no "(K) the reader took via=\"import\" for the hedge: [$GOT]"; fi
printf 'nothing here' >"$TMP/k4.xml"
if [ "$( parse rows "$TMP/k4.xml" )" = "NOROOT" ]; then ok "(K) an answer with no root element is NOROOT"
else no "(K) a rootless document read as an answer"; fi
printf '<callers of="x" found="0"/>' >"$TMP/k5.xml"
if [ "$( parse rows "$TMP/k5.xml" )" = "NOROOT" ]; then ok "(K) an answer about no symbol (no defs=) is NOROOT"
else no "(K) a not-found answer read as an empty answer"; fi
printf '<ctx><b n="other"><calls total="1"><c n="send" l="7">sig</c></calls></b></ctx>' >"$TMP/k6.xml"
if [ "$( parse ecalls "$TMP/k6.xml" respondWith )" = "NOROOT" ]; then ok "(K) a --for answer without the named body is NOROOT, never an empty pass"
else no "(K) ecalls read another body's <calls> as respondWith's"; fi
printf '<ctx><b n="respondWith"><calls total="1"><c n="send" l="7" via="name">sig</c></calls></b></ctx>' >"$TMP/k7.xml"
if [ "$( parse ecalls "$TMP/k7.xml" respondWith )" = "send 7 name" ]; then ok "(K) ecalls reads a marked <c> row"
else no "(K) ecalls missed a marked <c> row: [$( parse ecalls "$TMP/k7.xml" respondWith )]"; fi
printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"calls\":[{\"name\":\"send\",\"file\":\"lib/reply.js\",\"line\":7,\"via\":\"name\"},{\"name\":\"code\",\"file\":\"lib/reply.js\",\"line\":12}]}"}]}}' >"$TMP/k8.json"
if [ "$( parse mcp "$TMP/k8.json" calls | tr '\n' ';' )" = "send lib/reply.js 7 name;code lib/reply.js 12 -;" ]; then ok "(K) the MCP reader reads the hedge bit per entry"
else no "(K) the MCP reader misread: [$( parse mcp "$TMP/k8.json" calls | tr '\n' ';' )]"; fi
if [ "$( parse mcp "$TMP/k8.json" calledBy )" = "NOROOT" ]; then ok "(K) an MCP answer without the field is NOROOT"
else no "(K) the MCP reader invented a missing field"; fi
printf '1' >"$TMP/k9.rc"
if ( ran_ok k "$TMP/k9" ) >/dev/null; then no "(K) ran_ok accepted a run that exited 1"
else ok "(K) ran_ok fails a run that exited non-zero"; fi
rm -f "$TMP/k10.rc"
if ( ran_ok k "$TMP/k10" ) >/dev/null; then no "(K) ran_ok accepted a run with no recorded exit status"
else ok "(K) ran_ok fails a run with no recorded exit status"; fi
if ( parity k "a#-" "a#name" ) | grep -q FAIL; then ok "(K) parity fails when the hedge bit differs"
else no "(K) parity accepted differing hedge bits"; fi
if ( parity k "" "" ) | grep -q FAIL; then ok "(K) parity fails on two empty sides (never a vacuous pass)"
else no "(K) parity accepted two empty sides"; fi
if ( parity k "RUNFAIL --callees=x rc=1" "RUNFAIL --callees=x rc=1" ) | grep -q FAIL; then ok "(K) parity fails when a run exited non-zero"
else no "(K) parity accepted a failed run"; fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; exit 1; fi
