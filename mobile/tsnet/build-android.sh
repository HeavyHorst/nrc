#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${ANDROID_HOME:?Set ANDROID_HOME to an Android SDK with platform 35 and an installed NDK}"
export GOMAXPROCS="${GOMAXPROCS:-2}"
export GOFLAGS="${GOFLAGS:--p=2}"
mkdir -p build/tools
export GOBIN="$PWD/build/tools"
export PATH="$GOBIN:$PATH"
# The versions of both generators live in go.mod, not in global Go tooling.
go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
gomobile bind -target=android/arm64 -androidapi=26 -o build/tailnet.aar .
