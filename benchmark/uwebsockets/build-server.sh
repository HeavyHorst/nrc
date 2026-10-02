#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UWS_DIR="${UWS_DIR:-$SCRIPT_DIR/.deps/uWebSockets}"
UWS_REVISION="${UWS_REVISION:-66dcff3dd48f0c19dd1703426365d062039321d0}"
OUTPUT_BIN="$SCRIPT_DIR/uwebsockets-bench-server"
MANIFEST="$OUTPUT_BIN.manifest.txt"
CC_BIN="${CC:-cc}"
CXX_BIN="${CXX:-g++}"
AR_BIN="${AR:-ar}"

if [[ ! -d "$UWS_DIR" ]]; then
  git clone --no-checkout https://github.com/uNetworking/uWebSockets "$UWS_DIR"
fi

git -C "$UWS_DIR" reset --hard
git -C "$UWS_DIR" submodule foreach --recursive 'git reset --hard; git clean -ffd'
git -C "$UWS_DIR" clean -ffd
git -C "$UWS_DIR" fetch --depth 1 origin "$UWS_REVISION"
git -C "$UWS_DIR" checkout --force --detach "$UWS_REVISION"
git -C "$UWS_DIR" submodule sync --recursive
git -C "$UWS_DIR" submodule update --init --recursive --force --depth 1
git -C "$UWS_DIR" submodule foreach --recursive 'git reset --hard; git clean -ffd'

make -C "$UWS_DIR/uSockets" clean
if [[ -n "$(git -C "$UWS_DIR" status --porcelain --untracked-files=all --ignore-submodules=none)" ]]; then
  echo "uWebSockets dependency checkout is not clean after reset" >&2
  git -C "$UWS_DIR" status --short --untracked-files=all --ignore-submodules=none >&2
  exit 1
fi

USOCKETS_BUILD_ARGS=(
  "CC=$CC_BIN"
  "AR=$AR_BIN"
  "CFLAGS="
  "WITH_LTO=1"
  "WITH_OPENSSL=0"
  "WITH_BORINGSSL=0"
  "WITH_WOLFSSL=0"
  "WITH_IO_URING=0"
  "WITH_LIBUV=0"
  "WITH_ASIO=0"
  "WITH_GCD=0"
  "WITH_ASAN=0"
  "WITH_QUIC=0"
)
make -C "$UWS_DIR/uSockets" "${USOCKETS_BUILD_ARGS[@]}"

CXX_FLAGS=(
  -march=native
  -O3
  -Wpedantic
  -Wall
  -Wextra
  -Wsign-conversion
  -Wconversion
  -std=c++2b
  -pthread
)

"$CXX_BIN" \
  "${CXX_FLAGS[@]}" \
  -I"$UWS_DIR/src" \
  -I"$UWS_DIR/uSockets/src" \
  "$SCRIPT_DIR/server.cpp" \
  "$UWS_DIR"/uSockets/*.o \
  -lz \
  -o "$OUTPUT_BIN"

{
  echo "uwebsockets_revision=$(git -C "$UWS_DIR" rev-parse HEAD)"
  echo "submodules_begin"
  git -C "$UWS_DIR" submodule status --recursive
  echo "submodules_end"
  echo "cc=$CC_BIN"
  echo "cc_version=$($CC_BIN --version | head -1)"
  echo "cxx=$CXX_BIN"
  echo "cxx_version=$($CXX_BIN --version | head -1)"
  echo "ar=$AR_BIN"
  printf 'usockets_make_arg=%q\n' "${USOCKETS_BUILD_ARGS[@]}"
  printf 'cxx_flag=%q\n' "${CXX_FLAGS[@]}"
  echo "server_source_sha256=$(sha256sum "$SCRIPT_DIR/server.cpp" | awk '{print $1}')"
  echo "binary_sha256=$(sha256sum "$OUTPUT_BIN" | awk '{print $1}')"
} >"$MANIFEST"

echo "built: $OUTPUT_BIN"
echo "manifest: $MANIFEST"
