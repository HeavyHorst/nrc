#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library="$("$repo_root/test/fetch_libhegel.sh")"
export HEGEL_LIBHEGEL_PATH="$library"
hegel_flags=(-define:HEGEL_REQUIRED=true)
for argument in "$@"; do
	if [[ "$argument" == -define:HEGEL_REQUIRED=* ]]; then
		hegel_flags=()
	fi
done

# Preserve the caller's working directory for package paths and test fixtures.
# Let the compiler exit before running tests so its memory is not retained.
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/nrc-tests.XXXXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

"${ODIN_BIN:-odin}" build "$@" "${hegel_flags[@]}" -build-mode:test -out:"$test_dir/nrc-tests"
"$test_dir/nrc-tests"
