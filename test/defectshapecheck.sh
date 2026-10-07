#!/usr/bin/env bash
# defectshapecheck.sh — gate for the twelfth --quality-delta kind, defect-shape: four shapes of a REAL defect
# that review keeps finding by hand and that a deterministic syntactic check finds at write time. Each row is
# <r kind="defect-shape" ... defect="FACET" ...>, one kind with four facets so the kind list grows once and
# --ack-only=FACET selects one shape:
#   format-arity   — a literal std::format-family / rw::emitTo / rw::formatTo / fmt:: format string, or a Python
#                    "literal".format(...), whose replacement fields do not match its arguments. GATES (a dropped
#                    argument is a defect, not debt — so it gates whatever the origin; see §1 freshbad).
#                    std::format_string rejects too FEW arguments at compile time and accepts too MANY silently;
#                    Python raises on too few at run time and ignores too many.
#   utf8-cut       — C++: a byte cap on display text (a cut plus an appended ellipsis) with no UTF-8 boundary
#                    back-off, or an ellipsis appended at a byte cap reached by pushing bytes. REPORT-ONLY.
#   dedup-first    — C++: std::unique / std::ranges::unique with a predicate over a type that carries a
#                    severity-like field, where neither the predicate nor the sort before it reads that field,
#                    so the FIRST row of a run survives, not the most severe. REPORT-ONLY.
#   vacuous-assert — Bash, test-script paths only: an ABSENCE assertion (grep -q PAT whose match is the failure
#                    branch) read off a command whose failure is never checked, so a crash reads as PASS.
#                    REPORT-ONLY.
# Like every kind, a row fires only on what THIS change introduced (a count that grew against the baseline),
# never on pre-existing debt; each facet has near-miss negatives the new code could plausibly mis-handle.
#
# Every absence assertion in this gate is read off a delta run that SUCCEEDED (rc 0 or 2 and a
# <quality-delta root) — the very shape §4 detects. Operates in temp dirs; the repo is never touched.
#
# Usage:  bash test/defectshapecheck.sh "$PWD/build/ripwire"
set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
. "$ROOT/test/lib/clean-env.sh"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"          # absolutize BEFORE we cd away
fail=0
ok(){ printf '  PASS  %s\n' "$*" || { fail=1; printf '  FAIL  could not write the PASS line for: %s\n' "$*"; }; return 0; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }
[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "  SKIP  defectshapecheck (git not available)"; exit 0; }

