#!/usr/bin/env bash
#
# cockroachdb/mayhem/build.sh — build all 7 cockroachdb OSS-Fuzz targets as
# sanitized libFuzzer binaries.
#
# Targets built (Bazel-generated .pb.go already baked into the image by the Dockerfile):
#   /mayhem/fuzzuuid               — pkg/util/uuid Fuzz (legacy go-fuzz, []byte harness)
#   /mayhem/fuzzEncryptDecryptAES  — pkg/sql/pgcrypto/pgcryptocipher FuzzEncryptDecryptAES
#   /mayhem/fuzzNoPaddingEncryptDecryptAES — same package, FuzzNoPaddingEncryptDecryptAES
#   /mayhem/fuzzSessionIDEncoding  — pkg/sql/sqlliveness/slstorage FuzzSessionIDEncoding
#   /mayhem/fuzzBtreeFrontier      — pkg/util/span FuzzBtreeFrontier
#   /mayhem/fuzzEngineKeysInvariants — pkg/storage FuzzEngineKeysInvariants
#   /mayhem/fuzzPrettyPrint        — pkg/keys FuzzPrettyPrint
#
# NOTE: FuzzLLRBFrontier was removed from upstream in commit 8ff17db7405
# ("span: remove llrb frontier") and does not exist in the current codebase.
# fuzzPrettyPrint (pkg/keys) is included as the 7th target in its place.
# OSS-Fuzz had it commented out due to a go-118-fuzz-build race-condition bug
# that has since been resolved in newer versions of go-118-fuzz-build.
#
# This script is the rebuildable (PATCH-tier) step. Bazel does NOT run here.
# All generated .pb.go files were produced by `bazel run pkg/gen:code` in the
# Dockerfile and are already present in the source tree.
#
# Air-gapped (SPEC §6.5): GOPROXY=file:// prefix serves from the in-image module
# cache populated by `go mod download` in the Dockerfile.
#
# DWARF gate (SPEC §6.2 item 10): CGO shims forced to DWARF3 via GO_DEBUG_FLAGS;
# the final clang++ link also uses GO_DEBUG_FLAGS so the first .debug_info CU is
# DWARF3 → passes the verify-repo <4 check.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# DWARF3 for the C/CGO shim CU (first CU in the binary → passes verify-repo's -m1 check).
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# pkg/geo/geoproj/proj.cc includes <proj_api.h>.  generate-cgo writes the proj
# library path into zcgo_flags.go LDFLAGS but omits the include path (Bazel
# resolves it automatically through CcInfo; plain go build does not).  Add it
# explicitly so the CGO C++ compiler can find proj4 headers.
export CGO_CPPFLAGS="${CGO_CPPFLAGS:+$CGO_CPPFLAGS }-I$SRC/bin/c-deps/archived_cdep_libproj_linux/include"

# Air-gapped contract: resolve from the in-image module cache; fall back to network
# only if the cache is incomplete (should not happen for a correctly-built image).
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

# SRC is the root of the cockroach repo (copied to /mayhem by the Dockerfile).
: "${SRC:=/mayhem}"
cd "$SRC"
go version

mkdir -p "$SRC/mayhem-build"

# Pre-fetch the go-118-fuzz-build testing shim (needed by go-118-fuzz-build internally).
# With GOPROXY=file://..., this resolves from the baked GOMODCACHE in offline mode.
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

# Save go.mod/go.sum so we can restore after each go-fuzz-build run that rewrites them.
cp go.mod /tmp/go.mod.orig
cp go.sum /tmp/go.sum.orig

restore_gomod() {
    cp /tmp/go.mod.orig go.mod
    cp /tmp/go.sum.orig go.sum
}

# ── Target 1: fuzzuuid (legacy go-fuzz / go114-fuzz-build) ───────────────────
echo "=== building fuzzuuid (pkg/util/uuid, go114-fuzz-build, gofuzz) ==="
go-fuzz -tags gofuzz -func Fuzz -o "$SRC/mayhem-build/fuzzuuid.a" \
    github.com/cockroachdb/cockroach/pkg/util/uuid
restore_gomod
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$SRC/mayhem-build/fuzzuuid.a" -o /mayhem/fuzzuuid
echo "built /mayhem/fuzzuuid"

