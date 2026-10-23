#!/usr/bin/env bash
# Linux: prove TLSF poisoning is effective before trusting real io_uring tests.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nrc-asan.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Do not inherit options that could suppress failures or redirect diagnostics.
export ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:abort_on_error=0:exitcode=86
names=main.test_linux_connection_close_barrier_deferred_send
names+=,main.test_linux_connection_close_barrier_deferred_writev
names+=,main.test_linux_connection_close_barrier_deferred_shutdown
names+=,main.test_linux_connection_close_barrier_partial_send
names+=,main.test_linux_connection_close_barrier_partial_writev

for quarantine in false true; do
	echo "ASan checks: TLSF_ASAN_QUARANTINE=$quarantine"
	flags=(-sanitize:address -debug -define:TLSF_ASAN_QUARANTINE="$quarantine" -define:TLSF_CHECK_INVARIANTS=true)
	"${ODIN_BIN:-odin}" build test/asan_probe "${flags[@]}" -out:"$scratch/probe"
	"$scratch/probe" valid
	probes=(use-after-free overflow shrink shrink-non-zeroed free-all)
	if [[ "$quarantine" == true ]]; then
		probes+=(reuse)
	else
		"$scratch/probe" reuse
		echo 'Control: stale access after immediate reuse is undetected without quarantine.'
	fi
	for probe in "${probes[@]}"; do
		status=0
		"$scratch/probe" "$probe" >"$scratch/$probe.log" 2>&1 || status=$?
		expected=use-after-poison
		if [[ "$status" != 86 ]] || ! grep -q "ERROR: AddressSanitizer: $expected" "$scratch/$probe.log"; then
			cat "$scratch/$probe.log"
			echo "FAIL: $probe did not produce the required ASan diagnostic (exit $status)" >&2
			exit 1
		fi
		echo "Detected $probe: AddressSanitizer: $expected (exit $status)"
	done
	assertion_probes=(corrupt-size corrupt-neighbor corrupt-list corrupt-class corrupt-bitmap corrupt-head corrupt-next corrupt-prev)
	if [[ "$quarantine" == true ]]; then
		assertion_probes+=(double-free resize-freed resize-freed-non-zeroed)
	fi
	for probe in "${assertion_probes[@]}"; do
		case "$probe" in
			corrupt-size) expected='TLSF invariant: block size' ;;
			corrupt-neighbor) expected='TLSF invariant: previous-free flag' ;;
			corrupt-list) expected='TLSF invariant: duplicate or cyclic free-list member' ;;
			corrupt-class) expected='TLSF invariant: size class' ;;
			corrupt-bitmap) expected='TLSF invariant: first-level bitmap' ;;
			corrupt-head|corrupt-next) expected='TLSF invariant: free-list member' ;;
			corrupt-prev) expected='TLSF invariant: previous free-list link' ;;
			*) expected='block already quarantined' ;;
		esac
		status=0
		{ timeout 10s "$scratch/probe" "$probe"; } >"$scratch/$probe.log" 2>&1 || status=$?
		if [[ "$status" == 0 || "$status" == 124 ]] || ! grep -Fq "runtime assertion: $expected" "$scratch/$probe.log"; then
			cat "$scratch/$probe.log"
			echo "FAIL: $probe did not produce the required assertion (exit $status)" >&2
			exit 1
		fi
		echo "Detected $probe: $expected"
	done
	./test/run_odin_tests.sh vendor/tlsf/ "${flags[@]}" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
	./test/run_odin_tests.sh . "${flags[@]}" \
		-define:ODIN_TEST_TRACK_MEMORY=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
		-define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES="$names"
done
echo 'ASan detector, allocator and real io_uring checks passed with and without quarantine.'