WORK="$( mktemp -d )" || { echo "  FAIL  defectshapecheck: mktemp -d failed"; exit 1; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "  FAIL  defectshapecheck: no temp dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
echo "defectshapecheck: BIN=$BIN  (temp corpora)"

# ── harness ─────────────────────────────────────────────────────────────────────────────────────────────
fx_init(){   # NAME → a fresh git repo at $WORK/NAME
    local d="$WORK/$1"
    mkdir -p "$d" && ( cd "$d" && git init -q && git config user.email t@t && git config user.name t ) \
        || { no "$1: fixture repo could not be created"; return 1; }
}
fx_commit(){ ( cd "$WORK/$1" && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 ) || no "$1: baseline commit failed"; }
QD_OUT=""; QD_RC=99; QD_OK=0
fx_run(){    # NAME [extra args] → QD_OUT, QD_RC, QD_OK (1 only when the run succeeded and produced its root)
    local d="$WORK/$1"; shift
    QD_OUT="$( cd "$d" && "$BIN" . --quality-delta --no-cache "$@" 2>/dev/null )"
    QD_RC=$?
    QD_OK=0
    if { [ "$QD_RC" = 0 ] || [ "$QD_RC" = 2 ]; } && printf '%s' "$QD_OUT" | grep -q '<quality-delta '; then
        QD_OK=1
    else
        no "$( basename "$d" ): the delta run failed (rc=$QD_RC) — no assertion below reads an absence off it"
    fi
}
ds_rows(){ printf '%s' "$QD_OUT" | tr '>' '\n' | grep '<r kind="defect-shape" '; }                       # every defect-shape row
ds_row(){  ds_rows | grep "defect=\"$1\"" | grep " sym=\"$2\""; }                                           # FACET SYM
ds_row_p(){ ds_rows | grep "defect=\"$1\"" | grep " p=\"$2:"; }                                             # FACET PATH (a file-anchored row)
ds_any_sym(){ ds_rows | grep " sym=\"$1\""; }
ds_any_p(){ ds_rows | grep " p=\"$1:"; }
ds_judge(){  # LABEL ROW WANT
    local label="$1" row="$2"
    case "$3" in
        gating)     printf '%s' "$row" | grep -q 'gating="1"' && ! printf '%s' "$row" | grep -q 'sev="minor"' \
                        && ! printf '%s' "$row" | grep -q 'origin="new-symbol"' \
                        && ok "$label: gating (preexisting)" || no "$label: should gate as preexisting-worse: $row" ;;
        gating-new) printf '%s' "$row" | grep -q 'gating="1"' && printf '%s' "$row" | grep -q 'origin="new-symbol"' \
                        && ok "$label: origin=new-symbol AND gating (a defect, not debt)" || no "$label: a new-symbol format-arity row should still gate: $row" ;;
        minor)      printf '%s' "$row" | grep -q 'sev="minor"' && ! printf '%s' "$row" | grep -q 'gating=' \
                        && ! printf '%s' "$row" | grep -q 'origin="new-symbol"' \
                        && ok "$label: sev=minor (report-only)" || no "$label: should be report-only sev=minor: $row" ;;
        new-symbol) printf '%s' "$row" | grep -q 'origin="new-symbol"' && ! printf '%s' "$row" | grep -q 'gating=' \
                        && ok "$label: origin=new-symbol, never gating" || no "$label: should be new-symbol and non-gating: $row" ;;
        *)          no "$label: harness: unknown WANT '$3'" ;;
    esac
}
ds_has(){    # LABEL FACET SYM WANT
    local row; row="$( ds_row "$2" "$3" )"
    if [ -z "$row" ]; then no "$1: no defect=\"$2\" row on $3"; ds_rows | head -20; return; fi
    [ "$( printf '%s\n' "$row" | wc -l | tr -d ' ' )" = 1 ] || { no "$1: more than one defect=\"$2\" row on $3: $row"; return; }
    ds_judge "$1: defect=\"$2\" on $3" "$row" "$4"
}
ds_has_p(){  # LABEL FACET PATH WANT
    local row; row="$( ds_row_p "$2" "$3" )"
    if [ -z "$row" ]; then no "$1: no defect=\"$2\" row anchored in $3"; ds_rows | head -20; return; fi
    [ "$( printf '%s\n' "$row" | wc -l | tr -d ' ' )" = 1 ] || { no "$1: more than one defect=\"$2\" row in $3: $row"; return; }
    ds_judge "$1: defect=\"$2\" in $3" "$row" "$4"
}
ds_none(){   # LABEL SYM WHY — no defect-shape row of ANY facet on SYM
    [ "$QD_OK" = 1 ] || { no "$1: cannot read an absence on $2 off a failed run"; return; }
    local row; row="$( ds_any_sym "$2" )"
    if [ -z "$row" ]; then ok "$1: no defect-shape row on $2 ($3)"; else no "$1: false positive on $2 ($3): $row"; fi
}
ds_none_p(){ # LABEL PATH WHY — no defect-shape row anchored in PATH
    [ "$QD_OK" = 1 ] || { no "$1: cannot read an absence in $2 off a failed run"; return; }
    local row; row="$( ds_any_p "$2" )"
    if [ -z "$row" ]; then ok "$1: no defect-shape row in $2 ($3)"; else no "$1: false positive in $2 ($3): $row"; fi
}
ds_wasnow(){ # LABEL FACET SYM WAS NOW — the count is distinct offending sites, not a double count
    local row; row="$( ds_row "$2" "$3" )"
    printf '%s' "$row" | grep -q "was=\"$4\"" && printf '%s' "$row" | grep -q "now=\"$5\"" \
        && ok "$1: $3 counts was=$4 now=$5" || no "$1: $3 should count was=$4 now=$5: ${row:-<no row>}"
}
hdr_attr(){ printf '%s' "$QD_OUT" | tr '>' '\n' | grep '<quality-delta ' | head -1 | grep -o " $1=\"[0-9]*\"" | grep -o '[0-9][0-9]*'; }
gating_split(){  # LABEL MIN_FORMAT_ARITY_GATING — who gates. The near-miss functions are clones of each other on purpose, so the
                 # duplication kind gates in these fixtures too; the exit is judged by attribution, not by a bare 0/2:
                 # header gating= equals the gating rows, no REPORT-ONLY facet carries gating=, format-arity carries >= MIN,
                 # and the exit is 2 exactly when some row gates.
    [ "$QD_OK" = 1 ] || { no "$1: cannot judge gating off a failed run"; return; }
    local hg all fa other
    hg="$( hdr_attr gating )"
    case "$hg" in ''|*[!0-9]*) no "$1: header gating= is missing or not numeric ('$hg')"; return ;; esac
    all="$( printf '%s' "$QD_OUT" | tr '>' '\n' | grep '<r ' | grep -c 'gating="1"' )"
    fa="$( ds_rows | grep 'defect="format-arity"' | grep -c 'gating="1"' )"
    other="$( ds_rows | grep 'gating=' | grep -vc 'defect="format-arity"' )"
    if [ "$hg" = "$all" ]; then ok "$1: header gating=$hg counts every gating row"; else no "$1: header gating=$hg but $all rows carry gating=\"1\""; fi
    [ "$other" = 0 ] && ok "$1: no report-only facet (utf8-cut, dedup-first, vacuous-assert) carries gating=" \
        || no "$1: $other report-only defect-shape rows carry gating=: $( ds_rows | grep 'gating=' | grep -v 'defect="format-arity"' | head -3 )"
    if [ "$fa" -ge "$2" ]; then ok "$1: $fa format-arity rows gate (want >= $2)"; else no "$1: $fa format-arity rows gate, want >= $2"; fi
    if [ "$all" -gt 0 ]; then
        if [ "$QD_RC" = 2 ]; then ok "$1: exit 2 with $all gating rows"; else no "$1: $all gating rows but exit $QD_RC"; fi
    else
        if [ "$QD_RC" = 0 ]; then ok "$1: exit 0 with no gating row"; else no "$1: no gating row but exit $QD_RC"; fi
    fi
}

# ── 1) FORMAT-ARITY, C++ ────────────────────────────────────────────────────────────────────────────────
#   Every function exists at the baseline with a CORRECT call. The edit turns some into a mismatch (the
#   positives) and the rest into correct-but-tricky spellings the counter must get right (the near-misses):
#   {{ }} escapes, format specs, positional {0}, nested dynamic width {:>{}} (it consumes an argument), a
#   non-literal or macro format (skipped, never guessed), a "{}" inside an ARGUMENT, a raw string, a wide
#   literal, a member function that happens to be called format, a commented-out call, a char argument '{'.
fx_init fmt_cpp
mkdir -p "$WORK/fmt_cpp/src"
FMT_HDR='#include <cstdio>
#include <format>
#include <iterator>
#include <print>
#include <string>
#include <fmt/format.h>

namespace rw
{
template<class... A> void emitTo( std::FILE* stream, std::format_string<A...> f, A&&... a );
template<class... A> std::size_t formatTo( char* buf, std::size_t cap, std::format_string<A...> f, A&&... a );
template<class S> void emitRaw( std::FILE* stream, const S& text );
}

#define FMT_PAIR "{} {}"
constexpr const char* kFmt = "{} and {}";

