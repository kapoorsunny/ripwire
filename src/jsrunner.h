#pragma once

// jsrunner.h — #323: TS/JS test-runner evidence. Before this file, testmap.h's TestRunnerIndex derived a
// runner for exactly two script kinds (bash .sh, python3/pytest .py) — no .ts/.js/.tsx/.jsx entry existed,
// so every TS/JS test row carried run_unknown="1" forever (testmap.h's own M21(b) disclosure), even after
// the suite had been run and passed. The reporter's own measurement: 154 of 154 --test-gate runs over three
// days on a vitest project hit this, because the gate exits 4 whenever the tests-to-run list is non-empty
// and no TS/JS row could ever clear it.
//
// EVIDENCE, NEVER A GUESS — same rule pythonrunner.h already applies to Python: a runner is derived ONLY
// from bytes actually present in the repo (here, the nearest package.json's own "scripts"/"dependencies"/
// "devDependencies"), and an absent or inconclusive manifest yields NO command, exactly like a Python test
// file with no main-guard and no pytest project — testmap.h's runHint family turns that "" into
// run_unknown="1", never a fabricated default. The three cases this derives are the three the issue names
// and nothing else: `vitest` or `jest` named as a scripts.test runner or a dependency/devDependency ⇒ the
// corresponding CLI invocation; a scripts.test that runs node's OWN built-in runner (`node --test`) names
// itself directly — there is no package to depend on for it.
//
// NEAREST MANIFEST, WALKING UP (mirrors pythonrunner::hasPytestProject exactly): monorepo/workspace layouts
// are common (the issue's own point 1), so the search starts at the test file's own directory and climbs to
// the crawl root, inclusive, stopping at the first package.json found. The command is still spelled ROOT-
// RELATIVE, same as every other run= this codebase emits (testmap.h::spellUncached) — a package.json found
// in a subdirectory is evidence of WHICH runner, not a cd target; running the emitted command may need the
// reader's own shell to be inside that subdirectory on a workspace where the runner is not hoisted to the
// crawl root's node_modules. That is a stated scope limit (see the fix report), not a silent one: it is the
// SAME limit testmap.h's Python branch already carries (a nested pyproject.toml is evidence, not a `cd`).
//
// LANGUAGE NEUTRALITY (BRIEF_COMMON, standing house rule): the mechanism — walk up from a test file to the
// nearest project manifest and read its OWN declared scripts/dependencies as evidence, never guess — is the
// same shape pythonrunner.h already uses for Python (nearest pytest config) and the one testmap.h's shell
// branch trivially satisfies (a runnable script IS its own runner, no manifest needed). It is NOT extended
// here to the other languages testmap.h indexes test files for (Kotlin, Java, Ruby, Go, Rust, Swift, C#,
// Bash beyond .sh): Bash's .sh case above already has a runner (verb="bash", no evidence needed beyond the
// extension); Kotlin/Java build their test command from Gradle/Maven, not a single JSON manifest this file's
// shape can read; Ruby's is a Gemfile plus a Rakefile, same shape gap; Go's `go test` needs no manifest
// evidence at all (there is only ever the one command, so `go.mod`'s presence would be sufficient, but no
// issue reports that gap and it is out of scope for #323, which is TS/JS only); Rust/Swift/C# were not
// reported and are not audited here. This is a stated scope limit, not a silent one — see the fix report.
//
// #60 (train 20): a repo can have NO package.json at all (the reporter's own repro: one source file, one
// node:test-based test file, nothing else) — in which case the walk above finds no manifest, decides
// nothing, and the row stayed run_unknown="1" forever, even though the test file names its own runner in
// its own bytes (`import test from "node:test"`, `require("node:test")`). That is evidence about the FILE,
// the same kind pythonrunner::hasMainGuard already reads for Python's main-guard case, so `hasNodeTestImport`
// below re-parses the test file with its own grammar (never a substring scan — a "node:test" mention inside
// a comment or an unrelated string literal is not a real import) and is consulted ONLY as a FALLBACK, after
// `nearestPackageJson`'s own evidence has had its say: an authoritative-but-unrecognized `scripts.test`
// (mocha, say) still wins and is never overridden by this weaker, file-local evidence (the same F2 rule
// `detectFramework` already applies one level up, restated at this new layer) — see resolveJsVerb's own
// caller comment in testmap.h. A `.ts`/`.mts`/`.cts` file additionally needs a Node-version decision: node's
// own `--test` runner strips TypeScript types WITHOUT a flag only from Node 23.6 onward; earlier Nodes need
// `--experimental-strip-types` (which 23.6+ still accepts, now a no-op). This file cannot see which Node
// will actually run the emitted command, so it reads `engines.node` from the SAME nearest manifest (if any)
// and derives the flagged, conservative form UNLESS that field proves every satisfying Node is >= 23.6 —
// never a guess at an unseen runtime. See nodeTestVerb / floorGuaranteesTypeStripping below.

