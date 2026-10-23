#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Known-answer tests against the CLI that mayhem/build.sh built (normal flags, no sanitizers). Each case
# pipes data through bzip3 and compares a sha256 (computed by coreutils, outside the program under test)
# with a value recorded from upstream's own fixtures — a neutered or broken bzip3 produces empty/wrong
# output and fails every case.
BZ=/mayhem/mayhem-oracle/bzip3
[ -x "$BZ" ] || { echo "missing $BZ — mayhem/build.sh must build it" >&2; emit_ctrf "bzip3-kat" 0 1 0; exit 1; }
EX="$SRC/examples"
SHAKES_SHA=c5601d266987ac885ca96522b1b4e439feb7eca39f0fe1111f7342b63b6468f3
SMALL_SHA=ee66ff1ce470d33482b8de7fff2f8b8e95cd95b8ba81f4ec9c2e7a8866e8d30c
SMALL_ENC_SHA=89211f0fa54f485027a37f3df3b07c2a2666abce4ae0b385edac1092242e1413
SHAKES_ENC_SHA=36e54727718b1c63d779f00169b595a2b6fbfcd6b3bda00264ac8bf183a4784a
REP_SHA=038678c98dfaded1f32cc63d7fc0414cc4cc595dd4eb3a84d96aac278a17a46f
REP_ENC_SHA=9b4f7b6cae52a2f16214cae1864589eaee466b674ce56288be7896d3909bf313

pass=0; fail=0
check() {  # check <name> <expected-sha> <actual-sha>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1: expected $2 got $3" >&2; fi
}
sha() { sha256sum | cut -d' ' -f1; }

check "decode upstream shakespeare.txt.bz3" "$SHAKES_SHA" "$("$BZ" -d < "$EX/shakespeare.txt.bz3" | sha)"
check "encode 65-byte file (known compressed bytes)" "$SMALL_ENC_SHA" "$("$BZ" -e -b 1 < "$EX/standard_test_files/65_byte_file.bin" | sha)"
check "roundtrip 65-byte file" "$SMALL_SHA" "$("$BZ" -e -b 1 < "$EX/standard_test_files/65_byte_file.bin" | "$BZ" -d | sha)"
check "encode shakespeare.txt (known compressed bytes)" "$SHAKES_ENC_SHA" "$("$BZ" -e -b 1 < "$EX/shakespeare.txt" | sha)"
check "encode shakespeare.txt, 2 jobs (same bytes)" "$SHAKES_ENC_SHA" "$("$BZ" -e -j 2 -b 1 < "$EX/shakespeare.txt" | sha)"
check "roundtrip LZP/RLE-heavy input" "$REP_SHA" "$("$BZ" -e -b 1 < "$SRC/mayhem/round_trip/testsuite/rep.bin" | "$BZ" -d | sha)"
check "encode LZP/RLE-heavy input (known compressed bytes)" "$REP_ENC_SHA" "$("$BZ" -e -b 1 < "$SRC/mayhem/round_trip/testsuite/rep.bin" | sha)"

# A truncated archive must be rejected and must not yield the original data.
head -c 100000 "$EX/shakespeare.txt.bz3" > "${TMPDIR:-/tmp}/bzip3-trunc.bz3"
if "$BZ" -t < "${TMPDIR:-/tmp}/bzip3-trunc.bz3" >/dev/null 2>&1; then
  fail=$((fail+1)); echo "FAIL truncated archive accepted" >&2
else pass=$((pass+1)); echo "ok   truncated archive rejected"; fi
rm -f "${TMPDIR:-/tmp}/bzip3-trunc.bz3"

emit_ctrf "bzip3-kat" "$pass" "$fail" 0