struct Log
{
    std::string format( const char* f, int a ) const;
};
'
{ printf '%s' "$FMT_HDR"; cat <<'EOF'
std::string extra( int a, int b ) { return std::format( "a={} b={}", a, b ); }
std::string fewer( int a, int b ) { return std::format( "a={} b={}", a, b ); }
void concat( int a, int b )
{
    rw::emitTo( stdout, "<legend a=\"{}\" "
                        "b=\"{}\"/>\n",
                a, b );
}
std::size_t formatto( int a, int b ) { char buf[64]; return rw::formatTo( buf, sizeof( buf ), "<x a=\"{}\" b=\"{}\"/>", a, b ); }
std::string formattostd( int a, int b ) { std::string out; std::format_to( std::back_inserter( out ), "{}-{}", a, b ); return out; }
std::string positional( int a, int b ) { return std::format( "{0} {1}", a, b ); }
std::string dynwidthbad( const std::string& s, int w ) { return std::format( "{:>{}}", s, w ); }
void printstream( int a, int b ) { std::print( stderr, "{} {}\n", a, b ); }
std::string fmtns( int a, int b ) { return fmt::format( "{} {}", a, b ); }
std::string escaped( int a ) { return std::format( "{}", a ); }
std::string spec( int a, double d, int b ) { return std::format( "{} {} {}", a, d, b ); }
std::string posok( int a, int b ) { return std::format( "{} {}", a, b ); }
std::string dynwidth( const std::string& s, int w, double d, int p ) { return std::format( "{} {} {} {}", s, w, d, p ); }
std::string nonliteral( int a, int b ) { return std::format( "{} {}", a, b ); }
std::string fmtconstarg( int a ) { return std::format( "{}", a ); }
std::string macro( int a, int b ) { return std::format( "{} {}", a, b ); }
std::string inarg( int a ) { return std::format( "{}", a ); }
std::string rawstr( int a ) { return std::format( "{}", a ); }
std::wstring wide( int a, int b ) { return std::format( L"{}", a + b ); }
std::string member( const Log& log, int a ) { return log.format( "{}", a ); }
std::string commented( int a ) { return std::format( "{}", a ); }
std::string charlit( int a ) { return std::format( "{}", a ); }
void printok( int a ) { std::println( "{}", a ); }
void raw() { rw::emitRaw( stdout, "plain" ); }
std::string legacy( int a ) { return std::format( "{} {}", a, a, a ); }
int drive() { return 0; }
EOF
} >"$WORK/fmt_cpp/src/fmt.cpp"
fx_commit fmt_cpp
{ printf '%s' "$FMT_HDR"; cat <<'EOF'
std::string extra( int a, int b ) { return std::format( "a={} b={}", a, b, a + b ); }
std::string fewer( int a, int b ) { return std::format( "a={} b={} c={}", a, b ); }
void concat( int a, int b )
{
    rw::emitTo( stdout, "<legend a=\"{}\" "
                        "b=\"{}\" c=\"{}\"/>\n",
                a, b, a, b );
}
std::size_t formatto( int a, int b ) { char buf[64]; return rw::formatTo( buf, sizeof( buf ), "<x a=\"{}\"/>", a, b ); }
std::string formattostd( int a, int b ) { std::string out; std::format_to( std::back_inserter( out ), "{}-{}", a, b, a ); return out; }
std::string positional( int a, int b ) { return std::format( "{0} {1}", a, b, a ); }
std::string dynwidthbad( const std::string& s, int w ) { return std::format( "{:>{}}", s ); }
void printstream( int a, int b ) { std::print( stderr, "{} {}\n", a ); }
std::string fmtns( int a, int b ) { return fmt::format( "{} {}", a ); }
std::string escaped( int a ) { return std::format( "{{literal}} {} }}{{", a ); }
std::string spec( int a, double d, int b ) { return std::format( "{:>8} {:.2f} {:#x}", a, d, b ); }
std::string posok( int a, int b ) { return std::format( "{0} and {0} and {1}", a, b ); }
std::string dynwidth( const std::string& s, int w, double d, int p ) { return std::format( "{:>{}} {:{}.{}f}", s, w, d, w, p ); }
std::string nonliteral( int a, int b ) { return std::format( kFmt, a, b, a ) + std::vformat( kFmt, std::make_format_args( a, b, a ) ); }
std::string fmtconstarg( int a ) { return std::format( kFmt, "{}" ); }
std::string macro( int a, int b ) { return std::format( FMT_PAIR, a, b, a ); }
std::string inarg( int a ) { return std::format( "{}", "{} {}" ); }
std::string rawstr( int a ) { return std::format( R"x(<a x="{}" y="{{}}" q=")"/>)x", a ); }
std::wstring wide( int a, int b ) { return std::format( L"{} {}", a, b ); }
std::string member( const Log& log, int a ) { return log.format( "{} {} {}", a ); }
std::string commented( int a )
{
    // return std::format( "{} {}", a );
    return std::format( "{}", a );
}
std::string charlit( int a ) { return std::format( "{}{}", '{', a ); }
void printok( int a ) { std::println( "{} {}", a, a ); }
void raw() { rw::emitRaw( stdout, "{} {} {}" ); }
std::string legacy( int a ) { return std::format( "{} {}", a, a, a ); }
std::string freshbad( int a ) { return std::format( "{}", a, a ); }
std::string freshok( int a ) { return std::format( "{} {}", a, a ); }
int drive() { return 1; }
EOF
} >"$WORK/fmt_cpp/src/fmt.cpp"
fx_run fmt_cpp
L="format-arity (c++)"
ds_has  "$L" format-arity extra       gating
ds_has  "$L" format-arity fewer       gating
ds_has  "$L" format-arity concat      gating
ds_has  "$L" format-arity formatto    gating
ds_has  "$L" format-arity formattostd gating
ds_has  "$L" format-arity positional  gating
ds_has  "$L" format-arity dynwidthbad gating
ds_has  "$L" format-arity printstream gating
ds_has  "$L" format-arity fmtns       gating
ds_has  "$L" format-arity freshbad    gating-new
ds_wasnow "$L" format-arity extra 0 1
ds_wasnow "$L" format-arity concat 0 1
ds_none "$L" escaped     "{{ and }} are escapes, not fields"
ds_none "$L" spec        "a format spec is part of its field"
ds_none "$L" posok       "{0} twice and {1} need two arguments"
ds_none "$L" dynwidth    "a nested {} width/precision consumes an argument"
ds_none "$L" nonliteral  "a named format constant or vformat is skipped, never guessed"
ds_none "$L" fmtconstarg "the literal is an ARGUMENT, not the format"
ds_none "$L" macro       "a macro format is skipped, never guessed"
ds_none "$L" inarg       "a {} inside an argument string is not a field"
ds_none "$L" rawstr      "a raw string with a custom delimiter and a )\" inside, one field"
ds_none "$L" wide        "an L-prefixed literal counts like any other"
ds_none "$L" member      "Log::format is not the format family"
ds_none "$L" commented   "a commented-out call is not code"
ds_none "$L" charlit     "a '{' char argument is an argument"
ds_none "$L" printok     "std::println with matching arguments"
ds_none "$L" raw         "emitRaw prints bytes, it does not format"
ds_none "$L" legacy      "a mismatch the change did not introduce (untouched function)"
ds_none "$L" freshok     "a new function with a matching call"
gating_split "$L" 10
OFMT="$QD_OUT"
fx_run fmt_cpp
if [ "$QD_OK" = 1 ] && [ "$OFMT" = "$QD_OUT" ]; then ok "$L: delta byte-identical run-to-run"; else no "$L: non-deterministic delta"; fi
if command -v xmllint >/dev/null 2>&1; then
    if printf '%s' "$OFMT" | xmllint --noout - 2>/dev/null; then ok "$L: xml well-formed"; else no "$L: xml malformed"; fi
