#+feature dynamic-literals

package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import pr "protocol"
import sql "sqlite"
import db "workspace_db"

ATTACHMENT_GC_TEST_TASK_ID :: "att_00000000000000000000000000000001"
ATTACHMENT_GC_TEST_ASSET_ID :: "att_00000000000000000000000000000002"
ATTACHMENT_GC_TEST_ORPHAN_ID :: "att_00000000000000000000000000000003"
ATTACHMENT_GC_TEST_OTHER_ID :: "att_00000000000000000000000000000004"
ATTACHMENT_GC_TEST_MESSAGE_ID :: "att_00000000000000000000000000000005"

@(test)
test_attachment_gc_sqlite_references_and_fail_closed :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("sqlite-gc")
	defer os.remove_all(dir)
	lock, ok := sqlite_storage_layout_gate(dir, 1)
	if !testing.expect(t, ok) do return
	defer release_data_directory_lock(&lock)
	shard := int(shard_for_workspace(transmute([]byte)string("gc")))
	path := sqlite_shard_path(dir, 1, shard); defer delete(path)
	cpath := strings.clone_to_cstring(path); defer delete(cpath)
	store, rc := db.open(cpath)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	attachments := [2]pr.Attachment {
		{file_id = transmute([]byte)string(ATTACHMENT_GC_TEST_TASK_ID)},
		{file_id = transmute([]byte)string(ATTACHMENT_GC_TEST_ASSET_ID)},
	}
	task := pr.Task {
		id          = 1,
		title       = transmute([]byte)string("GC"),
		attachments = attachments[:1],
	}
	asset := pr.Asset {
		asset_id    = 1,
		asset_type  = .Note,
		attachments = attachments[:],
	}
	testing.expect_value(t, db.put_task(&store, "gc", &task), sql.OK)
	testing.expect_value(t, sqlite_put_asset(&store, "gc", &asset), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	// Keep the writer open so the reader must see committed WAL records too.
	root := sharded_generation_path(dir, 1); defer delete(root)
	leaf := sharded_shard_path(root, shard); defer delete(leaf)
	messages: Message_Store
	if !testing.expect(t, init_message_store(&messages, leaf, shard, 24 * time.Hour, 0)) do return
	message := test_retained_message("gc", 9, 1, nrc_time_unix_nanos())
	message.content = transmute([]byte)string("/files/" + ATTACHMENT_GC_TEST_MESSAGE_ID + "?inline=true")
	message.fingerprint = message_fingerprint(&message)
	result, _ := append_or_deduplicate_message(&messages, &message)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	testing.expect(t, shutdown_message_store(&messages))
	live := make(map[string]struct{}); defer attachment_gc_destroy_live_references(&live)
	testing.expect(t, attachment_gc_sqlite_live_references(dir, 1, &live))
	testing.expect_value(t, len(live), 3)
	for id in ([3]string{ATTACHMENT_GC_TEST_TASK_ID, ATTACHMENT_GC_TEST_ASSET_ID, ATTACHMENT_GC_TEST_MESSAGE_ID}) do testing.expect(t, id in live)
	testing.expect_value(t, sql.exec(store.db, "PRAGMA user_version=11", nil, nil, nil), sql.OK)
	testing.expect(t, !attachment_gc_sqlite_live_references(dir, 1, &live), "unmigrated shards must abort the mark phase")
	testing.expect_value(t, sql.exec(store.db, "PRAGMA user_version=12", nil, nil, nil), sql.OK)
	bad := sqlite_shard_path(dir, 1, 255); defer delete(bad)
	testing.expect(t, os.write_entire_file(bad, transmute([]byte)string("broken")) == nil)
	testing.expect(t, !attachment_gc_sqlite_live_references(dir, 1, &live), "later shard corruption must abort the entire mark phase")
}

attachment_gc_test_directory :: proc(name: string) -> string {
	mode := "prod"
	when NRC_SIMULATION do mode = "sim"
	return fmt.tprintf("/tmp/nrc-attachment-gc-%s-pid%d-%s", mode, os.get_pid(), name)
}

attachment_gc_test_write :: proc(dir, name, contents: string) -> bool {
	path := storage_layout_path(dir, name)
	defer delete(path)
	return os.write_entire_file(path, transmute([]byte)contents) == nil
}

attachment_gc_test_batch_path :: proc(dir: string, now: i64) -> string {
	quarantine_dir := storage_layout_path(dir, ATTACHMENT_GC_QUARANTINE_NAME)
	defer delete(quarantine_dir)
	batch_name := fmt.aprintf("%s%d", ATTACHMENT_GC_BATCH_PREFIX, now)
	defer delete(batch_name)
	return storage_layout_path(quarantine_dir, batch_name)
}

