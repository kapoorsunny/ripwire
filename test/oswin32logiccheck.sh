#!/usr/bin/env bash
# oswin32logiccheck.sh — the Windows port's pure logic is compiled and tested on the platforms that review it.
#
# WHY THIS GATE EXISTS
#   src/infra/os_win32.cpp is compiled only for Windows, and the people and CI legs that review this repository run
#   Linux and macOS. Everything in that file that is not a Win32 call — the Win32→errno table, strict UTF-8/UTF-16
#   conversion and the stack-buffered WidePath, the program's path spelling and the intake rewrite, CreateProcessW
#   argument quoting (adapted from libuv), reparse-tag and st_mode classification, the FILETIME, wait-status and
#   SO_RCVTIMEO conversions, the socket descriptor range, and the trusted-shell predicates — lives in
#   src/infra/os_win32_logic.h, a header with no <windows.h> and no platform test. Uncompiled code rots silently;
#   untested quoting runs the wrong program. This gate compiles that header on this leg and runs
#   test/verify_os_win32_logic.cpp, whose oracles are independent algorithms (a reference UTF-8 encoder, a state-
#   machine MSVCRT command-line parser, the traditional Unix wait-status and st_mode encodings plus the host's own W*
#   and S_IS* macros where it has them, a linear scan of the table).
#
# ARMS
#   (A) the CMake target ripwire_test_oswin32logic builds under -DRIPWIRE_TESTS=ON (fully disconnected: every
#       dependency is vendored) and every test case passes, with the assertion count above a floor — a filter or a
#       lost TEST_CASE that ran nothing would otherwise read as a pass;
#   (B) the same test file under the G1 sanitizer stack (ASan + UBSan + integer, -fno-sanitize-recover=all) passes;
#   (C) can-go-red: the file compiled with -DOSWIN_LOGIC_MUTANT=1 (it swaps one expected quoting result and one
#       errno row) must FAIL — otherwise (A) proves nothing about the assertions it claims to run.
#
# Usage:  bash test/oswin32logiccheck.sh      (CXX=<compiler> to choose one; binds no ripwire binary)
# Exits non-zero on any FAIL; prints ALL PASS on success.

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
CXX="${CXX:-c++}"
fail=0
ok(){ printf '  PASS  %s\n' "$*" || { fail=1; printf '  FAIL  could not write the PASS line for: %s\n' "$*"; }; return 0; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

. "$ROOT/scripts/cxxstd.sh"
. "$ROOT/scripts/asanprobe.sh"
CXXSTD="$( ripwire_cxx_std_flag "$CXX" )"
SRC="$ROOT/test/verify_os_win32_logic.cpp"
WORK="$( mktemp -d )"; trap 'gate_bounded_reap; rm -rf "$WORK"' EXIT; gate_bounded_arm
ASAN_SKIPPED=""
MIN_ASSERTIONS=4000000   # the full-range UTF round trip alone is 3.3 M assertions; far below this, something did not run
CM_ARGS=()
if [ "${OS:-}" = Windows_NT ]; then
    # as in strkerncheck: the default Visual Studio Debug generator's /RTC1 conflicts with the project's /O2 profile
    CM_ARGS=( -G Ninja -DCMAKE_BUILD_TYPE= -DCMAKE_C_COMPILER=clang-cl.exe -DCMAKE_CXX_COMPILER=clang-cl.exe )
fi

echo "oswin32logiccheck: CXX=$CXX  target=ripwire_test_oswin32logic"

read_counts()   # $1 = log; sets CASES, ASSERTS, FAILED
{
    CASES="$(   sed -n 's/^\[doctest\] test cases: *\([0-9][0-9]*\) .*/\1/p' "$1" | tail -1 )"
    ASSERTS="$( sed -n 's/^\[doctest\] assertions: *\([0-9][0-9]*\) .*/\1/p' "$1" | tail -1 )"
    FAILED="$(  sed -n 's/^\[doctest\] assertions:.*| *\([0-9][0-9]*\) failed |$/\1/p' "$1" | tail -1 )"
    : "${CASES:=0}" "${ASSERTS:=0}" "${FAILED:=1}"
}

# ── (A) the CMake target ─────────────────────────────────────────────────────────────────────────────────────
if ! cmake -S "$ROOT" -B "$WORK/cmb" ${CM_ARGS[@]+"${CM_ARGS[@]}"} -DRIPWIRE_TESTS=ON -DFETCHCONTENT_FULLY_DISCONNECTED=ON > "$WORK/cfg.log" 2>&1; then
    no "(A) cmake configure (-DRIPWIRE_TESTS=ON) failed"; tail -20 "$WORK/cfg.log" | sed 's/^/    /'
elif ! cmake --build "$WORK/cmb" --target ripwire_test_oswin32logic -j 2 > "$WORK/build.log" 2>&1; then
    no "(A) ripwire_test_oswin32logic failed to build"; tail -30 "$WORK/build.log" | sed 's/^/    /'
else
    "$WORK/cmb/ripwire_test_oswin32logic" > "$WORK/plain.out" 2>&1
    rc=$?
    read_counts "$WORK/plain.out"
    if [ "$rc" -ne 0 ] || [ "$FAILED" != 0 ]; then
        no "(A) the portable Windows logic tests FAILED (rc=$rc)"; grep -E 'ERROR|TEST CASE' "$WORK/plain.out" | head -30 | sed 's/^/    /'
    elif [ "$ASSERTS" -lt "$MIN_ASSERTIONS" ]; then
        no "(A) only $ASSERTS assertions ran (floor $MIN_ASSERTIONS) — a test case was lost or filtered out"
    else
        ok "(A) os_win32_logic.h: $CASES test cases, $ASSERTS assertions, 0 failed (CMake target, this leg's compiler)"
    fi
fi

# ── (B) under the G1 sanitizer stack ─────────────────────────────────────────────────────────────────────────
SAN="-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer"
if "$CXX" -fsanitize=integer -x c++ -o /dev/null - <<<'int main(){}' >/dev/null 2>&1; then
    SAN="-fsanitize=address,undefined,integer -fno-sanitize-recover=all -fno-omit-frame-pointer"
fi
# Deliberately NOT switched to llvm@22 (unlike connectcorecheck): its libc++ 22 trips an -fsanitize=integer report in
# <string> itself (CONTRIBUTING.md, Sanitizer build), which would turn a hang into a red that is not ripwire's. Probe the
# compiler the caller chose; a start-up hang is a named missing premise, so this arm SKIPs and (A) and (C) still gate.
if ! ripwire_asan_probe "$CXX" "$WORK"; then
    echo "  SKIP  (B) sanitizer run: $RIPWIRE_ASAN_PROBE_WHY. Set CXX to a toolchain whose ASan runtime starts, or update the Command Line Tools/Xcode (CONTRIBUTING.md, Sanitizer build)."
    ASAN_SKIPPED=1
elif "$CXX" "$CXXSTD" -O1 -g $SAN -I"$ROOT/src" -I"$ROOT/third_party/deps/doctest" "$SRC" -o "$WORK/san" > "$WORK/san.log" 2>&1; then
    ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 gate_bounded 300 "$WORK/san" > "$WORK/san.out" 2>&1
    rc=$?
    read_counts "$WORK/san.out"
    if [ "$rc" -eq 0 ] && [ "$FAILED" = 0 ] && ! grep -qE 'runtime error|AddressSanitizer' "$WORK/san.out"; then
        ok "(B) the same $CASES test cases pass under $SAN"
    else
        no "(B) sanitizer run failed (rc=$rc)"; grep -E 'runtime error|AddressSanitizer|ERROR' "$WORK/san.out" | head -20 | sed 's/^/    /'
    fi
else
    no "(B) the sanitizer build failed"; head -20 "$WORK/san.log" | sed 's/^/    /'
fi

# ── (C) can-go-red ───────────────────────────────────────────────────────────────────────────────────────────
if "$CXX" "$CXXSTD" -O1 -DOSWIN_LOGIC_MUTANT=1 -I"$ROOT/src" -I"$ROOT/third_party/deps/doctest" "$SRC" -o "$WORK/mutant" > "$WORK/mut.log" 2>&1; then
    "$WORK/mutant" > "$WORK/mut.out" 2>&1
    rc=$?
    read_counts "$WORK/mut.out"
    if [ "$rc" -ne 0 ] && [ "$FAILED" -ge 2 ]; then
        ok "(C) the mutant expectations are caught ($FAILED failing assertions, rc=$rc) — arm (A)'s assertions can go red"
    else
        no "(C) the mutant build passed (rc=$rc, failed=$FAILED) — the assertions in arm (A) are not observing what they claim"
    fi
else
    no "(C) the mutant build failed to compile"; head -20 "$WORK/mut.log" | sed 's/^/    /'
fi

if [ "$fail" = 0 ] && [ -n "$ASAN_SKIPPED" ]; then
    echo "PASS (arms A and C; arm B was skipped above)"
elif [ "$fail" = 0 ]; then
    echo "ALL PASS"
else
    echo "SOME CHECKS FAILED"
fi
exit "$fail"
