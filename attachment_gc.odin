package main

import "core:c"
import "core:crypto/sha2"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

import "persistence"
import "storage_io"
import "ulid"

foreign import attachment_gc_libc "system:c"

foreign attachment_gc_libc {
	syncfs :: proc(fd: c.int) -> c.int ---
}

ATTACHMENT_GC_COMMAND :: "attachment-gc"
ATTACHMENT_GC_DEFAULT_DIRECTORY :: "/data/files"
ATTACHMENT_GC_QUARANTINE_NAME :: ".quarantine"
ATTACHMENT_GC_MANIFEST_NAME :: "manifest.v1"
ATTACHMENT_GC_COMPLETE_NAME :: "complete"
ATTACHMENT_GC_BATCH_PREFIX :: "batch-"
ATTACHMENT_GC_DEFAULT_RETENTION_DAYS :: 30

Attachment_GC_Options :: struct {
	attachments_dir: string,
	retention_days:  int,
	apply:           bool,
	help:            bool,
}

Attachment_GC_Candidate :: struct {
	file_id: string,
	size:    i64,
}

Attachment_GC_Stats :: struct {
	live_references: int,
	active_files:    int,
	active_bytes:    i64,
	orphan_files:    int,
	orphan_bytes:    i64,
	restored_files:  int,
	purged_batches:  int,
	purged_files:    int,
	purged_bytes:    i64,
	skipped_entries: int,
	unsafe_batches:  int,
}

@(thread_local)
attachment_gc_fail_active_sync_for_test: bool

@(thread_local)
attachment_gc_fail_database_sync_for_test: bool

@(thread_local)
attachment_gc_message_live_references: ^map[string]struct{}

attachment_gc_print_usage :: proc() {
	fmt.println("Usage: server attachment-gc [--apply] [--attachments-dir PATH] [--retention-days DAYS]")
	fmt.println("Defaults to a dry run. --apply quarantines unreferenced blobs and purges completed quarantine batches after the retention period.")
}

attachment_gc_parse_command :: proc(args: []string) -> (options: Attachment_GC_Options, requested, ok: bool) {
	options.attachments_dir = ATTACHMENT_GC_DEFAULT_DIRECTORY
	options.retention_days = ATTACHMENT_GC_DEFAULT_RETENTION_DAYS
	if len(args) < 2 || args[1] != ATTACHMENT_GC_COMMAND do return options, false, true
	requested = true
	for i := 2; i < len(args); i += 1 {
		switch args[i] {
		case "--apply":
			options.apply = true
		case "--help", "-h":
			options.help = true
			return options, true, true
		case "--attachments-dir":
			i += 1
			if i >= len(args) || args[i] == "" do return options, true, false
			options.attachments_dir = args[i]
		case "--retention-days":
			i += 1
			if i >= len(args) do return options, true, false
			value, parsed := strconv.parse_int(args[i])
			if !parsed || value < 0 || value > int(max(i64) / i64(24 * time.Hour)) do return options, true, false
			options.retention_days = int(value)
		case:
			return options, true, false
		}
	}
	return options, true, true
}

attachment_file_id_is_valid :: proc(file_id: string) -> bool {
	if len(file_id) != 36 || file_id[:4] != "att_" do return false
	for c in file_id[4:] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') do return false
	}
	return true
}

attachment_gc_mark_file_id :: proc(file_id: string, live: ^map[string]struct{}) -> bool {
	if !attachment_file_id_is_valid(file_id) do return true
	if _, exists := live^[file_id]; exists do return true
	owned, clone_err := strings.clone(file_id)
	if clone_err != nil do return false
	live^[owned] = {}
	return true
}

