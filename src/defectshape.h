#pragma once

// defectshape.h — the scanners behind --quality-delta's defect-shape kind: four shapes of a REAL defect that
// review keeps finding by hand and that a deterministic syntactic check finds at write time.
//
//   format-arity    C++: a literal std::format / format_to / format_to_n / print / println, fmt::format /
//                   format_to / format_to_n / print / println, rw::emitTo / rw::formatTo format string whose
//                   replacement fields do not match its arguments. Python: a "literal".format( ... ).
//                   std::format_string rejects too FEW arguments at compile time and accepts too MANY
//                   silently; Python raises on too few at run time and ignores too many.
//   utf8-cut        C++: a byte cap on display text — a cut (resize / erase / substr( 0, N )) plus an appended
//                   ellipsis on the same string, the cut length being the bound of a size comparison on that
//                   string or a cap-named constant — or an ellipsis appended once a single-char push loop
//                   reaches a size cap, with no UTF-8 boundary back-off anywhere in the function.
//   dedup-first     C++: std::unique / std::ranges::unique with a lambda predicate over a type that carries a
//                   severity-like field (a bounded name token sev / severity / priority / prio), where neither
//                   the predicate nor a sort before it in the function reads that field: the FIRST row of a
//                   run survives, not the most severe.
//   vacuous-assert  Bash test scripts: an ABSENCE assertion (grep -q PAT whose match is the failure branch)
//                   read off a command whose failure is never checked, so a crash reads as PASS.
//
// Each scanner returns SITES: a facet, the byte the offending text starts at (the caller anchors it on the
// innermost enclosing definition, or on the file), and the offending text NORMALIZED (comments dropped,
// whitespace runs collapsed). The normalized text is the site's identity across a change: --quality-delta
// reports a site only when its text is not among the baseline's sites of that facet, so an untouched, moved
// or renamed defect is not new, and an edited one is.
//
// PRECISION BEFORE RECALL. Every test below answers "not this shape" when it cannot decide — a format held in
// a named constant or a macro, a pack expansion, a named predicate, a producer this file never assigns — and
// each of those is a stated miss, never a finding. The legend names the floors.

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "infra/Diagnostics.h"

