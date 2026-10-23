#!/usr/bin/env bash
# Coverage-guided fuzzing for the protocol request parsers.
#
# Odin cannot drive libFuzzer directly, so the package is emitted as LLVM IR and
# linked against clang's libFuzzer + AddressSanitizer runtimes. Odin's own
# `-sanitize:address` instruments the parser code, because clang does not re-run
# the ASan pass on IR input; clang only adds the sanitizer-coverage pass.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

package="test/protocol_fuzz"
seeds="$repo_root/$package/corpus"
artifacts="$repo_root/$package/artifacts"
build_dir="${NRC_FUZZ_BUILD_DIR:-$repo_root/$package/.build}"
corpus="${NRC_FUZZ_CORPUS:-$build_dir/corpus}"
seconds=60
runs=""
replay_file=""
mode=run
extra=()

usage() {
	cat <<'EOF'
Usage: ./test/run_protocol_fuzz.sh [options] [-- libFuzzer flags]

Builds the fuzzer, then fuzzes for a bounded time (default 60 seconds).

  --build              build the fuzzer binary and stop
  --seeds              regenerate test/protocol_fuzz/corpus from the serializers
  --check-seeds        fail if the committed corpus differs from the serializers
  --seconds N          fuzz for N seconds (default 60)
  --runs N             fuzz for N runs instead of a time budget
  --corpus DIR         working corpus (default $NRC_FUZZ_BUILD_DIR/corpus)
  --artifacts DIR      crash artifact directory (default test/protocol_fuzz/artifacts)
  --replay FILE        re-run one input (a libFuzzer crash artifact) and exit
  --                   pass the remaining arguments to libFuzzer

Environment:
  ODIN_BIN             Odin binary (default: odin)
  CLANG                clang binary; needs LLVM 19+ to read Odin's IR
  NRC_FUZZ_BUILD_DIR   build output directory
  NRC_FUZZ_CORPUS      working corpus directory
  NRC_FUZZ_MAX_LEN     maximum input length (default: 8192)
EOF
}

while (($#)); do
	case "$1" in
		--build) mode=build ;;
		--seeds) mode=seeds ;;
		--check-seeds) mode=check-seeds ;;
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

odin_bin="${ODIN_BIN:-odin}"
command -v "$odin_bin" >/dev/null 2>&1 || {
	echo "Odin not found; set ODIN_BIN" >&2
	exit 1
}

# The corpus generator is an ordinary Odin program: no sanitizer runtime needed.
if [[ "$mode" == seeds || "$mode" == check-seeds ]]; then
	mkdir -p "$build_dir"
	"$odin_bin" build "$package" -out:"$build_dir/seedgen"
	if [[ "$mode" == seeds ]]; then
		"$build_dir/seedgen" "-nrc-write-seeds=$seeds"
		exit 0
	fi
	# Regenerating must reproduce the committed corpus exactly, so a serializer
	# or parser change cannot leave the corpus stale.
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/nrc-seeds.XXXXXXXX")"
	trap 'rm -rf "$scratch"' EXIT
	"$build_dir/seedgen" "-nrc-write-seeds=$scratch" >/dev/null
	if ! diff -r "$seeds" "$scratch"; then
		echo "The committed corpus no longer matches the protocol serializers." >&2
		echo "Run ./test/run_protocol_fuzz.sh --seeds and review the change." >&2
		exit 1
	fi
	echo "Committed corpus matches the protocol serializers."
	exit 0
fi

# Odin emits opaque-pointer IR, which clang only reads from version 15 on.
pick_clang() {
	local candidate version
	for candidate in "${CLANG:-}" clang-21 clang-20 clang-19 clang-18 clang-17 clang-16 clang-15 clang; do
		[[ -n "$candidate" ]] || continue
		command -v "$candidate" >/dev/null 2>&1 || continue
		version="$("$candidate" -dumpversion 2>/dev/null | cut -d. -f1)"
		[[ "$version" =~ ^[0-9]+$ ]] || continue
		((version >= 15)) || continue
		printf '%s' "$candidate"
		return 0
	done
	return 1
}

clang_bin="$(pick_clang)" || {
	echo 'No clang >= 15 found. Install clang and libclang-rt (Debian/Ubuntu: clang-19 libclang-rt-19-dev).' >&2
	exit 1
}
clang_major="$("$clang_bin" -dumpversion | cut -d. -f1)"

llvm_link=""
for candidate in "llvm-link-$clang_major" llvm-link; do
	if command -v "$candidate" >/dev/null 2>&1; then
		llvm_link="$candidate"
		break
	fi
done
[[ -n "$llvm_link" ]] || {
	echo "llvm-link-$clang_major not found; install the matching llvm-$clang_major package." >&2
	exit 1
}