attachment_gc_mark_message_content :: proc(content: []byte, live: ^map[string]struct{}) -> bool {
	prefix := "/files/"
	for offset := 0; offset + len(prefix) + 36 < len(content); {
		found := -1
		for i := offset; i + len(prefix) <= len(content); i += 1 {
			if string(content[i:i + len(prefix)]) == prefix {found = i; break}
		}
		if found < 0 do break
		start := found + len(prefix)
		end := start + 36
		// File links emitted by clients always begin a query after the ID. This
		// boundary prevents longer path components from accidentally becoming live.
		if end < len(content) && content[end] == '?' {
			if !attachment_gc_mark_file_id(string(content[start:end]), live) do return false
		}
		offset = start + 1
	}
	return true
}

attachment_gc_message_scan_record :: proc(op: u8, version: u16, payload: []byte) -> bool {
	if op != 1 || version != MESSAGE_WAL_VERSION || attachment_gc_message_live_references == nil do return false
	message, ok := decode_message_record_borrowed(payload)
	if !ok || message.sequence == 0 || message.fingerprint != message_fingerprint(&message) do return false
	return attachment_gc_mark_message_content(message.content, attachment_gc_message_live_references)
}

attachment_gc_mark_retained_messages :: proc(shard_dir: string, shard: int, live: ^map[string]struct{}) -> bool {
	directory := fmt.aprintf("%s/messages", shard_dir)
	defer delete(directory)
	storage := storage_io.host_context()
	exists, exists_err := storage_io.exists(storage, directory)
	if exists_err != nil do return false
	if !exists do return true
	store := Message_Store {
		shard     = shard,
		directory = directory,
		storage   = storage,
	}
	found, loaded := load_message_manifest(&store)
	defer {
		destroy_frozen_message_store(&store, false)
		destroy_message_segment_metadata(&store, store.segments[:])
		delete(store.segments)
	}
	if !found || !loaded do return false
	attachment_gc_message_live_references = live
	defer attachment_gc_message_live_references = nil
	for segment in store.segments {
		path := message_store_path(directory, segment.generation, "wal")
		inspection := persistence.inspect_wal_file_strict(path, MESSAGE_WAL_MAGIC, shard, attachment_gc_message_scan_record)
		delete(path)
		if !inspection.ok || inspection.file_size != segment.bytes do return false
	}
	if store.frozen != nil {
		path := message_store_path(directory, store.frozen.active_generation, "wal")
		inspection := persistence.inspect_wal_file_strict(path, MESSAGE_WAL_MAGIC, shard, attachment_gc_message_scan_record)
		delete(path)
		if !inspection.ok || inspection.file_size != store.frozen.active_bytes do return false
	}
	active_path := message_store_path(directory, store.active_generation, "wal")
	defer delete(active_path)
	return persistence.inspect_wal_file_strict(active_path, MESSAGE_WAL_MAGIC, shard, attachment_gc_message_scan_record).ok
}

attachment_gc_mark_live_references :: proc(workspaces: map[string]^Workspace_State, live: ^map[string]struct{}) -> bool {
	for _, ws in workspaces {
		for _, conv in ws.conversations {
			for _, task in conv.tasks {
				for attachment in task.attachments {
					file_id := string(attachment.file_id)
					if !attachment_gc_mark_file_id(file_id, live) do return false
				}
			}
			for _, asset in conv.assets {
				for attachment in asset.attachments {
					file_id := string(attachment.file_id)
					if !attachment_gc_mark_file_id(file_id, live) do return false
				}
			}
		}
	}
	return true
}

attachment_gc_destroy_live_references :: proc(live: ^map[string]struct{}) {
	for file_id in live^ do delete(file_id)
	delete(live^)
}

