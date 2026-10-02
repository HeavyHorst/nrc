package ulid

import "core:log"
import "core:sys/linux"
import "core:time"

// This is an optimized time.now() implementation using the Time Stamp Counter (TSC).
//
// The TSC is a hardware counter that increments at a fixed frequency, providing
// a high-resolution timer. This package leverages the TSC to provide a faster and more
// precise way to get the current time compared to the standard time.now() function,
// especially in scenarios where high precision is required.
//
// The package maintains thread-local variables to store the TSC value and wall-clock time
// at the last synchronization point. This allows for quick calculation of the current time
// by simply calculating the elapsed cycles since the last sync.
//
// To ensure accuracy, the TSC is periodically synchronized with the system clock. This
// synchronization process involves retrieving the current TSC value and the corresponding
// wall-clock time.
//
// A resynchronization is triggered if the elapsed time since the last synchronization
// exceeds a certain threshold (10 seconds in this implementation). This prevents drift
// and maintains accuracy over longer periods. If the TSC frequency can't be obtained
// or the CPU does not have an invariant TSC (TSC at a fixed frequency, independent of ACPI state, and CPU frequency)
// the package falls back to vDSO-optimized glibc clock_gettime, and then to the raw syscall.
//
// This package is designed to improve performance in situations where frequent calls to
// time.now() are made and high precision is needed. However, it's important to note that
// the TSC might not be available or reliable on all systems (e.g., virtualized environments,
// systems with varying CPU frequencies). Therefore, appropriate fallback mechanisms are
// implemented:
// 1. TSC-based timing (fastest, ~2 ns/call)
// 2. glibc vDSO clock_gettime (fast, ~26 ns/call)
// 3. Raw syscall clock_gettime (slowest, ~335 ns/call, fallback)
//
// FIXED-POINT ARITHMETIC FOR TSC CONVERSION
// ==========================================
// Converting TSC cycles to nanoseconds requires: ns = cycles * 1e9 / freq
//
// Integer division is expensive (~20-40 CPU cycles). We avoid it using fixed-point math:
//
//   1. Precompute a multiplier: mul = (1e9 << shift) / freq
//      where shift=32 gives good precision without overflow.
//
//   2. In the hot path, compute: ns = (cycles * mul) >> shift
//
// Why this works (algebraically):
//
//   (cycles * mul) >> shift
//   = (cycles * (1e9 << shift) / freq) >> shift
//   = (cycles * 1e9 << shift) / freq >> shift
//   = (cycles * 1e9) / freq                        ✓ same as exact formula
//
// The integer division when computing mul introduces a small error (floor rounding).
// Error bound: at most 1 LSB in mul, which translates to ~0.23 picoseconds per cycle
// at shift=32. Over a 10-second resync interval at 3.8 GHz, max accumulated error is ~9ns.
//
// We use u128 for the hot-path multiplication to prevent overflow:
//   ns = base_ns + u64((u128(delta) * u128(mul)) >> shift)
//
// This is actually faster than u64 (~2.0 ns vs ~2.2 ns in benchmarks) because
// the compiler can optimize the 128-bit multiply+shift into efficient x86-64 instructions.

// Thread-local variable to store the Time Stamp Counter (TSC) value at the last synchronization
@(thread_local)
base_tsc: u64

// Thread-local variable to store the wall-clock time in nanoseconds (faster than time.Time)
@(thread_local)
base_ns: u64

// Thread-local variable to store the TSC frequency in Hz
@(thread_local)
tsc_freq: u64

// Fixed-point multiplier for TSC to nanoseconds conversion (avoids division in hot path)
// Formula: elapsed_ns = (elapsed_cycles * tsc_to_ns_mul) >> tsc_to_ns_shift
@(thread_local)
tsc_to_ns_mul: u64

@(thread_local)
tsc_to_ns_shift: u64

// Resync threshold in cycles (computed from tsc_freq during init)
@(thread_local)
resync_threshold_cycles: u64

// Global variable to track if TSC is available (checked on first call)
@(thread_local)
tsc_checked: bool

@(thread_local)
tsc_available: bool

// Thread-local variable to track which fallback mechanism is in use
@(thread_local)
fallback_method: Fallback_Method

@(thread_local)
timing_init_logged: bool

Fallback_Method :: enum {
	TSC,
	VDSO,
	SYSCALL,
}

// vDSO-optimized glibc clock_gettime (when available)
@(default_calling_convention = "c")
foreign _ {
	clock_gettime :: proc(clockid: i32, timespec: rawptr) -> i32 ---
}

@(private)
timespec :: struct {
	tv_sec:  i64,
	tv_nsec: i64,
}

@(private)
CLOCK_REALTIME :: i32(linux.Clock_Id.REALTIME)

@(private)
CLOCK_MONOTONIC_RAW :: i32(linux.Clock_Id.MONOTONIC_RAW)

// Function to get current time using glibc vDSO clock_gettime
@(private)
vdso_clock_gettime :: proc "contextless" (monotonic: bool = false) -> time.Time {
	ts: timespec
	clock_id := CLOCK_REALTIME
	if monotonic {
		clock_id = CLOCK_MONOTONIC_RAW
	}

	if clock_gettime(clock_id, rawptr(&ts)) == 0 {
		ns := ts.tv_sec * 1e9 + ts.tv_nsec
		return time.Time{_nsec = ns}
	}
	// If vDSO fails, fall back to syscall
	return fallback_clock_gettime(monotonic)
}

