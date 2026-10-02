package persistence

import "core:log"
import "core:os"
import "core:path/filepath"

// ============================================================================
// Lifecycle
// ============================================================================

get_parent_directory_path :: proc(path: string) -> string {
	parent_dir, _ := filepath.split(path)
	if parent_dir == "" {
		return "."
	}
	return parent_dir
}

fsync_parent_directory_for_path :: proc(path: string, thread_index: int) -> bool {
	parent_dir := get_parent_directory_path(path)
	dir_handle, open_err := os.open(parent_dir, {.Read})
	if open_err != nil {
		log.errorf("[T%d] Failed to open parent directory for fsync: %s (%v)", thread_index, parent_dir, open_err)
		return false
	}
	defer os.close(dir_handle)

	if sync_err := os.sync(dir_handle); sync_err != nil {
		log.errorf("[T%d] Failed to fsync parent directory: %s (%v)", thread_index, parent_dir, sync_err)
		return false
	}
	return true
}