attachment_gc_replay_live_references :: proc(data_dir: string, generation: u64, live: ^map[string]struct{}) -> bool {
	shard_replay_state_init()
	defer shard_replay_state_destroy()
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		shard_dir := sharded_shard_path(generation_dir, shard)
		manifest, found, loaded := load_shard_compaction_manifest(shard_dir)
		if !loaded {
			delete(shard_dir)
			return false
		}
		if found && manifest.shard != shard {
			delete(shard_dir)
			return false
		}
		if !found {
			// A fresh shard has the pre-manifest active.wal generation zero. Keep
			// dry-run genuinely read-only instead of calling ensure_* here.
			manifest = {
				shard               = shard,
				manifest_generation = 1,
				active_generation   = 0,
			}
			if !shard_compaction_manifest_files_are_valid(shard_dir, manifest) {
				delete(shard_dir)
				return false
			}
		}
		_, replayed := replay_shard_compaction_sequence(shard_dir, manifest, true, false)
		if !replayed || !attachment_gc_mark_retained_messages(shard_dir, shard, live) {
			delete(shard_dir)
			return false
		}
		delete(shard_dir)
	}
	return attachment_gc_mark_live_references(td.workspaces, live)
}

attachment_gc_storage_lock :: proc(attachments_dir: string) -> (lock: ^os.File, ok: bool) {
	opened, open_err := os.open(attachments_dir, {.Read})
	if open_err != nil do return nil, false
	if linux.flock(linux.Fd(os.fd(opened)), {.EX, .NB}) != .NONE {
		os.close(opened)
		return nil, false
	}
	return opened, true
}

attachment_gc_storage_unlock :: proc(lock: ^os.File) {
	if lock == nil do return
	_ = linux.flock(linux.Fd(os.fd(lock)), {.UN})
	os.close(lock)
}

attachment_gc_sync_directory :: proc(path: string) -> bool {
	directory, open_err := os.open(path, {.Read})
	if open_err != nil do return false
	sync_err := os.sync(directory)
	close_err := os.close(directory)
	return sync_err == nil && close_err == nil
}

attachment_gc_sync_database :: proc(data_dir: string) -> bool {
	if attachment_gc_fail_database_sync_for_test {
		attachment_gc_fail_database_sync_for_test = false
		return false
	}
	directory, open_err := os.open(data_dir, {.Read})
	if open_err != nil do return false
	sync_result := syncfs(c.int(os.fd(directory)))
	close_err := os.close(directory)
	return sync_result == 0 && close_err == nil
}

attachment_gc_batch_timestamp :: proc(name: string) -> (i64, bool) {
	if !strings.has_prefix(name, ATTACHMENT_GC_BATCH_PREFIX) do return 0, false
	value, ok := strconv.parse_i64(name[len(ATTACHMENT_GC_BATCH_PREFIX):])
	return value, ok && value > 0
}

attachment_gc_scan_active :: proc(
	attachments_dir: string,
	live: map[string]struct{},
	candidates: ^[dynamic]Attachment_GC_Candidate,
	stats: ^Attachment_GC_Stats,
) -> bool {
	entries, read_err := os.read_all_directory_by_path(attachments_dir, context.temp_allocator)
	if read_err != nil do return false
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.name == ATTACHMENT_GC_QUARANTINE_NAME do continue
		if entry.type != .Regular || !attachment_file_id_is_valid(entry.name) {
			stats.skipped_entries += 1
			continue
		}
		stats.active_files += 1
		stats.active_bytes += entry.size
		if _, referenced := live[entry.name]; referenced do continue
		file_id, clone_err := strings.clone(entry.name)
		if clone_err != nil do return false
		if _, append_err := append(candidates, Attachment_GC_Candidate{file_id = file_id, size = entry.size}); append_err != nil {
			delete(file_id)
			return false
		}
		stats.orphan_files += 1
		stats.orphan_bytes += entry.size
	}
	slice.sort_by(candidates[:], proc(a, b: Attachment_GC_Candidate) -> bool {return a.file_id < b.file_id})
	return true
}

attachment_gc_destroy_candidates :: proc(candidates: ^[dynamic]Attachment_GC_Candidate) {
	for candidate in candidates^ do delete(candidate.file_id)
	delete(candidates^)
}