#include "docparse.h"
#include "infra/Diagnostics.h" // ASSUME — the same raw-reparse contract pythonrunner.h's hasMainGuard uses
#include "infra/dirwalk.h"    // ascendToRoot — the ONE nearest-config walk, shared with pythonrunner.h
#include "infra/fieldid.h"    // fieldChild/NodeField — the ONE field-lookup pythonrunner.h/ingest_jsimports.h share
#include "infra/jsonesc.h"    // jsonStringEnd — the ONE escape-aware JSON string walk, applied inline below (see detail's banner)
#include "infra/namesplit.h"  // isIdentChar / containsWordBoundedBy — the shared ident-byte test and word-boundary scan
#include "infra/nodekind.h"   // kindIs — grammar-string compare without a libc call (per nodekind.h's own banner)
#include "infra/tschildren.h" // ChildCursor/appendChildren — the ONE DFS-stack child-walk shape (tschildren.h's own banner)

#include <filesystem>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

// #60: re-parsed here with the SAME raw-reparse contract pythonrunner.h's hasMainGuard already uses (a
// fresh TSParser over the file's own bytes, independent of the ingest walk that parsed it once already and
// keeps no tree around for a caller this late) — never a second, ingest.cpp-private grammar table. Declared
// extern "C" at file scope, matching pythonrunner.h's tree_sitter_python/tree_sitter_toml pair and
// verbs_doctor.h's identical trio for these three JS/TS/TSX grammars.
extern "C"
{
    const TSLanguage* tree_sitter_javascript( void );
    const TSLanguage* tree_sitter_typescript( void );
    const TSLanguage* tree_sitter_tsx( void );
}