# ── Target 2: fuzzEncryptDecryptAES ──────────────────────────────────────────
echo "=== building fuzzEncryptDecryptAES (pgcryptocipher) ==="
go-118-fuzz-build -func FuzzEncryptDecryptAES \
    -o "$SRC/mayhem-build/fuzzEncryptDecryptAES.a" \
    github.com/cockroachdb/cockroach/pkg/sql/pgcrypto/pgcryptocipher
restore_gomod
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$SRC/mayhem-build/fuzzEncryptDecryptAES.a" -o /mayhem/fuzzEncryptDecryptAES
echo "built /mayhem/fuzzEncryptDecryptAES"

# ── Target 3: fuzzNoPaddingEncryptDecryptAES ──────────────────────────────────
echo "=== building fuzzNoPaddingEncryptDecryptAES (pgcryptocipher) ==="
go-118-fuzz-build -func FuzzNoPaddingEncryptDecryptAES \
    -o "$SRC/mayhem-build/fuzzNoPaddingEncryptDecryptAES.a" \
    github.com/cockroachdb/cockroach/pkg/sql/pgcrypto/pgcryptocipher
restore_gomod
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$SRC/mayhem-build/fuzzNoPaddingEncryptDecryptAES.a" -o /mayhem/fuzzNoPaddingEncryptDecryptAES
echo "built /mayhem/fuzzNoPaddingEncryptDecryptAES"

# ── Target 4: fuzzSessionIDEncoding ──────────────────────────────────────────
echo "=== building fuzzSessionIDEncoding (sqlliveness/slstorage) ==="
go-118-fuzz-build -func FuzzSessionIDEncoding \
    -o "$SRC/mayhem-build/fuzzSessionIDEncoding.a" \
    github.com/cockroachdb/cockroach/pkg/sql/sqlliveness/slstorage
restore_gomod
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$SRC/mayhem-build/fuzzSessionIDEncoding.a" -o /mayhem/fuzzSessionIDEncoding
echo "built /mayhem/fuzzSessionIDEncoding"

# ── Target 5: fuzzBtreeFrontier ───────────────────────────────────────────────
# FuzzBtreeFrontier is in frontier_fuzz_test.go (internal test file, package span).
# frontier_test.go was renamed to frontier_test_fuzz.go in the Dockerfile so its
# helper functions (newSpanMaker etc.) are available as regular package symbols.
echo "=== building fuzzBtreeFrontier (util/span) ==="
go-118-fuzz-build -func FuzzBtreeFrontier \
    -o "$SRC/mayhem-build/fuzzBtreeFrontier.a" \
    github.com/cockroachdb/cockroach/pkg/util/span
restore_gomod
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$SRC/mayhem-build/fuzzBtreeFrontier.a" -o /mayhem/fuzzBtreeFrontier
echo "built /mayhem/fuzzBtreeFrontier"

# ── Target 6: fuzzEngineKeysInvariants ───────────────────────────────────────
echo "=== building fuzzEngineKeysInvariants (storage) ==="
go-118-fuzz-build -func FuzzEngineKeysInvariants \
    -o "$SRC/mayhem-build/fuzzEngineKeysInvariants.a" \
    github.com/cockroachdb/cockroach/pkg/storage
restore_gomod
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$SRC/mayhem-build/fuzzEngineKeysInvariants.a" -o /mayhem/fuzzEngineKeysInvariants
echo "built /mayhem/fuzzEngineKeysInvariants"

# ── Target 7: fuzzPrettyPrint ─────────────────────────────────────────────────
echo "=== building fuzzPrettyPrint (pkg/keys) ==="
go-118-fuzz-build -func FuzzPrettyPrint \
    -o "$SRC/mayhem-build/fuzzPrettyPrint.a" \
    github.com/cockroachdb/cockroach/pkg/keys
restore_gomod
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$SRC/mayhem-build/fuzzPrettyPrint.a" -o /mayhem/fuzzPrettyPrint
echo "built /mayhem/fuzzPrettyPrint"

echo "=== build.sh complete — 7 fuzzers ==="
ls -la /mayhem/fuzzuuid \
        /mayhem/fuzzEncryptDecryptAES \
        /mayhem/fuzzNoPaddingEncryptDecryptAES \
        /mayhem/fuzzSessionIDEncoding \
        /mayhem/fuzzBtreeFrontier \
        /mayhem/fuzzEngineKeysInvariants \
        /mayhem/fuzzPrettyPrint 2>&1 || true