attachment_gc_next_manifest_line :: proc(data: []byte, offset: ^int) -> (line: string, ok: bool) {
	if offset^ >= len(data) do return
	start := offset^
	for offset^ < len(data) && data[offset^] != '\n' do offset^ += 1
	if offset^ >= len(data) do return
	line = string(data[start:offset^])
	offset^ += 1
	return line, true
}

attachment_gc_batch_is_safe :: proc(batch_dir: string, batch_started: i64) -> (file_count: int, bytes: i64, safe: bool) {
	manifest_path := storage_layout_path(batch_dir, ATTACHMENT_GC_MANIFEST_NAME)
	defer delete(manifest_path)
	manifest_info, manifest_stat_err := os.lstat(manifest_path, context.temp_allocator)
	if manifest_stat_err != nil do return
	defer os.file_info_delete(manifest_info, context.temp_allocator)
	if manifest_info.type != .Regular || manifest_info.size < 0 || manifest_info.size > 64 * 1024 * 1024 do return
	manifest_data, manifest_read_err := os.read_entire_file(manifest_path, context.allocator)
	if manifest_read_err != nil do return
	defer delete(manifest_data)
	offset := 0
	header, header_ok := attachment_gc_next_manifest_line(manifest_data, &offset)
	created_line, created_ok := attachment_gc_next_manifest_line(manifest_data, &offset)
	if !header_ok || header != "nrc-attachment-quarantine-v1" || !created_ok || !strings.has_prefix(created_line, "created_unix_ns=") do return
	created, parsed_created := strconv.parse_i64(created_line[len("created_unix_ns="):])
	if !parsed_created || created != batch_started do return
	expected := make(map[string]i64)
	defer delete(expected)
	for offset < len(manifest_data) {
		line, line_ok := attachment_gc_next_manifest_line(manifest_data, &offset)
		if !line_ok || line == "" do return
		tab := -1
		for c, i in line {
			if c == '\t' {tab = i; break}
		}
		if tab <= 0 || tab == len(line) - 1 do return
		file_id := line[:tab]
		size, parsed_size := strconv.parse_i64(line[tab + 1:])
		if !attachment_file_id_is_valid(file_id) || !parsed_size || size < 0 do return
		if _, duplicate := expected[file_id]; duplicate do return
		expected[file_id] = size
	}

	complete_path := storage_layout_path(batch_dir, ATTACHMENT_GC_COMPLETE_NAME)
	defer delete(complete_path)
	complete_info, complete_stat_err := os.lstat(complete_path, context.temp_allocator)
	if complete_stat_err != nil do return
	defer os.file_info_delete(complete_info, context.temp_allocator)
	if complete_info.type != .Regular || complete_info.size != 3 do return
	complete_data, complete_read_err := os.read_entire_file(complete_path, context.temp_allocator)
	if complete_read_err != nil || string(complete_data) != "ok\n" do return

	entries, read_err := os.read_all_directory_by_path(batch_dir, context.temp_allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		switch entry.name {
		case ATTACHMENT_GC_COMPLETE_NAME, ATTACHMENT_GC_MANIFEST_NAME:
			continue
		case:
			if entry.type != .Regular || !attachment_file_id_is_valid(entry.name) do return
			expected_size, present := expected[entry.name]
			if !present || expected_size != entry.size do return
			file_count += 1
			bytes += entry.size
		}
	}
	return file_count, bytes, file_count == len(expected)
}