else
    echo "  SKIP  $L: xml well-formedness (xmllint not installed)"
fi

# ── 1b) FORMAT-ARITY, Python "literal".format(...) ──────────────────────────────────────────────────────
#   Too few raises IndexError/KeyError at run time; too many is ignored silently. Named fields count against
#   keyword arguments, auto/positional fields against positional ones; *args / **kwargs make the count
#   unknowable (skipped). f-strings, %-formatting and a non-literal receiver are out of the shape.
fx_init fmt_py
printf 'VERSION = "1"\nBANNER = "v{}".format(VERSION)\n' >"$WORK/fmt_py/banner.py"
cat >"$WORK/fmt_py/fmt.py" <<'EOF'


def extra(a, b):
    return "a={} b={}".format(a, b)


def fewer(a, b):
    return "a={} b={}".format(a, b)


def namedmissing(x, y):
    return "{x} {y}".format(x=x, y=y)


def concat(a, b):
    return ("a={} " "b={}").format(a, b)


def escaped(a):
    return "{}".format(a)


def star(pair):
    return "{} {}".format(pair[0], pair[1])


def kwstar(d):
    return "{a} {b}".format(a=d["a"], b=d["b"])


def attr(f):
    return "{}".format(f.name)


def index(d):
    return "{}".format(d["k"])


def nested(a):
    return "{}".format(a)


def mixed(a, b):
    return "{} {}".format(a, b)


def fstring(a, b):
    return "{} {}".format(a, b)


def nonliteral(tmpl, a, b):
    return tmpl.format(a, b)


def percent(a):
    return "%s" % (a,)


def triple(a, b):
    return """{} {}""".format(a, b)


def legacy(a):
    return "{} {}".format(a, a, a)
EOF
fx_commit fmt_py
printf 'VERSION = "1"\nBANNER = "v{} build {}".format(VERSION)\n' >"$WORK/fmt_py/banner.py"
cat >"$WORK/fmt_py/fmt.py" <<'EOF'


def extra(a, b):
    return "a={} b={}".format(a, b, a + b)


def fewer(a, b):
    return "a={} b={} c={}".format(a, b)


def namedmissing(x, y):
    return "{x} {y}".format(x=x)


def concat(a, b):
    return ("a={} " "b={} " "c={}").format(a, b)


def escaped(a):
    return "{{}} {} {{x}}".format(a)


def star(pair):
    return "{} {} {}".format(*pair)


def kwstar(d):
    return "{a} {b} {c}".format(**d)


def attr(f):
    return "{0.name} {0.size}".format(f)


def index(d):
    return "{0[k]} {0[j]}".format(d)


def nested(a):
    return "{!r:>{w}}".format(a, w=3)


def mixed(a, b):
    return "{0} {name}".format(a, name=b)


def fstring(a, b):
    return f"{a} {b} {{}}"


def nonliteral(tmpl, a, b):
    return tmpl.format(a, b, a)


def percent(a):
    return "%s %s" % (a,)


def triple(a, b):
    return """{}
{}""".format(a, b)


def legacy(a):
    return "{} {}".format(a, a, a)


def freshbad(a):
    return "{}".format(a, a)
EOF
fx_run fmt_py
L="format-arity (python)"
ds_has   "$L" format-arity extra        gating
ds_has   "$L" format-arity fewer        gating
ds_has   "$L" format-arity namedmissing gating
ds_has   "$L" format-arity concat       gating
ds_has   "$L" format-arity freshbad     gating-new
ds_has_p "$L" format-arity banner.py    gating
ds_none  "$L" escaped    "{{ }} are escapes"
ds_none  "$L" star       "*args makes the count unknowable"
ds_none  "$L" kwstar     "**kwargs makes the names unknowable"
ds_none  "$L" attr       "{0.name} {0.size} need one positional argument"
ds_none  "$L" index      "{0[k]} {0[j]} need one positional argument"
ds_none  "$L" nested     "a nested named width {w} is a keyword argument"
ds_none  "$L" mixed      "one positional, one named, both given"
ds_none  "$L" fstring    "an f-string has no argument list"
ds_none  "$L" nonliteral "a non-literal receiver is skipped, never guessed"
ds_none  "$L" percent    "%-formatting is not this shape"
ds_none  "$L" triple     "a triple-quoted literal with two fields and two arguments"
ds_none  "$L" legacy     "a mismatch the change did not introduce"
gating_split "$L" 6

