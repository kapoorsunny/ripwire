#!/usr/bin/env bash
# asanprobe.sh — pick a C++ compiler whose AddressSanitizer runtime can start, for the gates that compile their own
# ASan harness. Sourced, not executed (it lives in scripts/ for the reason scripts/cxxstd.sh does):
#
#     . "$ROOT/scripts/asanprobe.sh"                  # also sources scripts/gatebound.sh
#     EXPLICIT_CXX="${CXX:-}"                          # BEFORE the gate defaults CXX
#     CXX="${CXX:-c++}"
#     ASAN_CXX="$( ripwire_asan_pick_cxx "$EXPLICIT_CXX" )"
#     if ! ripwire_asan_probe "$ASAN_CXX" "$WORK"; then echo "  SKIP  ... $RIPWIRE_ASAN_PROBE_WHY"; exit 0; fi
#
# WHY. On macOS 26.7 with Command Line Tools 26.3 (Apple clang 17.0.0, clang-1700.6.4.2) EVERY binary built with
# -fsanitize=address deadlocks before main(), even `int main(){return 0;}`: libSystem's malloc init wraps the default
# zone, which enters the ASan runtime's AsanInitFromRtl; its shadow-memory set-up calls get_dyld_hdr ->
# dyld_shared_cache_iterate_text -> _Block_copy -> malloc, which re-enters AsanInitFromRtl while the first init is
# unfinished, and the second entry waits on a lock the first holds. Nothing in ripwire runs yet. A newer Apple
# toolchain (or Homebrew LLVM) carries a runtime that does not allocate on that path. Without this probe such a gate
# only times out (rc=124) and the contributor learns nothing.
#
# TWO STEPS, both here so every ASan-harness gate says the same thing:
#   ripwire_asan_pick_cxx   an explicit CXX is respected as given; otherwise Homebrew's keg-only llvm@22 clang++ when it
#                           is installed (its runtime starts on the affected macOS); otherwise c++.
#   ripwire_asan_probe      builds an empty `int main(){return 0;}` with -fsanitize=address and runs it under a 10 s
#                           cap (scripts/gatebound.sh). Returns 0 when it ran to completion. Returns 1 and sets
#                           RIPWIRE_ASAN_PROBE_WHY to a one-line, gate-printable reason when it could not be built or
#                           did not finish; the gate then SKIPs BY NAME with that reason (checklist 14/17: a named,
#                           expected missing premise) and never edits its own assertions.
# RIPWIRE_ASAN_PROBE_SEC overrides the 10 s cap (a very busy host); RIPWIRE_GATE_HARNESS_CAP_SEC still wins, as it
# does for every capped harness.

. "$(dirname "${BASH_SOURCE[0]}")/gatebound.sh"

RIPWIRE_ASAN_PROBE_WHY=""

ripwire_asan_llvm22_cxx()   # prints the Homebrew llvm@22 clang++ and returns 0 when it exists; returns 1 otherwise
{
    local d
    for d in /opt/homebrew/opt/llvm@22 /usr/local/opt/llvm@22; do
        if [ -x "$d/bin/clang++" ]; then printf '%s\n' "$d/bin/clang++"; return 0; fi
    done
    return 1
}

ripwire_asan_pick_cxx()   # $1 = the caller's explicit CXX (empty when none); prints the compiler to build the harness with
{
    local explicit="${1:-}" l22
    if [ -n "$explicit" ]; then printf '%s\n' "$explicit"; return 0; fi
    # Only Darwin has the affected runtime; elsewhere the default compiler is the right one and stays untouched.
    if [ "$( uname -s )" = "Darwin" ] && l22="$( ripwire_asan_llvm22_cxx )"; then printf '%s\n' "$l22"; return 0; fi
    printf '%s\n' "c++"
}

ripwire_asan_probe()   # $1 = compiler, $2 = writable scratch dir; extra args = extra compile/link flags
{
    local cxx="$1" dir="$2" cap="${RIPWIRE_ASAN_PROBE_SEC:-10}" rc
    shift 2
    RIPWIRE_ASAN_PROBE_WHY=""
    printf 'int main(){return 0;}\n' > "$dir/asanprobe.cpp"
    if ! "$cxx" "$@" -fsanitize=address "$dir/asanprobe.cpp" -o "$dir/asanprobe" >"$dir/asanprobe.log" 2>&1; then
        RIPWIRE_ASAN_PROBE_WHY="$cxx cannot build an -fsanitize=address program on this host"
        return 1
    fi
    ASAN_OPTIONS=detect_leaks=0 gate_bounded "$cap" "$dir/asanprobe" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 142 ] || [ "$rc" -eq 124 ]; then   # 128+SIGALRM: gate_bounded's cap fired
        RIPWIRE_ASAN_PROBE_WHY="an empty -fsanitize=address program built by $cxx did not run to completion within ${cap} s (rc=$rc: it hung, as the sanitizer runtime of Apple clang 17 / Command Line Tools 26.3 does before main on macOS 26; fixed by a newer Command Line Tools/Xcode or by Homebrew llvm@22)"
        return 1
    elif [ "$rc" -ne 0 ]; then
        RIPWIRE_ASAN_PROBE_WHY="an empty -fsanitize=address program built by $cxx exited rc=$rc instead of 0 (the sanitizer runtime failed at start-up on this host)"
        return 1
    fi
    return 0
}
