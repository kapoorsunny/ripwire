#pragma once

// countfloor.h — when a per-row count is a FLOOR, and which call finds the rest.
//
// WHY. A root's counts_floor="1" and a verb legend's "a zero means none found" are blanket statements; the reader
// meets them once, far from the number. A graded comparison showed what that costs: of the false claims scored
// against this tool, eight were a ZERO or "none" read as a TOTAL — a method's `<enc callers="0">` while six calls the
// resolver declined to bind could have meant it, a module variable's `<enc callers="0">` while another file READS it
// (it is never called), a C struct's `--safe-delete` answering callers/uses="0" risk="none-found" although its type
// mentions — which the index does not capture at all — sat in thirty files. Each number was what the graph
// held; none of them was the answer the reader took from it.
//
// THE RULE. A row's count stays a plain total only when nothing this index knows could add to it. It is a floor —
// spelled `<count>_floor="1"` beside the number (the locals="N" locals_floor="1" precedent), with a pasteable
// follow-up that finds the rest — when the index itself holds EVIDENCE of a miss for THAT definition:
//   * declined  — a call the resolver refused to bind named it among its candidates (graph.h declinedCallsNaming);
//   * unbound   — a call or macro site SPELLED like it bound to no definition of that name at all (a receiver the
//                 resolver could not type, a name whose every candidate was filtered), from a symbol that is not
//                 already one of its callers;
//   * value     — the function is stored or passed as a value (valuerefindex.h), so it is called by another name;
//   * unmodelled — its KIND is used by reading or naming it (a variable, a struct, an interface, a field), and a
//                 call count cannot see a read or a type mention at all.
// None of these says the missing callers EXIST: an unbound `x.last()` may be a list's own method. The marker is a
// statement about what was NOT read, which is exactly what a total would have claimed was read.
//
// CLI AND MCP. Every input here is identical in the lean (CLI nav verbs) and rich (MCP) ingest families: call and
// macro references, inherit references, the graph's edges and declines, value references (both families capture
// them, ingest_sidecap.h) and symbol kinds. Read/write/type references — the rich family's extra rows — are never
// consulted, so the two surfaces cannot disagree about a floor.