# ── 2) UTF8-CUT, C++ (report-only) ──────────────────────────────────────────────────────────────────────
#   The corpus shapes: a cut (resize / substr(0,N) / erase(N)) plus an appended ellipsis on the SAME string
#   with no UTF-8 back-off in the function, and an ellipsis appended once a byte-pushing loop reaches the
#   cap (the cut lands mid-sequence and the ellipsis can fire with nothing dropped). Near-misses: a
#   continuation-byte back-off (0xC0/0x80), a utf8-named helper, a cut with no ellipsis (a buffer, not text —
#   a stated floor), an ellipsis on a different variable, an ellipsis that replaces the value, a u32string.
fx_init utf8
mkdir -p "$WORK/utf8/src"
U8_HDR='#include <string>
#include <string_view>

constexpr std::size_t kCap = 80;
std::string truncateUtf8WithEllipsis( std::string_view s, std::size_t cap );
'
{ printf '%s' "$U8_HDR"; cat <<'EOF'
std::string excerpt( std::string s ) { return s; }
std::string clip( const std::string& s, std::size_t n ) { return s; }
std::string build( std::string_view s )
{
    std::string out;
    for( char c : s )
    {
        out.push_back( c );
    }
    return out;
}
std::string erasecut( std::string s, std::size_t n ) { return s; }
std::string guarded( std::string s ) { return s; }
std::string helper( const std::string& s ) { return s; }
std::string noellipsis( std::string s, std::size_t n ) { return s; }
std::string othervar( std::string buf, std::string label, std::size_t n ) { return buf + label; }
std::string replaced( const std::string& s, std::size_t n ) { return s; }
std::string loading( std::string out ) { return out; }
std::u32string wide( std::u32string s, std::size_t n ) { return s; }
std::string legacy( std::string s ) { if( s.size() > 40 ) { s.resize( 40 ); s += "..."; } return s; }
int drive() { return 0; }
EOF
} >"$WORK/utf8/src/text.cpp"
fx_commit utf8
{ printf '%s' "$U8_HDR"; cat <<'EOF'
std::string excerpt( std::string s )
{
    if( s.size() > 117 )
    {
        s.resize( 117 );
        s += "...";
    }
    return s;
}
std::string clip( const std::string& s, std::size_t n ) { return s.size() > n ? s.substr( 0, n ) + "\xE2\x80\xA6" : s; }
std::string build( std::string_view s )
{
    std::string out;
    for( char c : s )
    {
        out.push_back( c );
        if( out.size() >= kCap )
        {
            out += "\xE2\x80\xA6";
            break;
        }
    }
    return out;
}
std::string erasecut( std::string s, std::size_t n )
{
    if( s.size() > n )
    {
        s.erase( n );
        s.append( "..." );
    }
    return s;
}
std::string guarded( std::string s )
{
    if( s.size() > 117 )
    {
        std::size_t n = 117;
        while( n > 0 && ( static_cast<unsigned char>( s[n] ) & 0xC0 ) == 0x80 )
        {
            --n;
        }
        s.resize( n );
        s += "...";
    }
    return s;
}
std::string helper( const std::string& s ) { return truncateUtf8WithEllipsis( s, 117 ); }
std::string noellipsis( std::string s, std::size_t n )
{
    if( s.size() > n )
    {
        s.resize( n );
    }
    return s;
}
std::string othervar( std::string buf, std::string label, std::size_t n )
{
    buf.resize( n );
    label += "...";
    return buf + label;
}
std::string replaced( const std::string& s, std::size_t n ) { return s.size() > n ? std::string( "..." ) : s; }
std::string loading( std::string out ) { out += "loading..."; return out; }
std::u32string wide( std::u32string s, std::size_t n )
{
    if( s.size() > n )
    {
        s.resize( n );
        s += U"…";
    }
    return s;
}
std::string legacy( std::string s ) { if( s.size() > 40 ) { s.resize( 40 ); s += "..."; } return s; }
std::string freshcut( std::string s ) { if( s.size() > 60 ) { s = s.substr( 0, 60 ) + "..."; } return s; }
int drive() { return 1; }
EOF
} >"$WORK/utf8/src/text.cpp"
fx_run utf8
L="utf8-cut (c++)"
ds_has  "$L" utf8-cut excerpt  minor
ds_has  "$L" utf8-cut clip     minor
ds_has  "$L" utf8-cut build    minor
ds_has  "$L" utf8-cut erasecut minor
ds_has  "$L" utf8-cut freshcut new-symbol
ds_wasnow "$L" utf8-cut excerpt 0 1
ds_none "$L" guarded    "the cut backs off continuation bytes (0xC0/0x80)"
ds_none "$L" helper     "a utf8 truncation helper does the cut"
ds_none "$L" noellipsis "a cut with no ellipsis is not judged display text (stated floor)"
ds_none "$L" othervar   "the ellipsis goes on a different string than the one cut"
ds_none "$L" replaced   "the ellipsis replaces the value, nothing is cut"
ds_none "$L" loading    "a literal that merely ends in ... with no cap"
ds_none "$L" wide       "a u32string holds code points, a cut cannot split one"
ds_none "$L" legacy     "a cut the change did not introduce"
gating_split "$L" 0

# ── 3) DEDUP-FIRST, C++ (report-only) ───────────────────────────────────────────────────────────────────
#   The corpus shape (a two-pass merge, sorted on (line, rule), uniqued keeping the first) plus its ranges and
#   unsorted siblings. Near-misses: the sort orders on severity (worst first), the predicate compares severity,
#   a type with no severity-like field, a field whose name only CONTAINS a severity word (indentLevel — a
#   bounded token match), a predicate-less unique, a unique over ints.
fx_init dedup
mkdir -p "$WORK/dedup/src"
DD_HDR='#include <algorithm>
#include <string>
#include <vector>

