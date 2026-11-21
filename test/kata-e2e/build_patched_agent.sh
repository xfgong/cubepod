#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/test/kata-e2e/versions.env"

OUT_BIN=${1:?Usage: build_patched_agent.sh <output-kata-agent-path>}
PATCH_FILE="$ROOT/test/kata-e2e/patches/0001-agent-wait-for-non-zero-capacity-on-virtio-mmio.patch"
[[ -f "$PATCH_FILE" ]] || { echo "Missing patch file: $PATCH_FILE" >&2; exit 1; }

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential clang file gperf libprotobuf-dev musl-tools pkg-config protobuf-compiler

WORKDIR=$(mktemp -d /tmp/cubepod-kata-agent-build.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# Build static musl libseccomp matching Kata 4.4.0 static-build/agent
curl -fsSL --retry 3 https://github.com/seccomp/libseccomp/releases/download/v2.5.5/libseccomp-2.5.5.tar.gz \
  | tar -xz -C "$WORKDIR"
(
  cd "$WORKDIR/libseccomp-2.5.5"
  CFLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=1 -O2" \
    ./configure --prefix="$WORKDIR/seccomp" --enable-static --disable-shared
  make -j"$(nproc)"
  make install
)

git clone --depth 1 --branch "$KATA_VERSION" https://github.com/kata-containers/kata-containers.git "$WORKDIR/kata"
git -C "$WORKDIR/kata" apply -v "$PATCH_FILE"

rustup toolchain install 1.97 --profile minimal --target x86_64-unknown-linux-musl

(
  cd "$WORKDIR/kata"
  export RUSTUP_TOOLCHAIN=1.97
  export LIBSECCOMP_LINK_TYPE=static
  export LIBSECCOMP_LIB_PATH="$WORKDIR/seccomp/lib"
  export PKG_CONFIG_PATH="$WORKDIR/seccomp/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  make -C src/agent LIBC=musl BUILD_TYPE=release SECCOMP=yes INIT_DATA=yes AGENT_POLICY=no USE_DEVMAPPER=no
)

BUILT_BIN="$WORKDIR/kata/target/x86_64-unknown-linux-musl/release/kata-agent"
[[ -x "$BUILT_BIN" ]] || { echo "Expected built kata-agent at $BUILT_BIN" >&2; exit 1; }
file "$BUILT_BIN" | tee /dev/stderr | grep -q "statically linked"

mkdir -p "$(dirname "$OUT_BIN")"
install -m 0755 "$BUILT_BIN" "$OUT_BIN"
sha256sum "$OUT_BIN"
