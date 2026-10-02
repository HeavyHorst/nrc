#!/usr/bin/env bash

set -euo pipefail

# Print only the absolute library path on stdout so test runners can export it.
if [[ -n "${HEGEL_LIBHEGEL_PATH:-}" ]]; then
	if [[ ! -f "$HEGEL_LIBHEGEL_PATH" ]]; then
		echo "HEGEL_LIBHEGEL_PATH is not a regular file: $HEGEL_LIBHEGEL_PATH" >&2
		exit 1
	fi
	printf '%s/%s\n' "$(cd "$(dirname "$HEGEL_LIBHEGEL_PATH")" && pwd)" "$(basename "$HEGEL_LIBHEGEL_PATH")"
	exit 0
fi

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
	echo "Automatic libhegel download supports Linux amd64; set HEGEL_LIBHEGEL_PATH for other platforms." >&2
	exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version=0.33.3
sha256=1ceb1636f3dd8e939fef88e99e3417b9da23675c7847e4cb22717ca8834c699b
cache="$repo_root/.hegel/libhegel-$version"
library="$cache/libhegel-linux-amd64.so"

if [[ -f "$library" ]]; then
	if ! printf '%s  %s\n' "$sha256" "$library" | sha256sum --check --status; then
		echo "Cached libhegel failed SHA256 verification: $library; remove it and retry." >&2
		exit 1
	fi
else
	mkdir -p "$cache"
	temporary="$(mktemp "$cache/.download.XXXXXXXX")"
	trap 'rm -f "$temporary"' EXIT
	echo "Downloading libhegel $version for tests" >&2
	curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
		--connect-timeout 15 --max-time 180 --retry 3 \
		"https://github.com/hegeldev/hegel-rust/releases/download/v$version/libhegel-linux-amd64.so" \
		--output "$temporary"
	if ! printf '%s  %s\n' "$sha256" "$temporary" | sha256sum --check --status; then
		echo "Downloaded libhegel failed SHA256 verification; nothing was installed." >&2
		exit 1
	fi
	mv "$temporary" "$library"
fi

printf '%s\n' "$library"