enum class Severity { Info, Warn, Critical };
struct Finding
{
    int line = 0;
    std::string rule;
    Severity sev = Severity::Info;
};
struct Row
{
    int line = 0;
    std::string rule;
    std::string text;
};
struct Node
{
    int line = 0;
    std::string rule;
    int indentLevel = 0;
};
'
{ printf '%s' "$DD_HDR"; cat <<'EOF'
void mergeFirst( std::vector<Finding>& v ) { (void)v; }
void rangesFirst( std::vector<Finding>& v ) { (void)v; }
void unsortedFirst( std::vector<Finding>& v ) { (void)v; }
void worstFirst( std::vector<Finding>& v ) { (void)v; }
void predSev( std::vector<Finding>& v ) { (void)v; }
void noSev( std::vector<Row>& v ) { (void)v; }
void indent( std::vector<Node>& v ) { (void)v; }
void defaultEq( std::vector<int>& v ) { (void)v; }
void ints( std::vector<int>& v ) { (void)v; }
void legacy( std::vector<Finding>& v )
{
    v.erase( std::unique( v.begin(), v.end(), []( const Finding& a, const Finding& b ) { return a.line == b.line; } ), v.end() );
}
int drive() { return 0; }
EOF
} >"$WORK/dedup/src/merge.cpp"
fx_commit dedup
{ printf '%s' "$DD_HDR"; cat <<'EOF'
void mergeFirst( std::vector<Finding>& v )
{
    std::stable_sort( v.begin(), v.end(), []( const Finding& a, const Finding& b )
                      { return a.line != b.line ? a.line < b.line : a.rule < b.rule; } );
    v.erase( std::unique( v.begin(), v.end(), []( const Finding& a, const Finding& b )
                          { return a.line == b.line && a.rule == b.rule; } ),
             v.end() );
}
void rangesFirst( std::vector<Finding>& v )
{
    std::ranges::sort( v, []( const Finding& a, const Finding& b ) { return a.line < b.line; } );
    v.erase( std::ranges::unique( v, []( const Finding& a, const Finding& b ) { return a.line == b.line; } ).begin(), v.end() );
}
void unsortedFirst( std::vector<Finding>& v )
{
    v.erase( std::unique( v.begin(), v.end(), []( const Finding& a, const Finding& b ) { return a.rule == b.rule; } ), v.end() );
}
void worstFirst( std::vector<Finding>& v )
{
    std::stable_sort( v.begin(), v.end(), []( const Finding& a, const Finding& b )
                      { return a.line != b.line ? a.line < b.line : a.sev > b.sev; } );
    v.erase( std::unique( v.begin(), v.end(), []( const Finding& a, const Finding& b ) { return a.line == b.line; } ), v.end() );
}
void predSev( std::vector<Finding>& v )
{
    v.erase( std::unique( v.begin(), v.end(), []( const Finding& a, const Finding& b )
                          { return a.line == b.line && a.sev == b.sev; } ),
             v.end() );
}
void noSev( std::vector<Row>& v )
{
    v.erase( std::unique( v.begin(), v.end(), []( const Row& a, const Row& b ) { return a.line == b.line; } ), v.end() );
}
void indent( std::vector<Node>& v )
{
    v.erase( std::unique( v.begin(), v.end(), []( const Node& a, const Node& b ) { return a.line == b.line; } ), v.end() );
}
void defaultEq( std::vector<int>& v )
{
    std::sort( v.begin(), v.end() );
    v.erase( std::unique( v.begin(), v.end() ), v.end() );
}
void ints( std::vector<int>& v )
{
    v.erase( std::unique( v.begin(), v.end(), []( int a, int b ) { return a / 10 == b / 10; } ), v.end() );
}
void legacy( std::vector<Finding>& v )
{
    v.erase( std::unique( v.begin(), v.end(), []( const Finding& a, const Finding& b ) { return a.line == b.line; } ), v.end() );
}
void freshFirst( std::vector<Finding>& v )
{
    v.erase( std::unique( v.begin(), v.end(), []( const Finding& a, const Finding& b ) { return a.line == b.line; } ), v.end() );
}
int drive() { return 1; }
EOF
} >"$WORK/dedup/src/merge.cpp"
fx_run dedup
L="dedup-first (c++)"
ds_has  "$L" dedup-first mergeFirst    minor
ds_has  "$L" dedup-first rangesFirst   minor
ds_has  "$L" dedup-first unsortedFirst minor
ds_has  "$L" dedup-first freshFirst    new-symbol
ds_none "$L" worstFirst "the sort before the unique orders on severity, worst first"
ds_none "$L" predSev    "the predicate keeps rows of different severity apart"
ds_none "$L" noSev      "the element type has no severity-like field"
ds_none "$L" indent     "indentLevel only contains a severity word (bounded token match)"
ds_none "$L" defaultEq  "a predicate-less unique compares whole values"
ds_none "$L" ints       "a unique over ints carries no severity"
ds_none "$L" legacy     "a keep-first the change did not introduce"
gating_split "$L" 0

# ── 4) VACUOUS-ASSERT, Bash gate scripts (report-only) ──────────────────────────────────────────────────
#   One script per arm (top-level code has no enclosing symbol, so its row anchors on the file and a file
#   per arm keeps the arms apart). Baseline: each script has its reporters and one sound assertion; the edit
#   appends the arm. Positives: an absence assertion read off an unchecked $( ) capture, off a direct pipe
#   (with or without pipefail — under pipefail a crash makes the pipeline false, which takes the same PASS
#   branch), the if/else spelling, backslash continuations, the !-negated pass spelling, other reporter
#   names, inside a function, and a brand-new script. Near-misses: the capture's rc checked, `|| no` on the
#   capture, a presence check, a positive assertion on the same output first, the match-is-pass polarity,
#   a literal producer, a commented-out shape, a pre-existing vacuous line, a sound if, and the same shape in
#   a script outside a test path.
fx_init vac
mkdir -p "$WORK/vac/test" "$WORK/vac/scripts"
VHDR="$( cat <<'EOF'
#!/usr/bin/env bash
BIN="${1:?}"
fail=0
ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }
V0="$( "$BIN" --version 2>&1 )"; RC0=$?
[ "$RC0" = 0 ] && ok "version runs" || no "version failed: $V0"
EOF
)"
VHDR="$VHDR
"
for f in t_var t_pipe t_pipefail t_if t_cont t_neg t_names t_fn n_rc n_orno n_presence n_positive n_polarity n_literal n_comment n_legacy n_ifok; do
    printf '%s' "$VHDR" >"$WORK/vac/test/$f.sh"