@(test)
test_attachment_gc_file_id_validation_is_exact :: proc(t: ^testing.T) {
	testing.expect(t, attachment_file_id_is_valid(ATTACHMENT_GC_TEST_TASK_ID))
	testing.expect(t, !attachment_file_id_is_valid("att_0000000000000000000000000000000"))
	testing.expect(t, !attachment_file_id_is_valid("att_0000000000000000000000000000000G"))
	testing.expect(t, !attachment_file_id_is_valid("../att_00000000000000000000000000000001"))
}

@(test)
test_attachment_gc_marks_local_file_links_in_message_content :: proc(t: ^testing.T) {
	live := make(map[string]struct{})
	defer attachment_gc_destroy_live_references(&live)
	content := fmt.tprintf(
		"ordinary [%s](/files/%s?filename=report.pdf) and ![image](/files/%s?inline=true&filename=x.png) ignored /files/att_0000000000000000000000000000000A?filename=x /files/%sx?filename=x",
		"file",
		ATTACHMENT_GC_TEST_MESSAGE_ID,
		ATTACHMENT_GC_TEST_TASK_ID,
		ATTACHMENT_GC_TEST_OTHER_ID,
	)
	testing.expect(t, attachment_gc_mark_message_content(transmute([]byte)content, &live))
	testing.expect_value(t, len(live), 2)
	_, message_live := live[ATTACHMENT_GC_TEST_MESSAGE_ID]
	_, image_live := live[ATTACHMENT_GC_TEST_TASK_ID]
	testing.expect(t, message_live && image_live)
	structured := fmt.tprintf(
		`{"type":"attachment","version":1,"fileId":"%s","filename":"clip.mp4","size":123,"mimeType":"video/mp4","url":"/files/%s?filename=clip.mp4"}`,
		ATTACHMENT_GC_TEST_OTHER_ID,
		ATTACHMENT_GC_TEST_OTHER_ID,
	)
	testing.expect(t, attachment_gc_mark_message_content(transmute([]byte)structured, &live))
	_, structured_live := live[ATTACHMENT_GC_TEST_OTHER_ID]
	testing.expect(t, structured_live)
	testing.expect_value(t, len(live), 3)
}

@(test)
test_attachment_gc_dry_run_quarantine_restore_and_retained_purge :: proc(t: ^testing.T) {
	dir := attachment_gc_test_directory("sweep")
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	if !os.exists(dir) do return
	defer os.remove_all(dir)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_TASK_ID, "live"))
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_ORPHAN_ID, "orphan"))
	testing.expect(t, attachment_gc_test_write(dir, "operator-note", "leave me"))

	live := make(map[string]struct{})
	defer delete(live)
	live[ATTACHMENT_GC_TEST_TASK_ID] = {}
	options := Attachment_GC_Options {
		attachments_dir = dir,
		retention_days  = 30,
	}
	now := i64(1_800_000_000_000_000_000)
	dry, dry_ok := attachment_gc_sweep(options, live, now, dir)
	testing.expect(t, dry_ok && dry.active_files == 2 && dry.orphan_files == 1 && dry.skipped_entries == 1)
	orphan_path := storage_layout_path(dir, ATTACHMENT_GC_TEST_ORPHAN_ID)
	defer delete(orphan_path)
	quarantine_dir := storage_layout_path(dir, ATTACHMENT_GC_QUARANTINE_NAME)
	defer delete(quarantine_dir)
	testing.expect(t, os.exists(orphan_path) && !os.exists(quarantine_dir))

	options.apply = true
	applied, apply_ok := attachment_gc_sweep(options, live, now, dir)
	testing.expect(t, apply_ok && applied.orphan_files == 1)
	batch_dir := attachment_gc_test_batch_path(dir, now)
	defer delete(batch_dir)
	quarantined_path := storage_layout_path(batch_dir, ATTACHMENT_GC_TEST_ORPHAN_ID)
	defer delete(quarantined_path)
	testing.expect(t, !os.exists(orphan_path) && os.exists(quarantined_path))
	_, _, batch_safe := attachment_gc_batch_is_safe(batch_dir, now)
	testing.expect(t, batch_safe)

	live[ATTACHMENT_GC_TEST_ORPHAN_ID] = {}
	restored, restore_ok := attachment_gc_sweep(options, live, now + i64(24 * time.Hour), dir)
	testing.expect(t, restore_ok && restored.restored_files == 1)
	testing.expect(t, os.exists(orphan_path) && os.exists(quarantined_path))

	delete_key(&live, ATTACHMENT_GC_TEST_ORPHAN_ID)
	purged, purge_ok := attachment_gc_sweep(options, live, now + i64(31 * 24 * time.Hour), dir)
	testing.expect(t, purge_ok && purged.purged_batches == 1)
	testing.expect(t, !os.exists(batch_dir) && !os.exists(orphan_path))
	unknown_path := storage_layout_path(dir, "operator-note")
	defer delete(unknown_path)
	testing.expect(t, os.exists(unknown_path))
}

