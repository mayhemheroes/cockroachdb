# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — cockroachdb/cockroach OSS-Fuzz integration.
#
# Targets built (7):
#   /mayhem/fuzzuuid                       pkg/util/uuid (legacy go-fuzz)
#   /mayhem/fuzzEncryptDecryptAES          pkg/sql/pgcrypto/pgcryptocipher
#   /mayhem/fuzzNoPaddingEncryptDecryptAES pkg/sql/pgcrypto/pgcryptocipher
#   /mayhem/fuzzSessionIDEncoding          pkg/sql/sqlliveness/slstorage
#   /mayhem/fuzzBtreeFrontier              pkg/util/span
#   /mayhem/fuzzEngineKeysInvariants       pkg/storage
#   /mayhem/fuzzPrettyPrint                pkg/keys
#
# NOTE: FuzzLLRBFrontier was removed from upstream in commit
# 8ff17db7405 ("span: remove llrb frontier") — it no longer exists.
# FuzzPrettyPrint (pkg/keys) fills the 7th slot.
#
# DESIGN — Option B (Bazel runs ONCE online in image-build; build.sh is offline):
#   1. ONLINE (this Dockerfile, image-build time, network available):
#      - Install Java + bazelisk + Go fuzz tools
#      - COPY full source into /mayhem
#      - Create minimal docs/generated/metrics stub (excluded by .dockerignore)
#        so Bazel's dependency graph can be fully analyzed
#      - bazel run pkg/gen:code  →  generates ALL .pb.go + other generated Go code
#      - Apply OSS-Fuzz source fixups (rm fuzz.go, rename frontier_test.go)
#      - go mod download  →  bakes complete GOMODCACHE into image
#      - bazel clean --expunge  →  removes the multi-GB Bazel cache
#   2. OFFLINE (build.sh, --network none re-run):
#      - Only go114-fuzz-build / go-118-fuzz-build (= pure go build)
#      - Uses baked generated .pb.go + baked GOMODCACHE; fetches nothing
#
# Build (from the checkout root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       -t cockroachdb-7:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake as ENV — empty value breaks clang.
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# ── Go 1.26.4 — SHA256-pinned ─────────────────────────────────────────────────────────────────
# cockroach go.mod requires go 1.26.2; install 1.26.4 (satisfies ≥).
ARG GO_VERSION=1.26.4
ARG GO_SHA256=1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f

ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/bin:/usr/bin:/bin

# ─── Phase 1: root — install toolchains + run Bazel codegen ──────────────────────────────────

USER root

# Java is required by Bazel 7.x.
# Debian trixie ships openjdk-21; default-jre-headless installs the distro default.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        default-jre-headless \
        python3 \
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/*

# ── Install Go + go-fuzz build tools ─────────────────────────────────────────────────────────
RUN install -d /opt/toolchains/go-path \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
    && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && go version \
    && go install github.com/mdempsky/go114-fuzz-build@latest \
    && ln -sf "$(go env GOPATH)/bin/go114-fuzz-build" "$(go env GOPATH)/bin/go-fuzz" \
    && go install github.com/AdamKorcz/go-118-fuzz-build@latest \
    && go clean -cache 2>/dev/null || true

# ── Install cockroachdb/bazelisk (respects .bazelversion = cockroachdb/7.6.0) ───────────────
# SHA256-pinned from the CockroachDB CI Dockerfile (build/bazelbuilder/Dockerfile).
RUN curl -fsSL \
    "https://github.com/cockroachdb/bazelisk/releases/download/2025-07-14/bazelisk-linux-amd64" \
    -o /usr/local/bin/bazelisk \
    && echo "84916c44c8d81cb64f6c9a9f8fd8fa059342e872bfc1ce185f5dcbf70c6aadea  /usr/local/bin/bazelisk" \
    | sha256sum -c - \
    && chmod +x /usr/local/bin/bazelisk \
    && ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel

# ── Copy full source tree into /mayhem ────────────────────────────────────────────────────────
COPY --chown=root:root . /mayhem
WORKDIR /mayhem

# Bazel uses HOME for its local state; pin to /root (running as root).
ENV HOME=/root \
    XDG_CACHE_HOME=/root/.cache

# ── Stub docs/generated/metrics (excluded by .dockerignore; needed by Bazel analysis) ───────
# pkg/gen:code → :misc → //pkg/roachprod/agents/opentelemetry:cockroachdb_metrics
#             → //docs/generated/metrics:metrics.yaml
# The real BUILD.bazel would build cockroach-short to generate metrics.yaml (very heavy).
# We replace it with a minimal exports_files stub so Bazel can analyze the graph.
# The resulting cockroachdb_metrics.yaml is wrong but our fuzz targets don't import it.
RUN mkdir -p docs/generated/metrics \
    && printf 'exports_files(["metrics.yaml"], visibility = ["//visibility:public"])\n' \
       > docs/generated/metrics/BUILD.bazel \
    && printf 'metrics: []\n' > docs/generated/metrics/metrics.yaml

# ── Bazel codegen + CGO pre-compilation (ONLINE — Bazel only runs here) ─────────────────────
# Step 1: pkg/gen:code — generates ALL .pb.go files from 182+ .proto sources.
# Step 2: generate-cgo — builds libjemalloc, libproj, libkrb5 via Bazel and writes
#         zcgo_flags.go into pkg/{server/status,geo/geoproj,cli,...}, plus copies
#         the compiled static libraries to /mayhem/bin/c-deps/.
#         generate-cgo places SYMLINKS in bin/c-deps pointing into the Bazel output
#         base. We dereference them to real directories immediately, before the cache
#         is deleted; otherwise the symlinks become dangling after bazel clean.
# Source fixups per OSS-Fuzz build.sh:
#   - rm pkg/sql/pgwire/fuzz.go  — outdated gofuzz file causes compile errors
#   - mv frontier_test.go → frontier_test_fuzz.go  — exposes helper functions to go-118-fuzz-build
# After codegen: expunge Bazel cache (several GB) and workspace symlinks.
RUN bazel run pkg/gen:code \
    && bazel run pkg/cmd/generate-cgo:generate-cgo --run_under "cd /mayhem && " \
    && for f in bin/c-deps/*; do \
           if [ -L "$f" ]; then \
               src=$(readlink -f "$f") \
               && name=$(basename "$f") \
               && rm "$f" \
               && cp -r "$src" "bin/c-deps/$name"; \
           fi; \
       done \
    && rm -f pkg/sql/pgwire/fuzz.go \
    && mv pkg/util/span/frontier_test.go pkg/util/span/frontier_test_fuzz.go \
    && bazel clean --expunge 2>/dev/null || true \
    && rm -rf /root/.cache/bazel /root/.cache/bazelisk 2>/dev/null || true \
    && find /mayhem -maxdepth 1 -name '_bazel' -type d -exec rm -rf {} + 2>/dev/null || true \
    && chown -R 2000:2000 /opt/toolchains/go-path

# ── Pre-bake Go module cache (offline re-run uses file:// GOPROXY) ───────────────────────────
RUN GOPROXY="https://proxy.golang.org,direct" go mod download 2>&1 | tail -5 \
    && GOPROXY="https://proxy.golang.org,direct" \
       go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -3 || true \
    && go clean -testcache 2>/dev/null || true \
    && chown -R 2000:2000 /opt/toolchains/go-path /mayhem

# ─── Phase 2: mayhem user — offline compile ───────────────────────────────────────────────────

USER mayhem
WORKDIR /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
