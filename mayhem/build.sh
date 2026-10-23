#!/usr/bin/env bash
#
# mayhem/build.sh — build bzip3's fuzz harnesses (libFuzzer ports of examples/fuzz-*.c) and the oracle CLI.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# bzip3 is two C files (src/libbz3.c library, src/main.c CLI) with no external deps. Intermediates go
# to a scratch dir under /tmp (recreated each run, so the script is re-runnable offline).
VERSION_STR="1.5.5"
OBJ=/tmp/bzip3-mayhem-build
rm -rf "$OBJ" && mkdir -p "$OBJ"
COMMON=(-I"$SRC/include" "-DVERSION=\"$VERSION_STR\"" -DPTHREAD -pthread)

# 1) The library, instrumented: sanitizers + DWARF<=3 + SanCov (fuzzer-no-link) so Mayhem sees edges inside libbz3.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 "${COMMON[@]}" \
    -c "$SRC/src/libbz3.c" -o "$OBJ/libbz3.o"

# round_trip links a second copy of the library with two UBSan checks relaxed. libsais (included by
# libbz3.c) uses the sign bit as a flag (1 << 31) and relies on signed wraparound (INT_MIN - 1), so with
# halting shift-base / signed-integer-overflow nearly every input aborts before the BWT and decode run.
# ASan and every other UBSan check stay halting; decode_block and decompress use the fully-checked copy.
$CC $SANITIZER_FLAGS -fno-sanitize=shift-base,signed-integer-overflow $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 "${COMMON[@]}" \
    -c "$SRC/src/libbz3.c" -o "$OBJ/libbz3_relaxed.o"

# LeakSanitizer off at build time (no leak findings).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"

# 2) Each harness twice: libFuzzer binary + run-once standalone reproducer.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c -x c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
for t in decode_block decompress round_trip; do
  LIB="$OBJ/libbz3.o"
  [ "$t" != round_trip ] || LIB="$OBJ/libbz3_relaxed.o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -O1 "${COMMON[@]}" \
      "$SRC/mayhem/fuzz_$t.c" "$LIB" "$OBJ/lsan_off.o" -o "/mayhem/fuzz_$t"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 "${COMMON[@]}" \
      "$SRC/mayhem/fuzz_$t.c" "$OBJ/standalone_main.o" "$LIB" "$OBJ/lsan_off.o" -o "/mayhem/fuzz_$t-standalone"
done

# 3) The oracle CLI with the project's normal flags (no sanitizers, no -gdwarf-3), where test.sh runs it.
mkdir -p /mayhem/mayhem-oracle
$CC -O2 $COVERAGE_FLAGS "${COMMON[@]}" "$SRC/src/main.c" "$SRC/src/libbz3.c" -o /mayhem/mayhem-oracle/bzip3 $COVERAGE_FLAGS