done
printf '%s' "$VHDR" >"$WORK/vac/scripts/build.sh"
cat >>"$WORK/vac/test/n_legacy.sh" <<'EOF'
OLD="$( "$BIN" --old 2>/dev/null )"
printf '%s' "$OLD" | grep -q 'stale' && no "stale present" || ok "stale absent"
EOF
cat >"$WORK/vac/test/t_names.sh" <<'EOF'
#!/usr/bin/env bash
BIN="${1:?}"
status=0
report_pass(){ echo "PASS $*"; }
report_fail(){ echo "FAIL $*"; status=1; }
"$BIN" --version >/dev/null 2>&1 && report_pass "runs" || report_fail "does not run"
EOF
cat >>"$WORK/vac/test/t_fn.sh" <<'EOF'
absent(){
    local out
    out="$( "$BIN" --version 2>&1 )" || { no "version failed"; return; }
    printf '%s' "$out" | grep -q "$1" && no "$1 present" || ok "$1 absent"
}
absent zzz
EOF
fx_commit vac
cat >>"$WORK/vac/test/t_var.sh" <<'EOF'
OUT="$( "$BIN" --list 2>/dev/null )"
printf '%s' "$OUT" | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
cat >>"$WORK/vac/test/t_pipe.sh" <<'EOF'
"$BIN" --list 2>/dev/null | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
{ printf 'set -o pipefail\n'; cat <<'EOF'
"$BIN" --list 2>/dev/null | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
} >>"$WORK/vac/test/t_pipefail.sh"
cat >>"$WORK/vac/test/t_if.sh" <<'EOF'
OUT2="$( "$BIN" --list 2>/dev/null )"
if printf '%s' "$OUT2" | grep -q 'bad'; then
    no "bad present"
else
    ok "bad absent"
fi
EOF
cat >>"$WORK/vac/test/t_cont.sh" <<'EOF'
MAP="$( "$BIN" --map 2>/dev/null )"
printf '%s' "$MAP" | grep -q 'suspect=' \
    && no "(f) a clean file carries suspect=" \
    || ok "(f) no suspect= on the clean file"
EOF
cat >>"$WORK/vac/test/t_neg.sh" <<'EOF'
NOUT="$( "$BIN" --list 2>/dev/null )"
! printf '%s' "$NOUT" | grep -q 'bad' && ok "bad absent" || no "bad present"
EOF
cat >>"$WORK/vac/test/t_names.sh" <<'EOF'
R="$( "$BIN" --list 2>/dev/null )"
echo "$R" | grep -q 'bad' && report_fail "bad present" || report_pass "bad absent"
EOF
cat >>"$WORK/vac/test/t_fn.sh" <<'EOF'
absent_unchecked(){
    local out
    out="$( "$BIN" --list 2>/dev/null )"
    printf '%s' "$out" | grep -q "$1" && no "$1 present" || ok "$1 absent"
}
absent_unchecked yyy
EOF
{ printf '%s' "$VHDR"; cat <<'EOF'
FRESH="$( "$BIN" --list 2>/dev/null )"
printf '%s' "$FRESH" | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
} >"$WORK/vac/test/t_new.sh"
cat >>"$WORK/vac/test/n_rc.sh" <<'EOF'
OUT="$( "$BIN" --list 2>/dev/null )"; RC=$?
[ "$RC" = 0 ] || no "the list run failed (rc=$RC)"
printf '%s' "$OUT" | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
cat >>"$WORK/vac/test/n_orno.sh" <<'EOF'
OUT="$( "$BIN" --list 2>/dev/null )" || no "the list run failed"
printf '%s' "$OUT" | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
cat >>"$WORK/vac/test/n_presence.sh" <<'EOF'
OUT="$( "$BIN" --list 2>/dev/null )"
[ -n "$OUT" ] || no "the list run printed nothing"
printf '%s' "$OUT" | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
cat >>"$WORK/vac/test/n_positive.sh" <<'EOF'
OUT="$( "$BIN" --list 2>/dev/null )"
printf '%s' "$OUT" | grep -q '<list ' && ok "the list root is there" || no "no list root"
printf '%s' "$OUT" | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
cat >>"$WORK/vac/test/n_polarity.sh" <<'EOF'
OUT="$( "$BIN" --list 2>/dev/null )"
printf '%s' "$OUT" | grep -q 'good' && ok "good present" || no "good missing"
EOF
cat >>"$WORK/vac/test/n_literal.sh" <<'EOF'
X="fixed text"
printf '%s' "$X" | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
cat >>"$WORK/vac/test/n_comment.sh" <<'EOF'
# OUT="$( "$BIN" --list 2>/dev/null )"
# printf '%s' "$OUT" | grep -q 'bad' && no "bad present" || ok "bad absent"
echo done
EOF
cat >>"$WORK/vac/test/n_legacy.sh" <<'EOF'
echo "an unrelated line after the pre-existing assertion"
EOF
cat >>"$WORK/vac/test/n_ifok.sh" <<'EOF'
OUT="$( "$BIN" --list 2>/dev/null )"; RC=$?
if [ "$RC" = 0 ] && ! printf '%s' "$OUT" | grep -q 'bad'; then ok "bad absent"; else no "bad present or the run failed (rc=$RC)"; fi
EOF
cat >>"$WORK/vac/scripts/build.sh" <<'EOF'
OUT="$( "$BIN" --list 2>/dev/null )"
printf '%s' "$OUT" | grep -q 'bad' && no "bad present" || ok "bad absent"
EOF
fx_run vac
L="vacuous-assert (bash)"
for f in t_var t_pipe t_pipefail t_if t_cont t_neg t_names; do
    ds_has_p "$L" vacuous-assert "test/$f.sh" minor
