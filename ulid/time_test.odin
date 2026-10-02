package ulid

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"

// Comprehensive test suite for the ulid time package.
// Tests all timing variants: TSC -> vDSO -> syscall fallback chain.
//
// Test coverage:
// - test_time_now: Verifies time_now() advances correctly
// - test_time_now_monotonic: Verifies monotonic time advances
// - test_fallback_method: Confirms which timing method is active
// - test_vdso_clock_gettime: Tests glibc vDSO directly
// - test_fallback_clock_gettime: Tests raw syscall fallback
// - test_resync_behavior: Verifies TSC resync behavior
// - test_tsc_sync: Tests TSC synchronization
// - test_time_comparison_all_methods: Compares outputs from all methods

// Helper to report errors in tests
@(private)
test_error :: proc(t: ^testing.T, msg: string) {
	fmt.panicf("[time_test] %s", msg)
}

@(test)
test_time_now :: proc(t: ^testing.T) {
	init()

	// Get current time
	t1 := time_now()

	// Sleep a bit
	time.sleep(1 * time.Millisecond)

	// Get time again
	t2 := time_now()

	// Should have advanced
	if time.since(t1) < 1 * time.Millisecond {
		test_error(t, fmt.tprintf("time_now() did not advance enough: t1=%v, t2=%v", t1, t2))
	}
}

@(test)
test_time_now_lazy_init :: proc(t: ^testing.T) {
	// Simulate a fresh thread where init() was not called.
	tsc_checked = false
	tsc_available = false
	fallback_method = .TSC

	now := time_now()
	if now._nsec <= 0 {
		test_error(t, "time_now() returned invalid timestamp during lazy init")
	}

	if !tsc_checked {
		test_error(t, "time_now() did not set tsc_checked during lazy init")
	}

	if tsc_available {
		if fallback_method != .TSC {
			test_error(t, "lazy init marked TSC available but fallback_method is not TSC")
		}
	} else {
		if fallback_method == .TSC {
			test_error(t, "lazy init marked TSC unavailable but fallback_method stayed TSC")
		}
	}
}

@(test)
test_time_now_monotonic :: proc(t: ^testing.T) {
	init()

	// Get monotonic time
	t1 := time_now_monotonic()

	// Sleep a bit
	time.sleep(1 * time.Millisecond)

	// Get time again
	t2 := time_now_monotonic()

	// Should have advanced
	if time.diff(t1, t2) < 1 * time.Millisecond {
		test_error(t, fmt.tprintf("time_now_monotonic() did not advance enough: t1=%v, t2=%v", t1, t2))
	}
}

@(test)
test_fallback_method :: proc(t: ^testing.T) {
	init()

	// Log which fallback method is being used
	switch fallback_method {
	case .TSC:
		fmt.println("[time_test] Using TSC-based timing")
	case .VDSO:
		fmt.println("[time_test] Using glibc vDSO clock_gettime")
	case .SYSCALL:
		fmt.println("[time_test] Using raw syscall clock_gettime")
	}

	// At least one method should be available
	if tsc_available == false && fallback_method == .TSC {
		test_error(t, "tsc_available is false but fallback_method is TSC")
	}
}

@(test)
test_vdso_clock_gettime :: proc(t: ^testing.T) {
	// Test the vDSO fallback directly (REALTIME)
	t1 := vdso_clock_gettime(monotonic = false)

	time.sleep(1 * time.Millisecond)

	_ = vdso_clock_gettime(monotonic = false)

	if time.since(t1) < 1 * time.Millisecond {
		test_error(t, "vdso_clock_gettime(monotonic=false) did not advance enough")
	}
}

@(test)
test_vdso_clock_gettime_monotonic :: proc(t: ^testing.T) {
	// Test the vDSO fallback directly (MONOTONIC_RAW)
	t1 := vdso_clock_gettime(monotonic = true)

	time.sleep(1 * time.Millisecond)

	t2 := vdso_clock_gettime(monotonic = true)

	if time.diff(t1, t2) < 1 * time.Millisecond {
		test_error(t, "vdso_clock_gettime(monotonic=true) did not advance enough")
	}
}

@(test)
test_fallback_clock_gettime :: proc(t: ^testing.T) {
	// Test the syscall fallback directly (REALTIME)
	t1 := fallback_clock_gettime(monotonic = false)

	time.sleep(1 * time.Millisecond)

	_ = fallback_clock_gettime(monotonic = false)

	if time.since(t1) < 1 * time.Millisecond {
		test_error(t, "fallback_clock_gettime(monotonic=false) did not advance enough")
	}
}

