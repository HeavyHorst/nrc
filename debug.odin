//
// debug.odin - Debug Logging Utilities
//
// Provides compile-time gated debug logging that bypasses the main logger's level filter.
// Usage: when ODIN_DEBUG do debug_log("[T%d] message", thread_id)
//
// This is only compiled when building with -debug flag.
//
package main

import "core:fmt"
import "core:log"
import "core:time"
import "ulid"

// Suppress unused import warnings when ODIN_DEBUG is false
_ :: fmt.eprintf
_ :: log.info
_ :: time.clock_from_time
_ :: ulid.time_now

when ODIN_DEBUG {
	init_debug_logger :: proc() {
		// No-op for now, but could initialize file output etc.
	}

	debug_log :: #force_inline proc(fmt_str: string, args: ..any, loc := #caller_location) {
		// Direct output - bypasses log level filtering entirely
		// Format: [timestamp] [DEBUG] file:line: message
		now := ulid.time_now()
		hour, min, sec := time.clock_from_time(now)
		fmt.eprintf("[%02d:%02d:%02d] [DEBUG] %s(%d): ", hour, min, sec, loc.file_path, loc.line)
		fmt.eprintfln(fmt_str, ..args)
	}
}