done
ds_has   "$L" vacuous-assert absent_unchecked new-symbol
ds_has_p "$L" vacuous-assert test/t_new.sh new-symbol
ds_none  "$L" absent "the capture's failure is handled (|| { no; return; }) — and the function is untouched"
ds_none_p "$L" test/n_rc.sh       "the capture's rc is checked before the absence"
ds_none_p "$L" test/n_orno.sh     "|| no on the capture"
ds_none_p "$L" test/n_presence.sh "a presence check before the absence"
ds_none_p "$L" test/n_positive.sh "a positive assertion on the same output first"
ds_none_p "$L" test/n_polarity.sh "a match is the PASS branch: a crash fails"
ds_none_p "$L" test/n_literal.sh  "the producer is a literal, not a command"
ds_none_p "$L" test/n_comment.sh  "a commented-out shape is not code"
ds_none_p "$L" test/n_legacy.sh   "a vacuous line the change did not introduce"
ds_none_p "$L" test/n_ifok.sh     "the if checks the rc in its condition"
ds_none_p "$L" scripts/build.sh   "not a test-script path: the kind is scoped to gate scripts"
gating_split "$L" 0

# ── 5) SURFACES: legend, JSON twin, MCP, and the ack identity of a facet ─────────────────────────────────
L="surfaces"
LEG="$( cd "$WORK/fmt_cpp" && "$BIN" . --quality-delta --no-cache --legend=full 2>/dev/null )"
if printf '%s' "$LEG" | grep -q '<quality-delta '; then
    miss=""
    for w in defect-shape format-arity utf8-cut dedup-first vacuous-assert; do
        printf '%s' "$LEG" | grep -q -- "$w" || miss="$miss $w"
    done
    if [ -z "$miss" ]; then ok "$L: the full legend names defect-shape and its four facets"; else no "$L: the full legend does not name:$miss"; fi
    if printf '%s' "$LEG" | grep -q 'ELEVEN KINDS'; then no "$L: the legend still says ELEVEN KINDS (stale count)"; else ok "$L: the legend's kind count is not the stale ELEVEN"; fi
else
    no "$L: the --legend=full delta run produced no <quality-delta root"
fi
if command -v python3 >/dev/null 2>&1; then
    JS="$( cd "$WORK/fmt_cpp" && "$BIN" . --quality-delta --no-cache --json 2>/dev/null )"
    JV="$( printf '%s' "$JS" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception as e: print("BROKEN %s" % e); raise SystemExit
rows = [r for r in d.get("r", []) if r.get("kind") == "defect-shape" and r.get("defect") == "format-arity"]
print("ROWS %d" % len(rows))' )"
    case "$JV" in ROWS\ *) n="${JV#ROWS }"; [ "$n" -ge 10 ] && ok "$L: --json carries the $n format-arity rows (kind + defect keys)" \
                                                      || no "$L: --json carries $n format-arity rows, want >= 10" ;;
                  *) no "$L: --json probe: $JV" ;; esac
    MC="$( printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"quality_delta","arguments":{"path":"'"$WORK/fmt_cpp"'"}}}' \
        | "$BIN" --mcp 2>/dev/null | tail -1 )"
    MV="$( printf '%s' "$MC" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
    t = r["result"]["content"][0]["text"]
    d = json.loads(t)
except Exception as e: print("BROKEN %s" % e); raise SystemExit
rows = [x for x in d.get("r", []) if x.get("kind") == "defect-shape" and x.get("defect") == "format-arity"]
print("ROWS %d" % len(rows))' )"
    case "$MV" in ROWS\ *) n="${MV#ROWS }"; [ "$n" -ge 10 ] && ok "$L: MCP quality_delta carries the $n format-arity rows" \
                                                      || no "$L: MCP quality_delta carries $n format-arity rows, want >= 10" ;;
                  *) no "$L: MCP quality_delta probe: $MV" ;; esac
else
    echo "  SKIP  $L: --json and MCP row checks (python3 not installed)"
fi

#   Ack identity (checklist 16): one symbol with BOTH a format-arity and a utf8-cut row. Acking only the
#   format-arity facet must leave the utf8-cut row on the same symbol standing — a facet is part of the
#   finding's identity, not a label on one shared per-symbol key.
fx_init both
mkdir -p "$WORK/both/src"
cat >"$WORK/both/src/b.cpp" <<'EOF'
#include <format>
#include <string>
std::string label( std::string s, int a ) { return std::format( "{}", a ) + s; }
int drive() { return 0; }
EOF
fx_commit both
cat >"$WORK/both/src/b.cpp" <<'EOF'
#include <format>
#include <string>
std::string label( std::string s, int a )
{
    if( s.size() > 50 )
    {
        s.resize( 50 );
        s += "...";
    }
    return std::format( "{}", a, a ) + s;
}
int drive() { return 1; }
EOF
fx_run both
ds_has "$L ack" format-arity label gating
ds_has "$L ack" utf8-cut     label minor
( cd "$WORK/both" && "$BIN" . --quality-delta --no-cache --ack-only=format-arity --quality-ack="deliberate in this fixture" >/dev/null 2>&1 )
ARC=$?
if [ "$ARC" = 0 ]; then ok "$L ack: --ack-only=format-arity selects the facet (exit 0)"; else no "$L ack: --ack-only=format-arity exited $ARC"; fi
fx_run both
if [ "$QD_OK" = 1 ]; then
    if [ -z "$( ds_row format-arity label )" ]; then ok "$L ack: the acked format-arity row is suppressed"; else no "$L ack: the format-arity row survived its ack: $( ds_row format-arity label )"; fi
fi
ds_has "$L ack" utf8-cut label minor
if [ "$QD_RC" = 0 ]; then ok "$L ack: with format-arity acked the run exits 0"; else no "$L ack: should exit 0 after the ack (got $QD_RC)"; fi

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES ABOVE"
exit $fail