namespace rw::defectshape
{

enum class Facet : std::uint8_t
{
    FormatArity   = 0,
    Utf8Cut       = 1,
    DedupFirst    = 2,
    VacuousAssert = 3,
};
inline constexpr std::size_t kFacetCount = 4;
inline constexpr std::array<std::string_view, kFacetCount> kFacetNames = { "format-arity", "utf8-cut", "dedup-first", "vacuous-assert" };

inline constexpr std::string_view facetName( Facet f ) noexcept
{
    return kFacetNames[ static_cast<std::size_t>( f ) ];
}

// The one facet whose rows gate, on ANY origin: a placeholder/argument mismatch on a literal format has no
// legitimate intent (an argument the format never prints is dropped output; a field with no argument is a
// compile error or a run-time exception), so it is a defect, not debt. The other three are report-only.
inline constexpr bool facetGatesOnAnyOrigin( Facet f ) noexcept
{
    return f == Facet::FormatArity;
}

struct Site
{
    Facet         facet     = Facet::FormatArity;
    std::uint32_t startByte = 0;
    std::string   text;
};

// A definition's byte span [begin, end) in the scanned file — the function bodies the per-function rules
// (utf8-cut, dedup-first) and the Bash scopes (vacuous-assert) read.
struct Span
{
    std::uint32_t begin = 0;
    std::uint32_t end   = 0;
};

namespace detail
{

inline bool isIdentStart( char c ) noexcept
{
    const unsigned char u = static_cast<unsigned char>( c );
    return ( c >= 'a' && c <= 'z' ) || ( c >= 'A' && c <= 'Z' ) || c == '_' || u >= 0x80;
}

inline bool isIdentChar( char c ) noexcept
{
    return isIdentStart( c ) || ( c >= '0' && c <= '9' );
}

inline bool isDigit( char c ) noexcept
{
    return c >= '0' && c <= '9';
}

inline bool isSpace( char c ) noexcept
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

enum class TokKind : std::uint8_t
{
    Ident,
    Number,
    String,
    Char,
    Punct,
};

// One token of a C-family or Python source: [begin, end) in the file. A String token spans its prefix and
// quotes; contentBegin/contentEnd are the bytes between the quotes (between the raw delimiters for a C++ raw
// string, between the triple quotes for a Python long string).
struct Tok
{
    TokKind       kind         = TokKind::Punct;
    std::uint32_t begin        = 0;
    std::uint32_t end          = 0;
    std::uint32_t contentBegin = 0;
    std::uint32_t contentEnd   = 0;
};

inline std::string_view tokText( std::string_view src, const Tok& t ) noexcept
{
    return src.substr( t.begin, t.end - t.begin );
}

inline std::string_view tokContent( std::string_view src, const Tok& t ) noexcept
{
    return src.substr( t.contentBegin, t.contentEnd - t.contentBegin );
}

inline bool tokIs( std::string_view src, const Tok& t, std::string_view s ) noexcept
{
    return tokText( src, t ) == s;
}

// The longest punctuator at `i` from a small fixed table (longest first), else one byte.
inline std::uint32_t punctLen( std::string_view s, std::size_t i ) noexcept
{
    static constexpr std::array<std::string_view, 27> kPunct = {
        "<<=", ">>=", "<=>", "->*", "...", "::", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "**", ":=",
    };
    for( std::string_view p : kPunct )
    {
        if( s.substr( i, p.size() ) == p )
        {
            return static_cast<std::uint32_t>( p.size() );
        }
    }
    return 1;
}

// Skip a quoted run starting at the opening quote s[i]; returns the index one past the closing quote (or the
// end of the line for an unterminated literal). Backslash escapes the next byte.
inline std::size_t skipQuoted( std::string_view s, std::size_t i, char q ) noexcept
{
    std::size_t j = i + 1;
    while( j < s.size() && s[j] != q && s[j] != '\n' )
    {
        j += ( s[j] == '\\' && j + 1 < s.size() ) ? 2 : 1;
    }
    return ( j < s.size() && s[j] == q ) ? j + 1 : j;
}

// C++ tokens with comments and preprocessor directives dropped. A directive is skipped whole (continuation
// lines included): a format inside a macro body is never judged — its arguments are whatever the expansion
// site passes.
inline std::vector<Tok> lexCpp( std::string_view s )
{
    std::vector<Tok> out;
    std::size_t      i         = 0;
    bool             lineStart = true;
    while( i < s.size() )
    {
        const char c = s[i];
        if( c == '\n' )
        {
            lineStart = true;
            ++i;
            continue;
        }
        if( isSpace( c ) )
        {
            ++i;
            continue;
        }
        if( c == '/' && i + 1 < s.size() && s[i + 1] == '/' )
        {
            while( i < s.size() && s[i] != '\n' )
            {
                ++i;
            }
            continue;
        }
        if( c == '/' && i + 1 < s.size() && s[i + 1] == '*' )
        {
            const std::size_t e = s.find( "*/", i + 2 );
            i                   = ( e == std::string_view::npos ) ? s.size() : e + 2;
            continue;
        }
        if( c == '#' && lineStart )
        {
            while( i < s.size() && s[i] != '\n' )
            {
                i += ( s[i] == '\\' && i + 1 < s.size() ) ? 2 : 1;
            }
            continue;
        }
        lineStart = false;
        const std::uint32_t b = static_cast<std::uint32_t>( i );
        if( isIdentStart( c ) )
        {
            std::size_t j = i;
            while( j < s.size() && isIdentChar( s[j] ) )
            {
                ++j;
            }
            const std::string_view word = s.substr( i, j - i );
            const bool isStrPrefix = word == "L" || word == "u" || word == "U" || word == "u8" || word == "R" || word == "LR" || word == "uR"
                                  || word == "UR" || word == "u8R";
            if( isStrPrefix && j < s.size() && s[j] == '"' )
            {
                if( word.back() == 'R' )
                {
                    const std::size_t open = s.find( '(', j + 1 );
                    if( open != std::string_view::npos && open - j - 1 <= 16 )
                    {
                        const std::string close = ")" + std::string( s.substr( j + 1, open - j - 1 ) ) + "\"";
                        const std::size_t e     = s.find( close, open + 1 );
                        const std::size_t endAt = ( e == std::string_view::npos ) ? s.size() : e + close.size();
                        const std::size_t cEnd  = ( e == std::string_view::npos ) ? s.size() : e;
                        out.push_back( { TokKind::String, b, static_cast<std::uint32_t>( endAt ), static_cast<std::uint32_t>( open + 1 ), static_cast<std::uint32_t>( cEnd ) } );
                        i = endAt;
                        continue;
                    }
                }
                const std::size_t e = skipQuoted( s, j, '"' );
                out.push_back( { TokKind::String, b, static_cast<std::uint32_t>( e ), static_cast<std::uint32_t>( j + 1 ), static_cast<std::uint32_t>( e > j + 1 ? e - 1 : j + 1 ) } );
                i = e;
                continue;
            }
            if( isStrPrefix && word.back() != 'R' && j < s.size() && s[j] == '\'' )
            {
                const std::size_t e = skipQuoted( s, j, '\'' );
                out.push_back( { TokKind::Char, b, static_cast<std::uint32_t>( e ), b, static_cast<std::uint32_t>( e ) } );
                i = e;
                continue;
            }
            out.push_back( { TokKind::Ident, b, static_cast<std::uint32_t>( j ), b, static_cast<std::uint32_t>( j ) } );
            i = j;
            continue;
        }
        if( isDigit( c ) || ( c == '.' && i + 1 < s.size() && isDigit( s[i + 1] ) ) )
        {
            std::size_t j = i + 1;
            while( j < s.size() && ( isIdentChar( s[j] ) || s[j] == '.' || s[j] == '\''
                                     || ( ( s[j] == '+' || s[j] == '-' ) && ( s[j - 1] == 'e' || s[j - 1] == 'E' || s[j - 1] == 'p' || s[j - 1] == 'P' ) ) ) )
            {
                ++j;
            }
            out.push_back( { TokKind::Number, b, static_cast<std::uint32_t>( j ), b, static_cast<std::uint32_t>( j ) } );
            i = j;
            continue;
        }
        if( c == '"' )
        {
            const std::size_t e = skipQuoted( s, i, '"' );
            out.push_back( { TokKind::String, b, static_cast<std::uint32_t>( e ), b + 1, static_cast<std::uint32_t>( e > i + 1 ? e - 1 : i + 1 ) } );
            i = e;
            continue;
        }
        if( c == '\'' )
        {
            const std::size_t e = skipQuoted( s, i, '\'' );
            out.push_back( { TokKind::Char, b, static_cast<std::uint32_t>( e ), b, static_cast<std::uint32_t>( e ) } );
            i = e;
            continue;
        }
        const std::uint32_t n = punctLen( s, i );
        out.push_back( { TokKind::Punct, b, b + n, b, b + n } );
        i += n;
    }
    return out;
}

// Python tokens with comments dropped (newlines are not tokens: an implicit concat inside parentheses spans
// lines, and the shapes read here never need statement boundaries).
inline std::vector<Tok> lexPython( std::string_view s )
{
    std::vector<Tok> out;
    std::size_t      i = 0;
    const auto       isPrefixChar = []( char c ) { return c == 'r' || c == 'R' || c == 'b' || c == 'B' || c == 'u' || c == 'U' || c == 'f' || c == 'F'; };
    while( i < s.size() )
    {
        const char c = s[i];
        if( isSpace( c ) || c == '\\' )
        {
            ++i;
            continue;
        }
        if( c == '#' )
        {
            while( i < s.size() && s[i] != '\n' )
            {
                ++i;
            }
            continue;
        }
        const std::uint32_t b = static_cast<std::uint32_t>( i );
        std::size_t         q = i;
        while( q < s.size() && q - i < 2 && isPrefixChar( s[q] ) )
        {
            ++q;
        }
        if( q < s.size() && ( s[q] == '"' || s[q] == '\'' ) && ( q == i || !isIdentChar( i > 0 ? s[i - 1] : ' ' ) ) )
        {
            const char  quote  = s[q];
            const bool  triple = s.substr( q, 3 ) == std::string( 3, quote );
            std::size_t j      = q + ( triple ? 3 : 1 );
            const std::size_t cb = j;
            while( j < s.size() )
            {
                if( s[j] == '\\' )
                {
                    j += 2;
                    continue;
                }
                if( triple ? s.substr( j, 3 ) == std::string( 3, quote ) : s[j] == quote )
                {
                    break;
                }
                if( !triple && s[j] == '\n' )
                {
                    break;
                }
                ++j;
            }
            const std::size_t ce  = std::min( j, s.size() );
            const std::size_t end = std::min( s.size(), j + ( j < s.size() && s[j] != '\n' ? ( triple ? 3 : 1 ) : 0 ) );
            out.push_back( { TokKind::String, b, static_cast<std::uint32_t>( end ), static_cast<std::uint32_t>( cb ), static_cast<std::uint32_t>( ce ) } );
            i = end;
            continue;
        }
        if( isIdentStart( c ) )
        {
            std::size_t j = i;
            while( j < s.size() && isIdentChar( s[j] ) )
            {
                ++j;
            }
            out.push_back( { TokKind::Ident, b, static_cast<std::uint32_t>( j ), b, static_cast<std::uint32_t>( j ) } );
            i = j;
            continue;
        }
        if( isDigit( c ) )
        {
            std::size_t j = i + 1;
            while( j < s.size() && ( isIdentChar( s[j] ) || s[j] == '.' ) )
            {
                ++j;
            }
            out.push_back( { TokKind::Number, b, static_cast<std::uint32_t>( j ), b, static_cast<std::uint32_t>( j ) } );
            i = j;
            continue;
        }
        const std::uint32_t n = punctLen( s, i );
        out.push_back( { TokKind::Punct, b, b + n, b, b + n } );
        i += n;
    }
    return out;
}

// The tokens [from, to] joined by single spaces: a site's identity text, immune to reformatting.
inline std::string joinTokens( std::string_view src, const std::vector<Tok>& toks, std::size_t from, std::size_t to )
{
    std::string out;
    for( std::size_t k = from; k <= to && k < toks.size(); ++k )
    {
        if( !out.empty() )
        {
            out.push_back( ' ' );
        }
        out.append( tokText( src, toks[k] ) );
    }
    return out;
}

// The index of the bracket that closes the one at `open` (round, square or curly; the others nest inside),
// or toks.size() when unbalanced.
inline std::size_t matchClose( std::string_view src, const std::vector<Tok>& toks, std::size_t open ) noexcept
{
    int depth = 0;
    for( std::size_t k = open; k < toks.size(); ++k )
    {
        if( toks[k].kind != TokKind::Punct )
        {
            continue;
        }
        const char c = src[ toks[k].begin ];
        if( toks[k].end - toks[k].begin != 1 )
        {
            continue;
        }
        if( c == '(' || c == '[' || c == '{' )
        {
            ++depth;
        }
        else if( c == ')' || c == ']' || c == '}' )
        {
            --depth;
            if( depth == 0 )
            {
                return k;
            }
            if( depth < 0 )
            {
                return toks.size();
            }
        }
    }
    return toks.size();
}

// A call's arguments: token index ranges [first, last] between the parentheses at `open` and `close`, split at
// top-level commas. An empty argument (a trailing comma) is kept as first > last.
struct ArgRange
{
    std::size_t first = 0;
    std::size_t last  = 0;
    bool        empty() const noexcept { return first > last; }
};

inline std::vector<ArgRange> splitArgs( std::string_view src, const std::vector<Tok>& toks, std::size_t open, std::size_t close )
{
    std::vector<ArgRange> out;
    if( close == open + 1 )
    {
        return out;
    }
    int         depth = 0;
    std::size_t start = open + 1;
    for( std::size_t k = open + 1; k < close; ++k )
    {
        if( toks[k].kind != TokKind::Punct || toks[k].end - toks[k].begin != 1 )
        {
            continue;
        }
        const char c = src[ toks[k].begin ];
        if( c == '(' || c == '[' || c == '{' )
        {
            ++depth;
        }
        else if( c == ')' || c == ']' || c == '}' )
        {
            --depth;
        }
        else if( c == ',' && depth == 0 )
        {
            out.push_back( { start, k - 1 } );
            start = k + 1;
        }
    }
    out.push_back( { start, close - 1 } );
    return out;
}

// ─── replacement-field grammars ─────────────────────────────────────────────────────────────────────────

// What a format string asks of its argument list. ok=false: the string is not one this check can judge
// (mixed automatic and manual numbering, a lone brace, a named field where the family has none) — skipped.
struct FieldUse
{
    bool                       ok         = false;
    std::uint32_t              autoFields = 0;
    std::vector<std::uint32_t> indices;   // manual positional indices, one per use
    std::vector<std::string>   names;     // Python named fields
};

// The arg-id at s[i..]: digits → a manual index, an identifier → a name, empty → automatic. Advances i.
// Returns false on anything else.
inline bool readArgId( std::string_view s, std::size_t& i, FieldUse& use, bool allowNames, bool pythonFieldName )
{
    const std::size_t b = i;
    if( i < s.size() && isDigit( s[i] ) )
    {
        std::uint32_t v = 0;
        while( i < s.size() && isDigit( s[i] ) )
        {
            if( v > 100000 )
            {
                return false;   // not a real argument index — refuse rather than wrap
            }
            v = v * 10 + static_cast<std::uint32_t>( s[i] - '0' );
            ++i;
        }
        use.indices.push_back( v );
    }
    else if( i < s.size() && isIdentStart( s[i] ) )
    {
        if( !allowNames )
        {
            return false;
        }
        while( i < s.size() && isIdentChar( s[i] ) )
        {
            ++i;
        }
        use.names.emplace_back( s.substr( b, i - b ) );
    }
    else
    {
        ++use.autoFields;
    }
    if( pythonFieldName )
    {
        // attribute / index accessors after the arg name: .attr and [key], neither consumes an argument
        while( i < s.size() && ( s[i] == '.' || s[i] == '[' ) )
        {
            if( s[i] == '[' )
            {
                const std::size_t e = s.find( ']', i );
                if( e == std::string_view::npos )
                {
                    return false;
                }
                i = e + 1;
            }
            else
            {
                ++i;
                while( i < s.size() && isIdentChar( s[i] ) )
                {
                    ++i;
                }
            }
        }
    }
    return true;
}

// The std::format / fmt / Python str.format replacement-field grammar, over the literal's content as written
// (escape sequences do not produce braces, except Python's \N{...}, which is skipped). `python` selects the
// Python field-name and conversion syntax.
inline FieldUse parseFields( std::string_view s, bool python )
{
    FieldUse use;
    std::size_t i = 0;
    while( i < s.size() )
    {
        const char c = s[i];
        if( python && c == '\\' && i + 1 < s.size() && s[i + 1] == 'N' && i + 2 < s.size() && s[i + 2] == '{' )
        {
            const std::size_t e = s.find( '}', i + 3 );
            if( e == std::string_view::npos )
            {
                return use;
            }
            i = e + 1;
            continue;
        }
        if( c == '}' )
        {
            if( i + 1 < s.size() && s[i + 1] == '}' )
            {
                i += 2;
                continue;
            }
            return use;   // a lone '}' — not a format this check can judge
        }
        if( c != '{' )
        {
            ++i;
            continue;
        }
        if( i + 1 < s.size() && s[i + 1] == '{' )
        {
            i += 2;
            continue;
        }
        ++i;
        if( !readArgId( s, i, use, python, python ) )
        {
            return use;
        }
        if( python && i < s.size() && s[i] == '!' )
        {
            i += 2;   // !r / !s / !a
        }
        if( i < s.size() && s[i] == ':' )
        {
            ++i;
            // the spec: nested replacement fields (dynamic width / precision) each consume an argument
            while( i < s.size() && s[i] != '}' )
            {
                if( s[i] == '{' )
                {
                    ++i;
                    if( !readArgId( s, i, use, python, python ) || i >= s.size() || s[i] != '}' )
                    {
                        return use;
                    }
                }
                ++i;
            }
        }
        if( i >= s.size() || s[i] != '}' )
        {
            return use;
        }
        ++i;
    }
    use.ok = !( use.autoFields > 0 && !use.indices.empty() );   // mixed numbering is an error this check does not judge
    return use;
}

// True when `use` against `positional` arguments (and, for Python, the keyword names `kw`) is a mismatch.
inline bool fieldsMismatch( const FieldUse& use, std::uint32_t positional, const std::vector<std::string>& kw )
{
    bool bad = false;
    if( !use.indices.empty() )
    {
        std::vector<char> seen( positional, 0 );
        for( std::uint32_t ix : use.indices )
        {
            if( ix >= positional )
            {
                bad = true;   // a field with no argument
            }
            else
            {
                seen[ix] = 1;
            }
        }
        bad = bad || std::find( seen.begin(), seen.end(), char( 0 ) ) != seen.end();   // an argument no field prints
    }
    else
    {
        bad = use.autoFields != positional;
    }
    for( const std::string& n : use.names )
    {
        bad = bad || std::find( kw.begin(), kw.end(), n ) == kw.end();
    }
    for( const std::string& k : kw )
    {
        bad = bad || std::find( use.names.begin(), use.names.end(), k ) == use.names.end();
    }
    return bad;
}

// ─── format-arity, C++ ──────────────────────────────────────────────────────────────────────────────────

// The format family: (namespace, name) → the index the format argument sits at, and whether a leading
// stdout / stderr argument shifts it (the print overloads that take a FILE*). A leading std::locale(...)
// argument shifts every family by one. Nothing else moves the index: a non-literal at that position is
// skipped, never searched past (the literal there may be an ARGUMENT, as in std::format( kFmt, "{}" )).
struct FormatFamily
{
    std::string_view ns;
    std::string_view name;
    std::uint8_t     fmtIndex;
    bool             streamShift;
};
inline constexpr std::array<FormatFamily, 12> kFormatFamilies = { {
    { "std", "format", 0, false },      { "std", "format_to", 1, false }, { "std", "format_to_n", 2, false },
    { "std", "print", 0, true },        { "std", "println", 0, true },    { "fmt", "format", 0, false },
    { "fmt", "format_to", 1, false },   { "fmt", "format_to_n", 2, false }, { "fmt", "print", 0, true },
    { "fmt", "println", 0, true },      { "rw", "emitTo", 1, false },     { "rw", "formatTo", 2, false },
} };

inline const FormatFamily* formatFamilyAt( std::string_view src, const std::vector<Tok>& toks, std::size_t k ) noexcept
{
    if( k < 2 || toks[k].kind != TokKind::Ident || !tokIs( src, toks[k - 1], "::" ) || toks[k - 2].kind != TokKind::Ident )
    {
        return nullptr;
    }
    if( k >= 3 && ( tokIs( src, toks[k - 3], "." ) || tokIs( src, toks[k - 3], "->" ) ) )
    {
        return nullptr;
    }
    const std::string_view ns   = tokText( src, toks[k - 2] );
    const std::string_view name = tokText( src, toks[k] );
    for( const FormatFamily& f : kFormatFamilies )
    {
        if( f.ns == ns && f.name == name )
        {
            return &f;
        }
    }
    return nullptr;
}

inline bool isAllCapsIdent( std::string_view w ) noexcept
{
    if( w.size() < 2 || !( w[0] >= 'A' && w[0] <= 'Z' ) )
    {
        return false;
    }
    return std::all_of( w.begin(), w.end(), []( char c ) { return ( c >= 'A' && c <= 'Z' ) || isDigit( c ) || c == '_'; } );
}

// An argument whose count is unknowable here: a pack expansion, __VA_ARGS__, an all-caps identifier alone (an
// object-like macro may expand to a comma list), or more '<' than '>' (a template argument list the comma split
// may have cut: std::pair<int, int>{} splits as "std::pair<int" and "int>{}"). A lone '>' is a comparison
// (n > 0) and does not make the count unknowable.
inline bool argCountUnknowable( std::string_view src, const std::vector<Tok>& toks, const ArgRange& a ) noexcept
{
    if( a.empty() )
    {
        return true;
    }
    if( tokIs( src, toks[a.last], "..." ) )
    {
        return true;
    }
    if( a.first == a.last && toks[a.first].kind == TokKind::Ident && isAllCapsIdent( tokText( src, toks[a.first] ) ) )
    {
        return true;
    }
    int angle = 0;
    for( std::size_t k = a.first; k <= a.last; ++k )
    {
        if( tokIs( src, toks[k], "__VA_ARGS__" ) )
        {
            return true;
        }
        angle += tokIs( src, toks[k], "<" ) ? 1 : 0;
        angle -= tokIs( src, toks[k], ">" ) ? 1 : 0;
    }
    return angle > 0;
}

// The argument's tokens are one or more adjacent string literals → their concatenated content; else empty
// optional-by-flag (a named constant, a macro piece such as PRIu64, a runtime_format wrapper).
inline bool literalContent( std::string_view src, const std::vector<Tok>& toks, const ArgRange& a, std::string& out )
{
    out.clear();
    if( a.empty() )
    {
        return false;
    }
    for( std::size_t k = a.first; k <= a.last; ++k )
    {
        if( toks[k].kind != TokKind::String )
        {
            return false;
        }
        out.append( tokContent( src, toks[k] ) );
    }
    return true;
}

inline void scanFormatArityCpp( std::string_view src, const std::vector<Tok>& toks, std::vector<Site>& out )
{
    std::string fmt;
    for( std::size_t k = 2; k + 1 < toks.size(); ++k )
    {
        const FormatFamily* fam = formatFamilyAt( src, toks, k );
        if( fam == nullptr || !tokIs( src, toks[k + 1], "(" ) )
        {
            continue;
        }
        const std::size_t close = matchClose( src, toks, k + 1 );
        if( close >= toks.size() )
        {
            continue;
        }
        const std::vector<ArgRange> args = splitArgs( src, toks, k + 1, close );
        std::size_t                 fi   = fam->fmtIndex;
        if( fi < args.size() && fam->streamShift && args[fi].first == args[fi].last
            && ( tokIs( src, toks[ args[fi].first ], "stdout" ) || tokIs( src, toks[ args[fi].first ], "stderr" ) ) )
        {
            ++fi;
        }
        if( fi < args.size() && !args[fi].empty() && args[fi].first + 3 <= args[fi].last && tokIs( src, toks[ args[fi].first ], "std" )
            && tokIs( src, toks[ args[fi].first + 1 ], "::" ) && tokIs( src, toks[ args[fi].first + 2 ], "locale" ) )
        {
            ++fi;
        }
        if( fi >= args.size() || !literalContent( src, toks, args[fi], fmt ) )
        {
            continue;
        }
        bool unknowable = false;
        for( std::size_t a = fi + 1; a < args.size(); ++a )
        {
            unknowable = unknowable || argCountUnknowable( src, toks, args[a] );
        }
        const FieldUse use = parseFields( fmt, false );
        if( unknowable || !use.ok )
        {
            continue;
        }
        const std::uint32_t positional = static_cast<std::uint32_t>( args.size() - fi - 1 );
        if( fieldsMismatch( use, positional, {} ) )
        {
            out.push_back( { Facet::FormatArity, toks[k - 2].begin, joinTokens( src, toks, k - 2, close ) } );
        }
    }
}

// ─── format-arity, Python "literal".format( ... ) ───────────────────────────────────────────────────────

inline bool pyStringPrefixOk( std::string_view src, const Tok& t ) noexcept
{
    for( std::uint32_t p = t.begin; p < t.contentBegin; ++p )
    {
        const char c = src[p];
        if( c == 'f' || c == 'F' || c == 'b' || c == 'B' )
        {
            return false;   // an f-string has no argument list; bytes have no .format
        }
    }
    return true;
}

// A keyword before '(' makes the parentheses a grouping (return ( "a" "b" ).format(…)), not a call.
inline bool isPythonKeyword( std::string_view w ) noexcept
{
    static constexpr std::array<std::string_view, 15> kKw = { "return", "yield", "in", "not", "and", "or", "if", "else", "elif", "while", "assert",
                                                              "await", "lambda", "is", "for" };
    return std::find( kKw.begin(), kKw.end(), w ) != kKw.end();
}

inline void scanFormatArityPython( std::string_view src, const std::vector<Tok>& toks, std::vector<Site>& out )
{
    std::string fmt;
    for( std::size_t k = 1; k + 2 < toks.size(); ++k )
    {
        if( !tokIs( src, toks[k], "." ) || !tokIs( src, toks[k + 1], "format" ) || !tokIs( src, toks[k + 2], "(" ) )
        {
            continue;
        }
        // the receiver: adjacent literals right before the dot, or a parenthesised group holding only literals
        std::size_t firstLit = k;
        std::size_t lastLit  = k - 1;
        std::size_t siteFrom = k;
        if( toks[k - 1].kind == TokKind::String )
        {
            firstLit = k - 1;
            while( firstLit > 0 && toks[firstLit - 1].kind == TokKind::String )
            {
                --firstLit;
            }
            siteFrom = firstLit;
        }
        else if( tokIs( src, toks[k - 1], ")" ) )
        {
            std::size_t open = k - 1;
            while( open > 0 && toks[open - 1].kind == TokKind::String )
            {
                --open;
            }
            if( open == 0 || !tokIs( src, toks[open - 1], "(" ) || open > k - 2 )
            {
                continue;
            }
            const std::size_t paren = open - 1;
            if( paren > 0 && ( ( toks[paren - 1].kind == TokKind::Ident && !isPythonKeyword( tokText( src, toks[paren - 1] ) ) )
                               || tokIs( src, toks[paren - 1], ")" ) || tokIs( src, toks[paren - 1], "]" ) ) )
            {
                continue;   // a call's parentheses, not a grouping
            }
            firstLit = open;
            lastLit  = k - 2;
            siteFrom = paren;
        }
        if( firstLit > lastLit )
        {
            continue;
        }
        fmt.clear();
        bool prefixOk = true;
        for( std::size_t p = firstLit; p <= lastLit; ++p )
        {
            prefixOk = prefixOk && pyStringPrefixOk( src, toks[p] );
            fmt.append( tokContent( src, toks[p] ) );
        }
        const std::size_t close = matchClose( src, toks, k + 2 );
        if( !prefixOk || close >= toks.size() )
        {
            continue;
        }
        std::vector<ArgRange> args = splitArgs( src, toks, k + 2, close );
        if( !args.empty() && args.back().empty() )
        {
            args.pop_back();   // a trailing comma
        }
        std::uint32_t            positional = 0;
        std::vector<std::string> kw;
        bool                     unknowable = false;
        for( const ArgRange& a : args )
        {
            if( a.empty() || tokIs( src, toks[a.first], "*" ) || tokIs( src, toks[a.first], "**" ) )
            {
                unknowable = true;
                break;
            }
            if( a.first < a.last && toks[a.first].kind == TokKind::Ident && tokIs( src, toks[a.first + 1], "=" ) )
            {
                kw.emplace_back( tokText( src, toks[a.first] ) );
            }
            else
            {
                ++positional;
            }
        }
        const FieldUse use = parseFields( fmt, true );
        if( unknowable || !use.ok )
        {
            continue;
        }
        if( fieldsMismatch( use, positional, kw ) )
        {
            out.push_back( { Facet::FormatArity, toks[siteFrom].begin, joinTokens( src, toks, siteFrom, close ) } );
        }
    }
}

// ─── utf8-cut, C++ ──────────────────────────────────────────────────────────────────────────────────────

// An ellipsis literal: an ordinary or u8 literal whose content, spaces trimmed, is "..." or U+2026 (written
// raw or as \xE2\x80\xA6). A wide / u16 / u32 literal holds code units or points: a cut cannot split one.
inline bool isEllipsisLiteral( std::string_view src, const Tok& t ) noexcept
{
    if( t.kind != TokKind::String )
    {
        return false;
    }
    const std::string_view pre = src.substr( t.begin, t.contentBegin - t.begin );
    if( pre != "\"" && pre != "u8\"" )
    {
        return false;
    }
    std::string_view c = tokContent( src, t );
    while( !c.empty() && c.front() == ' ' )
    {
        c.remove_prefix( 1 );
    }
    while( !c.empty() && c.back() == ' ' )
    {
        c.remove_suffix( 1 );
    }
    return c == "..." || c == "\xE2\x80\xA6" || c == "\\xE2\\x80\\xA6" || c == "\\xe2\\x80\\xa6" || c == "\\u2026";
}

// A UTF-8 boundary back-off or a utf8-aware helper anywhere in the function exempts it (a precision choice:
// the guard is not proven to cover the cut): the 0xC0 / 0x80 continuation mask, or a call whose name has a
// utf8 token.
inline bool hasUtf8Guard( std::string_view src, const std::vector<Tok>& toks, std::size_t from, std::size_t to ) noexcept
{
    bool c0 = false;
    bool c80 = false;
    for( std::size_t k = from; k < to; ++k )
    {
        const std::string_view w = tokText( src, toks[k] );
        if( toks[k].kind == TokKind::Number )
        {
            c0  = c0 || w == "0xC0" || w == "0xc0" || w == "0xC0u" || w == "0xc0u" || w == "0xC0U";
            c80 = c80 || w == "0x80" || w == "0x80u" || w == "0x80U";
        }
        if( toks[k].kind == TokKind::Ident && ( w.find( "utf8" ) != std::string_view::npos || w.find( "Utf8" ) != std::string_view::npos
                                                || w.find( "UTF8" ) != std::string_view::npos ) )
        {
            return true;
        }
    }
    return c0 && c80;
}

// V . size ( ) / V . length ( ) at k: the receiver name, or empty.
inline std::string_view sizeCallReceiver( std::string_view src, const std::vector<Tok>& toks, std::size_t k ) noexcept
{
    if( k + 4 < toks.size() && toks[k].kind == TokKind::Ident && tokIs( src, toks[k + 1], "." )
        && ( tokIs( src, toks[k + 2], "size" ) || tokIs( src, toks[k + 2], "length" ) ) && tokIs( src, toks[k + 3], "(" ) && tokIs( src, toks[k + 4], ")" ) )
    {
        return tokText( src, toks[k] );
    }
    return {};
}

inline bool isCompareOp( std::string_view src, const Tok& t ) noexcept
{
    const std::string_view w = tokText( src, t );
    return w == ">" || w == ">=" || w == "<" || w == "<=" || w == "==";
}

// Name tokens of an identifier (camelCase and snake_case boundaries), lower-cased.
inline std::vector<std::string> nameTokens( std::string_view w )
{
    std::vector<std::string> out;
    std::string              cur;
    for( std::size_t i = 0; i < w.size(); ++i )
    {
        const char c = w[i];
        if( c == '_' || isDigit( c ) )
        {
            if( !cur.empty() )
            {
                out.push_back( cur );
                cur.clear();
            }
            continue;
        }
        const bool upper = c >= 'A' && c <= 'Z';
        if( upper && !cur.empty() && !( i > 0 && w[i - 1] >= 'A' && w[i - 1] <= 'Z' ) )
        {
            out.push_back( cur );
            cur.clear();
        }
        cur.push_back( upper ? static_cast<char>( c - 'A' + 'a' ) : c );
    }
    if( !cur.empty() )
    {
        out.push_back( cur );
    }
    return out;
}

inline bool isCapName( std::string_view w )
{
    for( const std::string& t : nameTokens( w ) )
    {
        if( t == "cap" || t == "max" || t == "limit" || t == "budget" )
        {
            return true;
        }
    }
    return false;
}

// Is the length text `n` (the tokens of a cut's length argument) the bound of a size comparison on `v`
// within [from, to), or a single cap-named identifier?
inline bool lengthIsSizeBound( std::string_view src, const std::vector<Tok>& toks, std::size_t from, std::size_t to, std::string_view v,
                               const std::string& n )
{
    for( std::size_t k = from; k < to; ++k )
    {
        if( sizeCallReceiver( src, toks, k ) != v )
        {
            continue;
        }
        // V.size() OP M / M OP V.size(), where the cut length N is M, or M less the ellipsis width (1 to 3 bytes:
        // resize( 117 ) under size() > 120 leaves room for "...")
        const auto boundMatches = [ & ]( const Tok& m )
        {
            const std::string_view mt = tokText( src, m );
            if( mt == n || n == std::string( mt ) + " - 1" || n == std::string( mt ) + " - 2" || n == std::string( mt ) + " - 3" )
            {
                return true;
            }
            if( m.kind != TokKind::Number || n.empty() || !std::all_of( n.begin(), n.end(), isDigit ) || n.size() > 9
                || !std::all_of( mt.begin(), mt.end(), isDigit ) || mt.size() > 9 )
            {
                return false;
            }
            const long nv = std::stol( n );
            const long mv = std::stol( std::string( mt ) );
            return mv >= nv && mv - nv <= 3;
        };
        if( k + 6 < to && isCompareOp( src, toks[k + 5] ) && boundMatches( toks[k + 6] ) )
        {
            return true;
        }
        if( k >= 2 && isCompareOp( src, toks[k - 1] ) && boundMatches( toks[k - 2] ) )
        {
            return true;
        }
    }
    return n.find( ' ' ) == std::string::npos && isCapName( n );
}

// Does `V += ELL` / `V.append( ELL )` occur in [from, to)? Returns the index of the statement's first token,
// or `to`.
inline std::size_t ellipsisAppendOn( std::string_view src, const std::vector<Tok>& toks, std::size_t from, std::size_t to, std::string_view v ) noexcept
{
    for( std::size_t k = from; k + 2 < to; ++k )
    {
        if( toks[k].kind != TokKind::Ident || tokText( src, toks[k] ) != v || ( k > 0 && ( tokIs( src, toks[k - 1], "." ) || tokIs( src, toks[k - 1], "->" ) ) ) )
        {
            continue;
        }
        if( tokIs( src, toks[k + 1], "+=" ) && isEllipsisLiteral( src, toks[k + 2] ) )
        {
            return k;
        }
        if( k + 4 < to && tokIs( src, toks[k + 1], "." ) && tokIs( src, toks[k + 2], "append" ) && tokIs( src, toks[k + 3], "(" ) && isEllipsisLiteral( src, toks[k + 4] ) )
        {
            return k;
        }
    }
    return to;
}

// The single-argument text of the call whose '(' is at `open`, or empty when it has more than one argument.
inline std::string singleArgText( std::string_view src, const std::vector<Tok>& toks, std::size_t open )
{
    const std::size_t close = matchClose( src, toks, open );
    if( close >= toks.size() )
    {
        return {};
    }
    const std::vector<ArgRange> args = splitArgs( src, toks, open, close );
    if( args.size() != 1 || args[0].empty() )
    {
        return {};
    }
    return joinTokens( src, toks, args[0].first, args[0].last );
}

// substr( 0 , N ) at the '(' `open`: N's text, or empty.
inline std::string substrZeroLength( std::string_view src, const std::vector<Tok>& toks, std::size_t open )
{
    const std::size_t close = matchClose( src, toks, open );
    if( close >= toks.size() )
    {
        return {};
    }
    const std::vector<ArgRange> args = splitArgs( src, toks, open, close );
    if( args.size() != 2 || args[0].empty() || args[1].empty() || args[0].first != args[0].last || !tokIs( src, toks[ args[0].first ], "0" ) )
    {
        return {};
    }
    return joinTokens( src, toks, args[1].first, args[1].last );
}

inline void scanUtf8CutFunction( std::string_view src, const std::vector<Tok>& toks, std::size_t from, std::size_t to, std::vector<Site>& out )
{
    if( hasUtf8Guard( src, toks, from, to ) )
    {
        return;
    }
    for( std::size_t k = from; k + 3 < to; ++k )
    {
        if( toks[k].kind != TokKind::Ident || !tokIs( src, toks[k + 1], "." ) || ( k > 0 && ( tokIs( src, toks[k - 1], "." ) || tokIs( src, toks[k - 1], "->" ) ) ) )
        {
            continue;
        }
        const std::string_view v      = tokText( src, toks[k] );
        const std::string_view method = tokText( src, toks[k + 2] );
        if( !tokIs( src, toks[k + 3], "(" ) )
        {
            continue;
        }
        const std::size_t close = matchClose( src, toks, k + 3 );
        if( close >= to )
        {
            continue;
        }
        // (1) V.resize( N ) / V.erase( N ), then V += ELL / V.append( ELL ) later in the function
        if( method == "resize" || method == "erase" )
        {
            const std::string n = singleArgText( src, toks, k + 3 );
            if( n.empty() || !lengthIsSizeBound( src, toks, from, to, v, n ) )
            {
                continue;
            }
            const std::size_t ell = ellipsisAppendOn( src, toks, close + 1, to, v );
            if( ell < to )
            {
                const std::size_t ellEnd = std::min( to - 1, ell + 2 + ( tokIs( src, toks[ell + 1], "." ) ? 3 : 0 ) );
                out.push_back( { Facet::Utf8Cut, toks[ell].begin, joinTokens( src, toks, k, close ) + " ; " + joinTokens( src, toks, ell, ellEnd ) } );
            }
            continue;
        }
        if( method != "substr" )
        {
            continue;
        }
        // (2) V.substr( 0, N ) + ELL, as an expression
        const std::string n = substrZeroLength( src, toks, k + 3 );
        if( n.empty() || !lengthIsSizeBound( src, toks, from, to, v, n ) )
        {
            continue;
        }
        if( close + 2 < to && tokIs( src, toks[close + 1], "+" ) && isEllipsisLiteral( src, toks[close + 2] ) )
        {
            out.push_back( { Facet::Utf8Cut, toks[k].begin, joinTokens( src, toks, k, close + 2 ) } );
            continue;
        }
        // (3) W = V.substr( 0, N ) (or a declaration of W), then W += ELL later
        if( k >= 2 && tokIs( src, toks[k - 1], "=" ) && toks[k - 2].kind == TokKind::Ident )
        {
            const std::string_view w   = tokText( src, toks[k - 2] );
            const std::size_t      ell = ellipsisAppendOn( src, toks, close + 1, to, w );
            if( ell < to )
            {
                const std::size_t ellEnd = std::min( to - 1, ell + 2 + ( tokIs( src, toks[ell + 1], "." ) ? 3 : 0 ) );
                out.push_back( { Facet::Utf8Cut, toks[ell].begin, joinTokens( src, toks, k - 2, close ) + " ; " + joinTokens( src, toks, ell, ellEnd ) } );
            }
        }
    }
    // (4) a single-char push loop: V.push_back( c ) somewhere, and `if( V.size() OP CAP ) { … V += ELL … }`
    for( std::size_t k = from; k + 2 < to; ++k )
    {
        if( !tokIs( src, toks[k], "if" ) || !tokIs( src, toks[k + 1], "(" ) )
        {
            continue;
        }
        const std::string_view v = sizeCallReceiver( src, toks, k + 2 );
        if( v.empty() || k + 7 >= to || !isCompareOp( src, toks[k + 7] ) )
        {
            continue;
        }
        const std::size_t condClose = matchClose( src, toks, k + 1 );
        if( condClose + 1 >= to || !tokIs( src, toks[condClose + 1], "{" ) )
        {
            continue;
        }
        const std::size_t blockClose = matchClose( src, toks, condClose + 1 );
        const std::size_t ell        = ellipsisAppendOn( src, toks, condClose + 2, std::min( blockClose, to ), v );
        if( blockClose >= to || ell >= blockClose )
        {
            continue;
        }
        bool pushes = false;
        for( std::size_t p = from; p + 3 < to && !pushes; ++p )
        {
            pushes = tokText( src, toks[p] ) == v && tokIs( src, toks[p + 1], "." ) && tokIs( src, toks[p + 2], "push_back" ) && tokIs( src, toks[p + 3], "(" );
        }
        if( pushes )
        {
            const std::size_t ellEnd = std::min( to - 1, ell + 2 + ( tokIs( src, toks[ell + 1], "." ) ? 3 : 0 ) );
            out.push_back( { Facet::Utf8Cut, toks[ell].begin, joinTokens( src, toks, k, condClose ) + " { " + joinTokens( src, toks, ell, ellEnd ) } );
        }
    }
}

// ─── dedup-first, C++ ───────────────────────────────────────────────────────────────────────────────────

inline bool isSeverityName( std::string_view field )
{
    for( const std::string& t : nameTokens( field ) )
    {
        if( t == "sev" || t == "severity" || t == "priority" || t == "prio" )
        {
            return true;
        }
    }
    return false;
}

// The member fields named in `struct T { … }` / `class T { … }` bodies in this file: the severity-like ones.
// A member is an identifier followed by '=', ';', '{' or '[' at the body's top level.
inline std::vector<std::string> severityFieldsOf( std::string_view src, const std::vector<Tok>& toks, std::string_view type )
{
    std::vector<std::string> out;
    for( std::size_t k = 0; k + 2 < toks.size(); ++k )
    {
        if( !( tokIs( src, toks[k], "struct" ) || tokIs( src, toks[k], "class" ) ) || tokText( src, toks[k + 1] ) != type )
        {
            continue;
        }
        std::size_t open = k + 2;
        while( open < toks.size() && !tokIs( src, toks[open], "{" ) && !tokIs( src, toks[open], ";" ) )
        {
            ++open;
        }
        if( open >= toks.size() || !tokIs( src, toks[open], "{" ) )
        {
            continue;
        }
        const std::size_t close = matchClose( src, toks, open );
        int               depth = 0;
        for( std::size_t m = open + 1; m + 1 < close && close < toks.size(); ++m )
        {
            if( tokIs( src, toks[m], "{" ) || tokIs( src, toks[m], "(" ) )
            {
                ++depth;
            }
            else if( tokIs( src, toks[m], "}" ) || tokIs( src, toks[m], ")" ) )
            {
                --depth;
            }
            else if( depth == 0 && toks[m].kind == TokKind::Ident
                     && ( tokIs( src, toks[m + 1], "=" ) || tokIs( src, toks[m + 1], ";" ) || tokIs( src, toks[m + 1], "{" ) || tokIs( src, toks[m + 1], "[" ) )
                     && isSeverityName( tokText( src, toks[m] ) ) )
            {
                out.emplace_back( tokText( src, toks[m] ) );
            }
        }
    }
    return out;
}

// Does any `. FIELD` / `-> FIELD` for a field in `fields` occur in [from, to]?
inline bool readsAnyField( std::string_view src, const std::vector<Tok>& toks, std::size_t from, std::size_t to, const std::vector<std::string>& fields )
{
    for( std::size_t k = from + 1; k <= to && k < toks.size(); ++k )
    {
        if( ( tokIs( src, toks[k - 1], "." ) || tokIs( src, toks[k - 1], "->" ) )
            && std::find( fields.begin(), fields.end(), tokText( src, toks[k] ) ) != fields.end() )
        {
            return true;
        }
    }
    return false;
}

// The element type of a lambda `[ … ]( const T& a, … )` starting at `lb`: T, or empty (auto, a builtin, not a
// lambda). Returns the index of the lambda's closing '}' in `bodyEnd`.
inline std::string_view lambdaElementType( std::string_view src, const std::vector<Tok>& toks, std::size_t lb, std::size_t& bodyEnd )
{
    bodyEnd = toks.size();
    if( lb >= toks.size() || !tokIs( src, toks[lb], "[" ) )
    {
        return {};
    }
    const std::size_t capClose = matchClose( src, toks, lb );
    if( capClose + 1 >= toks.size() || !tokIs( src, toks[capClose + 1], "(" ) )
    {
        return {};
    }
    const std::size_t parClose = matchClose( src, toks, capClose + 1 );
    std::size_t       body     = parClose + 1;
    while( body < toks.size() && !tokIs( src, toks[body], "{" ) && !tokIs( src, toks[body], ";" ) && !tokIs( src, toks[body], ")" ) )
    {
        ++body;
    }
    if( body >= toks.size() || !tokIs( src, toks[body], "{" ) )
    {
        return {};
    }
    bodyEnd = matchClose( src, toks, body );
    // the first parameter: the identifier right before '&' / '*' / the parameter name
    std::string_view type;
    for( std::size_t k = capClose + 2; k < parClose && !tokIs( src, toks[k], "," ); ++k )
    {
        if( toks[k].kind != TokKind::Ident )
        {
            continue;
        }
        const std::string_view w = tokText( src, toks[k] );
        if( w == "const" || w == "volatile" || w == "std" || w == "struct" )
        {
            continue;
        }
        if( type.empty() )
        {
            type = w;
        }
        else if( k + 1 < parClose && tokIs( src, toks[k - 1], "::" ) )
        {
            type = w;   // a qualified type: keep its last segment
        }
    }
    if( type == "auto" || type == "int" || type == "long" || type == "unsigned" || type == "char" || type == "double" || type == "float" || type == "bool"
        || type == "size_t" )
    {
        return {};
    }
    return type;
}

inline void scanDedupFirstFunction( std::string_view src, const std::vector<Tok>& toks, std::size_t from, std::size_t to, std::vector<Site>& out )
{
    for( std::size_t k = from + 2; k + 1 < to; ++k )
    {
        if( !tokIs( src, toks[k], "unique" ) || !tokIs( src, toks[k - 1], "::" ) || !tokIs( src, toks[k + 1], "(" ) )
        {
            continue;
        }
        const bool ranges = tokIs( src, toks[k - 2], "ranges" );
        if( !ranges && !tokIs( src, toks[k - 2], "std" ) )
        {
            continue;
        }
        const std::size_t close = matchClose( src, toks, k + 1 );
        if( close >= to )
        {
            continue;
        }
        const std::vector<ArgRange> args   = splitArgs( src, toks, k + 1, close );
        const std::size_t           predAt = ranges ? ( args.size() == 2 ? 1 : 2 ) : 2;
        if( predAt >= args.size() || args[predAt].empty() )
        {
            continue;   // no predicate: whole values compare
        }
        std::size_t            lambdaEnd = 0;
        const std::string_view type      = lambdaElementType( src, toks, args[predAt].first, lambdaEnd );
        if( type.empty() || lambdaEnd > close )
        {
            continue;   // a named predicate, an auto / builtin element: skipped, never guessed
        }
        const std::vector<std::string> sev = severityFieldsOf( src, toks, type );
        if( sev.empty() || readsAnyField( src, toks, args[predAt].first, lambdaEnd, sev ) )
        {
            continue;
        }
        // a sort before the unique, in this function, whose arguments read the severity field (either direction)
        bool sorted = false;
        for( std::size_t s = from; s < k && !sorted; ++s )
        {
            const std::string_view w = tokText( src, toks[s] );
            if( ( w == "sort" || w == "stable_sort" ) && s + 1 < k && tokIs( src, toks[s + 1], "(" ) )
            {
                const std::size_t sc = matchClose( src, toks, s + 1 );
                sorted = sc < k && readsAnyField( src, toks, s + 1, sc, sev );
            }
        }
        if( !sorted )
        {
            out.push_back( { Facet::DedupFirst, toks[k - 2].begin, joinTokens( src, toks, k - ( ranges ? 4 : 2 ), close ) } );
        }
    }
}

// ─── vacuous-assert, Bash test scripts ──────────────────────────────────────────────────────────────────

// One logical line of a shell script: continuation lines joined, comments dropped, heredoc bodies and the
// tails of multi-line quotes removed (they are data, not code).
struct ShLine
{
    std::uint32_t startByte = 0;
    std::string   text;
};

inline std::vector<ShLine> shLogicalLines( std::string_view s )
{
    std::vector<ShLine>      out;
    std::vector<std::string> heredocEnds;     // pending terminators, in order
    bool                     heredocStrip = false;
    char                     openQuote    = 0; // a quote left open at the end of the previous physical line
    std::size_t              i            = 0;
    ShLine                   cur;
    bool                     haveCur = false;
    while( i < s.size() )
    {
        std::size_t e = s.find( '\n', i );
        if( e == std::string_view::npos )
        {
            e = s.size();
        }
        std::string_view phys = s.substr( i, e - i );
        const std::uint32_t physStart = static_cast<std::uint32_t>( i );
        i = e + 1;
        if( !heredocEnds.empty() )
        {
            std::string_view t = phys;
            while( heredocStrip && !t.empty() && t.front() == '\t' )
            {
                t.remove_prefix( 1 );
            }
            if( t == heredocEnds.front() )
            {
                heredocEnds.erase( heredocEnds.begin() );
            }
            continue;
        }
        // code bytes of this physical line: quotes tracked, comments dropped
        std::string code;
        std::size_t k = 0;
        if( openQuote != 0 )
        {
            const std::size_t close = phys.find( openQuote );
            if( close == std::string_view::npos )
            {
                continue;   // the whole line is inside a multi-line literal
            }
            k         = close + 1;
            openQuote = 0;
            code.append( "\"\"" );
        }
        char q = 0;
        for( ; k < phys.size(); ++k )
        {
            const char c = phys[k];
            if( q == 0 && c == '#' && ( k == 0 || isSpace( phys[k - 1] ) || phys[k - 1] == ';' ) )
            {
                break;
            }
            if( c == '\\' && q != '\'' && k + 1 < phys.size() )
            {
                code.push_back( c );
                code.push_back( phys[k + 1] );
                ++k;
                continue;
            }
            if( q == 0 && ( c == '\'' || c == '"' ) )
            {
                q = c;
            }
            else if( q == c )
            {
                q = 0;
            }
            code.push_back( c );
        }
        if( q != 0 )
        {
            openQuote = q;   // a literal that runs on: the rest of it is data
        }
        // heredoc operators on this line (not here-strings)
        for( std::size_t h = code.find( "<<" ); h != std::string::npos; h = code.find( "<<", h + 2 ) )
        {
            if( h + 2 < code.size() && code[h + 2] == '<' )
            {
                h += 1;
                continue;
            }
            std::size_t p = h + 2;
            const bool  strip = p < code.size() && code[p] == '-';
            p += strip ? 1 : 0;
            while( p < code.size() && code[p] == ' ' )
            {
                ++p;
            }
            std::string word;
            while( p < code.size() && !isSpace( code[p] ) && code[p] != ';' && code[p] != ')' && code[p] != '|' && code[p] != '&' && code[p] != '>' )
            {
                if( code[p] != '\'' && code[p] != '"' && code[p] != '\\' )
                {
                    word.push_back( code[p] );
                }
                ++p;
            }
            // a terminator is a word ( << 2 inside $(( )) is a shift, not a heredoc )
            if( !word.empty() && isIdentStart( word[0] ) && std::all_of( word.begin(), word.end(), []( char ch ) { return isIdentChar( ch ); } ) )
            {
                heredocEnds.push_back( word );
                heredocStrip = strip;
            }
        }
        const bool continues = !code.empty() && code.back() == '\\' && openQuote == 0;
        if( continues )
        {
            code.pop_back();
        }
        if( !haveCur )
        {
            cur     = ShLine{ physStart, {} };
            haveCur = true;
        }
        cur.text.append( code );
        if( continues && heredocEnds.empty() )
        {
            cur.text.push_back( ' ' );
            continue;
        }
        out.push_back( std::move( cur ) );
        cur     = ShLine{};
        haveCur = false;
    }
    if( haveCur )
    {
        out.push_back( std::move( cur ) );
    }
    return out;
}

// A shell word or operator, quote- and $( )-aware.
struct ShTok
{
    std::string text;
    bool        op = false;
};

inline std::vector<ShTok> shTokens( std::string_view l )
{
    std::vector<ShTok> out;
    std::size_t        i = 0;
    while( i < l.size() )
    {
        const char c = l[i];
        if( isSpace( c ) )
        {
            ++i;
            continue;
        }
        if( l.substr( i, 2 ) == "&&" || l.substr( i, 2 ) == "||" || l.substr( i, 2 ) == ";;" )
        {
            out.push_back( { std::string( l.substr( i, 2 ) ), true } );
            i += 2;
            continue;
        }
        if( c == '|' || c == ';' || c == '&' || ( c == '!' && ( i + 1 >= l.size() || isSpace( l[i + 1] ) ) ) )
        {
            out.push_back( { std::string( 1, c ), true } );
            ++i;
            continue;
        }
        std::string w;
        int         paren = 0;
        char        q     = 0;
        while( i < l.size() )
        {
            const char d = l[i];
            if( q == 0 && paren == 0 && ( isSpace( d ) || d == '|' || d == ';' || d == '&' ) )
            {
                break;
            }
            if( d == '\\' && q != '\'' && i + 1 < l.size() )
            {
                w.push_back( d );
                w.push_back( l[i + 1] );
                i += 2;
                continue;
            }
            // A "$( … )" capture's inner quotes are balanced, so plain toggling keeps the word whole; an UNQUOTED
            // $( … ) with spaces inside is held together by the paren depth.
            if( q == 0 && d == '$' && i + 1 < l.size() && l[i + 1] == '(' )
            {
                ++paren;
                w.append( "$(" );
                i += 2;
                continue;
            }
            if( q == 0 && paren > 0 && d == '(' )
            {
                ++paren;
            }
            else if( q == 0 && paren > 0 && d == ')' )
            {
                --paren;
            }
            else if( q == 0 && ( d == '\'' || d == '"' ) )
            {
                q = d;
            }
            else if( q != 0 && d == q )
            {
                q = 0;
            }
            w.push_back( d );
            ++i;
        }
        out.push_back( { std::move( w ), false } );
    }
    return out;
}

using ShLineToks = std::vector<std::vector<ShTok>>;   // every logical line's tokens, computed once per script

inline std::string_view unquoted( std::string_view w ) noexcept
{
    if( w.size() >= 2 && ( w.front() == '"' || w.front() == '\'' ) && w.back() == w.front() )
    {
        return w.substr( 1, w.size() - 2 );
    }
    return w;
}

// "$VAR" / "${VAR}" / $VAR → VAR, else empty.
inline std::string_view varRef( std::string_view w ) noexcept
{
    w = unquoted( w );
    if( w.size() < 2 || w[0] != '$' )
    {
        return {};
    }
    w.remove_prefix( 1 );
    if( !w.empty() && w.front() == '{' && w.back() == '}' )
    {
        w = w.substr( 1, w.size() - 2 );
    }
    if( w.empty() || !isIdentStart( w[0] ) )
    {
        return {};
    }
    for( char c : w )
    {
        if( !isIdentChar( c ) )
        {
            return {};
        }
    }
    return w;
}

enum class Reporter : std::uint8_t
{
    None,
    Pass,
    Fail,
};

// A reporter is named by its tokens (ok / pass vs no / fail …), or is an echo / printf of PASS / FAIL text,
// an exit / return with a nonzero status, or a fail-flag assignment.
inline Reporter reporterOf( const std::vector<ShTok>& t, std::size_t k, const std::vector<std::pair<std::string, Reporter>>& defined )
{
    while( k < t.size() && ( ( !t[k].op && ( t[k].text == "{" || t[k].text == "then" || t[k].text == "else" ) ) || ( t[k].op && t[k].text == ";" ) ) )
    {
        ++k;   // the branch's opening words and the line breaks (joined as ';') before its first command
    }
    if( k >= t.size() || t[k].op )
    {
        return Reporter::None;
    }
    const std::string& w = t[k].text;
    for( const auto& [ name, r ] : defined )
    {
        if( name == w && r != Reporter::None )
        {
            return r;
        }
    }
    if( w == "echo" || w == "printf" )
    {
        for( std::size_t a = k + 1; a < t.size() && !t[a].op; ++a )
        {
            std::string_view u = unquoted( t[a].text );
            while( !u.empty() && ( u.front() == ' ' || u.front() == '[' ) )
            {
                u.remove_prefix( 1 );
            }
            if( u.starts_with( "FAIL" ) )
            {
                return Reporter::Fail;
            }
            if( u.starts_with( "PASS" ) || u.starts_with( "ok " ) )
            {
                return Reporter::Pass;
            }
        }
        return Reporter::None;
    }
    if( ( w == "exit" || w == "return" ) && k + 1 < t.size() && !t[k + 1].op && t[k + 1].text != "0" )
    {
        return Reporter::Fail;
    }
    if( w.find( '=' ) != std::string::npos )
    {
        const std::string lhs = w.substr( 0, w.find( '=' ) );
        const std::string rhs = w.substr( w.find( '=' ) + 1 );
        for( const std::string& tk : nameTokens( lhs ) )
        {
            if( ( tk == "fail" || tk == "failed" || tk == "failures" || tk == "status" ) && rhs != "0" )
            {
                return Reporter::Fail;
            }
        }
        return Reporter::None;
    }
    for( const std::string& tk : nameTokens( w ) )
    {
        if( tk == "ok" || tk == "pass" || tk == "passed" || tk == "good" )
        {
            return Reporter::Pass;
        }
        if( tk == "no" || tk == "fail" || tk == "failed" || tk == "bad" || tk == "die" )
        {
            return Reporter::Fail;
        }
    }
    return Reporter::None;
}

// The grep -q assertion of one pipeline [b, e) of tokens: its producer and polarity.
struct GrepPipe
{
    bool             ok        = false;
    bool             negated   = false;   // a leading `!`
    bool             direct    = false;   // the producer is a command (not a variable's text)
    std::string      var;                 // the variable whose text is grepped, when not direct
};

inline bool isQuietGrep( const std::vector<ShTok>& t, std::size_t b, std::size_t e, std::size_t& operands )
{
    if( b >= e || t[b].op || t[b].text != "grep" )
    {
        return false;
    }
    bool quiet = false;
    operands   = 0;
    bool afterDashE = false;
    for( std::size_t k = b + 1; k < e; ++k )
    {
        const std::string& w = t[k].text;
        if( afterDashE )
        {
            ++operands;
            afterDashE = false;
            continue;
        }
        if( w == "--quiet" || w == "--silent" )
        {
            quiet = true;
        }
        else if( w == "-e" )
        {
            afterDashE = true;
        }
        else if( w.size() > 1 && w[0] == '-' && w[1] != '-' )
        {
            quiet = quiet || w.find( 'q' ) != std::string::npos;
        }
        else if( w == "--" )
        {
            continue;
        }
        else if( w.rfind( "<<<", 0 ) == 0 || w.rfind( "2>", 0 ) == 0 || w.rfind( ">", 0 ) == 0 )
        {
            continue;
        }
        else
        {
            ++operands;
        }
    }
    return quiet;
}

// Is the command at [b, e) a RUN UNDER TEST? Past `cd DIR &&`, environment assignments and the wrappers env /
// nice / timeout / command / exec / time / stdbuf, the command must be spelled through a variable ("$BIN")
// or a path. Not judged (stated floors): a text utility or builtin over a file — its input's provenance is
// not on this line — and a function the script defines, which may wrap a run or only read a variable.
inline bool isRunUnderTest( const std::vector<ShTok>& t, std::size_t b, std::size_t e )
{
    std::size_t k = b;
    while( k < e )
    {
        const std::string& w = t[k].text;
        if( !t[k].op && w == "cd" )
        {
            while( k < e && !( t[k].op && t[k].text == "&&" ) )
            {
                ++k;
            }
            ++k;
            continue;
        }
        if( !t[k].op && ( w == "env" || w == "nice" || w == "timeout" || w == "command" || w == "exec" || w == "time" || w == "stdbuf"
                          || ( !w.empty() && w[0] == '-' ) || ( !w.empty() && isDigit( w[0] ) )
                          || ( w.find( '=' ) != std::string::npos && w[0] != '$' && w[0] != '"' && w[0] != '\'' ) ) )
        {
            ++k;
            continue;
        }
        break;
    }
    if( k >= e || t[k].op )
    {
        return false;
    }
    const std::string_view head = unquoted( t[k].text );
    return !head.empty() && ( head.front() == '$' || head.find( '/' ) != std::string_view::npos );
}

inline GrepPipe grepPipe( const std::vector<ShTok>& t, std::size_t b, std::size_t e )
{
    GrepPipe g;
    while( b < e && !t[b].op && ( t[b].text == "{" || t[b].text == "(" ) )
    {
        ++b;   // a brace group or subshell around the pipe: { echo "$V" | grep -q P && … ; }
    }
    if( b < e && t[b].op && t[b].text == "!" )
    {
        g.negated = true;
        ++b;
    }
    // stage boundaries
    std::vector<std::size_t> stages{ b };
    for( std::size_t k = b; k < e; ++k )
    {
        if( t[k].op && t[k].text == "|" )
        {
            stages.push_back( k + 1 );
        }
    }
    const std::size_t last = stages.back();
    std::size_t       operands = 0;
    if( !isQuietGrep( t, last, e, operands ) )
    {
        return g;
    }
    if( stages.size() == 1 )
    {
        // grep -q PAT <<< "$V" reads a variable; grep -q PAT FILE reads a file (not this shape)
        for( std::size_t k = last + 1; k < e; ++k )
        {
            if( t[k].text == "<<<" && k + 1 < e )
            {
                g.var = std::string( varRef( t[k + 1].text ) );
            }
            else if( t[k].text.rfind( "<<<", 0 ) == 0 )
            {
                g.var = std::string( varRef( std::string_view( t[k].text ).substr( 3 ) ) );
            }
        }
        g.ok = !g.var.empty();
        return g;
    }
    if( operands > 1 )
    {
        return g;   // the last grep reads files, not the pipe
    }
    const std::size_t p0  = stages.front();
    const std::size_t p0e = stages[1] - 1;
    if( p0 >= p0e )
    {
        return g;
    }
    const std::string& cmd = t[p0].text;
    if( cmd == "printf" || cmd == "echo" )
    {
        // printf '%s' "$V" / echo "$V" — the text of one variable; anything else printed is not a run's output
        std::string_view v;
        std::size_t      vars = 0;
        for( std::size_t k = p0 + 1; k < p0e; ++k )
        {
            const std::string_view r = varRef( t[k].text );
            if( !r.empty() )
            {
                v = r;
                ++vars;
            }
            else if( t[k].text.find( "$(" ) != std::string::npos )
            {
                const std::vector<ShTok> inner = shTokens( std::string_view( t[k].text ).substr( t[k].text.find( "$(" ) + 2 ) );
                std::size_t              innerEnd = 0;
                while( innerEnd < inner.size() && !( inner[innerEnd].op && inner[innerEnd].text == "|" ) )
                {
                    ++innerEnd;
                }
                if( !isRunUnderTest( inner, 0, innerEnd ) )
                {
                    return g;   // printf "$( wrapper … )": not a run under test
                }
                g.direct = true;
            }
        }
        if( g.direct )
        {
            g.ok = true;
            return g;
        }
        if( vars != 1 )
        {
            return g;
        }
        g.var = std::string( v );
        g.ok  = true;
        return g;
    }
    if( !isRunUnderTest( t, p0, p0e ) )
    {
        return g;   // a direct pipe judges only a run under test
    }
    g.direct = true;
    g.ok     = true;
    return g;
}

// The shape of one list: `PIPE && R1 || R2`. Returns the grep pipe and the two reporters.
struct AndOr
{
    GrepPipe pipe;
    Reporter onTrue  = Reporter::None;
    Reporter onFalse = Reporter::None;
};

inline bool andOrShape( const std::vector<ShTok>& t, const std::vector<std::pair<std::string, Reporter>>& defined, AndOr& out )
{
    std::size_t andAt = t.size();
    std::size_t orAt  = t.size();
    for( std::size_t k = 0; k < t.size(); ++k )
    {
        if( t[k].op && t[k].text == "&&" && andAt == t.size() )
        {
            andAt = k;
        }
        else if( t[k].op && t[k].text == "||" && andAt != t.size() && orAt == t.size() )
        {
            orAt = k;
        }
        else if( t[k].op && ( t[k].text == ";" || t[k].text == ";;" ) && andAt == t.size() )
        {
            return false;
        }
    }
    if( andAt == t.size() || orAt == t.size() )
    {
        return false;
    }
    out.pipe    = grepPipe( t, 0, andAt );
    out.onTrue  = reporterOf( t, andAt + 1, defined );
    out.onFalse = reporterOf( t, orAt + 1, defined );
    return out.pipe.ok;
}

// Is a list an ABSENCE assertion (the grep matching is the failure branch)? Or a REQUIREMENT on the same
// text (a match is the pass branch, or no match is the failure branch)?
enum class Polarity : std::uint8_t
{
    None,
    Absence,
    Requirement,
};

inline Polarity polarityOf( bool negated, Reporter onMatch, Reporter onNoMatch ) noexcept
{
    if( negated )
    {
        std::swap( onMatch, onNoMatch );
    }
    if( onMatch == Reporter::Fail && onNoMatch == Reporter::Pass )
    {
        return Polarity::Absence;
    }
    if( onMatch == Reporter::Pass || onNoMatch == Reporter::Fail )
    {
        return Polarity::Requirement;
    }
    return Polarity::None;
}

// Every grep assertion in a script: the line, its pipe, its polarity.
struct ShAssert
{
    std::size_t line = 0;
    GrepPipe    pipe;
    Polarity    pol  = Polarity::None;
};

inline std::vector<ShAssert> shAssertions( const ShLineToks& lt, const std::vector<std::pair<std::string, Reporter>>& defined )
{
    std::vector<ShAssert> out;
    for( std::size_t li = 0; li < lt.size(); ++li )
    {
        const std::vector<ShTok>& t = lt[li];
        if( t.empty() )
        {
            continue;
        }
        // case arm: `pattern) LIST ;;` — read the list after the arm's ')'
        std::size_t from = 0;
        if( !t[0].op && t[0].text.size() > 1 && t[0].text.back() == ')' && t[0].text.find( "$(" ) == std::string::npos )
        {
            from = 1;
        }
        if( !t[from].op && ( t[from].text == "elif" || t[from].text == "while" ) )
        {
            continue;   // an elif / while condition is not judged (a stated floor)
        }
        if( !t[from].op && t[from].text == "if" )
        {
            std::size_t condEnd = from + 1;
            while( condEnd < t.size() && !( t[condEnd].op && ( t[condEnd].text == ";" || t[condEnd].text == "&&" || t[condEnd].text == "||" ) )
                   && !( !t[condEnd].op && t[condEnd].text == "then" ) )
            {
                ++condEnd;
            }
            const GrepPipe g = grepPipe( t, from + 1, condEnd );
            if( !g.ok || ( condEnd < t.size() && t[condEnd].op && ( t[condEnd].text == "&&" || t[condEnd].text == "||" ) ) )
            {
                continue;
            }
            // the whole if … fi, lines joined with ';': its top-level then / elif / else, nested ifs skipped
            std::vector<ShTok> st;
            for( std::size_t j = li; j < lt.size() && j < li + 80; ++j )
            {
                st.insert( st.end(), lt[j].begin(), lt[j].end() );
                st.push_back( { ";", true } );
            }
            std::size_t thenAt = st.size(), elseAt = st.size();
            bool        hasElif = false;
            int         depth   = 0;
            for( std::size_t k = 0; k < st.size(); ++k )
            {
                if( st[k].op )
                {
                    continue;
                }
                const std::string& w = st[k].text;
                if( w == "if" )
                {
                    ++depth;
                }
                else if( w == "fi" )
                {
                    if( --depth == 0 )
                    {
                        break;
                    }
                }
                else if( depth == 1 && w == "then" && thenAt == st.size() )
                {
                    thenAt = k;
                }
                else if( depth == 1 && w == "elif" )
                {
                    hasElif = true;
                }
                else if( depth == 1 && w == "else" )
                {
                    elseAt = k;
                }
            }
            if( thenAt == st.size() || hasElif )
            {
                continue;   // no then found, or an elif chain (its branches are not judged)
            }
            const Reporter onThen = reporterOf( st, thenAt + 1, defined );
            const Reporter onElse = elseAt < st.size() ? reporterOf( st, elseAt + 1, defined ) : Reporter::None;
            out.push_back( { li, g, polarityOf( g.negated, onThen, onElse ) } );
            continue;
        }
        std::vector<ShTok> list( t.begin() + static_cast<std::ptrdiff_t>( from ), t.end() );
        AndOr              ao;
        if( andOrShape( list, defined, ao ) )
        {
            out.push_back( { li, ao.pipe, polarityOf( ao.pipe.negated, ao.onTrue, ao.onFalse ) } );
            continue;
        }
        // `PIPE || R` / `PIPE && R` alone
        for( std::size_t k = 0; k < list.size(); ++k )
        {
            if( list[k].op && ( list[k].text == "||" || list[k].text == "&&" ) )
            {
                const GrepPipe g = grepPipe( list, 0, k );
                const Reporter r = reporterOf( list, k + 1, defined );
                if( g.ok && r != Reporter::None )
                {
                    const bool onMatch = list[k].text == "&&";
                    out.push_back( { li, g, polarityOf( g.negated, onMatch ? r : Reporter::None, onMatch ? Reporter::None : r ) } );
                }
                break;
            }
        }
    }
    return out;
}

// The innermost span (function) holding `byte`, or spans.size() for top-level code.
inline std::size_t scopeOf( const std::vector<Span>& spans, std::uint32_t byte ) noexcept
{
    std::size_t   best    = spans.size();
    std::uint32_t bestLen = UINT32_MAX;
    for( std::size_t k = 0; k < spans.size(); ++k )
    {
        if( byte >= spans[k].begin && byte < spans[k].end && spans[k].end - spans[k].begin < bestLen )
        {
            best    = k;
            bestLen = spans[k].end - spans[k].begin;
        }
    }
    return best;
}

// The assignment of `v` that reaches line `li` within its scope: the last such line before it, or npos.
inline std::size_t assignmentOf( const ShLineToks& lt, const std::vector<std::size_t>& scope, std::size_t li, std::string_view v )
{
    const std::string eq = std::string( v ) + "=";
    for( std::size_t k = li; k-- > 0; )
    {
        if( scope[k] != scope[li] )
        {
            continue;
        }
        const std::vector<ShTok>& t = lt[k];
        for( std::size_t w = 0; w < t.size(); ++w )
        {
            if( !t[w].op && t[w].text.rfind( eq, 0 ) == 0 )
            {
                return k;
            }
        }
    }
    return std::string::npos;
}

// Is the text of `v` required somewhere in the absence's scope: a presence test (-n / -z / ${#v}), a case on
// it, or a requirement assertion (a match is the pass branch, or no match the failure branch) on it?
inline bool contentRequired( const std::vector<ShLine>& lines, const ShLineToks& lt, const std::vector<std::size_t>& scope,
                             const std::vector<ShAssert>& asserts, std::size_t absenceLine, std::string_view v )
{
    const std::string q1 = "\"$" + std::string( v ) + "\"";
    const std::string q2 = "\"${" + std::string( v ) + "}\"";
    const std::string q3 = "$" + std::string( v );
    const std::string q4 = "${#" + std::string( v ) + "}";
    for( std::size_t k = 0; k < lines.size(); ++k )
    {
        if( scope[k] != scope[absenceLine] || k == absenceLine )
        {
            continue;
        }
        const std::string& l = lines[k].text;
        for( const char* test : { "-n ", "-z " } )
        {
            for( std::size_t p = l.find( test ); p != std::string::npos; p = l.find( test, p + 1 ) )
            {
                const std::string_view rest = std::string_view( l ).substr( p + 3 );
                if( rest.starts_with( q1 ) || rest.starts_with( q2 ) || ( rest.starts_with( q3 ) && ( rest.size() == q3.size() || !isIdentChar( rest[q3.size()] ) ) ) )
                {
                    return true;
                }
            }
        }
        if( l.find( q4 ) != std::string::npos )
        {
            return true;
        }
        const std::vector<ShTok>& ct = lt[k];
        if( ct.size() >= 3 && ct[0].text == "case" && varRef( ct[1].text ) == v )
        {
            return true;
        }
    }
    for( const ShAssert& a : asserts )
    {
        if( a.line != absenceLine && scope[a.line] == scope[absenceLine] && a.pol == Polarity::Requirement && !a.pipe.direct && a.pipe.var == v )
        {
            return true;
        }
    }
    return false;
}

// Is the variable's capture guarded — its failure checked or its content required somewhere in scope?
inline bool captureGuarded( const std::vector<ShLine>& lines, const ShLineToks& lt, const std::vector<std::size_t>& scope,
                            const std::vector<ShAssert>& asserts, std::size_t absenceLine, std::size_t assignLine, std::string_view v, bool errexit )
{
    const std::string eq = std::string( v ) + "=";
    const std::vector<ShTok>& t = lt[assignLine];
    bool        plainAssign = false;
    std::size_t at          = t.size();
    for( std::size_t w = 0; w < t.size(); ++w )
    {
        if( !t[w].op && t[w].text.rfind( eq, 0 ) == 0 )
        {
            at          = w;
            plainAssign = w == 0 || ( t[w - 1].op ) || t[w - 1].text == "if" || t[w - 1].text == "elif" || t[w - 1].text == "while";
            break;
        }
    }
    // if ! V="$( … )"; then / while V=… — the rc decides a branch
    if( at > 0 && at < t.size() && ( t[at - 1].text == "if" || t[at - 1].text == "elif" || t[at - 1].text == "while" || ( t[at - 1].op && t[at - 1].text == "!" ) ) )
    {
        return true;
    }
    // V="$( … )" || … / && … on the capture, or an rc read right after it on the same line
    for( std::size_t w = at + 1; w < t.size(); ++w )
    {
        if( t[w].op && ( t[w].text == "||" || t[w].text == "&&" ) )
        {
            return true;
        }
        if( t[w].text.find( "$?" ) != std::string::npos || t[w].text.find( "PIPESTATUS" ) != std::string::npos )
        {
            return true;
        }
    }
    // the next line in scope reads $? / PIPESTATUS
    for( std::size_t k = assignLine + 1; k < lines.size(); ++k )
    {
        if( scope[k] != scope[assignLine] )
        {
            continue;
        }
        if( lines[k].text.find( "$?" ) != std::string::npos || lines[k].text.find( "PIPESTATUS" ) != std::string::npos )
        {
            return true;
        }
        break;
    }
    // errexit aborts the script on a plain capture's failure (local / declare / export mask the rc)
    if( errexit && plainAssign )
    {
        return true;
    }
    // a presence test, a case on the text, or a requirement on the text anywhere in scope — on the variable
    // itself or on one DERIVED from it (W="$( printf '%s' "$V" | … )" then a check on W): a check that W is
    // non-empty or carries a pattern is a check that V had content.
    if( contentRequired( lines, lt, scope, asserts, absenceLine, v ) )
    {
        return true;
    }
    const std::string ref1 = "\"$" + std::string( v ) + "\"";
    for( std::size_t k = 0; k < lines.size(); ++k )
    {
        if( scope[k] != scope[absenceLine] || k == absenceLine || lt[k].empty() || lt[k][0].op )
        {
            continue;
        }
        const std::string& w0 = lt[k][0].text;
        const std::size_t  eqAt = w0.find( '=' );
        if( eqAt == std::string::npos || eqAt == 0 || w0.find( "$(" ) == std::string::npos )
        {
            continue;
        }
        const std::string_view rhs = std::string_view( w0 ).substr( eqAt + 1 );
        const std::size_t      cap = rhs.find( "$(" );
        const std::string_view in  = rhs.substr( cap + 2 );
        std::size_t            b   = 0;
        while( b < in.size() && isSpace( in[b] ) )
        {
            ++b;
        }
        if( ( in.substr( b ).starts_with( "printf" ) || in.substr( b ).starts_with( "echo" ) ) && in.find( ref1 ) != std::string_view::npos )
        {
            const std::string w = w0.substr( 0, eqAt );
            if( w != v && contentRequired( lines, lt, scope, asserts, absenceLine, w ) )
            {
                return true;
            }
        }
    }
    return false;
}

// Does the absence's own line read an rc ($?, or a variable named like rc / status) — `if [ "$RC" = 0 ] && ! …`?
inline bool lineReadsRc( std::string_view l )
{
    if( l.find( "$?" ) != std::string_view::npos || l.find( "PIPESTATUS" ) != std::string_view::npos )
    {
        return true;
    }
    for( std::size_t p = l.find( '$' ); p != std::string_view::npos; p = l.find( '$', p + 1 ) )
    {
        std::size_t q = p + 1;
        if( q < l.size() && l[q] == '{' )
        {
            ++q;
        }
        std::size_t e = q;
        while( e < l.size() && isIdentChar( l[e] ) )
        {
            ++e;
        }
        for( const std::string& tk : nameTokens( l.substr( q, e - q ) ) )
        {
            if( tk == "rc" || tk == "status" || tk == "ret" || tk == "exit" )
            {
                return true;
            }
        }
    }
    return false;
}

// Script-defined reporter functions, classified by name tokens, else by body signal (prints FAIL / sets a
// failure flag → fail; prints PASS → pass).
inline std::vector<std::pair<std::string, Reporter>> shDefinedReporters( std::string_view src, const std::vector<ShLine>& lines, const ShLineToks& lt,
                                                                         const std::vector<Span>& spans )
{
    std::vector<std::pair<std::string, Reporter>> out;
    for( std::size_t li = 0; li < lines.size(); ++li )
    {
        const ShLine&             l = lines[li];
        const std::vector<ShTok>& t = lt[li];
        if( t.empty() || t[0].op )
        {
            continue;
        }
        std::string name;
        if( t[0].text == "function" && t.size() > 1 )
        {
            name = t[1].text;
        }
        else if( t[0].text.size() > 2 && t[0].text.find( "()" ) != std::string::npos && t[0].text.find( '$' ) == std::string::npos )
        {
            name = t[0].text.substr( 0, t[0].text.find( "()" ) );
        }
        else if( t.size() > 1 && t[1].text.rfind( "()", 0 ) == 0 )
        {
            name = t[0].text;
        }
        while( !name.empty() && name.back() == '(' )
        {
            name.pop_back();
        }
        if( name.empty() || !std::all_of( name.begin(), name.end(), []( char c ) { return isIdentChar( c ) || c == '-'; } ) )
        {
            continue;
        }
        std::vector<ShTok> probe{ { name, false } };
        Reporter           r = reporterOf( probe, 0, {} );
        if( r == Reporter::None )
        {
            const std::size_t s = scopeOf( spans, l.startByte );
            const std::string_view body = s < spans.size() ? src.substr( spans[s].begin, spans[s].end - spans[s].begin ) : std::string_view( l.text );
            if( body.find( "FAIL" ) != std::string_view::npos || body.find( "fail=1" ) != std::string_view::npos )
            {
                r = Reporter::Fail;
            }
            else if( body.find( "PASS" ) != std::string_view::npos )
            {
                r = Reporter::Pass;
            }
        }
        out.emplace_back( name, r );
    }
    return out;
}

// errexit state at each logical line: a top-level `set -e…` / `set -o errexit` turns it on, `set +e` off.
inline std::vector<char> shErrexit( const std::vector<ShLine>& lines, const ShLineToks& lt )
{
    std::vector<char> out( lines.size(), 0 );
    bool              on = false;
    if( !lines.empty() && lines[0].text.rfind( "#!", 0 ) == 0 )
    {
        on = lines[0].text.find( " -e" ) != std::string::npos;
    }
    for( std::size_t k = 0; k < lines.size(); ++k )
    {
        const std::vector<ShTok>& t = lt[k];
        for( std::size_t w = 0; w + 1 < t.size(); ++w )
        {
            if( t[w].op || t[w].text != "set" )
            {
                continue;
            }
            for( std::size_t a = w + 1; a < t.size() && !t[a].op; ++a )
            {
                const std::string& f = t[a].text;
                if( f.size() > 1 && f[0] == '-' && f[1] != 'o' && f.find( 'e' ) != std::string::npos )
                {
                    on = true;
                }
                else if( f.size() > 1 && f[0] == '+' && f.find( 'e' ) != std::string::npos )
                {
                    on = false;
                }
                else if( f == "-o" && a + 1 < t.size() && t[a + 1].text == "errexit" )
                {
                    on = true;
                }
            }
        }
        out[k] = on ? 1 : 0;
    }
    return out;
}

inline std::string collapseSpaces( std::string_view s )
{
    std::string out;
    bool        space = false;
    for( char c : s )
    {
        if( isSpace( c ) )
        {
            space = !out.empty();
            continue;
        }
        if( space )
        {
            out.push_back( ' ' );
            space = false;
        }
        out.push_back( c );
    }
    return out;
}

inline void scanVacuousAssertBash( std::string_view src, const std::vector<Span>& spans, std::vector<Site>& out )
{
    const std::vector<ShLine> lines = shLogicalLines( src );
    if( lines.empty() )
    {
        return;
    }
    std::vector<std::size_t> scope( lines.size() );
    ShLineToks               lt( lines.size() );
    for( std::size_t k = 0; k < lines.size(); ++k )
    {
        scope[k] = scopeOf( spans, lines[k].startByte );
        lt[k]    = shTokens( lines[k].text );
    }
    const std::vector<std::pair<std::string, Reporter>> defined = shDefinedReporters( src, lines, lt, spans );
    const std::vector<ShAssert>                         asserts = shAssertions( lt, defined );
    const std::vector<char>                             errexit = shErrexit( lines, lt );
    for( const ShAssert& a : asserts )
    {
        if( a.pol != Polarity::Absence || lineReadsRc( lines[a.line].text ) )
        {
            continue;
        }
        bool vacuous = a.pipe.direct;
        if( !vacuous )
        {
            // follow a derived capture (V="$( printf '%s' "$W" | … )") back to its source, up to three steps: the
            // absence is vacuous only when the chain ends in a capture of a RUN UNDER TEST and no step of it is
            // guarded (its failure checked, or its content required).
            std::string var = a.pipe.var;
            bool        guard = false;
            bool        runSource = false;
            for( int step = 0; step < 3 && !guard && !runSource; ++step )
            {
                const std::size_t as = assignmentOf( lt, scope, a.line, var );
                if( as == std::string::npos )
                {
                    break;
                }
                const std::string&     al  = lines[as].text;
                const std::size_t      eq  = al.find( var + "=" );
                const std::string_view rhs = std::string_view( al ).substr( eq + var.size() + 1 );
                if( rhs.find( "$(" ) == std::string_view::npos )
                {
                    break;   // a literal or a copy: not a run under test
                }
                const std::vector<ShTok> inner = shTokens( rhs.substr( rhs.find( "$(" ) + 2 ) );
                std::size_t              innerEnd = 0;
                while( innerEnd < inner.size() && !( inner[innerEnd].op && inner[innerEnd].text == "|" ) )
                {
                    ++innerEnd;
                }
                guard = captureGuarded( lines, lt, scope, asserts, a.line, as, var, errexit[as] != 0 );
                if( isRunUnderTest( inner, 0, innerEnd ) )
                {
                    runSource = true;
                    break;
                }
                std::string next;
                if( !inner.empty() && ( inner[0].text == "printf" || inner[0].text == "echo" ) )
                {
                    for( std::size_t w = 1; w < inner.size() && !inner[w].op; ++w )
                    {
                        const std::string_view r = varRef( inner[w].text );
                        if( !r.empty() )
                        {
                            next = std::string( r );
                        }
                    }
                }
                if( next.empty() )
                {
                    break;   // a text utility over a file, or a wrapper function: not judged
                }
                var = next;
            }
            vacuous = runSource && !guard;
        }
        if( vacuous )
        {
            out.push_back( { Facet::VacuousAssert, lines[a.line].startByte, collapseSpaces( lines[a.line].text ) } );
        }
    }
}

}   // namespace detail

// ─── the per-language entry points ──────────────────────────────────────────────────────────────────────

// C++: format-arity over the whole file; utf8-cut and dedup-first inside each function span. A site found
// in nested spans is reported once (the scan of each span is independent; the caller anchors by byte).
inline std::vector<Site> scanCpp( std::string_view src, const std::vector<Span>& fnSpans )
{
    std::vector<Site>            out;
    const std::vector<detail::Tok> toks = detail::lexCpp( src );
    detail::scanFormatArityCpp( src, toks, out );
    for( const Span& sp : fnSpans )
    {
        const auto first = std::lower_bound( toks.begin(), toks.end(), sp.begin, []( const detail::Tok& t, std::uint32_t b ) { return t.begin < b; } );
        const auto last  = std::lower_bound( toks.begin(), toks.end(), sp.end, []( const detail::Tok& t, std::uint32_t b ) { return t.begin < b; } );
        const std::size_t from = static_cast<std::size_t>( first - toks.begin() );
        const std::size_t to   = static_cast<std::size_t>( last - toks.begin() );
        if( from >= to )
        {
            continue;
        }
        detail::scanUtf8CutFunction( src, toks, from, to, out );
        detail::scanDedupFirstFunction( src, toks, from, to, out );
    }
    std::sort( out.begin(), out.end(), []( const Site& a, const Site& b ) { return a.startByte != b.startByte ? a.startByte < b.startByte : a.text < b.text; } );
    out.erase( std::unique( out.begin(), out.end(), []( const Site& a, const Site& b ) { return a.facet == b.facet && a.startByte == b.startByte && a.text == b.text; } ),
               out.end() );
    return out;
}

inline std::vector<Site> scanPython( std::string_view src )
{
    std::vector<Site> out;
    detail::scanFormatArityPython( src, detail::lexPython( src ), out );
    return out;
}

// Bash, for a test-script path only (the caller decides the path): `fnSpans` are the script's function
// definitions, the scopes a capture and its guards are matched in.
inline std::vector<Site> scanBashTestScript( std::string_view src, const std::vector<Span>& fnSpans )
{
    std::vector<Site> out;
    detail::scanVacuousAssertBash( src, fnSpans, out );
    return out;
}

// A cheap byte prefilter: can this C++ file hold any of the three C++ shapes at all?
inline bool cppMayHoldShapes( std::string_view src ) noexcept
{
    for( std::string_view needle : { std::string_view( "format" ), std::string_view( "print" ), std::string_view( "emitTo" ), std::string_view( "formatTo" ),
                                     std::string_view( "unique" ), std::string_view( "..." ), std::string_view( "\xE2\x80\xA6" ), std::string_view( "xE2" ),
                                     std::string_view( "u2026" ) } )
    {
        if( src.find( needle ) != std::string_view::npos )
        {
            return true;
        }
    }
    return false;
}

}   // namespace rw::defectshape