// Fallback to raw syscall clock_gettime
@(private)
fallback_clock_gettime :: proc "contextless" (monotonic: bool = false) -> time.Time {
	clock_id := linux.Clock_Id.REALTIME
	if monotonic {
		clock_id = .MONOTONIC_RAW
	}

	time_spec_now, _ := linux.clock_gettime(clock_id)
	ns := i64(time_spec_now.time_sec) * 1e9 + i64(time_spec_now.time_nsec)
	return time.Time{_nsec = ns}
}

// Initializes the TSC conversion constants once per thread.
//
// time.tsc_frequency() can fall back to a sleep-based calibration path on
// virtualized hosts where the perf mmap page does not expose user timing
// metadata. Keep that cost out of worker/test reinitialization and periodic
// wall-clock resyncs by caching the frequency and fixed-point multiplier.
ensure_tsc_frequency :: proc "contextless" () -> bool {
	if tsc_freq != 0 {
		return true
	}

	freq, ok := time.tsc_frequency()
	if !ok {
		return false
	}

	// Fixed-point multiplier: ns = (cycles * mul) >> shift
	// With shift=32, precision error is ~0.23 picoseconds per cycle.
	// Over 10s resync interval at 3.8GHz: max accumulated error ~9ns.
	// Floor rounding in integer division introduces slight negative bias,
	// but this is negligible (<1 LSB per conversion).
	tsc_freq = freq
	tsc_to_ns_shift = 32
	tsc_to_ns_mul = u64((u128(1_000_000_000) << 32) / u128(freq))

	// Resync every 10 seconds to correct for drift
	resync_threshold_cycles = freq * 10
	return true
}

// Function to synchronize the TSC with the system clock.
// Returns true on success, false on failure.
//
// REENTRANCY NOTE: This procedure calls time.now(), which is Odin's stdlib
// clock, not this package's time_now(). TSC frequency calibration is cached by
// ensure_tsc_frequency(), so normal resync does not repeat the potentially slow
// stdlib fallback calibration.
sync_tsc_with_clock :: proc "contextless" () -> bool {
	if !ensure_tsc_frequency() {
		return false
	}

	// Capture current TSC and wall-clock time
	// NOTE: time.now() is Odin stdlib, not our time_now()
	base_tsc = time.read_cycle_counter()
	wall_time := time.now()
	base_ns = u64(wall_time._nsec)

	return true
}

initialize_timing :: proc "contextless" () {
	if tsc_checked {
		return
	}

	success := sync_tsc_with_clock()
	tsc_checked = true
	tsc_available = success

	if success {
		fallback_method = .TSC
		return
	}

	// Try vDSO next
	ts: timespec
	if clock_gettime(CLOCK_REALTIME, rawptr(&ts)) == 0 {
		fallback_method = .VDSO
	} else {
		fallback_method = .SYSCALL
	}
}

// Initialize time package and log TSC availability
// Should be called once at startup
init :: proc() {
	initialize_timing()
	if timing_init_logged {
		return
	}
	timing_init_logged = true

	if tsc_available {
		fallback_method = .TSC
		log.infof("TSC (Time Stamp Counter) enabled for high-resolution timing (freq: %d Hz)", tsc_freq)
	} else {
		if fallback_method == .VDSO {
			log.info("TSC not available, using glibc vDSO clock_gettime for timing")
		} else {
			log.info("TSC and vDSO not available, falling back to raw syscall clock_gettime")
		}
	}
}

time_now_monotonic :: proc "contextless" () -> time.Time {
	return time_now(monotonic = true)
}

// Optimized version of time.now() with tiered fallback: TSC -> vDSO -> syscall
// monotonic: if true, doesn't resync TSC (ensuring monotonicity) and uses CLOCK_MONOTONIC_RAW
//            if false, periodically resyncs TSC and uses CLOCK_REALTIME
time_now :: proc "contextless" (monotonic: bool = false) -> time.Time {
	if !tsc_checked {
		initialize_timing()
	}

	// Use TSC if available - optimized hot path
	if tsc_available {
		tsc := time.read_cycle_counter()
		delta := tsc - base_tsc

		// Resync check using raw cycles (no conversion overhead)
		if !monotonic && delta > resync_threshold_cycles {
			sync_tsc_with_clock()
			delta = time.read_cycle_counter() - base_tsc
		}

		// Fixed-point multiply+shift instead of division
		// Use u128 to prevent overflow at large deltas (benchmarked: ~2ns/op, faster than u64)
		ns := base_ns + u64((u128(delta) * u128(tsc_to_ns_mul)) >> tsc_to_ns_shift)
		return time.Time{_nsec = i64(ns)}
	}

	// Fallback to vDSO or syscall based on what's available
	switch fallback_method {
	case .VDSO:
		return vdso_clock_gettime(monotonic)
	case .SYSCALL:
		return fallback_clock_gettime(monotonic)
	case .TSC:
		// TSC should have been handled above, but if we get here try to sync
		if ok := sync_tsc_with_clock(); ok {
			tsc := time.read_cycle_counter()
			delta := tsc - base_tsc
			ns := base_ns + u64((u128(delta) * u128(tsc_to_ns_mul)) >> tsc_to_ns_shift)
			return time.Time{_nsec = i64(ns)}
		}
		return vdso_clock_gettime(monotonic)
	}

	// Should not reach here, but fallback to vDSO just in case
	return vdso_clock_gettime(monotonic)
}