attachment_gc_copy_file :: proc(source_path, destination_path: string, expected_size: i64) -> bool {
	source, source_err := os.open(source_path, {.Read})
	if source_err != nil do return false
	destination, destination_err := os.open(destination_path, {.Write, .Create, .Excl}, os.perm(0o644))
	if destination_err != nil {os.close(source); return false}
	success := false
	defer if !success do _ = os.remove(destination_path)
	total: i64
	buffer: [64 * 1024]byte
	for {
		read_count, read_err := os.read(source, buffer[:])
		if read_err != nil && read_err != .EOF {os.close(source); os.close(destination); return false}
		if read_count == 0 do break
		written_total := 0
		for written_total < read_count {
			written, write_err := os.write(destination, buffer[written_total:read_count])
			if write_err != nil || written <= 0 {os.close(source); os.close(destination); return false}
			written_total += written
		}
		total += i64(read_count)
	}
	synced := total == expected_size && os.sync(destination) == nil
	source_close_err := os.close(source)
	destination_close_err := os.close(destination)
	success = synced && source_close_err == nil && destination_close_err == nil
	return success
}

attachment_gc_sync_file :: proc(path: string) -> bool {
	if attachment_gc_fail_active_sync_for_test {
		attachment_gc_fail_active_sync_for_test = false
		return false
	}
	file, open_err := os.open(path, {.Read})
	if open_err != nil do return false
	sync_err := os.sync(file)
	close_err := os.close(file)
	return sync_err == nil && close_err == nil
}

attachment_gc_file_digest :: proc(path: string, expected_size: i64) -> (digest: [sha2.DIGEST_SIZE_256]byte, ok: bool) {
	file, open_err := os.open(path, {.Read})
	if open_err != nil do return
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	total: i64
	buffer: [64 * 1024]byte
	for {
		read_count, read_err := os.read(file, buffer[:])
		if read_err != nil && read_err != .EOF {
			os.close(file)
			return
		}
		if read_count == 0 do break
		sha2.update(&ctx, buffer[:read_count])
		total += i64(read_count)
	}
	sha2.final(&ctx, digest[:])
	return digest, total == expected_size && os.close(file) == nil
}

attachment_gc_files_equal :: proc(first, second: string, expected_size: i64) -> bool {
	first_digest, first_ok := attachment_gc_file_digest(first, expected_size)
	if !first_ok do return false
	second_digest, second_ok := attachment_gc_file_digest(second, expected_size)
	return second_ok && first_digest == second_digest
}