@(test)
test_attachment_gc_fails_closed_on_corrupt_quarantine_before_new_moves :: proc(t: ^testing.T) {
	dir := attachment_gc_test_directory("corrupt-batch")
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	if !os.exists(dir) do return
	defer os.remove_all(dir)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_ORPHAN_ID, "first"))
	live := make(map[string]struct{})
	defer delete(live)
	options := Attachment_GC_Options {
		attachments_dir = dir,
		retention_days  = 30,
		apply           = true,
	}
	now := i64(1_800_000_000_000_000_000)
	_, quarantined := attachment_gc_sweep(options, live, now, dir)
	testing.expect(t, quarantined)
	batch_dir := attachment_gc_test_batch_path(dir, now)
	defer delete(batch_dir)
	manifest_path := storage_layout_path(batch_dir, ATTACHMENT_GC_MANIFEST_NAME)
	defer delete(manifest_path)
	testing.expect(t, os.write_entire_file(manifest_path, transmute([]byte)string("corrupt\n")) == nil)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_OTHER_ID, "second"))

	stats, ok := attachment_gc_sweep(options, live, now + i64(31 * 24 * time.Hour), dir)
	testing.expect(t, !ok && stats.unsafe_batches == 1)
	first_quarantined := storage_layout_path(batch_dir, ATTACHMENT_GC_TEST_ORPHAN_ID)
	defer delete(first_quarantined)
	second_active := storage_layout_path(dir, ATTACHMENT_GC_TEST_OTHER_ID)
	defer delete(second_active)
	testing.expect(t, os.exists(first_quarantined) && os.exists(second_active))
}

@(test)
test_attachment_gc_keeps_blob_when_active_path_is_directory :: proc(t: ^testing.T) {
	dir := attachment_gc_test_directory("active-conflict")
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	if !os.exists(dir) do return
	defer os.remove_all(dir)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_ORPHAN_ID, "quarantined"))
	live := make(map[string]struct{})
	defer delete(live)
	options := Attachment_GC_Options {
		attachments_dir = dir,
		retention_days  = 0,
		apply           = true,
	}
	now := i64(1_800_000_000_000_000_000)
	_, quarantined := attachment_gc_sweep(options, live, now, dir)
	testing.expect(t, quarantined)
	active_path := storage_layout_path(dir, ATTACHMENT_GC_TEST_ORPHAN_ID)
	defer delete(active_path)
	testing.expect(t, os.make_directory(active_path) == nil)
	live[ATTACHMENT_GC_TEST_ORPHAN_ID] = {}

	_, ok := attachment_gc_sweep(options, live, now + i64(time.Hour), dir)
	testing.expect(t, !ok)
	batch_dir := attachment_gc_test_batch_path(dir, now)
	defer delete(batch_dir)
	blob_path := storage_layout_path(batch_dir, ATTACHMENT_GC_TEST_ORPHAN_ID)
	defer delete(blob_path)
	testing.expect(t, os.exists(blob_path))
}

@(test)
test_attachment_gc_retry_sync_failure_keeps_completed_batch :: proc(t: ^testing.T) {
	dir := attachment_gc_test_directory("retry-sync")
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	if !os.exists(dir) do return
	defer os.remove_all(dir)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_ORPHAN_ID, "blob"))
	live := make(map[string]struct{})
	defer delete(live)
	options := Attachment_GC_Options {
		attachments_dir = dir,
		retention_days  = 0,
		apply           = true,
	}
	now := i64(1_800_000_000_000_000_000)
	_, quarantined := attachment_gc_sweep(options, live, now, dir)
	testing.expect(t, quarantined)
	active_path := storage_layout_path(dir, ATTACHMENT_GC_TEST_ORPHAN_ID)
	defer delete(active_path)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_ORPHAN_ID, "blob"))
	live[ATTACHMENT_GC_TEST_ORPHAN_ID] = {}
	batch_dir := attachment_gc_test_batch_path(dir, now)
	defer delete(batch_dir)
	attachment_gc_fail_active_sync_for_test = true
	defer {attachment_gc_fail_active_sync_for_test = false}

	_, failed := attachment_gc_sweep(options, live, now + i64(time.Hour), dir)
	testing.expect(t, !failed && os.exists(batch_dir) && os.exists(active_path))
	_, retried := attachment_gc_sweep(options, live, now + i64(time.Hour), dir)
	testing.expect(t, retried && !os.exists(batch_dir) && os.exists(active_path))
}

