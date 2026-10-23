#!/usr/bin/env bash
# Coverage-guided fuzzing for the shared JS protocol decoder.
#
# The target is client/fuzz/protocol.fuzz.cjs, which drives the shared
# client/protocol.js and client/frames.js decoders with the same server frames
# the Odin and Go fuzzers use. This
# tier is opt-in because it installs Jazzer.js and its native addon; the normal
# node --test tier runs client/protocol-fuzz.test.mjs instead.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fuzz_dir="$repo_root/client/fuzz"
target="$fuzz_dir/protocol.fuzz.cjs"
seed_builder="$fuzz_dir/seed-corpus.cjs"
build_dir="${NRC_JS_FUZZ_BUILD_DIR:-$fuzz_dir/.build}"
corpus="${NRC_JS_FUZZ_CORPUS:-$build_dir/corpus}"
artifacts="$fuzz_dir/artifacts"
seconds=60
runs=""
replay_file=""
mode=run
extra=()

usage() {
	cat <<'EOF'
Usage: ./test/run_js_protocol_fuzz.sh [options] [-- libFuzzer flags]

Builds the JS working corpus from test/protocol_fuzz/corpus and
client/fuzz/corpus, then fuzzes the shared client decoders for a bounded time
(default 60 seconds).

  --install            install client/fuzz dependencies and stop
  --seeds              rebuild the working corpus and stop
  --seconds N          fuzz for N seconds (default 60)
  --runs N             fuzz for N runs instead of a time budget
  --corpus DIR         working corpus (default client/fuzz/.build/corpus)
  --artifacts DIR      crash artifact directory (default client/fuzz/artifacts)
  --replay FILE        re-run one input and exit
  --                   pass the remaining arguments to libFuzzer

Environment:
  NRC_JS_FUZZ_BUILD_DIR   working corpus parent directory
  NRC_JS_FUZZ_CORPUS      working corpus directory
  NRC_JS_FUZZ_MAX_LEN     maximum input length (default: 131072)
  JAZZER_BIN              jazzer executable (default: client/fuzz/node_modules/.bin/jazzer)
EOF
}

while (($#)); do
	case "$1" in
		--install) mode=install ;;
		--seeds) mode=seeds ;;
		--seconds) seconds="$2"; shift ;;
		--runs) runs="$2"; shift ;;
		--corpus) corpus="$2"; shift ;;
		--artifacts) artifacts="$2"; shift ;;
		--replay) mode=replay; replay_file="$2"; shift ;;
		-h | --help) usage; exit 0 ;;
		--) shift; extra=("$@"); break ;;
		*)
			echo "unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

command -v node >/dev/null 2>&1 || {
	echo "Node.js not found" >&2
	exit 1
}

jazzer="${JAZZER_BIN:-$fuzz_dir/node_modules/.bin/jazzer}"

install_dependencies() {
	echo "Installing client/fuzz dependencies"
	if [[ -f "$fuzz_dir/package-lock.json" ]]; then
		npm ci --prefix "$fuzz_dir" --no-audit --no-fund
	else
		npm install --prefix "$fuzz_dir" --no-audit --no-fund
	fi
}

if [[ "$mode" == install ]]; then
	install_dependencies
	exit 0
fi

if [[ ! -x "$jazzer" ]]; then
	install_dependencies
fi
[[ -x "$jazzer" ]] || {
	echo "jazzer not found at $jazzer; run with --install" >&2
	exit 1
}

build_corpus() {
	mkdir -p "$build_dir"
	node "$seed_builder" "$corpus"
}

if [[ "$mode" == seeds ]]; then
	build_corpus
	exit 0
fi

if [[ "$mode" == replay ]]; then
	[[ -f "$replay_file" ]] || {
		echo "no such input: $replay_file" >&2
		exit 1
	}
	echo "Replaying $replay_file"
	"$jazzer" "$target" --sync -- -runs=1 "$replay_file"
	exit $?
fi

build_corpus
mkdir -p "$artifacts"

budget=(-max_len="${NRC_JS_FUZZ_MAX_LEN:-131072}" -print_final_stats=1 -artifact_prefix="$artifacts/")
if [[ -n "$runs" ]]; then
	budget+=(-runs="$runs")
else
	budget+=(-max_total_time="$seconds")
fi

if [[ -n "$runs" ]]; then
	echo "Fuzzing $corpus for $runs runs"
else
	echo "Fuzzing $corpus for ${seconds}s"
fi
set +e
"$jazzer" "$target" --sync --timeout=2000 -- "${budget[@]}" "${extra[@]}" "$corpus"
status=$?
set -e

if ((status != 0)); then
	echo
	echo "Jazzer exited with status $status." >&2
	echo "Artifacts are in $artifacts; reproduce with:" >&2
	for artifact in "$artifacts"/crash-* "$artifacts"/timeout-* "$artifacts"/oom-*; do
		[[ -f "$artifact" ]] || continue
		echo "  ./test/run_js_protocol_fuzz.sh --replay $artifact" >&2
	done
	exit "$status"
fi
echo "No crash found in the bounded campaign."