machine="$(uname -m)"
resource_dir="$("$clang_bin" -print-resource-dir)"
fuzzer_runtime=""
for candidate in \
	"$resource_dir/lib/$machine/libclang_rt.fuzzer_no_main-$machine.a" \
	"$resource_dir/lib/linux/libclang_rt.fuzzer_no_main-$machine.a"; do
	if [[ -f "$candidate" ]]; then
		fuzzer_runtime="$candidate"
		break
	fi
done
if [[ -z "$fuzzer_runtime" ]]; then
	fuzzer_runtime="$(find "$resource_dir/lib" -name "libclang_rt.fuzzer_no_main-$machine.a" -print -quit 2>/dev/null || true)"
fi
[[ -n "$fuzzer_runtime" ]] || {
	echo "libFuzzer runtime not found under $resource_dir/lib" >&2
	echo 'Install the clang runtime package (Debian/Ubuntu: libclang-rt-19-dev).' >&2
	exit 1
}

binary="$build_dir/protocol_fuzz"
ir_dir="$build_dir/ir"
mkdir -p "$build_dir" "$ir_dir" "$artifacts"

build() {
	echo "Building $package with $odin_bin and $clang_bin ($llvm_link)"
	rm -f "$ir_dir"/*.ll
	"$odin_bin" build "$package" \
		-build-mode:llvm-ir -sanitize:address -debug \
		-define:NRC_LIBFUZZER=true -out:"$ir_dir"
	# Odin's nightly IR uses LLVM 19 debug records (#dbg_declare), which older
	# LLVM releases reject with "expected instruction opcode".
	if ! "$llvm_link" -S "$ir_dir"/*.ll -o "$build_dir/combined.ll"; then
		echo >&2
		echo "$llvm_link cannot read Odin's IR. Odin emits LLVM 19 debug records (#dbg_declare)," >&2
		echo "so $clang_bin (LLVM $clang_major) is too old; install clang-19 or newer." >&2
		exit 1
	fi
	# Odin already instrumented the IR for ASan. Compiling the object with only
	# the fuzzer coverage pass avoids a second, corrupting ASan pass.
	"$clang_bin" -c -O1 -g -fsanitize=fuzzer-no-link \
		-o "$build_dir/combined.o" "$build_dir/combined.ll"
	"$clang_bin" -fsanitize=fuzzer-no-link,address -g -O1 -o "$binary" \
		"$build_dir/combined.o" "$fuzzer_runtime" -lstdc++ -lpthread -ldl -lm
}

build
if [[ "$mode" == build ]]; then
	exit 0
fi

export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1:symbolize=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1}"
max_len="${NRC_FUZZ_MAX_LEN:-8192}"

if [[ "$mode" == replay ]]; then
	[[ -f "$replay_file" ]] || {
		echo "no such input: $replay_file" >&2
		exit 1
	}
	echo "Replaying $replay_file"
	"$binary" -runs=1 "$replay_file"
	exit $?
fi

# The committed corpus stays a curated seed set; campaigns grow a working copy.
# Named seeds are always overwritten so that a regenerated seed replaces the
# stale copy a previous campaign left behind.
mkdir -p "$corpus"
if [[ "$corpus" != "$seeds" ]]; then
	for seed in "$seeds"/*.bin; do
		[[ -f "$seed" ]] || continue
		cp -f "$seed" "$corpus/" || {
			echo "failed to copy $seed into $corpus" >&2
			exit 1
		}
	done
fi
seed_count="$(find "$corpus" -maxdepth 1 -type f | wc -l)"
((seed_count > 0)) || echo "warning: $corpus has no seeds; run --seeds first" >&2

budget=(-max_len="$max_len" -print_final_stats=1 -artifact_prefix="$artifacts/")
if [[ -n "$runs" ]]; then
	budget+=(-runs="$runs")
else
	budget+=(-max_total_time="$seconds")
fi

if [[ -n "$runs" ]]; then
	echo "Fuzzing $corpus with $seed_count seeds for $runs runs"
else
	echo "Fuzzing $corpus with $seed_count seeds for ${seconds}s"
fi
set +e
"$binary" "${budget[@]}" "${extra[@]}" "$corpus"
status=$?
set -e

if ((status != 0)); then
	echo
	echo "libFuzzer exited with status $status." >&2
	echo "Artifacts are in $artifacts; reproduce with:" >&2
	for artifact in "$artifacts"/crash-* "$artifacts"/leak-* "$artifacts"/timeout-* "$artifacts"/oom-*; do
		[[ -f "$artifact" ]] || continue
		echo "  ./test/run_protocol_fuzz.sh --replay $artifact" >&2
	done
	exit "$status"
fi
echo "No crash found in the bounded campaign."