attachment_gc_restore_and_purge :: proc(
	attachments_dir, quarantine_dir: string,
	live: map[string]struct{},
	now_ns, retention_ns: i64,
	apply: bool,
	stats: ^Attachment_GC_Stats,
) -> bool {
	if !os.exists(quarantine_dir) do return true
	if !storage_layout_is_real_directory(quarantine_dir) do return false
	batches, read_err := os.read_all_directory_by_path(quarantine_dir, context.temp_allocator)
	if read_err != nil do return false
	defer os.file_info_slice_delete(batches, context.temp_allocator)
	// Validate every recognized batch before making any change. Incomplete or
	// unexpected quarantine contents fail the entire destructive pass closed.
	for batch in batches {
		batch_started, named := attachment_gc_batch_timestamp(batch.name)
		if batch.type != .Directory || !named {
			stats.unsafe_batches += 1
			return false
		}
		batch_dir := storage_layout_path(quarantine_dir, batch.name)
		_, _, safe := attachment_gc_batch_is_safe(batch_dir, batch_started)
		delete(batch_dir)
		if !safe {
			stats.unsafe_batches += 1
			return false
		}
	}
	for batch in batches {
		batch_started, named := attachment_gc_batch_timestamp(batch.name)
		assert(batch.type == .Directory && named)
		batch_dir := storage_layout_path(quarantine_dir, batch.name)
		entries, batch_err := os.read_all_directory_by_path(batch_dir, context.temp_allocator)
		if batch_err != nil {delete(batch_dir); return false}
		contains_unrestored_live := false
		for entry in entries {
			if entry.type != .Regular || !attachment_file_id_is_valid(entry.name) do continue
			if _, referenced := live[entry.name]; !referenced do continue
			active_path := storage_layout_path(attachments_dir, entry.name)
			active_info, active_err := os.lstat(active_path, context.temp_allocator)
			quarantined_path := storage_layout_path(batch_dir, entry.name)
			if active_err == nil {
				active_valid :=
					active_info.type == .Regular && active_info.size == entry.size && attachment_gc_files_equal(quarantined_path, active_path, entry.size)
				os.file_info_delete(active_info, context.temp_allocator)
				if !active_valid {delete(quarantined_path); delete(active_path); os.file_info_slice_delete(entries, context.temp_allocator); delete(batch_dir); return false}
			} else {
				contains_unrestored_live = true
				if apply {
					restored := attachment_gc_copy_file(quarantined_path, active_path, entry.size)
					if !restored {delete(quarantined_path); delete(active_path); os.file_info_slice_delete(entries, context.temp_allocator); delete(batch_dir); return false}
					stats.restored_files += 1
					contains_unrestored_live = false
				}
			}
			if apply && (!attachment_gc_sync_file(active_path) || !attachment_gc_sync_directory(attachments_dir)) {
				delete(quarantined_path)
				delete(active_path)
				os.file_info_slice_delete(entries, context.temp_allocator)
				delete(batch_dir)
				return false
			}
			delete(quarantined_path)
			delete(active_path)
		}
		os.file_info_slice_delete(entries, context.temp_allocator)

		file_count, bytes, safe := attachment_gc_batch_is_safe(batch_dir, batch_started)
		assert(safe)
		eligible := !contains_unrestored_live && now_ns >= batch_started && now_ns - batch_started >= retention_ns
		if eligible {
			stats.purged_batches += 1
			stats.purged_files += file_count
			stats.purged_bytes += bytes
			if apply && os.remove_all(batch_dir) != nil {delete(batch_dir); return false}
		}
		delete(batch_dir)
	}
	if apply && (!attachment_gc_sync_directory(quarantine_dir) || !attachment_gc_sync_directory(attachments_dir)) do return false
	return true
}

attachment_gc_write_file_synced :: proc(path: string, data: []byte) -> bool {
	file, open_err := os.open(path, {.Write, .Create, .Excl}, os.perm(0o644))
	if open_err != nil do return false
	total := 0
	write_ok := true
	for total < len(data) {
		written, write_err := os.write(file, data[total:])
		if write_err != nil || written <= 0 {
			write_ok = false
			break
		}
		total += written
	}
	sync_err := os.sync(file)
	close_err := os.close(file)
	return write_ok && total == len(data) && sync_err == nil && close_err == nil
}

attachment_gc_quarantine :: proc(attachments_dir, quarantine_dir: string, candidates: []Attachment_GC_Candidate, now_ns: i64) -> bool {
	if len(candidates) == 0 do return true
	if !os.exists(quarantine_dir) {
		if os.make_directory(quarantine_dir, os.perm(0o700)) != nil || !attachment_gc_sync_directory(attachments_dir) do return false
	}
	batch_name := fmt.aprintf("%s%d", ATTACHMENT_GC_BATCH_PREFIX, now_ns)
	defer delete(batch_name)
	batch_dir := storage_layout_path(quarantine_dir, batch_name)
	defer delete(batch_dir)
	if os.make_directory(batch_dir, os.perm(0o700)) != nil do return false
	if !attachment_gc_sync_directory(quarantine_dir) do return false

	manifest := strings.builder_make()
	defer strings.builder_destroy(&manifest)
	fmt.sbprintf(&manifest, "nrc-attachment-quarantine-v1\ncreated_unix_ns=%d\n", now_ns)
	for candidate in candidates do fmt.sbprintf(&manifest, "%s\t%d\n", candidate.file_id, candidate.size)
	manifest_path := storage_layout_path(batch_dir, ATTACHMENT_GC_MANIFEST_NAME)
	manifest_ok := attachment_gc_write_file_synced(manifest_path, transmute([]byte)strings.to_string(manifest))
	delete(manifest_path)
	if !manifest_ok || !attachment_gc_sync_directory(batch_dir) do return false

	for candidate in candidates {
		source := storage_layout_path(attachments_dir, candidate.file_id)
		destination := storage_layout_path(batch_dir, candidate.file_id)
		moved := os.rename(source, destination) == nil
		delete(source)
		delete(destination)
		if !moved do return false
	}
	if !attachment_gc_sync_directory(batch_dir) || !attachment_gc_sync_directory(attachments_dir) do return false
	complete_path := storage_layout_path(batch_dir, ATTACHMENT_GC_COMPLETE_NAME)
	complete_ok := attachment_gc_write_file_synced(complete_path, transmute([]byte)string("ok\n"))
	delete(complete_path)
	return complete_ok && attachment_gc_sync_directory(batch_dir) && attachment_gc_sync_directory(quarantine_dir)
}