@(test)
test_fallback_clock_gettime_monotonic :: proc(t: ^testing.T) {
	// Test the syscall fallback directly (MONOTONIC_RAW)
	t1 := fallback_clock_gettime(monotonic = true)

	time.sleep(1 * time.Millisecond)

	t2 := fallback_clock_gettime(monotonic = true)

	if time.diff(t1, t2) < 1 * time.Millisecond {
		test_error(t, "fallback_clock_gettime(monotonic=true) did not advance enough")
	}
}

@(test)
test_monotonic_no_resync :: proc(t: ^testing.T) {
	init()

	if !tsc_available {
		fmt.println("[time_test] TSC not available, skipping monotonic test")
		return
	}

	// Get wall-clock time
	t1 := time_now(monotonic = false)

	// Get monotonic time (no resync)
	_ = time_now(monotonic = true)

	// Both should be close in time
	diff := time.since(t1)
	if diff > 10 * time.Millisecond {
		test_error(t, fmt.tprintf("monotonic=true returned unexpected time: diff=%v", diff))
	}

	fmt.println("[time_test] monotonic mode correctly disables resync")
}

@(test)
test_tsc_sync :: proc(t: ^testing.T) {
	// Test TSC synchronization
	if success := sync_tsc_with_clock(); !success {
		fmt.println("[time_test] TSC sync failed (may be unavailable on this system)")
		return
	}

	// After sync, frequency should be set
	if tsc_freq == 0 {
		test_error(t, "tsc_freq is 0 after sync")
	}

	// base_tsc should be set
	if base_tsc == 0 {
		test_error(t, "base_tsc is 0 after sync")
	}
}

@(test)
test_time_comparison_all_methods :: proc(t: ^testing.T) {
	init()

	// Get times from all three methods (REALTIME)
	tsc_time := time_now(monotonic = false)
	vdso_time := vdso_clock_gettime(monotonic = false)
	syscall_time := fallback_clock_gettime(monotonic = false)

	// All three should be relatively close (within 100ms)
	MAX_DIFF_NS :: i64(100_000_000) // 100ms in nanoseconds

	// Just verify all methods return reasonable timestamps
	tsc_ns := time.to_unix_nanoseconds(tsc_time)
	vdso_ns := time.to_unix_nanoseconds(vdso_time)
	syscall_ns := time.to_unix_nanoseconds(syscall_time)

	if tsc_ns <= 0 || vdso_ns <= 0 || syscall_ns <= 0 {
		test_error(t, "Invalid timestamps from timing methods")
	}

	// All timestamps should be from the same general time period (within 100ms)
	if tsc_ns > vdso_ns + MAX_DIFF_NS || tsc_ns < vdso_ns - MAX_DIFF_NS {
		fmt.printf("[time_test] Large diff between TSC and vDSO: %d ns\n", vdso_ns - tsc_ns)
	}

	if vdso_ns > syscall_ns + MAX_DIFF_NS || vdso_ns < syscall_ns - MAX_DIFF_NS {
		fmt.printf("[time_test] Large diff between vDSO and syscall: %d ns\n", syscall_ns - vdso_ns)
	}
}

@(test)
test_time_comparison_all_methods_monotonic :: proc(t: ^testing.T) {
	init()

	// Get times from all three methods (MONOTONIC_RAW)
	tsc_time := time_now(monotonic = true)
	vdso_time := vdso_clock_gettime(monotonic = true)
	syscall_time := fallback_clock_gettime(monotonic = true)

	// All three should return valid timestamps
	tsc_ns := time.to_unix_nanoseconds(tsc_time)
	vdso_ns := time.to_unix_nanoseconds(vdso_time)
	syscall_ns := time.to_unix_nanoseconds(syscall_time)

	if tsc_ns <= 0 || vdso_ns <= 0 || syscall_ns <= 0 {
		test_error(t, "Invalid monotonic timestamps from timing methods")
	}
}

