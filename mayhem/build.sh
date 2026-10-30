#!/usr/bin/env bash
#
# mayhem/build.sh — builds the ByteRangeTree libFuzzer harness (+ standalone reproducer) with the
# sanitizer/DWARF-3 flags, and, separately and with NORMAL flags, a wx-free gtest runner covering the
# header-only data-structure tests (ByteRangeTree, ByteRangeSet, BitOffset) for mayhem/test.sh.
#
# Only the data-structure code is built: the editor itself needs wxWidgets/GTK/Lua/Botan etc., none of
# which the ByteRangeTree code depends on. Re-runnable and offline: no fetches, objects live in
# mayhem/build (gitignored).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/mayhem/build"
mkdir -p "$B"

CXXSTD="-std=c++17"
JANSSON_CFLAGS="$(pkg-config --cflags jansson)"
JANSSON_LIBS="$(pkg-config --libs jansson)"

# 1) Sanitized fuzz build. -fsanitize=fuzzer-no-link puts SanCov instrumentation on the project code
#    (BitOffset.cpp); the header-only tree is instrumented as part of the harness TU.
FUZZ_CXXFLAGS="$CXXSTD -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $JANSSON_CFLAGS"

$CXX $FUZZ_CXXFLAGS -c "$SRC/src/BitOffset.cpp" -o "$B/BitOffset.fuzz.o"
$CXX $FUZZ_CXXFLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"
$CXX $FUZZ_CXXFLAGS -c "$SRC/mayhem/brt_fuzz.cpp" -o "$B/brt_fuzz.fuzz.o"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
	"$B/brt_fuzz.fuzz.o" "$B/BitOffset.fuzz.o" "$B/lsan_off.o" $JANSSON_LIBS \
	-o "$SRC/brt_fuzz"

# 2) Standalone (run-once) reproducer. The driver is C, compiled as C so the harness's extern "C" entry
#    point is not mangled.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"
$CXX $CXXSTD -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $JANSSON_CFLAGS -c "$SRC/mayhem/brt_fuzz.cpp" -o "$B/brt_fuzz.standalone.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
	"$B/brt_fuzz.standalone.o" "$B/standalone_main.o" "$B/BitOffset.fuzz.o" "$B/lsan_off.o" $JANSSON_LIBS \
	-o "$SRC/brt_fuzz-standalone"

# 3) Test suite, NORMAL flags (no sanitizers, no -gdwarf-3): the project's own gtest tests for the
#    standalone data structures, with the bundled googletest.
TEST_CXXFLAGS="$CXXSTD -O1 -Wall -I$SRC/include -I$SRC/googletest/include -I$SRC/googletest $JANSSON_CFLAGS $COVERAGE_FLAGS"

[ -f "$B/gtest-all.o" ] || $CXX $TEST_CXXFLAGS -c "$SRC/googletest/src/gtest-all.cc" -o "$B/gtest-all.o"
[ -f "$B/gtest_main.o" ] || $CXX $TEST_CXXFLAGS -c "$SRC/googletest/src/gtest_main.cc" -o "$B/gtest_main.o"

objs=()
for src in src/BitOffset.cpp src/ByteRangeSet.cpp src/MathUtils.cpp tests/BitOffset.cpp tests/ByteRangeSet.cpp tests/ByteRangeTree.cpp; do
	o="$B/test-$(dirname "$src")-$(basename "${src%.cpp}").o"
	$CXX $TEST_CXXFLAGS -c "$SRC/$src" -o "$o" &
	objs+=("$o")
	while [ "$(jobs -r | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n; done
done
wait

$CXX $COVERAGE_FLAGS "${objs[@]}" "$B/gtest-all.o" "$B/gtest_main.o" $JANSSON_LIBS -lpthread \
	-o "$SRC/rehex-datastructure-tests"