namespace rw::jsrunner
{

namespace detail
{

// Every "advance p past this JSON string" site below (p at s[p]=='"', the caller's own guard) applies
// rw::jsonStringEnd (infra/jsonesc.h) — the canonical escape-aware JSON string scan eval.h and mcpjson.h
// already share — INLINE, as `p = ( close == npos ) ? s.size() : close + 1`: a byte after the closing
// quote, or the end when unterminated (the same "no more evidence" degrade an unparseable file already
// gets, never a crash). Not wrapped in a fourth named function: eval.h::minedjson::skipString and
// mcpjson.h::mcpdetail::stringEnd are the two existing thin wrappers around this same walk, one clamped
// to size() and one returning npos for a different caller's truncation check — a third wrapper with
// the SAME clamp-to-size() convention as the first duplicates it outright (measured: --quality-delta
// flagged exactly that pairing), so this file's three call sites apply the two-line clamp themselves.

// Read the JSON string starting at `p` (the opening quote) and advance `p` past its closing quote.
// Minimal unescaping (the same "keep the byte after a backslash" rule resolve.h::parseTsconfigPaths uses) —
// package.json keys and the evidence values this file compares are all plain ASCII in every real corpus.
inline std::string readQuoted( std::string_view s, std::size_t& p )
{
    std::string out;
    if( p >= s.size() || s[p] != '"' )
    {
        return out;
    }
    ++p;
    while( p < s.size() && s[p] != '"' )
    {
        if( s[p] == '\\' && p + 1 < s.size() )
        {
            out.push_back( s[p + 1] );
            p += 2;
            continue;
        }
        out.push_back( s[p] );
        ++p;
    }
    if( p < s.size() )
    {
        ++p;
    }
    return out;
}

// The byte range (begin,end) of the FIRST top-level `"key": { ... }` object VALUE in `json` — package.json's
// own top level ("scripts", "dependencies", "devDependencies" are SIBLINGS, never nested in one another), so
// only a depth-1 key is a match; a same-named key inside some other object (e.g. a "scripts" key nested
// inside an unrelated config blob) is not evidence. A non-object value (or an absent key) yields npos/npos.
struct ObjSpan
{
    std::size_t begin = std::string_view::npos;
    std::size_t end   = std::string_view::npos;
};

inline ObjSpan topLevelObjectBody( std::string_view json, std::string_view key )
{
    std::size_t p     = 0;
    int         depth = 0;
    while( p < json.size() )
    {
        const char c = json[p];
        if( c == '"' )
        {
            const std::string k = readQuoted( json, p );
            if( depth == 1 && k == key )
            {
                std::size_t colon = json.find( ':', p );
                if( colon == std::string_view::npos )
                {
                    return {};
                }
                std::size_t v = colon + 1;
                while( v < json.size() && ( json[v] == ' ' || json[v] == '\t' || json[v] == '\n' || json[v] == '\r' ) )
                {
                    ++v;
                }
                if( v >= json.size() || json[v] != '{' )
                {
                    return {};   // scripts/dependencies must be an object; anything else is not this shape
                }
                const std::size_t objStart = v + 1;
                int                d       = 0;
                for( ; v < json.size(); ++v )
                {
                    if( json[v] == '"' )
                    {
                        const std::size_t close = rw::jsonStringEnd( json, v );
                        v = ( close == std::string_view::npos ) ? json.size() : close + 1;
                        --v;   // the for-loop's ++v re-lands exactly past the string
                        continue;
                    }
                    if( json[v] == '{' )
                    {
                        ++d;
                    }
                    else if( json[v] == '}' )
                    {
                        --d;
                        if( d == 0 )
                        {
                            return { objStart, v };
                        }
                    }
                }
                return {};   // unterminated object: malformed input, no evidence
            }
            continue;   // p already advanced past this string by readQuoted
        }
        if( c == '{' || c == '[' )
        {
            ++depth;
        }
        else if( c == '}' || c == ']' )
        {
            --depth;
        }
        ++p;
    }
    return {};
}

// Whether `body` (an object's byte span, exclusive of its braces) declares `name` as one of its OWN keys.
// Values are skipped whole (string or otherwise) so a version specifier that happens to contain `name` as a
// substring (a scoped package, a git URL) is never mistaken for a key match.
inline bool hasKey( std::string_view body, std::string_view name )
{
    std::size_t p = 0;
    while( p < body.size() )
    {
        while( p < body.size() && ( body[p] == ' ' || body[p] == '\t' || body[p] == '\n' || body[p] == '\r' || body[p] == ',' ) )
        {
            ++p;
        }
        if( p >= body.size() || body[p] != '"' )
        {
            break;   // not a key-shaped byte: malformed or exhausted — no more evidence to read
        }
        const std::string key = readQuoted( body, p );
        const std::size_t colon = body.find( ':', p );
        if( colon == std::string_view::npos )
        {
            break;
        }
        p = colon + 1;
        while( p < body.size() && ( body[p] == ' ' || body[p] == '\t' ) )
        {
            ++p;
        }
        if( key == name )
        {
            return true;
        }
        if( p < body.size() && body[p] == '"' )
        {
            const std::size_t close = rw::jsonStringEnd( body, p );
            p = ( close == std::string_view::npos ) ? body.size() : close + 1;
        }
        else
        {
            while( p < body.size() && body[p] != ',' && body[p] != '}' )   // a non-string value: skip to its end
            {
                ++p;
            }
        }
    }
    return false;
}

// The string VALUE of `body`'s `key` entry, or "" when absent or not a string (an object/array/number test
// script is not a shape this tool spells, and "" is exactly the "no evidence" reading every other caller here
// already uses for an absent field).
inline std::string stringValue( std::string_view body, std::string_view key )
{
    std::size_t p = 0;
    while( p < body.size() )
    {
        while( p < body.size() && ( body[p] == ' ' || body[p] == '\t' || body[p] == '\n' || body[p] == '\r' || body[p] == ',' ) )
        {
            ++p;
        }
        if( p >= body.size() || body[p] != '"' )
        {
            break;
        }
        const std::string k     = readQuoted( body, p );
        const std::size_t colon = body.find( ':', p );
        if( colon == std::string_view::npos )
        {
            break;
        }
        p = colon + 1;
        while( p < body.size() && ( body[p] == ' ' || body[p] == '\t' ) )
        {
            ++p;
        }
        const bool isStr = p < body.size() && body[p] == '"';
        if( k == key )
        {
            return isStr ? readQuoted( body, p ) : std::string();
        }
        if( isStr )
        {
            const std::size_t close = rw::jsonStringEnd( body, p );
            p = ( close == std::string_view::npos ) ? body.size() : close + 1;
        }
        else
        {
            while( p < body.size() && body[p] != ',' && body[p] != '}' )
            {
                ++p;
            }
        }
    }
    return {};
}

// rv-test-gate-tsjs F2: a byte that can continue an identifier/path SEGMENT — used to bound a word match
// so "jest" inside "jest-report-cleaner.js" (a FILENAME) is not mistaken for a "run jest" command. Built
// on rw::namesplit::isIdentChar (the ONE ASCII identifier-byte test) plus '-', the one byte this caller
// needs beyond it: darkflags.h's own identByte (planlint.h's word-boundary user) does NOT count '-' as a
// word byte, which is the wrong reading here — a hyphenated CLI token is one word, not two.
inline bool isWordByte( char c ) noexcept
{
    return rw::namesplit::isIdentChar( c ) || c == '-';
}

/// Whether `word` occurs in `text` bounded on BOTH sides by a non-word byte or the string edge — "vitest"
/// matches in "npx vitest run" (space both sides) and in "node_modules/.bin/jest" (a path separator, then
/// the string end), never in "jest-report-cleaner.js" (a '-' immediately follows) or "myvitest" (a letter
/// immediately precedes). rv-test-gate-tsjs F2: a runner name matched as a SUBSTRING of an unrelated token
/// is not evidence the script text was ever ".find()"-shaped for before this fix. The scan itself is
/// rw::namesplit::containsWordBoundedBy — the SAME walk planlint.h::containsWholeWord already uses, over
/// this file's own boundary predicate (see isWordByte's own comment for why the two predicates differ).
inline bool matchesWord( std::string_view text, std::string_view word )
{
    return rw::namesplit::containsWordBoundedBy( text, word, isWordByte );
}

} // namespace detail

/// Whether `dependencies` or `devDependencies` (either one — testmap.h's callers do not care which) names
/// `pkg` as a declared package. package.json bytes are external input; unparseable or absent input reads as
/// "no evidence", the same degrade the caller (detectFramework) already returns for every other miss.
inline bool hasDependency( std::string_view packageJson, std::string_view pkg )
{
    for( std::string_view key : { std::string_view( "dependencies" ), std::string_view( "devDependencies" ) } )
    {
        const detail::ObjSpan obj = detail::topLevelObjectBody( packageJson, key );
        if( obj.begin != std::string_view::npos && detail::hasKey( packageJson.substr( obj.begin, obj.end - obj.begin ), pkg ) )
        {
            return true;
        }
    }
    return false;
}

/// The literal `scripts.test` command string, or "" when package.json has no such field.
inline std::string testScript( std::string_view packageJson )
{
    const detail::ObjSpan obj = detail::topLevelObjectBody( packageJson, "scripts" );
    if( obj.begin == std::string_view::npos )
    {
        return {};
    }
    return detail::stringValue( packageJson.substr( obj.begin, obj.end - obj.begin ), "test" );
}

// The three runners #323 names, and nothing else — a fourth framework (mocha, ava, tap, jasmine…) is a
// bigger ask than "a package.json reader" and stays run_unknown="1" until its own issue asks for it (the
// issue's own wording: "any ONE of these would help", not "every framework").
enum class Framework : std::uint8_t { None, Vitest, Jest, NodeTest };

// npm's own generated placeholder (`npm init`'s default `scripts.test`) — present, but not really a script
// a human wrote, so it reads the same as "absent" for evidence purposes (rv-test-gate-tsjs F2). The named
// `marker` local (not a bare one-line `return x.find(y) != npos`) is deliberate: a bare return of that
// exact shape structurally matched three UNRELATED substring checks elsewhere in the tree
// (taskroute::has, verbs_for.h's forCoverageAttrPresent/forRouteAttrPresent) under --quality-delta's
// duplication kind — the same false-positive class infra/dirwalk.h's own banner already documents fixing
// for pythonrunner::hasPytestProject, not a real clone of any of those three unrelated checks.
inline bool isNpmPlaceholderScript( std::string_view script ) noexcept
{
    constexpr std::string_view marker = "Error: no test specified";
    return script.find( marker ) != std::string_view::npos;
}

/// rv-test-gate-tsjs G1: whether `packageJson` has a REAL `scripts.test` — non-empty, not npm's own
/// placeholder — regardless of whether that script names a runner this file recognizes. This is a
/// DIFFERENT question from `detectFramework(...) != Framework::None`: a manifest whose `scripts.test`
/// authoritatively runs mocha (unrecognized) and a manifest with NO `scripts.test` at all both return
/// `Framework::None`, but only the first has actually DECIDED anything for its subtree — the second is a
/// pure marker (a bare `{"type":"commonjs"}`) with nothing to decide. `nearestPackageJson` below needs to
/// tell those apart: the first must END the walk (its own unrecognized runner is the honest answer,
/// never overridable by a root manifest naming something else — F2's own rule, one level up), the second
/// must not (F5's whole point).
inline bool hasAuthoritativeScript( std::string_view packageJson )
{
    const std::string script  = testScript( packageJson );
    const bool        isEmpty = script.empty();
    if( isEmpty )
    {
        return false;   // no scripts.test at all: nothing here to be authoritative about
    }
    return !isNpmPlaceholderScript( script );
}

/// Evidence-only framework detection. rv-test-gate-tsjs F2: a NON-EMPTY, non-placeholder `scripts.test` is
/// AUTHORITATIVE — the script IS what a CI run of `npm test` executes, so once it names something, that
/// something (or nothing recognized) is the answer, and a same-named DEPENDENCY never overrides it (a repo
/// can depend on vitest for its config types while `scripts.test` runs mocha; a scripts.test that runs some
/// OTHER file whose path happens to contain "jest" is not a jest invocation either — matchesWord bounds
/// both). Dependencies are consulted ONLY when there is no real scripts.test to read: absent, empty, or
/// npm's own placeholder. node's OWN test runner has no package to depend on, so it is recognized ONLY by
/// its scripts.test spelling, inside the authoritative branch.
inline Framework detectFramework( std::string_view packageJson )
{
    const std::string script = testScript( packageJson );
    if( !script.empty() && !isNpmPlaceholderScript( script ) )
    {
        if( detail::matchesWord( script, "vitest" ) )
        {
            return Framework::Vitest;
        }
        if( detail::matchesWord( script, "jest" ) )
        {
            return Framework::Jest;
        }
        if( script.find( "node --test" ) != std::string::npos || script.find( "node --experimental-test-runner" ) != std::string::npos )
        {
            return Framework::NodeTest;
        }
        return Framework::None;   // scripts.test names something else entirely — never overridden by a dependency guess
    }
    if( hasDependency( packageJson, "vitest" ) )
    {
        return Framework::Vitest;
    }
    if( hasDependency( packageJson, "jest" ) )
    {
        return Framework::Jest;
    }
    return Framework::None;   // no scripts.test, no vitest/jest dependency: undecidable
}

/// Whether `path` matches vitest/jest's own default include-glob SHAPE — `.test.`/`.spec.` in the filename,
/// or a `__tests__/` directory segment — and never a bare `.d.ts` declaration file. rv-test-gate-tsjs F4:
/// isTestPath (filter.h) is deliberately BROADER (any file under a `test/`/`tests/` directory), which is
/// right for "code a test author wrote" but wrong for "a file vitest/jest itself would collect as a test
/// target" — a helper or a setup file living beside real tests matches isTestPath but not either runner's
/// own glob, so spelling `npx vitest run test/setup.ts` would fail with "no test files found" in CI.
///
/// rv-test-gate-tsjs G2 (delta review — fixed, not left as a follow-up): this function is only ever
/// CALLED on a path isTestPath already accepted (TestRunnerIndex's own candidate gate, testmap.h).
/// isTestPath (filter.h) now recognizes a bare `__tests__/` directory segment too (the SAME fix, applied
/// where every other verb reaches it, since isTestPath is the one shared test-path convention this whole
/// tool uses — not duplicated here), so the `__tests__/` branch below is reachable for a bare
/// `src/__tests__/foo.js` (jest's own default convention, no `.test.` in the name) exactly as it already
/// was for `src/__tests__/foo.test.ts`. jest's OTHER default pattern half — a bare `test.js`/`spec.js`
/// filename with no leading dot or underscore — is a narrower, separate gap neither isTestPath nor this
/// function closes; stated, not silent.
inline bool looksLikeJsTestFile( std::string_view path ) noexcept
{
    if( path.ends_with( ".d.ts" ) )
    {
        return false;   // a TypeScript declaration file — never test code, whatever the rest of its name is
    }
    const std::size_t slash = path.rfind( '/' );
    const std::string_view fn = ( slash == std::string_view::npos ) ? path : path.substr( slash + 1 );
    if( fn.find( ".test." ) != std::string_view::npos || fn.find( ".spec." ) != std::string_view::npos )
    {
        return true;
    }
    // a whole __tests__ directory SEGMENT, bounded by '/' or the path's own edges (never a substring hit
    // inside a longer directory name like "my__tests__stuff/")
    std::size_t pos = 0;
    while( ( pos = path.find( "__tests__/", pos ) ) != std::string_view::npos )
    {
        if( pos == 0 || path[pos - 1] == '/' )
        {
            return true;
        }
        ++pos;
    }
    return false;
}

/// The CLI verb for a detected framework, or nullptr for `Framework::None` — nullptr propagates to testmap.h
/// as "no runner", the same contract runnerVerb() already uses for an unrecognized extension. A table, not a
/// switch, matching testmap.h::runnerVerb's own kRunnerKinds shape (a small sorted-by-nothing row scan reads
/// identically to a switch but is a DIFFERENT shape than model.h::jsLitCtorName's enum switch beside it).
inline const char* verbFor( Framework fw ) noexcept
{
    struct FrameworkVerb { Framework fw; const char* verb; };
    static constexpr FrameworkVerb kFrameworkVerbs[] = {
        { Framework::Vitest,   "npx vitest run" },
        { Framework::Jest,     "npx jest" },
        { Framework::NodeTest, "node --test" },
    };
    for( const FrameworkVerb& fv : kFrameworkVerbs )
    {
        if( fv.fw == fw )
        {
            return fv.verb;
        }
    }
    return nullptr;   // Framework::None, or a byte past the enum: never a guessed verb
}

/// Search from `file`'s own directory through `root`, inclusive, for the nearest package.json that can
/// actually DECIDE a framework, and return its bytes — or, failing that, the nearest package.json found at
/// all (so a caller still reads its honest "names none of the three" rather than a silent miss), or "" when
/// none exists anywhere in the boundary. The walk is rw::dirwalk::ascendToRoot (shared with
/// pythonrunner::hasPytestProject — same boundary and symlink rules). Monorepo/workspace test files are
/// common (the issue's own point 1), so the search starts at the test file, not at the crawl root.
///
/// rv-test-gate-tsjs F5: a package.json with no scripts/dependencies evidence at all — a bare module-type
/// marker (`{"type":"commonjs"}`) is a real, common pattern in mixed-module repos — used to END the search
/// even though it decides nothing; the walk now keeps climbing past it toward a manifest that CAN decide
/// (a workspace root's runner is hoisted to every package under it anyway, so the root manifest is exactly
/// the right fallback).
///
/// rv-test-gate-tsjs G1 (a regression the F5 fix above introduced): "decides nothing" is NOT the same
/// test as `detectFramework(...) == Framework::None` — that also fires for a manifest whose OWN
/// `scripts.test` authoritatively names an unrecognized runner (mocha, say), and climbing past THAT one
/// let an unrelated root manifest's `jest`/`vitest` override a subtree that had already answered for
/// itself (F2's own rule, one level up the tree, is exactly what this fix restores). The walk now stops
/// at ANY manifest with a real `scripts.test` (`hasAuthoritativeScript`), recognized or not, and climbs
/// past only a manifest with neither a real script NOR a decisive dependency — a true marker.
///
/// The one case this file DOES treat as deciding, on purpose, pinned here rather than left implicit: a
/// manifest with NO `scripts.test` but a `vitest`/`jest` DEPENDENCY already makes `detectFramework`
/// return non-`None` (the dependency-fallback branch), so it already stops the walk under the plain
/// `decided` check below — a dependency with nothing wiring it into `scripts.test` is still read as this
/// package's own evidence, not deferred to a root manifest. `test/testgatecheck.sh` arm (p1)
/// (`fx/mochavitestdep`, mocha script + vitest dependency, single package) already pins the single-
/// package half of this; monorepo arm (u2) below pins that the SAME rule holds one level up a tree.
inline std::string nearestPackageJson( const std::string& file, std::string_view root )
{
    namespace fs = std::filesystem;
    std::string fallback;   // the NEAREST manifest found, even if it decides nothing (F5)
    std::string decisive;
    rw::dirwalk::ascendToRoot( file, root, [ & ]( const fs::path& dir )
    {
        std::error_code sec;
        const fs::path candidate = dir / "package.json";
        if( !fs::is_regular_file( fs::symlink_status( candidate, sec ) ) )   // never follow a manifest symlink out of the project
        {
            return false;
        }
        std::string bytes = docparse::detail::readWholeFile( candidate.string() ).value_or( "" );
        if( bytes.empty() )
        {
            return false;
        }
        if( fallback.empty() )
        {
            fallback = bytes;
        }
        const bool decided = detectFramework( bytes ) != Framework::None;
        if( !decided && !hasAuthoritativeScript( bytes ) )
        {
            return false;   // F5: a true marker (no script, no decisive dependency) decides nothing HERE
        }
        decisive = std::move( bytes );   // G1: an authoritative-but-unrecognized script also ends the walk
        return true;
    } );
    return decisive.empty() ? fallback : decisive;
}

// ---------------------------------------------------------------------------------------------------------
// #60 (train 20): the test file's OWN node:test import/require, consulted ONLY when nearestPackageJson's
// manifest evidence decided nothing for this file (see this section's own banner above, and resolveJsVerb's
// caller comment in testmap.h for the precedence wiring).
// ---------------------------------------------------------------------------------------------------------

namespace detail
{

/// The grammar `path`'s own extension selects, reduced to the three this file re-parses with (the same
/// ".ts"/".mts"/".cts" -> typescript, ".tsx" -> tsx, else javascript split ingest_crawl.h's kLangTable
/// uses for the full crawl — jsx parses natively under the plain javascript grammar, same as there).
inline const TSLanguage* grammarForPath( std::string_view path ) noexcept
{
    if( path.ends_with( ".tsx" ) )
    {
        return tree_sitter_tsx();
    }
    if( path.ends_with( ".ts" ) || path.ends_with( ".mts" ) || path.ends_with( ".cts" ) )
    {
        return tree_sitter_typescript();
    }
    return tree_sitter_javascript();   // .js/.jsx/.mjs/.cjs
}

/// Whether `node` is a `string` node (never a template string — a computed specifier proves nothing, the
/// same reading ingest_relations.h::jsModuleLoadTarget already gives it) whose one quote pair strips to
/// exactly "node:test" — single or double, either quote style. The stripping mirrors
/// ingest_relations.h::importSpecifierText exactly (that function is ingest.cpp-private; this file re-parses
/// independently, so the same two-line strip is applied here rather than shared across that boundary).
inline bool isNodeTestStringLiteral( TSNode node, std::string_view src ) noexcept
{
    if( !rw::kindIs( ts_node_type( node ), "string" ) )
    {
        return false;
    }
    const std::uint32_t a = ts_node_start_byte( node ), b = ts_node_end_byte( node );
    if( a >= b || b > src.size() )
    {
        return false;
    }
    std::string_view s = src.substr( a, b - a );
    if( s.size() >= 2 && ( s.front() == '\'' || s.front() == '"' ) && s.back() == s.front() )
    {
        s = s.substr( 1, s.size() - 2 );
    }
    return s == "node:test";
}

/// Whether `node` is itself node:test EVIDENCE — an ES `import … from "node:test"` (any clause shape: the
/// source field alone decides it, never the imported names) or a CommonJS `require("node:test")` call
/// (bare `require` callee, exactly one argument, that argument a string — the same three conditions
/// ingest_relations.h::jsModuleLoadTarget applies to `require`/`import(...)` calls generally, narrowed here
/// to the one specifier this evidence cares about). A "node:test" byte sequence anywhere else — a comment,
/// an unrelated string, `"node:test/mock"` — is a DIFFERENT node kind or a different string value and never
/// matches either shape; this is the parse-based check the negative-control gate arm pins.
inline bool nodeIsNodeTestEvidence( TSNode node, std::string_view src ) noexcept
{
    if( rw::kindIs( ts_node_type( node ), "import_statement" ) )
    {
        const TSNode source = fieldChild( node, NodeField::Source );
        return !ts_node_is_null( source ) && isNodeTestStringLiteral( source, src );
    }
    if( rw::kindIs( ts_node_type( node ), "call_expression" ) )
    {
        const TSNode callee = fieldChild( node, NodeField::Function );
        if( ts_node_is_null( callee ) || !rw::kindIs( ts_node_type( callee ), "identifier" ) )
        {
            return false;
        }
        const std::uint32_t ca = ts_node_start_byte( callee ), cb = ts_node_end_byte( callee );
        if( ca >= cb || cb > src.size() || src.substr( ca, cb - ca ) != "require" )
        {
            return false;
        }
        const TSNode args = fieldChild( node, NodeField::Arguments );
        if( ts_node_is_null( args ) )
        {
            return false;
        }
        TSNode          only  = {};
        std::uint32_t   named = 0;
        rw::ChildCursor cursor( args );
        rw::forEachNamedChild( args, cursor.cur, [ & ]( TSNode c ) { only = c; ++named; return true; } );
        return named == 1 && isNodeTestStringLiteral( only, src );
    }
    return false;
}

} // namespace detail

/// #60: whether `source` (the bytes of a TS/JS test file at `path`) itself imports or requires node's own
/// "node:test" module — checked by re-parsing `source` with the grammar `path`'s extension selects and
/// walking the WHOLE tree (a DFS stack, `infra/tschildren.h::appendChildren`'s own documented shape),
/// never a substring scan: a "node:test" mention inside a comment or an unrelated string literal is not an
/// import and must not count (the negative-control gate arm pins this). Oversized input, a failed parse, or
/// any syntax error anywhere in the file yields NO evidence — the same conservative read
/// pythonrunner::topLevelEvidence already applies to Python's main-guard scan, applied here to a whole-tree
/// walk instead of a top-level-only one (a `require("node:test")` can sit inside a function body, unlike an
/// ES `import`, which the grammar accepts only at top level regardless of source validity).
inline bool hasNodeTestImport( std::string_view source, std::string_view path )
{
    if( source.size() > std::numeric_limits<std::uint32_t>::max() )
    {
        return false;
    }
    TSParser* parser = ts_parser_new();
    ASSUME( parser != nullptr, "ts_parser_new: the default tree-sitter allocator aborts on failure" );
    const bool languageSet = ts_parser_set_language( parser, detail::grammarForPath( path ) );
    ASSUME( languageSet, "the javascript/typescript/tsx grammars are linked into this binary at a supported ABI" );
    TSTree* tree = ts_parser_parse_string( parser, nullptr, source.data(), std::uint32_t( source.size() ) );
    ts_parser_delete( parser );
    if( tree == nullptr )
    {
        return false;   // an external-scanner error on this text: no evidence, never a guessed runner
    }
    const TSNode root = ts_tree_root_node( tree );
    bool         found = false;
    if( !ts_node_has_error( root ) )
    {
        std::vector<TSNode> pending{ root };
        while( !pending.empty() )
        {
            const TSNode node = pending.back();
            pending.pop_back();
            if( detail::nodeIsNodeTestEvidence( node, source ) )
            {
                found = true;
                break;
            }
            rw::ChildCursor cursor( node );
            rw::appendChildren( node, cursor.cur, pending );
        }
    }
    ts_tree_delete( tree );
    return found;
}

/// The `engines.node` field's raw string value, or "" when absent — the same top-level-key + string-value
/// shape `testScript` already reads for "scripts"/"test", applied to "engines"/"node" instead. `packageJson`
/// may itself be "" (no manifest anywhere in the crawl boundary — the #60 repro exactly): topLevelObjectBody
/// on an empty string finds nothing, same as a manifest that simply omits the field.
inline std::string enginesNode( std::string_view packageJson )
{
    const detail::ObjSpan obj = detail::topLevelObjectBody( packageJson, "engines" );
    if( obj.begin == std::string_view::npos )
    {
        return {};
    }
    return detail::stringValue( packageJson.substr( obj.begin, obj.end - obj.begin ), "node" );
}

/// #60: whether an `engines.node` range PROVES every Node version satisfying it is >= 23.6 — the
/// version node's own `--test` runner started stripping TypeScript types WITHOUT `--experimental-strip-
/// types` (the flag stays accepted, now a no-op, on 23.6+, so adding it is never WRONG, only sometimes
/// unnecessary — the asymmetry `nodeTestVerb` below relies on). This is NOT a semver engine: it reads the
/// FIRST major.minor pair in the range as a FLOOR, which is exactly right for the shapes real package.json
/// files use (">=X.Y[.Z]", "^X.Y[.Z]", "~X.Y[.Z]", a bare "X.Y[.Z]", ">X.Y[.Z]" — patch-level exclusivity
/// never changes a major.minor comparison) and DELIBERATELY refuses to decide — returns false, the
/// conservative direction, since that only costs an unneeded flag rather than handing a reader on an older
/// Node a command that fails outright — for anything a floor read cannot safely bound: a range with no
/// version number, or one led by `<`/`<=` (asserts an UPPER bound, never a floor; a compound range beyond
/// that shape, e.g. "^18 || ^20", is likewise left undecided by the same leading-token read).
inline bool floorGuaranteesTypeStripping( std::string_view range ) noexcept
{
    std::size_t p = 0;
    while( p < range.size() && ( range[p] == ' ' || range[p] == '\t' ) )
    {
        ++p;
    }
    if( p < range.size() && range[p] == '<' )
    {
        return false;   // an upper-bound-led range asserts nothing about the floor
    }
    while( p < range.size() && !( range[p] >= '0' && range[p] <= '9' ) )   // skip '>=', '^', '~', '>', or nothing
    {
        ++p;
    }
    const auto readInt = [ & ]() -> int
    {
        const std::size_t start = p;
        int               v     = 0;
        while( p < range.size() && range[p] >= '0' && range[p] <= '9' && p - start < 6 )
        {
            v = v * 10 + ( range[p] - '0' );
            ++p;
        }
        return p == start ? -1 : v;
    };
    const int major = readInt();
    if( major < 0 )
    {
        return false;   // no version number found at all: undecidable
    }
    int minor = 0;
    if( p < range.size() && range[p] == '.' )
    {
        ++p;
        const int m = readInt();
        minor = m < 0 ? 0 : m;
    }
    return major > 23 || ( major == 23 && minor >= 6 );
}

/// #60: the command for node's own built-in test runner at `path`, decided from its own extension and —
/// for a TypeScript source — the nearest manifest's `engines.node` evidence, never a guess at the Node
/// version that will actually run it. `.js`/`.jsx`/`.mjs`/`.cjs` never need type stripping and always get
/// the bare form; `packageJson` may be "" (no manifest in the boundary at all), which reads as "no engines
/// evidence" exactly like a present manifest that omits the field — both take the flagged, conservative
/// form, the honest answer when nothing says the target Node is new enough.
inline const char* nodeTestVerb( std::string_view path, std::string_view packageJson )
{
    const bool isTs = path.ends_with( ".ts" ) || path.ends_with( ".mts" ) || path.ends_with( ".cts" ) || path.ends_with( ".tsx" );
    if( !isTs )
    {
        return "node --test";
    }
    return floorGuaranteesTypeStripping( enginesNode( packageJson ) ) ? "node --test" : "node --experimental-strip-types --test";
}

} // namespace rw::jsrunner