#include "graph.h"           // Graph, declinedCallsNaming — the declined evidence and the in-edge CSR
#include "model.h"
#include "nextverb.h"        // nextFlag — the follow-up's shell-safe spelling
#include "valuerefindex.h"   // ValueRefIndex, valueRefCallerRows — the value evidence
#include "infra/Diagnostics.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace rw
{

// How a definition is USED, for the one question a caller count can answer.
//   Calls    — a call reaches it: functions, methods, function-like macros.
//   NotCalls — it is read or named more than it is called: a variable, a class or struct (a constructor call is one use, a
//              type mention, a base clause or an isinstance are the others), an interface, a field, anything unclassified.
//              callers= is structurally blind to most of its uses.
//   NotCode  — a markdown heading or a file's module scope: no code calls or reads it, so a zero there is simply true.
enum class UseForm : std::uint8_t { Calls, NotCalls, NotCode };

inline UseForm useFormOf( const Symbol& s ) noexcept
{
    switch( s.kind )
    {
        case SymKind::Function:
        case SymKind::Method:
        case SymKind::Macro:
            return UseForm::Calls;
        case SymKind::Section:
        case SymKind::ModuleScope:
            return UseForm::NotCode;
        case SymKind::Class:       // a constructor call is one use; a type mention, a base clause, an isinstance are the rest
        case SymKind::Struct:
        case SymKind::Interface:
        case SymKind::Var:
        case SymKind::Field:
        case SymKind::Other:
            return UseForm::NotCalls;
    }
    return UseForm::NotCalls;   // a byte past the enum: the conservative answer (a floor), never a silent total
}

// Whether a read/write/type use of a symbol in `lang` reaches the use-site table in an ingest that captured value
// uses (ingest_sidecap.h arms that pass for C++, ObjC and Python only). Outside those, `--uses` lists calls and value
// references but never a read, so the honest follow-up for a NotCalls symbol is the literal scan.
inline bool valueUsesArmedFor( Lang lang ) noexcept
{
    return lang == Lang::Cpp || lang == Lang::ObjC || lang == Lang::Python;
}

// The follow-up that finds what a floored count could not: the uses verb lists every call, value and (where armed)
// read site spelled like the name, bound or not; a NotCalls symbol in a language whose reads are never captured gets
// the literal scan instead, which is the only verb that can see `struct cell c;`.
//
// A `.h` definition is the exception: the grammar reads it as C++, but its users are as often `.c` files, whose reads the
// uses verb never sees — so a header's NotCalls symbol gets the literal scan too (`struct cell` in a.h used in a.c).
inline std::string countFloorNext( const IngestResult& ing, const Symbol& s )
{
    const std::string_view path     = s.fileId < ing.files.size() ? std::string_view( ing.files[ s.fileId ] ) : std::string_view();
    const bool             cHeader  = path.ends_with( ".h" );
    const bool             literal  = useFormOf( s ) == UseForm::NotCalls && ( !valueUsesArmedFor( s.lang ) || cHeader );
    return nextFlag( literal ? "--grep=" : "--uses=", s.name );
}

// One row's verdict. `next` is a CLI flag spelling (MCP prints the same text), empty exactly when !isFloor.
struct CallerFloor
{
    bool        isFloor = false;
    bool        unmodelled = false;   // the NotCalls reason (no call form): the safe-delete verdict reads it
    std::string next;
};

// callers= floors for a batch of rows: sets[i] is one row's definitions (all one NAME — a grep <enc> row's ids, a
// safe-delete selector's defs). ONE pass over the symbols and ONE over the references, whatever the row count —
// never a per-row rescan of the reference table (editcheck.h's rule). `vri` may be null: then it is built here, once,
// and only when a Calls row is still undecided after the cheaper evidence.
inline std::vector<CallerFloor> callerFloors( const IngestResult& ing, const Graph& g, std::span<const std::vector<NodeId>> sets,
                                              const ValueRefIndex* vri = nullptr )
{
    std::vector<CallerFloor> out( sets.size() );
    if( sets.empty() )
    {
        return out;
    }
    const std::size_t nodeCount = g.wOutDeg.size();
    const auto*       inRo      = g.inEdges.rowOffsets();
    const auto*       inCi      = g.inEdges.colIndices();

    // Row → its name; a name may head several rows (two <enc> chains `A::f` and `B::f`) — each row asks of the NAME.
    HashMap<std::string_view, std::vector<std::uint32_t>> rowsOfName;
    std::vector<std::uint32_t>                            pending;   // Calls rows not yet decided by the cheap evidence
    for( std::uint32_t i = 0; i < sets.size(); ++i )
    {
        const std::vector<NodeId>& ids = sets[i];
        bool anyNotCalls = false;
        bool anyCalls    = false;
        for( const NodeId id : ids )
        {
            if( id >= ing.symbols.size() )
            {
                continue;
            }
            const UseForm form = useFormOf( ing.symbols[id] );
            anyNotCalls = anyNotCalls || form == UseForm::NotCalls;
            anyCalls    = anyCalls || form == UseForm::Calls;
        }
        if( ids.empty() || ids[0] >= ing.symbols.size() )
        {
            continue;
        }
        if( anyNotCalls )
        {
            out[i].isFloor = true;
            out[i].unmodelled = true;
            continue;
        }
        if( !anyCalls )
        {
            continue;   // NotCode only: nothing calls or reads a heading, the zero is true
        }
        if( declinedCallsNaming( g, ids ) > 0 )
        {
            out[i].isFloor = true;
            continue;
        }
        rowsOfName[ std::string_view( ing.symbols[ ids[0] ].name ) ].push_back( i );
        pending.push_back( i );
    }

    if( !pending.empty() )
    {
        // Per pending NAME: every symbol with an edge into ANY definition of that name. A call from one of them was
        // bound somewhere — to this row or to a same-named sibling — so it is not evidence of a miss.
        HashMap<std::string_view, std::vector<NodeId>> boundCallers;
        for( NodeId id = 0; id < ing.symbols.size() && id < nodeCount; ++id )
        {
            const auto it = rowsOfName.find( std::string_view( ing.symbols[id].name ) );
            if( it == rowsOfName.end() )
            {
                continue;
            }
            std::vector<NodeId>& bound = boundCallers[ it->first ];
            for( std::uint32_t k = inRo[id]; k < inRo[id + 1]; ++k )
            {
                bound.push_back( inCi[k] );
            }
        }
        for( auto& [ name, bound ] : boundCallers )
        {
            std::sort( bound.begin(), bound.end() );
            bound.erase( std::unique( bound.begin(), bound.end() ), bound.end() );
        }

        // ONE pass: a call or macro site spelled like a pending name, from a symbol no edge of that name leaves.
        for( const Reference& r : ing.references )
        {
            if( ( r.role != RefRole::Call && r.role != RefRole::Macro ) || r.isInherit || r.isDocLink || r.isCompose || r.lang == Lang::Markdown )
            {
                continue;
            }
            const auto it = rowsOfName.find( std::string_view( r.calleeName ) );
            if( it == rowsOfName.end() )
            {
                continue;
            }
            const auto                 boundIt = boundCallers.find( it->first );
            const std::vector<NodeId>* bound   = boundIt == boundCallers.end() ? nullptr : &boundIt->second;
            const bool isBound = r.fromSymbol != kNoNode && bound != nullptr && std::binary_search( bound->begin(), bound->end(), r.fromSymbol );
            if( isBound )
            {
                continue;
            }
            for( const std::uint32_t row : it->second )
            {
                out[row].isFloor = true;
            }
        }

        // value evidence, last and only where still undecided: a ValueRefIndex is one more pass over the table.
        std::vector<std::uint32_t> stillOpen;
        for( const std::uint32_t row : pending )
        {
            if( !out[row].isFloor )
            {
                stillOpen.push_back( row );
            }
        }
        if( !stillOpen.empty() )
        {
            std::optional<ValueRefIndex> own;
            const ValueRefIndex*         index = vri;
            if( index == nullptr )
            {
                own.emplace( ing );
                index = &*own;
            }
            for( const std::uint32_t row : stillOpen )
            {
                for( const ValueRefRow& vr : valueRefCallerRows( ing, *index, sets[row] ).rows )
                {
                    // a decorator row (into="@name") is a fact about the definition, not a path that calls it
                    if( vr.ref < ing.references.size() && !ing.references[ vr.ref ].fieldName.starts_with( '@' ) )
                    {
                        out[row].isFloor = true;
                        break;
                    }
                }
            }
        }
    }

    for( std::uint32_t i = 0; i < sets.size(); ++i )
    {
        if( out[i].isFloor )
        {
            out[i].next = countFloorNext( ing, ing.symbols[ sets[i][0] ] );
        }
    }
    return out;
}

// implementors= floors for the <lego> rows: an inherit reference spelled like the interface's name from a type that
// is in NO implementor list of any definition of that name — an `extends`/`implements` clause the graph did not
// bind (a cross-language filter, a qualified base it could not place). ONE pass over the references for the batch.
// The structural-typing limit (a TS class or Go type that satisfies an interface without naming it) leaves no
// reference at all, and is stated in the legend rather than guessed at here.
inline std::vector<char> implementorFloors( const IngestResult& ing, const std::vector<std::vector<NodeId>>& graphImplementors,
                                            std::span<const NodeId> ifaces )
{
    std::vector<char> out( ifaces.size(), 0 );
    HashMap<std::string_view, std::vector<std::uint32_t>> rowsOfName;
    for( std::uint32_t i = 0; i < ifaces.size(); ++i )
    {
        if( ifaces[i] < ing.symbols.size() )
        {
            rowsOfName[ std::string_view( ing.symbols[ ifaces[i] ].name ) ].push_back( i );
        }
    }
    if( rowsOfName.empty() )
    {
        return out;
    }
    HashMap<std::string_view, std::vector<NodeId>> boundDerived;   // every implementor of any def of the name
    for( NodeId id = 0; id < ing.symbols.size() && id < graphImplementors.size(); ++id )
    {
        const auto it = rowsOfName.find( std::string_view( ing.symbols[id].name ) );
        if( it == rowsOfName.end() )
        {
            continue;
        }
        std::vector<NodeId>& bound = boundDerived[ it->first ];
        bound.insert( bound.end(), graphImplementors[id].begin(), graphImplementors[id].end() );
    }
    for( auto& [ name, bound ] : boundDerived )
    {
        std::sort( bound.begin(), bound.end() );
        bound.erase( std::unique( bound.begin(), bound.end() ), bound.end() );
    }
    for( const Reference& r : ing.references )
    {
        if( !r.isInherit && r.role != RefRole::Extends )
        {
            continue;
        }
        const auto it = rowsOfName.find( std::string_view( r.calleeName ) );
        if( it == rowsOfName.end() )
        {
            continue;
        }
        const auto boundIt = boundDerived.find( it->first );
        const bool isBound = r.fromSymbol != kNoNode && boundIt != boundDerived.end()
                             && std::binary_search( boundIt->second.begin(), boundIt->second.end(), r.fromSymbol );
        if( !isBound )
        {
            for( const std::uint32_t row : it->second )
            {
                out[row] = 1;
            }
        }
    }
    return out;
}

// The targeted lego verb's clause for implementors_floor=/floor_next=, emitted as its own comment exactly when the root's
// interface carries them (kLegoLegend is one closed literal — the graphUnindexedLegendComment route). CLI and MCP share it.
inline constexpr const char* kImplementorsFloorLegendComment =
    "<!-- ripwire lego: implementors_floor=\"1\": an extends/implements clause spelled like this interface bound to NO definition "
    "(a cross-language base, a qualified base the graph could not place), so implementors= may be short by it; it does NOT mean "
    "another implementor exists. floor_next= lists every extends site of the name, bound or not. A type that satisfies an "
    "interface without naming it (structural typing) leaves no clause at all and is never counted. -->";

inline const char* implementorsFloorLegendComment( const IngestResult& ing, const std::vector<std::vector<NodeId>>& graphImplementors, NodeId focus )
{
    const NodeId one[1] = { focus };
    return implementorFloors( ing, graphImplementors, std::span<const NodeId>( one ) )[0] ? kImplementorsFloorLegendComment : "";
}

}   // namespace rw