attachment_gc_sweep :: proc(
	options: Attachment_GC_Options,
	live: map[string]struct{},
	now_ns: i64,
	data_dir: string,
) -> (
	stats: Attachment_GC_Stats,
	ok: bool,
) {
	stats.live_references = len(live)
	if !storage_layout_is_real_directory(options.attachments_dir) do return stats, false
	lock, locked := attachment_gc_storage_lock(options.attachments_dir)
	if !locked {
		log.error("Attachment store is in use; stop tailscale-proxy before running attachment GC")
		return stats, false
	}
	defer attachment_gc_storage_unlock(lock)
	if options.apply && !attachment_gc_sync_database(data_dir) {
		log.error("Attachment GC refused to modify files because the database durability barrier failed")
		return stats, false
	}

	quarantine_dir := storage_layout_path(options.attachments_dir, ATTACHMENT_GC_QUARANTINE_NAME)
	defer delete(quarantine_dir)
	retention_ns := i64(options.retention_days) * i64(24 * time.Hour)
	if !attachment_gc_restore_and_purge(options.attachments_dir, quarantine_dir, live, now_ns, retention_ns, options.apply, &stats) do return stats, false

	candidates := make([dynamic]Attachment_GC_Candidate)
	defer attachment_gc_destroy_candidates(&candidates)
	if !attachment_gc_scan_active(options.attachments_dir, live, &candidates, &stats) do return stats, false
	if options.apply && !attachment_gc_quarantine(options.attachments_dir, quarantine_dir, candidates[:], now_ns) do return stats, false
	return stats, true
}

run_attachment_gc :: proc(options: Attachment_GC_Options) -> bool {
	live := make(map[string]struct{})
	defer attachment_gc_destroy_live_references(&live)
	if !attachment_gc_replay_live_references(persistence.DATA_DIR, runtime_storage_layout.generation, &live) {
		log.error("Attachment GC refused to modify files because canonical shard replay failed")
		return false
	}
	now_ns := time.to_unix_nanoseconds(ulid.time_now())
	stats, ok := attachment_gc_sweep(options, live, now_ns, persistence.DATA_DIR)
	if !ok {
		log.error("Attachment GC failed without completing the requested operation")
		return false
	}
	mode := options.apply ? "APPLY" : "DRY-RUN"
	fmt.printf(
		"attachment-gc %s: references=%d active=%d (%d bytes) orphaned=%d (%d bytes) restored=%d purge_batches=%d purge_files=%d (%d bytes) skipped=%d unsafe_batches=%d\n",
		mode,
		stats.live_references,
		stats.active_files,
		stats.active_bytes,
		stats.orphan_files,
		stats.orphan_bytes,
		stats.restored_files,
		stats.purged_batches,
		stats.purged_files,
		stats.purged_bytes,
		stats.skipped_entries,
		stats.unsafe_batches,
	)
	if !options.apply && (stats.orphan_files > 0 || stats.purged_batches > 0) do fmt.println("No files changed; rerun with --apply after reviewing the dry-run counts.")
	return true
}