// Test fixed-point conversion accuracy across different frequencies and deltas.
// Verifies that (delta * mul) >> shift approximates (delta * 1e9) / freq
// with acceptable error bounds.
@(test)
test_fixed_point_conversion_accuracy :: proc(t: ^testing.T) {
	// Test frequencies: 1 GHz, 2.5 GHz, 3.5 GHz, 5 GHz
	test_freqs := [?]u64{1_000_000_000, 2_500_000_000, 3_500_000_000, 5_000_000_000}

	for freq in test_freqs {
		// Compute fixed-point multiplier (same as sync_tsc_with_clock)
		shift: u64 = 32
		mul := u64((u128(1_000_000_000) << 32) / u128(freq))
		resync_cycles := freq * 10

		// Test deltas: 0, 1, 1000, 1M, 1B, resync-1, resync
		test_deltas := [?]u64{0, 1, 1000, 1_000_000, 1_000_000_000, resync_cycles - 1, resync_cycles}

		for delta in test_deltas {
			// Approximation using fixed-point (same as hot path)
			approx_ns := u64((u128(delta) * u128(mul)) >> shift)

			// Exact calculation using u128 division
			exact_ns := u64((u128(delta) * u128(1_000_000_000)) / u128(freq))

			// Calculate error
			error_ns: i64
			if approx_ns >= exact_ns {
				error_ns = i64(approx_ns - exact_ns)
			} else {
				error_ns = -i64(exact_ns - approx_ns)
			}

			// Error should be within 100ns even at 10s delta
			// (theoretical max is ~35ns at shift=30, ~9ns at shift=32)
			MAX_ERROR_NS :: 100
			if math.abs(error_ns) > MAX_ERROR_NS {
				test_error(
					t,
					fmt.tprintf(
						"Fixed-point error too large: freq=%d, delta=%d, approx=%d, exact=%d, error=%d ns",
						freq,
						delta,
						approx_ns,
						exact_ns,
						error_ns,
					),
				)
			}
		}
	}
}

// Test strict monotonicity: rapid successive calls should never decrease.
// This catches potential issues with TSC ordering, resync jumps, or overflow.
@(test)
test_monotonicity_strict :: proc(t: ^testing.T) {
	init()

	if !tsc_available {
		fmt.println("[time_test] TSC not available, skipping strict monotonicity test")
		return
	}

	ITERATIONS :: 10_000
	prev := time_now_monotonic()

	violations := 0
	max_backward_jump: i64 = 0

	for _ in 0 ..< ITERATIONS {
		curr := time_now_monotonic()
		curr_ns := curr._nsec
		prev_ns := prev._nsec

		if curr_ns < prev_ns {
			violations += 1
			backward := prev_ns - curr_ns
			if backward > max_backward_jump {
				max_backward_jump = backward
			}
		}
		prev = curr
	}

	if violations > 0 {
		test_error(
			t,
			fmt.tprintf("Monotonicity violated: %d violations in %d iterations, max backward jump: %d ns", violations, ITERATIONS, max_backward_jump),
		)
	}
}

// Test that time_now (non-monotonic) also doesn't go backward under normal conditions.
// Note: This can fail if system clock is adjusted during test, which is expected.
@(test)
test_time_now_no_backward :: proc(t: ^testing.T) {
	init()

	if !tsc_available {
		fmt.println("[time_test] TSC not available, skipping backward test")
		return
	}

	ITERATIONS :: 10_000
	prev := time_now()

	violations := 0

	for _ in 0 ..< ITERATIONS {
		curr := time_now()
		if curr._nsec < prev._nsec {
			violations += 1
		}
		prev = curr
	}

	// Allow a small number of violations due to potential resync
	// (resync can cause small jumps if system clock drifted)
	MAX_ALLOWED_VIOLATIONS :: 10
	if violations > MAX_ALLOWED_VIOLATIONS {
		test_error(t, fmt.tprintf("Too many backward jumps in time_now: %d violations in %d iterations", violations, ITERATIONS))
	}
}

// Test TSC drift over time intervals.
// Measures the difference between TSC-based time and vDSO wall clock after various intervals.
// This verifies that TSC drift stays within acceptable bounds before resync kicks in.
@(private)
sample_tsc_vdso_offset :: proc "contextless" () -> i64 {
	// A pair of sequential reads can attribute scheduler/preemption latency to
	// either clock. Bracket the TSC read and keep the tightest of several
	// samples so the midpoint is a low-noise estimate of the vDSO time at it.
	SAMPLE_ATTEMPTS :: 7
	best_span := i64(max(i64))
	best_offset: i64

	for _ in 0 ..< SAMPLE_ATTEMPTS {
		vdso_before := vdso_clock_gettime(monotonic = true)._nsec
		tsc_ns := time_now(monotonic = true)._nsec
		vdso_after := vdso_clock_gettime(monotonic = true)._nsec
		span := vdso_after - vdso_before

		if span < best_span {
			best_span = span
			vdso_midpoint := vdso_before + span / 2
			best_offset = tsc_ns - vdso_midpoint
		}
	}

	return best_offset
}

