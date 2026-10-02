package storage_io

import "core:bytes"
import "core:os"
import "core:sys/linux"
import "core:testing"

when !NRC_SIMULATION {
	_ :: bytes.equal
	_ :: os.Error
	_ :: linux.Errno
}

@(test)
test_storage_invalid_context_never_uses_host_filesystem :: proc(t: ^testing.T) {
	_, err := exists({}, "/")
	testing.expect(t, err != nil)
}

when NRC_SIMULATION {
	virtual_test_exists :: proc(storage: Context, path: string) -> bool {
		found, err := exists(storage, path)
		return err == nil && found
	}

	@(test)
	test_virtual_storage_file_and_directory_durability_are_independent :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		testing.expect(t, make_directory(storage, "/world") == nil)
		testing.expect(t, sync_directory(storage, "/") == nil)

		file, open_err := open(storage, "/world/active.wal", {.Write, .Create, .Append})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		written, write_err := write(file, []byte{1, 2, 3})
		testing.expect(t, write_err == nil && written == 3)
		testing.expect(t, sync(file) == nil)
		virtual_fs_crash(&fs)
		new_context := virtual_context(&fs)
		testing.expect(t, !virtual_test_exists(new_context, "/world/active.wal"), "file fsync must not publish an unsynced directory entry")
		discard(file)
	}

	@(test)
	test_virtual_storage_older_sync_snapshot_cannot_regress_durable_content :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		file, open_err := open(storage, "/versioned", {.Read, .Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		testing.expect(t, sync_directory(storage, "/") == nil)

		_, _ = write(file, []byte{1, 2})
		older, older_err := capture_sync_snapshot(file)
		testing.expect(t, older_err == nil)
		defer destroy_sync_snapshot(&older)
		_, _ = write(file, []byte{3, 4})
		testing.expect(t, sync(file) == nil)
		testing.expect(t, commit_sync_snapshot(&older) == nil)

		virtual_fs_crash(&fs)
		discard(file)
		storage = virtual_context(&fs)
		reopened, reopen_err := open(storage, "/versioned", {.Read})
		testing.expect(t, reopen_err == nil && reopened != nil)
		if reopened == nil do return
		buf: [4]byte
		read, read_err := read_at(reopened, buf[:], 0)
		testing.expect(t, read_err == nil && read == 4 && bytes.equal(buf[:], []byte{1, 2, 3, 4}))
		testing.expect(t, close(reopened) == nil)
	}

	@(test)
	test_virtual_storage_older_snapshot_cannot_undo_newer_truncate :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		file, open_err := open(storage, "/truncated", {.Read, .Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		testing.expect(t, sync_directory(storage, "/") == nil)

		_, _ = write(file, []byte{1, 2, 3})
		older, older_err := capture_sync_snapshot(file)
		testing.expect(t, older_err == nil)
		defer destroy_sync_snapshot(&older)
		testing.expect(t, truncate(file, 1) == nil && sync(file) == nil)
		testing.expect(t, commit_sync_snapshot(&older) == nil)

		virtual_fs_crash(&fs)
		discard(file)
		storage = virtual_context(&fs)
		reopened, reopen_err := open(storage, "/truncated", {.Read})
		testing.expect(t, reopen_err == nil && reopened != nil)
		if reopened == nil do return
		buf: [3]byte
		read, read_err := read_at(reopened, buf[:], 0)
		testing.expect(t, read_err == nil && read == 1 && buf[0] == 1)
		testing.expect(t, close(reopened) == nil)
	}

	@(test)
	test_virtual_storage_crash_drops_durable_children_of_unsynced_directory :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		testing.expect(t, make_directory(storage, "/orphan") == nil)
		file, open_err := open(storage, "/orphan/file", {.Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		_, _ = write(file, []byte{1})
		testing.expect(t, sync(file) == nil && close(file) == nil)
		testing.expect(t, sync_directory(storage, "/orphan") == nil)
		virtual_fs_crash(&fs)
		storage = virtual_context(&fs)
		testing.expect(t, !virtual_test_exists(storage, "/orphan") && !virtual_test_exists(storage, "/orphan/file"))
	}

	@(test)
	test_virtual_storage_crash_restores_durable_content_and_namespace :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		testing.expect(t, make_directory(storage, "/world") == nil)
		testing.expect(t, sync_directory(storage, "/") == nil)
		file, open_err := open(storage, "/world/active.wal", {.Write, .Create, .Append})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		_, _ = write(file, []byte{1, 2, 3})
		testing.expect(t, sync(file) == nil)
		testing.expect(t, sync_directory(storage, "/world") == nil)
		_, _ = write(file, []byte{4, 5, 6})

		virtual_fs_crash(&fs, "/world/active.wal", 2)
		new_context := virtual_context(&fs)
		testing.expect(t, !virtual_context_valid(storage), "old context must be invalid after crash")
		_, stale_err := file_size(file)
		testing.expect(t, stale_err != nil, "old handle must be invalid after crash")
		discard(file)

		reopened, reopen_err := open(new_context, "/world/active.wal", {.Read})
		testing.expect(t, reopen_err == nil && reopened != nil)
		if reopened == nil do return
		buf: [8]byte
		read, read_err := read_at(reopened, buf[:], 0)
		testing.expect(t, read_err == nil && read == 5)
		testing.expect(t, bytes.equal(buf[:5], []byte{1, 2, 3, 4, 5}))
		testing.expect(t, close(reopened) == nil)
	}

	@(test)
	test_virtual_storage_rename_requires_directory_sync :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		testing.expect(t, make_directory(storage, "/world") == nil)
		testing.expect(t, sync_directory(storage, "/") == nil)
		file, open_err := open(storage, "/world/manifest.tmp", {.Write, .Create, .Excl})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		_, _ = write(file, []byte{9})
		testing.expect(t, sync(file) == nil)
		testing.expect(t, sync_directory(storage, "/world") == nil)
		testing.expect(t, rename(storage, "/world/manifest.tmp", "/world/manifest") == nil)
		virtual_fs_crash(&fs)
		storage = virtual_context(&fs)
		testing.expect(t, virtual_test_exists(storage, "/world/manifest.tmp"))
		testing.expect(t, !virtual_test_exists(storage, "/world/manifest"))
		discard(file)

		testing.expect(t, rename(storage, "/world/manifest.tmp", "/world/manifest") == nil)
		testing.expect(t, sync_directory(storage, "/world") == nil)
		virtual_fs_crash(&fs)
		storage = virtual_context(&fs)
		testing.expect(t, !virtual_test_exists(storage, "/world/manifest.tmp"))
		testing.expect(t, virtual_test_exists(storage, "/world/manifest"))
	}

	@(test)
	test_virtual_storage_open_handle_keeps_inode_identity_across_rename_and_remove :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		testing.expect(t, make_directory(storage, "/world") == nil)
		testing.expect(t, sync_directory(storage, "/") == nil)
		file, open_err := open(storage, "/world/source", {.Read, .Write, .Create, .Append})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		_, _ = write(file, []byte{1})
		testing.expect(t, rename(storage, "/world/source", "/world/destination") == nil)
		testing.expect(t, !virtual_test_exists(storage, "/world/source") && virtual_test_exists(storage, "/world/destination"))
		_, _ = write(file, []byte{2})
		testing.expect(t, remove(storage, "/world/destination") == nil)
		testing.expect(t, !virtual_test_exists(storage, "/world/destination"))
		buf: [2]byte
		read, read_err := read_at(file, buf[:], 0)
		testing.expect(t, read_err == nil && read == 2 && bytes.equal(buf[:], []byte{1, 2}))
		testing.expect(t, close(file) == nil)
	}

	@(test)
	test_virtual_storage_invalid_context_and_open_do_not_fall_back_or_mutate :: proc(t: ^testing.T) {
		_, invalid_open_err := open({}, "/tmp/nrc-storage-io-must-not-exist", {.Write, .Create})
		testing.expect(t, invalid_open_err != nil)
		_, invalid_exists_err := exists({}, "/tmp/nrc-storage-io-must-not-exist")
		testing.expect(t, invalid_exists_err != nil)

		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		file, open_err := open(storage, "/invalid", {.Create})
		testing.expect(t, file == nil && open_err != nil)
		testing.expect(t, !virtual_test_exists(storage, "/invalid"))
		file, open_err = open(storage, "/invalid-truncate", {.Read, .Create, .Trunc})
		testing.expect(t, file == nil && open_err != nil)
		testing.expect(t, !virtual_test_exists(storage, "/invalid-truncate"))

		relative, relative_err := open(storage, "relative", {.Write, .Create})
		testing.expect(t, relative_err == nil && relative != nil, "relative paths must resolve beneath the simulated cwd")
		if relative != nil do testing.expect(t, close(relative) == nil)
	}

	@(test)
	test_virtual_storage_failed_rename_and_directory_sync_are_atomic :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		file, open_err := open(storage, "/source", {.Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		virtual_fail_next_clone_for_test(&fs)
		testing.expect(t, rename(storage, "/source", "/destination") != nil)
		testing.expect(t, virtual_test_exists(storage, "/source") && !virtual_test_exists(storage, "/destination"))

		testing.expect(t, sync(file) == nil)
		testing.expect(t, sync_directory(storage, "/") == nil)
		destination, destination_err := open(storage, "/destination", {.Write, .Create})
		testing.expect(t, destination_err == nil && destination != nil)
		if destination == nil do return
		_, _ = write(destination, []byte{9})
		testing.expect(t, sync(destination) == nil && close(destination) == nil)
		testing.expect(t, sync_directory(storage, "/") == nil)
		testing.expect(t, rename(storage, "/source", "/destination") == nil)
		virtual_fail_next_clone_for_test(&fs)
		testing.expect(t, sync_directory(storage, "/") != nil)
		virtual_fs_crash(&fs)
		storage = virtual_context(&fs)
		testing.expect(
			t,
			virtual_test_exists(storage, "/source") && virtual_test_exists(storage, "/destination"),
			"failed directory sync must preserve the prior durable namespace",
		)
		durable_destination, durable_destination_err := open(storage, "/destination", {.Read})
		testing.expect(t, durable_destination_err == nil && durable_destination != nil)
		if durable_destination != nil {
			value: [1]byte
			read, read_err := read_at(durable_destination, value[:], 0)
			testing.expect(t, read_err == nil && read == 1 && value[0] == 9, "failed directory sync must preserve the prior destination inode")
			testing.expect(t, close(durable_destination) == nil)
		}
		discard(file)
	}

	@(test)
	test_virtual_storage_truncate_preserves_offset_and_crash_reclaims_stale_unlinked_inode :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		file, open_err := open(storage, "/volatile", {.Read, .Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		_, _ = write(file, []byte{1, 2, 3})
		testing.expect(t, truncate(file, 1) == nil)
		_, _ = write(file, []byte{4})
		size, size_err := file_size(file)
		testing.expect(t, size_err == nil && size == 4, "truncate must not move the open-file offset")

		virtual_fs_crash(&fs)
		_, write_err := write(file, []byte{5})
		read_buf: [1]byte
		_, read_err := read_at(file, read_buf[:], 0)
		_, stale_size_err := file_size(file)
		stale := os.Platform_Error(linux.Errno.ESTALE)
		testing.expect(t, write_err == stale && read_err == stale && stale_size_err == stale)
		testing.expect(t, sync(file) == stale && truncate(file, 0) == stale)
		testing.expect(t, close(file) == stale)
	}

	@(test)
	test_virtual_storage_space_reports_capacity_and_unique_inode_usage :: proc(t: ^testing.T) {
		fs: Virtual_FS
		testing.expect(t, virtual_fs_init(&fs, 100))
		defer virtual_fs_destroy(&fs)
		storage := virtual_context(&fs)
		file, open_err := open(storage, "/space", {.Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		written, write_err := write(file, make([]byte, 30, context.temp_allocator))
		testing.expect(t, write_err == nil && written == 30)
		space, space_err := storage_space(storage, "/")
		testing.expect(t, space_err == nil)
		testing.expect_value(t, space, Storage_Space{capacity_bytes = 100, used_bytes = 30, available_bytes = 70})
		testing.expect(t, rename(storage, "/space", "/renamed") == nil)
		space, space_err = storage_space(storage, "/")
		testing.expect(t, space_err == nil)
		testing.expect_value(t, space.used_bytes, u64(30))
		testing.expect(t, close(file) == nil)
	}
}
