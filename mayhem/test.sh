#!/usr/bin/env bash
#
# cockroachdb/mayhem/test.sh — behavioral oracle for the cockroach fuzz targets.
#
# Oracle approach (SPEC §6.3, anti-reward-hacking):
#
# Part 1 — Go test suite for pkg/util/uuid and pkg/sql/pgcrypto/pgcryptocipher.
#   Run `go test -json` on both packages. These are statically-linked Go binaries; the
#   LD_PRELOAD sabotage mechanism cannot neuter a static binary. However, the `go` toolchain
#   binary at /opt/toolchains/go/bin/go IS dynamically linked and will be neutered by the
#   sabotage LD_PRELOAD (it's not in /usr/bin or /bin). When sabotaged, `go test` exits 0
#   with no output, so the event count is 0 — which would make this part pass vacuously.
#   That's why Part 2 is essential.
#
# Part 2 — Fuzz binary behavioral probe (dynamically-linked, sabotage-detectable).
#   Run /mayhem/fuzzuuid on a known-valid UUID string. libFuzzer emits "Executed ... in"
#   when the input is processed. If the binary is neutered (sabotage LD_PRELOAD), it exits 0
#   without processing the input, so "Executed" is absent → FAILED increments → oracle detects
#   the neutering. This probe is UNCONDITIONAL — missing binary or seed ⇒ FAIL.
#
# The combination: go test (static, behavioral on real inputs) + fuzz probe (dynamic,
# sabotage-detectable) = oracle that asserts known-input → known-output AND fails when the
# fuzz program is neutered.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

PASSED=0; FAILED=0; SKIPPED=0

# ── Part 1: Go test suites (uuid + pgcryptocipher) ─────────────────────────────────────────────
if command -v go >/dev/null 2>&1; then
  echo "=== running: go test -json ./pkg/util/uuid/... ./pkg/sql/pgcrypto/pgcryptocipher/..."
  JSON="$SRC/mayhem-build/gotest.json"
  mkdir -p "$SRC/mayhem-build"
  # Run tests on the two buildable packages; -count=1 disables caching.
  go test -json -count=1 \
      ./pkg/util/uuid/... \
      ./pkg/sql/pgcrypto/pgcryptocipher/... \
      > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

  go test -count=1 \
      ./pkg/util/uuid/... \
      ./pkg/sql/pgcrypto/pgcryptocipher/... \
      2>&1 | tail -20 || true
  [ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

  count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
  P=$(count_act pass); F=$(count_act fail); S=$(count_act skip)
  : "${P:=0}" "${F:=0}" "${S:=0}"
  PASSED=$(( PASSED + P )); FAILED=$(( FAILED + F )); SKIPPED=$(( SKIPPED + S ))
  if [ "$(( P + F + S ))" -eq 0 ]; then
    echo "no test events parsed from go test (rc=$rc) — continuing to probe" >&2
    # Don't add passed/failed here — let the probe section decide.
  fi
  if [ "$rc" -ne 0 ] && [ "$F" -eq 0 ] && [ "$(( P + F + S ))" -gt 0 ]; then
    FAILED=$(( FAILED + 1 ))
  fi
else
  echo "go not available — skipping go test, relying on probe" >&2
fi

# ── Part 2: fuzzuuid behavioral probe (UNCONDITIONAL — missing binary/seed ⇒ FAIL) ──────────────
# Run the dynamically-linked fuzz binary on a known-valid UUID seed.
# libFuzzer emits "Executed N in M us" when it processes the input.
# Under LD_PRELOAD sabotage, the binary exits 0 immediately → no "Executed" → PROBE FAIL.
PROBE_INPUT="$SRC/mayhem/testsuite/fuzzuuid/seed-4a5e1e4b.bin"
echo "=== behavioral probe: fuzzuuid on known UUID seed ==="
if [ ! -x /mayhem/fuzzuuid ]; then
  echo "PROBE FAIL: /mayhem/fuzzuuid not found or not executable"
  FAILED=$(( FAILED + 1 ))
elif [ ! -f "$PROBE_INPUT" ]; then
  echo "PROBE FAIL: seed file $PROBE_INPUT not found"
  FAILED=$(( FAILED + 1 ))
else
  PROBE_OUT=$(/mayhem/fuzzuuid "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzzuuid processed the UUID input (parser active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzzuuid produced no 'Executed' output (sabotaged or broken)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

# ── Part 3: fuzzEncryptDecryptAES behavioral probe ──────────────────────────────────────────────
# Run the AES cipher fuzz binary on a known plaintext/key/iv seed.
PROBE_AES="$SRC/mayhem/testsuite/fuzzEncryptDecryptAES/seed-aes.bin"
echo "=== behavioral probe: fuzzEncryptDecryptAES on known AES seed ==="
if [ ! -x /mayhem/fuzzEncryptDecryptAES ]; then
  echo "PROBE FAIL: /mayhem/fuzzEncryptDecryptAES not found or not executable"
  FAILED=$(( FAILED + 1 ))
elif [ ! -f "$PROBE_AES" ]; then
  echo "PROBE FAIL: AES seed file $PROBE_AES not found"
  FAILED=$(( FAILED + 1 ))
else
  PROBE_OUT=$(/mayhem/fuzzEncryptDecryptAES "$PROBE_AES" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzzEncryptDecryptAES processed the AES input (cipher active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzzEncryptDecryptAES produced no 'Executed' output (sabotaged or broken)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