@(test)
test_attachment_gc_rejects_same_size_active_content_mismatch :: proc(t: ^testing.T) {
	dir := attachment_gc_test_directory("active-content-mismatch")
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	if !os.exists(dir) do return
	defer os.remove_all(dir)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_ORPHAN_ID, "blob"))
	live := make(map[string]struct{})
	defer delete(live)
	options := Attachment_GC_Options {
		attachments_dir = dir,
		retention_days  = 0,
		apply           = true,
	}
	now := i64(1_800_000_000_000_000_000)
	_, quarantined := attachment_gc_sweep(options, live, now, dir)
	testing.expect(t, quarantined)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_ORPHAN_ID, "xxxx"))
	live[ATTACHMENT_GC_TEST_ORPHAN_ID] = {}
	batch_dir := attachment_gc_test_batch_path(dir, now)
	defer delete(batch_dir)

	_, ok := attachment_gc_sweep(options, live, now + i64(time.Hour), dir)
	testing.expect(t, !ok && os.exists(batch_dir))
}

@(test)
test_attachment_gc_database_barrier_failure_precedes_attachment_mutation :: proc(t: ^testing.T) {
	dir := attachment_gc_test_directory("database-sync-failure")
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	if !os.exists(dir) do return
	defer os.remove_all(dir)
	testing.expect(t, attachment_gc_test_write(dir, ATTACHMENT_GC_TEST_ORPHAN_ID, "blob"))
	live := make(map[string]struct{})
	defer delete(live)
	options := Attachment_GC_Options {
		attachments_dir = dir,
		retention_days  = 0,
		apply           = true,
	}
	attachment_gc_fail_database_sync_for_test = true
	defer {attachment_gc_fail_database_sync_for_test = false}
	previous_logger := context.logger
	context.logger = log.nil_logger()

	_, ok := attachment_gc_sweep(options, live, i64(1_800_000_000_000_000_000), dir)
	context.logger = previous_logger
	active_path := storage_layout_path(dir, ATTACHMENT_GC_TEST_ORPHAN_ID)
	defer delete(active_path)
	quarantine_dir := storage_layout_path(dir, ATTACHMENT_GC_QUARANTINE_NAME)
	defer delete(quarantine_dir)
	testing.expect(t, !ok && os.exists(active_path) && !os.exists(quarantine_dir))
}

@(test)
test_attachment_gc_replays_retained_message_file_references :: proc(t: ^testing.T) {
	data_dir := attachment_gc_test_directory("retained-message-replay")
	_ = os.remove_all(data_dir)
	testing.expect(t, os.make_directory(data_dir) == nil)
	if !os.exists(data_dir) do return
	defer os.remove_all(data_dir)
	if !testing.expect(t, storage_layout_test_create_generation(data_dir, 2)) do return
	workspace := "attachment-gc-retained-message-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 2)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	store: Message_Store
	if !testing.expect(t, init_message_store(&store, shard_dir, shard, 24 * time.Hour, 0)) do return
	message := test_retained_message(workspace, 9, 1, nrc_time_unix_nanos())
	content := fmt.tprintf("![upload](/files/%s?inline=true&filename=upload.png)", ATTACHMENT_GC_TEST_MESSAGE_ID)
	message.content = transmute([]byte)content
	message.fingerprint = message_fingerprint(&message)
	result, _ := append_or_deduplicate_message(&store, &message)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	if !testing.expect(t, shutdown_message_store(&store)) do return

	live := make(map[string]struct{})
	defer attachment_gc_destroy_live_references(&live)
	testing.expect(t, attachment_gc_mark_retained_messages(shard_dir, shard, &live))
	_, found := live[ATTACHMENT_GC_TEST_MESSAGE_ID]
	testing.expect(t, found)

	message_dir := fmt.aprintf("%s/messages", shard_dir)
	defer delete(message_dir)
	active_path := message_store_path(message_dir, 1, "wal")
	defer delete(active_path)
	wal, read_err := os.read_entire_file(active_path, context.allocator)
	if !testing.expect(t, read_err == nil && len(wal) > 0) do return
	defer delete(wal)
	wal[len(wal) - 1] ~= 0xff
	testing.expect(t, os.write_entire_file(active_path, wal) == nil)
	failed_live := make(map[string]struct{})
	defer attachment_gc_destroy_live_references(&failed_live)
	testing.expect(t, !attachment_gc_mark_retained_messages(shard_dir, shard, &failed_live))
}
