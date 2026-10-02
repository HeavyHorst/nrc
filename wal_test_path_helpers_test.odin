package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

import "persistence"

// Returns a temporary string. Remove the filesystem path when finished, but do
// not delete the string through context.allocator.
test_wal_path :: proc(format: string, args: ..any) -> string {
	mode := "prod"
	when NRC_SIMULATION {
		mode = "sim"
	}
	name := fmt.tprintf("%s-pid%d-%s", mode, os.get_pid(), fmt.tprintf(format, ..args))
	path, err := filepath.join({persistence.DATA_DIR, name}, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("%s/%s", persistence.DATA_DIR, name)
	}
	return path
}