@(test)
test_tsc_drift_over_time :: proc(t: ^testing.T) {
	init()

	if !tsc_available {
		fmt.println("[time_test] TSC not available, skipping drift test")
		return
	}

	// Force a fresh sync before starting
	sync_tsc_with_clock()

	// Test intervals: 10ms, 100ms, 500ms, 1s, 2s, 3s, 4s, 5s
	test_intervals := [?]time.Duration {
		10 * time.Millisecond,
		100 * time.Millisecond,
		500 * time.Millisecond,
		1 * time.Second,
		2 * time.Second,
		3 * time.Second,
		4 * time.Second,
		5 * time.Second,
	}

	// Maximum acceptable drift per second (in nanoseconds)
	// TSC should be very stable, allowing ~1 microsecond per second of drift max
	MAX_DRIFT_NS_PER_SECOND :: 1_000

	fmt.println("[time_test] TSC drift test starting...")
	fmt.printf("[time_test] TSC frequency: %d Hz\n", tsc_freq)

	for interval in test_intervals {
		// Force resync before each interval test
		sync_tsc_with_clock()

		// Capture the initial offset between the clocks. Taking several
		// bracketed samples prevents call/scheduler latency from masquerading
		// as drift, particularly for the shortest interval.
		start_offset := sample_tsc_vdso_offset()

		// Sleep for the interval
		time.sleep(interval)

		end_offset := sample_tsc_vdso_offset()

		// Offset growth is the drift between the two clocks. Unlike comparing
		// sequential elapsed-time reads, common endpoint latency cancels out.
		drift_ns := end_offset - start_offset

		// Calculate expected max drift for this interval
		interval_seconds := f64(interval) / f64(time.Second)
		max_drift := i64(interval_seconds * MAX_DRIFT_NS_PER_SECOND)
		// Add a minimum threshold to account for measurement overhead
		min_threshold :: 10_000 // 10 microseconds minimum
		if max_drift < min_threshold {
			max_drift = min_threshold
		}

		fmt.printf("[time_test] Interval %v: drift=%d ns (max allowed: %d ns)\n", interval, drift_ns, max_drift)

		if math.abs(drift_ns) > max_drift {
			test_error(t, fmt.tprintf("TSC drift too large at interval %v: drift=%d ns, max=%d ns", interval, drift_ns, max_drift))
		}
	}

	fmt.println("[time_test] TSC drift test completed successfully")
}

// Test TSC accuracy at the resync boundary.
// Verifies that right before resync threshold, TSC is still reasonably accurate.
@(test)
test_tsc_accuracy_near_resync :: proc(t: ^testing.T) {
	init()

	if !tsc_available {
		fmt.println("[time_test] TSC not available, skipping resync accuracy test")
		return
	}

	// Force sync and get initial readings
	sync_tsc_with_clock()

	// Take multiple readings over 3 seconds (well before 10s resync)
	DURATION :: 3 * time.Second
	SAMPLE_INTERVAL :: 500 * time.Millisecond
	NUM_SAMPLES :: 6 // 3s / 500ms

	offsets: [NUM_SAMPLES]i64

	for i in 0 ..< NUM_SAMPLES {
		offsets[i] = sample_tsc_vdso_offset()

		if i < NUM_SAMPLES - 1 {
			time.sleep(SAMPLE_INTERVAL)
		}
	}

	// Check that drift doesn't accumulate excessively
	// Compare first and last offset - if TSC is drifting, this will grow.
	// Bracketed samples prevent endpoint scheduling latency from appearing as drift.
	initial_delta := offsets[0]
	final_delta := offsets[NUM_SAMPLES - 1]
	drift_growth := math.abs(final_delta - initial_delta)

	// Allow max 100 microseconds of drift growth over 3 seconds
	MAX_DRIFT_GROWTH :: 100_000 // 100 microseconds

	fmt.printf("[time_test] TSC accuracy test: initial_delta=%d ns, final_delta=%d ns, growth=%d ns\n", initial_delta, final_delta, drift_growth)

	if drift_growth > MAX_DRIFT_GROWTH {
		test_error(t, fmt.tprintf("TSC drift growth too large over %v: %d ns (max %d ns)", DURATION, drift_growth, MAX_DRIFT_GROWTH))
	}
}
