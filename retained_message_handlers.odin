package main

import "core:mem"
import "core:net"
import "core:strings"
import "core:sys/linux"
import "core:time"

import "byte_pool"
import nbio "nbio/poly"
import "persistence"
import pr "protocol"
import "storage_io"

when !NRC_SIMULATION {
	_ :: time.Duration
}

MAX_RETAINED_IO_PER_CONNECTION :: 4
RETAINED_PAGE_ARENA_BLOCK_BYTES :: 128 * 1024
RETAINED_COMMIT_WINDOW :: time.Millisecond
RETAINED_COMMIT_MAX_BYTES :: 128 * 1024

Retained_Dedup_Phase :: enum {
	Header,
	Probe,
	Record,
}
Retained_Dedup_Context :: struct {
	io_ctx:               Connection_IO_Context,
	store:                ^Message_Store,
	message:              Retained_Message,
	correlation_id:       u32,
	sender_sock:          net.TCP_Socket,
	sender_handle:        Connection_Handle,
	segment_index:        int,
	dedup_cutoff_ns:      i64,
	phase:                Retained_Dedup_Phase,
	index_file:           ^storage_io.File,
	wal_file:             ^storage_io.File,
	header:               [MESSAGE_INDEX_HEADER_SIZE]byte,
	entry:                [MESSAGE_DEDUP_ENTRY_SIZE]byte,
	count:                u64,
	dedup_offset:         u64,
	low:                  u64,
	high:                 u64,
	probe:                u64,
	record:               []byte,
	record_read:          int,
	holds_store_reader:   bool,
	counts_connection_io: bool,
	duplicates:           [dynamic]^Retained_Dedup_Context,
}

retained_message_release_store_reader :: proc(store: ^Message_Store) {
	assert(store != nil && store.async_readers > 0)
	store.async_readers -= 1
	if store.async_readers == 0 && store.rotation_pending && message_store_enabled(store) {
		retained_message_schedule_store_flush(store)
	}
}

destroy_retained_dedup_context :: proc(ctx: ^Retained_Dedup_Context, resume_rotation := true) {
	if ctx == nil do return
	for duplicate in ctx.duplicates do destroy_retained_dedup_context(duplicate, resume_rotation)
	delete(ctx.duplicates)
	if ctx.index_file != nil do storage_io.discard(ctx.index_file)
	if ctx.wal_file != nil do storage_io.discard(ctx.wal_file)
	if ctx.holds_store_reader {
		if resume_rotation {
			retained_message_release_store_reader(ctx.store)
		} else {
			assert(ctx.store != nil && ctx.store.async_readers > 0)
			ctx.store.async_readers -= 1
		}
	}
	if ctx.counts_connection_io {if conn := connection_from_io_context(ctx.io_ctx); conn != nil {assert(conn.retained_io > 0); conn.retained_io -= 1}}
	delete(ctx.record); destroy_retained_message(&ctx.message)
	connection_io_unpin(ctx.io_ctx); free(ctx)
}

when NRC_SIMULATION {
	retained_message_discard_speculative_process_state :: proc(registry: ^Message_Store_Registry) {
		if registry == nil do return
		for index in 0 ..< registry.pending_write_count {
			if store := registry.pending_writes[index]; store != nil do store.write_batch_pending = false
			registry.pending_writes[index] = nil
		}
		registry.pending_write_count = 0
		for &store in registry.stores {
			store.write_batch_pending = false
			delete(store.pending_dedup)
			store.pending_dedup = nil
			for pending in store.pending_appends {
				if len(pending.dedup_key) > 0 do delete(pending.dedup_key)
				destroy_retained_dedup_context((^Retained_Dedup_Context)(pending.ctx), false)
			}
			clear(&store.pending_appends)
			delete(store.deferred_dedup)
			store.deferred_dedup = nil
			for deferred in store.deferred_appends[store.deferred_head:] {
				if len(deferred.dedup_key) > 0 do delete(deferred.dedup_key)
				destroy_retained_dedup_context((^Retained_Dedup_Context)(deferred.ctx), false)
			}
			clear(&store.deferred_appends)
			store.deferred_head = 0
			store.rotation_pending = false
		}
	}
}

send_retained_message_page :: proc(c: ^NRC_Connection, page: pr.MessagePage) -> bool {
	protocol_size := pr.getSizeMessagePage(page)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "retained message page")
	if buf == nil do return false
	protocol_len := pr.serializeMessagePage(page, buf[header_len:])
	if protocol_len <= 0 {byte_pool.release(td.spool, buf); return false}
	return send_pooled_buffer(c, buf[:header_len + protocol_len])
}

broadcast_retained_message :: proc(message: ^Retained_Message, excluded_sock: net.TCP_Socket, excluded_handle: Connection_Handle) {
	ws := get_workspace(message.workspace); if ws == nil do return
	conv := get_conversation(ws, pr.ConversationID(message.conversation_id)); if conv == nil || subscriber_count(conv) == 0 do return
	record := pr.MessageRecord {
		conv_id           = pr.ConversationID(message.conversation_id),
		seq               = pr.MessageSeq(message.sequence),
		client_message_id = message.client_message_id,
		author_username   = transmute([]byte)message.sender_name,
		timestamp         = message.accepted_at_ns,
		content_type      = pr.MessageContentType(message.content_type),
		content           = message.content,
	}
	page := pr.MessagePage {
		conv_id             = record.conv_id,
		ascending           = true,
		high_water_seq      = record.seq,
		continuation_cursor = record.seq,
		messages            = []pr.MessageRecord{record},
	}
	protocol_size := pr.getSizeMessagePage(page)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "retained message broadcast"); if buf == nil do return
	protocol_len := pr.serializeMessagePage(page, buf[header_len:]); if protocol_len <= 0 {byte_pool.release(td.spool, buf); return}
	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool)); shared.data = buf[:header_len + protocol_len]; shared.ref_count = 1; shared.pool = td.spool
	_ = send_shared_to_subscriber_entries(conv, excluded_sock, shared, excluded_handle)
}

finish_retained_send :: proc(ctx: ^Retained_Dedup_Context, result: Message_Store_Result, sequence: u64) {
	conn := connection_from_io_context(ctx.io_ctx)
	if result == .Appended || result == .Duplicate {
		ctx.message.sequence = sequence
		if conn != nil do send_ack_message_direct(conn, pr.AckSendMessage{client_req_id = ctx.correlation_id, assigned_seq = pr.MessageSeq(sequence), timestamp = ctx.message.accepted_at_ns})
		if result == .Appended do broadcast_retained_message(&ctx.message, ctx.sender_sock, ctx.sender_handle)
	} else if conn != nil {
		text := result == .Conflict ? "client message id conflicts with an earlier message" : "retained message storage failed"
		send_error_response(conn, .C_SendMessageV2, text, ctx.correlation_id)
	}
	// Followers retain their admitted primary, even across rotation or ID reuse.
	for duplicate in ctx.duplicates do finish_retained_send(duplicate, result == .Appended ? .Duplicate : result, sequence)
	clear(&ctx.duplicates)
	destroy_retained_dedup_context(ctx)
}

retained_message_fail_deferred :: proc(store: ^Message_Store) {
	for deferred in store.deferred_appends[store.deferred_head:] {
		if len(deferred.dedup_key) > 0 do delete(deferred.dedup_key)
		finish_retained_send((^Retained_Dedup_Context)(deferred.ctx), .Poisoned, 0)
	}
	clear(&store.deferred_appends)
	store.deferred_head = 0
	delete(store.deferred_dedup)
	store.deferred_dedup = nil
}

retained_message_stage_deferred :: proc(store: ^Message_Store) {
	// Consume only what fits; preserve the untouched tail and its dedup keys.
	end := len(store.deferred_appends)
	for store.deferred_head < end && !store.rotation_pending {
		index := store.deferred_head
		item := store.deferred_appends[index]
		ctx := (^Retained_Dedup_Context)(item.ctx)
		delete_key(&store.deferred_dedup, item.dedup_key)
		if !retained_message_try_stage_append(ctx, item.dedup_key) {
			store.deferred_dedup[item.dedup_key] = index
			break
		}
		store.deferred_appends[index] = {}
		store.deferred_head += 1
	}
	if store.deferred_head == len(store.deferred_appends) {
		clear(&store.deferred_appends)
		store.deferred_head = 0
	} else if store.deferred_head >= len(store.deferred_appends) - store.deferred_head {
		// Repair indexes only after consuming at least as much as remains,
		// so compaction is amortized linear rather than per-batch tail work.
		remaining := len(store.deferred_appends) - store.deferred_head
		copy(store.deferred_appends[:remaining], store.deferred_appends[store.deferred_head:])
		resize(&store.deferred_appends, remaining)
		store.deferred_head = 0
		for item, index in store.deferred_appends {
			store.deferred_dedup[item.dedup_key] = index
		}
	}
}

retained_message_finish_staged_batch :: proc(store: ^Message_Store, write_ok: bool) -> bool {
	if store == nil || len(store.pending_appends) == 0 do return write_ok
	publish_ok := write_ok && message_store_enabled(store)
	if publish_ok {
		for pending in store.pending_appends {
			if pending.duplicate do continue
			ctx := (^Retained_Dedup_Context)(pending.ctx)
			ctx.message.sequence = pending.sequence
			record := store.wal.write_buffer[pending.batch_offset:pending.batch_offset + int(pending.length)]
			if !publish_staged_message(store, &ctx.message, pending.dedup_key, pending.offset, pending.length, record[persistence.LOG_HEADER_SIZE:]) {
				publish_ok = false
				break
			}
		}
	}
	for pending in store.pending_appends {
		if len(pending.dedup_key) > 0 {
			delete_key(&store.pending_dedup, pending.dedup_key)
			delete(pending.dedup_key)
		}
		ctx := (^Retained_Dedup_Context)(pending.ctx)
		result := Message_Store_Result.Poisoned
		if publish_ok do result = pending.duplicate ? .Duplicate : .Appended
		finish_retained_send(ctx, result, pending.sequence)
	}
	clear(&store.pending_appends)
	if !publish_ok {
		store.poisoned = true
		retained_message_fail_deferred(store)
		if td.server != nil do server_shutdown_after_storage_error(td.server)
	} else if store.rotation_pending {
		// Do not let deferred work refill A between the staged-write callback
		// wave and the pending rotation safe point.
		retained_message_schedule_store_flush(store)
	} else if len(store.deferred_appends) > 0 {
		retained_message_stage_deferred(store)
	}
	return publish_ok
}

retained_message_flush_store :: proc(store: ^Message_Store) -> bool {
	if store == nil do return true
	if store.seal_ready && !publish_frozen_message_seal(store) {
		// Publication is attempted before the active batch is written. Discard
		// only that never-written suffix, then complete every staged request so
		// fatal shutdown cannot strand its context or connection pins.
		store.poisoned = true
		persistence.reset_buffered_write_state(&store.wal)
		_ = retained_message_finish_staged_batch(store, false)
		retained_message_fail_deferred(store)
		if td.server != nil do server_shutdown_after_storage_error(td.server)
		return false
	}
	if len(store.pending_appends) == 0 {
		if !store.rotation_pending do return true
		if store.frozen != nil do return true
		if store.async_readers != 0 do return true
		if store.fsync_in_flight do return true
		now_ns := nrc_time_unix_nanos()
		if len(store.deferred_appends) > 0 {
			now_ns = (^Retained_Dedup_Context)(store.deferred_appends[store.deferred_head].ctx).message.accepted_at_ns
		}
		ok := false
		if message_seal_service_available() && store.wal.record_count > 0 {
			ok = enqueue_message_seal(store, now_ns)
		} else {
			ok = rotate_message_store(store, now_ns)
		}
		store.rotation_pending = false
		if !ok {
			store.poisoned = true
			retained_message_fail_deferred(store)
			if td.server != nil do server_shutdown_after_storage_error(td.server)
			return false
		}
		retained_message_stage_deferred(store)
		return true
	}
	write_ok := message_store_enabled(store) && persistence.flush_write_batch_deferred_fsync(&store.wal)
	if write_ok do _ = schedule_retained_message_fsync(store)
	if !write_ok do persistence.reset_buffered_write_state(&store.wal)
	return retained_message_finish_staged_batch(store, write_ok)
}

retained_message_schedule_store_flush :: proc(store: ^Message_Store) {
	if store.write_batch_pending do return
	registry := &td.message_stores
	assert(registry.pending_write_count < len(registry.pending_writes), "message store flush registry exhausted")
	store.write_batch_pending = true
	registry.pending_writes[registry.pending_write_count] = store
	registry.pending_write_count += 1
}

retained_message_fsync_complete :: proc(store: ^Message_Store, err: linux.Errno) {
	if store == nil || !store.fsync_in_flight do return
	snapshot := store.fsync_snapshot
	elapsed := time.diff(store.fsync_started, store.wal.get_time())
	store.fsync_in_flight = false
	store.fsync_snapshot = {}
	store.fsync_started = {}
	if !persistence.complete_async_fsync(&store.wal, snapshot, elapsed, err) {
		store.poisoned = true
		store.rotation_pending = false
		retained_message_fail_deferred(store)
		if td.server != nil do server_shutdown_after_storage_error(td.server)
		return
	}
	resume_durable_outboxes(&store.durability_waiters)
	if store.rotation_pending do retained_message_schedule_store_flush(store)
}

retained_message_commit_due :: proc(store: ^Message_Store) -> bool {
	if store == nil || !message_store_enabled(store) || store.fsync_in_flight || store.wal.pending_bytes == 0 do return false
	return(
		store.wal.pending_bytes >= RETAINED_COMMIT_MAX_BYTES ||
		(store.commit_pending && time.diff(store.commit_started, store.wal.get_time()) >= RETAINED_COMMIT_WINDOW) \
	)
}

schedule_retained_message_fsync :: proc(store: ^Message_Store) -> bool {
	if store == nil || !message_store_enabled(store) do return false
	// Only a suffix behind an in-flight snapshot starts the next window.
	if store.wal.pending_bytes > store.fsync_snapshot.pending_bytes && !store.commit_pending {
		store.commit_pending = true
		store.commit_started = store.wal.get_time()
	}
	if !retained_message_commit_due(store) do return false
	snapshot := persistence.WAL_Fsync_Snapshot {
		last_hash     = store.wal.last_hash,
		record_count  = store.wal.record_count,
		pending_bytes = store.wal.pending_bytes,
	}
	store.fsync_in_flight = true
	store.fsync_snapshot = snapshot
	store.fsync_started = store.wal.get_time()
	store.commit_pending = false
	_ = nrc_io_sync_file(store.wal.file, rawptr(store), proc(user: rawptr, err: linux.Errno) {retained_message_fsync_complete((^Message_Store)(user), err)})
	return true
}

flush_pending_retained_message_writes :: proc(registry: ^Message_Store_Registry) -> (did_work, ok: bool) {
	if registry == nil || registry.pending_write_count == 0 do return false, true
	count := registry.pending_write_count
	registry.pending_write_count = 0
	ok = true
	for i in 0 ..< count {
		store := registry.pending_writes[i]
		registry.pending_writes[i] = nil
		if store == nil do continue
		did_work = true
		store.write_batch_pending = false
		if !retained_message_flush_store(store) do ok = false
	}
	return
}

retained_message_defer_append :: proc(store: ^Message_Store, ctx: ^Retained_Dedup_Context, key: string) -> bool {
	deferred_index := len(store.deferred_appends)
	_, append_err := append(&store.deferred_appends, Message_Deferred_Append{ctx = ctx, dedup_key = key})
	if append_err != nil {
		delete(key); finish_retained_send(ctx, .Poisoned, 0); return false
	}
	if store.deferred_dedup == nil do store.deferred_dedup = make(map[string]int, 16)
	store.deferred_dedup[key] = deferred_index
	return true
}

retained_message_queue_committed_duplicate :: proc(store: ^Message_Store, ctx: ^Retained_Dedup_Context, sequence: u64) {
	if reserve(&store.pending_appends, len(store.pending_appends) + 1) != nil {
		finish_retained_send(ctx, .Poisoned, 0); return
	}
	_, append_err := append(&store.pending_appends, Message_Pending_Append{ctx = ctx, sequence = sequence, duplicate = true})
	if append_err != nil do unreachable()
	retained_message_schedule_store_flush(store)
}

retained_message_queue_append :: proc(ctx: ^Retained_Dedup_Context, sealed_checked: bool) {
	store := ctx.store
	// A completed negative lookup owns its message, not segment offsets. Drop
	// its pin before deferring admission so publication cannot deadlock on it.
	if sealed_checked && ctx.holds_store_reader {
		if ctx.index_file != nil {storage_io.discard(ctx.index_file); ctx.index_file = nil}
		if ctx.wal_file != nil {storage_io.discard(ctx.wal_file); ctx.wal_file = nil}
		ctx.holds_store_reader = false
		retained_message_release_store_reader(store)
	}
	if !message_store_enabled(store) || td.state == .Closing {finish_retained_send(ctx, .Poisoned, 0); return}
	ctx.message.fingerprint = message_fingerprint(&ctx.message)
	if ctx.message.fingerprint == 0 {finish_retained_send(ctx, .Invalid, 0); return}
	key := message_dedup_key(ctx.message.workspace, ctx.message.sender_principal, ctx.message.client_message_id)
	if result, sequence, found := message_store_active_dedup(store, &ctx.message, key); found {
		delete(key)
		if result == .Duplicate {
			retained_message_queue_committed_duplicate(store, ctx, sequence)
		} else {
			finish_retained_send(ctx, result, sequence)
		}
		return
	}
	if pending_index, found := store.pending_dedup[key]; found {
		primary := &store.pending_appends[pending_index]
		primary_ctx := (^Retained_Dedup_Context)(primary.ctx)
		delete(key)
		if primary_ctx.message.fingerprint != ctx.message.fingerprint {
			finish_retained_send(ctx, .Conflict, 0)
			return
		}
		ctx.message.accepted_at_ns = primary_ctx.message.accepted_at_ns
		_, append_err := append(&store.pending_appends, Message_Pending_Append{ctx = ctx, sequence = primary.sequence, duplicate = true})
		if append_err != nil do finish_retained_send(ctx, .Poisoned, 0)
		return
	}
	if deferred_index, found := store.deferred_dedup[key]; found {
		primary := &store.deferred_appends[deferred_index]
		primary_ctx := (^Retained_Dedup_Context)(primary.ctx)
		delete(key)
		if primary_ctx.message.fingerprint != ctx.message.fingerprint {
			finish_retained_send(ctx, .Conflict, 0)
			return
		}
		ctx.message.accepted_at_ns = primary_ctx.message.accepted_at_ns
		_, append_err := append(&primary_ctx.duplicates, ctx)
		if append_err != nil do finish_retained_send(ctx, .Poisoned, 0)
		return
	}
	if !sealed_checked && message_store_next_dedup_segment(store, len(store.segments) - 1, ctx.dedup_cutoff_ns, &ctx.message) >= 0 {
		delete(key)
		store.async_readers += 1
		ctx.holds_store_reader = true
		ctx.segment_index = len(store.segments) - 1
		retained_dedup_open_segment(ctx)
		_ = nbio.submit_pending(&td.io)
		return
	}
	if !retained_message_try_stage_append(ctx, key) {
		_ = retained_message_defer_append(store, ctx, key)
	}
}

// False retains ctx/key ownership with the caller while a full batch or
// rotation blocks staging. True consumes them, including terminal failures.
retained_message_try_stage_append :: proc(ctx: ^Retained_Dedup_Context, key: string) -> bool {
	store := ctx.store
	if !message_store_enabled(store) {delete(key); finish_retained_send(ctx, .Poisoned, 0); return true}
	if store.rotation_pending do return false
	size, valid := message_record_size(&ctx.message)
	if !valid || int(shard_for_workspace(transmute([]byte)ctx.message.workspace)) != store.shard {
		delete(key); finish_retained_send(ctx, .Invalid, 0); return true
	}
	record_length := persistence.LOG_HEADER_SIZE + size
	if record_length >= persistence.WRITE_BATCH_MAX_BYTES {
		delete(key); finish_retained_send(ctx, .Invalid, 0); return true
	}
	write_batch_records := td.message_stores.write_batch_records
	if write_batch_records > 0 && store.wal.buffered_record_count >= u64(write_batch_records) {
		return false
	}
	if store.wal.write_offset + record_length >= persistence.WRITE_BATCH_MAX_BYTES {
		return false
	}
	record_bytes := u64(record_length)
	if store.quota_bytes > 0 && store.total_bytes + u64(store.wal.write_offset) + record_bytes > store.quota_bytes {
		delete(key); finish_retained_send(ctx, .Capacity, 0); return true
	}
	if store.wal.record_count + store.wal.buffered_record_count + 1 > MESSAGE_MAX_INDEX_RECORDS {
		store.rotation_pending = true
		retained_message_schedule_store_flush(store)
		return false
	}
	now_hour := ctx.message.accepted_at_ns / i64(time.Hour)
	if store.wal.buffered_record_count == 0 &&
	   store.wal.record_count > 0 &&
	   (store.active_bytes + record_bytes >= MESSAGE_SEGMENT_BYTES ||
			   now_hour != store.active_started_hour ||
			   store.active_index_arena.total_used >= MESSAGE_ACTIVE_INDEX_BUDGET) {
		store.rotation_pending = true
		retained_message_schedule_store_flush(store)
		return false
	}
	if !store.active_arena_ready && !init_active_message_indexes(store) {delete(key); finish_retained_send(ctx, .Poisoned, 0); return true}
	ctx.message.sequence = store.high_water + store.wal.buffered_record_count + 1
	batch_offset := store.wal.write_offset
	offset := store.active_bytes + u64(batch_offset)
	pending_index := len(store.pending_appends)
	if reserve(&store.pending_appends, pending_index + 1) != nil {
		delete(key); finish_retained_send(ctx, .Poisoned, 0); return true
	}
	if store.pending_dedup == nil do store.pending_dedup = make(map[string]int, 16)
	record := store.wal.write_buffer[batch_offset:][:record_length]
	assert(encode_message_record(&ctx.message, record[persistence.LOG_HEADER_SIZE:]), "validated retained message failed to encode")
	assert(persistence.stage_record_in_place(&store.wal, 1, record_length), "bounded retained message failed to stage")
	if _, append_err := append(
		&store.pending_appends,
		Message_Pending_Append {
			ctx = ctx,
			dedup_key = key,
			offset = offset,
			length = u32(record_length),
			sequence = ctx.message.sequence,
			batch_offset = batch_offset,
		},
	); append_err != nil {
		unreachable()
	}
	store.pending_dedup[key] = pending_index
	retained_message_schedule_store_flush(store)
	return true
}

retained_dedup_submit_probe :: proc(ctx: ^Retained_Dedup_Context) {
	if ctx.low >= ctx.high {
		if ctx.low >= ctx.count {
			storage_io.discard(ctx.index_file); ctx.index_file = nil; storage_io.discard(ctx.wal_file); ctx.wal_file = nil
			ctx.segment_index -= 1; retained_dedup_open_segment(ctx); return
		}
		ctx.probe = ctx.low
	} else {
		ctx.probe = ctx.low + (ctx.high - ctx.low) / 2
	}
	ctx.phase = .Probe
	_ = nrc_io_read_file_at(
		ctx.index_file,
		ctx.entry[:],
		ctx.dedup_offset + ctx.probe * MESSAGE_DEDUP_ENTRY_SIZE,
		ctx,
		retained_dedup_on_read_raw,
		retained_dedup_read_discard_raw,
	)
}

retained_dedup_entry_compare :: proc(ctx: ^Retained_Dedup_Context) -> int {
	workspace_hash := message_get_u64(ctx.entry[:]); principal_hash := message_get_u64(ctx.entry[8:])
	target_workspace := message_string_hash(ctx.message.workspace); target_principal := message_string_hash(ctx.message.sender_principal)
	if workspace_hash != target_workspace do return workspace_hash < target_workspace ? -1 : 1
	if principal_hash != target_principal do return principal_hash < target_principal ? -1 : 1
	for value, i in ctx.message.client_message_id {
		other := ctx.entry[16 + i]; if other != value do return other < value ? -1 : 1
	}
	return 0
}

retained_dedup_open_segment :: proc(ctx: ^Retained_Dedup_Context) {
	ctx.segment_index = message_store_next_dedup_segment(ctx.store, ctx.segment_index, ctx.dedup_cutoff_ns, &ctx.message)
	if ctx.segment_index < 0 {
		ctx.message.accepted_at_ns = nrc_time_unix_nanos()
		retained_message_queue_append(ctx, true); return
	}
	segment := ctx.store.segments[ctx.segment_index]
	index_path := message_store_path(
		ctx.store.directory,
		segment.generation,
		"idx",
	); wal_path := message_store_path(ctx.store.directory, segment.generation, "wal")
	ctx.index_file, _ = storage_io.open(
		ctx.store.storage,
		index_path,
		{.Read},
	); ctx.wal_file, _ = storage_io.open(ctx.store.storage, wal_path, {.Read}); delete(index_path); delete(wal_path)
	if ctx.index_file == nil || ctx.wal_file == nil {ctx.store.poisoned = true; finish_retained_send(ctx, .Poisoned, 0); return}
	ctx.phase = .Header
	_ = nrc_io_read_file_at(ctx.index_file, ctx.header[:], 0, ctx, retained_dedup_on_read_raw, retained_dedup_read_discard_raw)
}

retained_dedup_on_read_raw :: proc(user: rawptr, read: int, err: linux.Errno) {
	retained_dedup_on_read((^Retained_Dedup_Context)(user), read, err)
}

retained_dedup_read_discard_raw :: proc(user: rawptr) {
	destroy_retained_dedup_context((^Retained_Dedup_Context)(user), false)
}

retained_dedup_on_read :: proc(ctx: ^Retained_Dedup_Context, read: int, err: linux.Errno) {
	if err != .NONE {ctx.store.poisoned = true; finish_retained_send(ctx, .Poisoned, 0); return}
	switch ctx.phase {
	case .Header:
		if read != len(ctx.header) || message_get_u32(ctx.header[:]) != MESSAGE_INDEX_MAGIC {ctx.store.poisoned = true; finish_retained_send(ctx, .Poisoned, 0)
			return}
		ctx.count = message_get_u64(ctx.header[24:])
		ctx.dedup_offset = message_get_u64(ctx.header[40:])
		ctx.low = 0
		ctx.high = ctx.count
		retained_dedup_submit_probe(ctx)
	case .Probe:
		if read != MESSAGE_DEDUP_ENTRY_SIZE {ctx.store.poisoned = true; finish_retained_send(ctx, .Poisoned, 0); return}
		comparison := retained_dedup_entry_compare(ctx)
		if ctx.low < ctx.high {
			if comparison < 0 {
				ctx.low = ctx.probe + 1
			} else {
				ctx.high = ctx.probe
			}
			retained_dedup_submit_probe(ctx); return
		}
		if comparison != 0 {
			storage_io.discard(ctx.index_file); ctx.index_file = nil; storage_io.discard(ctx.wal_file); ctx.wal_file = nil
			ctx.segment_index -= 1; retained_dedup_open_segment(ctx); return
		}
		length := int(
			message_get_u32(ctx.entry[56:]),
		); if length < persistence.LOG_HEADER_SIZE {ctx.store.poisoned = true; finish_retained_send(ctx, .Poisoned, 0); return}
		ctx.record = make([]byte, length); ctx.record_read = 0; ctx.phase = .Record
		_ = nrc_io_read_file_at(ctx.wal_file, ctx.record, message_get_u64(ctx.entry[48:]), ctx, retained_dedup_on_read_raw, retained_dedup_read_discard_raw)
	case .Record:
		if read <= 0 && ctx.record_read < len(ctx.record) {ctx.store.poisoned = true; finish_retained_send(ctx, .Poisoned, 0); return}
		ctx.record_read += read
		if ctx.record_read < len(ctx.record) {
			_ = nrc_io_read_file_at(
				ctx.wal_file,
				ctx.record[ctx.record_read:],
				message_get_u64(ctx.entry[48:]) + u64(ctx.record_read),
				ctx,
				retained_dedup_on_read_raw,
				retained_dedup_read_discard_raw,
			); return
		}
		stored, ok := decode_message_record(ctx.record[persistence.LOG_HEADER_SIZE:])
		if !ok {destroy_retained_message(&stored); ctx.store.poisoned = true; finish_retained_send(ctx, .Poisoned, 0); return}
		exact :=
			stored.workspace == ctx.message.workspace &&
			stored.sender_principal == ctx.message.sender_principal &&
			stored.client_message_id == ctx.message.client_message_id
		if !exact {
			destroy_retained_message(&stored); delete(ctx.record); ctx.record = nil
			ctx.low = ctx.probe + 1; ctx.high = ctx.low; retained_dedup_submit_probe(ctx); return
		}
		if stored.accepted_at_ns < ctx.dedup_cutoff_ns {
			destroy_retained_message(&stored); delete(ctx.record); ctx.record = nil
			ctx.low = ctx.probe + 1; ctx.high = ctx.low; retained_dedup_submit_probe(ctx); return
		}
		result := stored.fingerprint == ctx.message.fingerprint ? Message_Store_Result.Duplicate : Message_Store_Result.Conflict
		sequence := stored.sequence; ctx.message.accepted_at_ns = stored.accepted_at_ns; destroy_retained_message(&stored)
		finish_retained_send(ctx, result, sequence)
	}
}

process_send_message_v2 :: proc(c: ^NRC_Connection, req: pr.SendMessageV2Request) {
	if req.conv_id == pr.WORKSPACE_DATA_ID {
		send_error_response(c, .C_SendMessageV2, "Workspace data scope is not a chat", req.correlation_id)
		return
	}
	if req.client_message_id == {} {send_error_response(c, .C_SendMessageV2, "client message id must not be zero", req.correlation_id); return}
	if pr.is_dm_conversation(req.conv_id) {
		// DM membership is currently volatile; retained history must not outlive its access-control metadata.
		send_error_response(c, .C_SendMessageV2, "retained direct messages are not enabled", req.correlation_id); return
	}
	store := message_store_for_workspace(&td.message_stores, transmute([]byte)c.workspace_id)
	if store == nil {send_error_response(c, .C_SendMessageV2, "message retention is disabled", req.correlation_id); return}
	ctx := new(Retained_Dedup_Context); ctx.store = store; ctx.correlation_id = req.correlation_id; ctx.sender_sock = c.sock; ctx.sender_handle = c.handle
	ctx.message.conversation_id = u64(req.conv_id); ctx.message.client_message_id = req.client_message_id
	ctx.message.accepted_at_ns = nrc_time_unix_nanos(); ctx.message.content_type = u8(req.content_type)
	ctx.message.workspace, _ = strings.clone(
		c.workspace_id,
	); ctx.message.sender_name, _ = strings.clone(get_connection_nickname(c)); ctx.message.sender_principal, _ = strings.clone(c.verified_username)
	ctx.message.content = make([]byte, len(req.content)); copy(ctx.message.content, req.content)
	ctx.dedup_cutoff_ns = message_store_dedup_cutoff(store, ctx.message.accepted_at_ns)
	if c.retained_io >= MAX_RETAINED_IO_PER_CONNECTION {
		send_error_response(c, .C_SendMessageV2, "too many retained message operations", req.correlation_id); destroy_retained_dedup_context(ctx); return
	}
	if !connection_io_pin(c) {destroy_retained_dedup_context(ctx); return}
	ctx.io_ctx = connection_io_context_make(c); ctx.io_ctx.pinned = true
	c.retained_io += 1
	ctx.counts_connection_io = true
	retained_message_queue_append(ctx, false)
}

RETAINED_PAGE_BYTE_BUDGET :: 96 * 1024
RETAINED_HISTORY_MAX_COALESCED_READ_BYTES :: 1024 * 1024
RETAINED_HISTORY_MAX_READ_AMPLIFICATION :: 4
RETAINED_HISTORY_MAX_PARALLEL_READS :: 32
Retained_History_Phase :: enum {
	Probe,
	Entries,
}
Retained_Read_Spec :: struct {
	offset:         u64,
	length:         u32,
	sequence:       u64,
	accepted_at_ns: i64,
	cached_payload: []byte,
}
Retained_Parallel_Read :: struct {
	parent:     rawptr,
	storage:    []byte,
	offset:     u64,
	bytes_read: int,
	done:       bool,
}
when NRC_SIMULATION {
	Retained_History_Profile :: struct {
		enabled:        bool,
		started:        time.Time,
		retrieval:      time.Duration,
		decode:         time.Duration,
		decode_started: time.Time,
		decode_active:  bool,
		serialization:  time.Duration,
	}

	@(thread_local)
	retained_history_profile_enabled: bool
	@(thread_local)
	retained_history_profile_latest: Retained_History_Profile

	retained_history_profile_end_decode :: proc(ctx: ^Retained_History_Context) {
		if ctx.profile.enabled && ctx.profile.decode_active {
			ctx.profile.decode += time.since(ctx.profile.decode_started)
			ctx.profile.decode_active = false
		}
	}
} else {
	Retained_History_Profile :: struct {}
}
Retained_History_Context :: struct {
	io_ctx:               Connection_IO_Context,
	store:                ^Message_Store,
	frozen:               ^Message_Store,
	sealed_count:         int,
	workspace:            string,
	conversation_id:      u64,
	correlation_id:       u32,
	before:               u64,
	after:                u64,
	limit:                int,
	ascending:            bool,
	high_water:           u64,
	cutoff_ns:            i64,
	cutoff_seq:           u64,
	segment_index:        int,
	segment_step:         int,
	index_file:           ^storage_io.File,
	cached_message_index: []byte,
	wal_file:             ^storage_io.File,
	owns_wal_file:        bool,
	wal_segment:          ^Message_Segment_Descriptor,
	holds_store_reader:   bool,
	counts_connection_io: bool,
	phase:                Retained_History_Phase,
	entry:                [MESSAGE_INDEX_ENTRY_SIZE]byte,
	entry_buffer:         [101 * MESSAGE_INDEX_ENTRY_SIZE]byte,
	low:                  u64,
	high:                 u64,
	probe:                u64,
	target_sequence:      u64,
	target_upper:         bool,
	range_start:          u64,
	range_end:            u64,
	conversation_start:   u64,
	conversation_end:     u64,
	chunk_start:          u64,
	chunk_count:          int,
	specs:                [dynamic]Retained_Read_Spec,
	active_specs:         [dynamic]Retained_Read_Spec,
	frozen_specs:         [dynamic]Retained_Read_Spec,
	active_processed:     bool,
	spec_index:           int,
	record_storage:       []byte,
	record_batch_count:   int,
	record_coalesced:     bool,
	records_clustered:    bool,
	record_span_offset:   u64,
	record_bytes_read:    int,
	parallel_reads:       []Retained_Parallel_Read,
	parallel_pending:     int,
	parallel_failed:      bool,
	parallel_discarded:   bool,
	message_arena:        mem.Dynamic_Arena,
	message_arena_ready:  bool,
	messages:             [dynamic]Retained_Message,
	page_bytes:           int,
	has_more:             bool,
	truncated:            bool,
	profile:              Retained_History_Profile,
}

destroy_retained_history_context :: proc(ctx: ^Retained_History_Context, resume_rotation := true) {
	if ctx.index_file != nil do storage_io.discard(ctx.index_file)
	if ctx.wal_segment != nil do release_message_segment_read_borrow(ctx.wal_segment)
	if ctx.wal_file != nil && ctx.owns_wal_file do storage_io.discard(ctx.wal_file)
	if ctx.frozen != nil {
		assert(ctx.frozen.async_readers > 0)
		ctx.frozen.async_readers -= 1
	}
	if ctx.holds_store_reader {
		if resume_rotation {
			retained_message_release_store_reader(ctx.store)
		} else {
			assert(ctx.store != nil && ctx.store.async_readers > 0)
			ctx.store.async_readers -= 1
		}
	}
	if ctx.counts_connection_io {if conn := connection_from_io_context(ctx.io_ctx); conn != nil {assert(conn.retained_io > 0); conn.retained_io -= 1}}
	delete(ctx.workspace); delete(ctx.specs); delete(ctx.active_specs); delete(ctx.frozen_specs); retained_history_clear_record_batch(ctx)
	if ctx.message_arena_ready do mem.dynamic_arena_destroy(&ctx.message_arena)
	delete(ctx.messages); connection_io_unpin(ctx.io_ctx); free(ctx)
}

retained_history_fail :: proc(ctx: ^Retained_History_Context) {
	ctx.store.poisoned = true
	if conn := connection_from_io_context(ctx.io_ctx); conn != nil do send_error_response(conn, ctx.ascending ? .C_ReplayMessagesAfter : .C_ListMessagesBefore, "retained history read failed", ctx.correlation_id)
	destroy_retained_history_context(ctx)
}

retained_history_capacity :: proc(ctx: ^Retained_History_Context) {
	if conn := connection_from_io_context(ctx.io_ctx); conn != nil do send_error_response(conn, ctx.ascending ? .C_ReplayMessagesAfter : .C_ListMessagesBefore, "retained history capacity reached", ctx.correlation_id)
	destroy_retained_history_context(ctx)
}

retained_history_finish :: proc(ctx: ^Retained_History_Context) {
	conn := connection_from_io_context(ctx.io_ctx)
	if conn != nil {
		when NRC_SIMULATION {
			retained_history_profile_end_decode(ctx)
			serialization_started: time.Time
			if ctx.profile.enabled do serialization_started = time.now()
		}
		record_storage: [pr.MAX_MESSAGE_PAGE_COUNT]pr.MessageRecord
		records := record_storage[:len(ctx.messages)]
		for &message, i in ctx.messages {
			records[i] = {
				conv_id           = pr.ConversationID(message.conversation_id),
				seq               = pr.MessageSeq(message.sequence),
				client_message_id = message.client_message_id,
				author_username   = transmute([]byte)message.sender_name,
				timestamp         = message.accepted_at_ns,
				content_type      = pr.MessageContentType(message.content_type),
				content           = message.content,
			}
		}
		cursor: u64
		if len(ctx.messages) > 0 do cursor = ctx.messages[len(ctx.messages) - 1].sequence
		_ = send_retained_message_page(
			conn,
			pr.MessagePage {
				conv_id = pr.ConversationID(ctx.conversation_id),
				ascending = ctx.ascending,
				has_more = ctx.has_more,
				truncated = ctx.truncated,
				high_water_seq = pr.MessageSeq(ctx.high_water),
				retention_cutoff_seq = pr.MessageSeq(ctx.cutoff_seq),
				continuation_cursor = pr.MessageSeq(cursor),
				correlation_id = ctx.correlation_id,
				messages = records,
			},
		)
		when NRC_SIMULATION {
			if ctx.profile.enabled {
				ctx.profile.serialization += time.since(serialization_started)
				retained_history_profile_latest = ctx.profile
			}
		}
	}
	destroy_retained_history_context(ctx)
}

retained_history_clear_record_batch :: proc(ctx: ^Retained_History_Context) {
	delete(ctx.parallel_reads)
	ctx.record_storage = nil
	ctx.parallel_reads = nil
	ctx.record_batch_count = 0
	ctx.record_coalesced = false
	ctx.record_span_offset = 0
	ctx.record_bytes_read = 0
	ctx.parallel_pending = 0
	ctx.parallel_failed = false
	ctx.parallel_discarded = false
}

retained_history_process_record_batch :: proc(ctx: ^Retained_History_Context) {
	when NRC_SIMULATION {
		if ctx.profile.enabled {
			ctx.profile.decode_started = time.now()
			ctx.profile.decode_active = true
		}
	}
	batch_count := ctx.record_batch_count
	for i in 0 ..< batch_count {
		spec_index := ctx.spec_index + i
		spec := ctx.specs[spec_index]
		buffer: []byte
		if len(spec.cached_payload) > 0 {
			buffer = spec.cached_payload
		} else if ctx.record_coalesced {
			start := int(spec.offset - ctx.record_span_offset)
			buffer = ctx.record_storage[start:start + int(spec.length)]
		} else if len(ctx.parallel_reads) > 0 {
			buffer = ctx.parallel_reads[i].storage
		} else {
			buffer = ctx.record_storage
		}
		payload := buffer
		if len(spec.cached_payload) == 0 do payload = buffer[persistence.LOG_HEADER_SIZE:]
		message, ok := decode_message_record_borrowed(payload)
		if !ok || message.sequence != spec.sequence {
			retained_history_clear_record_batch(ctx)
			retained_history_fail(ctx)
			return
		}
		if message.workspace == ctx.workspace && message.conversation_id == ctx.conversation_id && message.accepted_at_ns >= ctx.cutoff_ns {
			message_bytes := 45 + len(message.sender_name) + len(message.content)
			if ctx.page_bytes > 0 && ctx.page_bytes + message_bytes > RETAINED_PAGE_BYTE_BUDGET {
				ctx.has_more = true
				ctx.truncated = true
				retained_history_clear_record_batch(ctx)
				retained_history_finish(ctx)
				return
			}
			if len(ctx.messages) >= ctx.limit {
				ctx.has_more = true
				retained_history_clear_record_batch(ctx)
				retained_history_finish(ctx)
				return
			}
			ctx.page_bytes += message_bytes
			if _, append_err := append(&ctx.messages, message); append_err != nil {
				retained_history_clear_record_batch(ctx)
				retained_history_fail(ctx)
				return
			}
		}
	}
	ctx.spec_index += batch_count
	when NRC_SIMULATION {
		retained_history_profile_end_decode(ctx)
	}
	retained_history_clear_record_batch(ctx)
	retained_history_submit_record_batch(ctx)
}

retained_history_on_record_read_raw :: proc(user: rawptr, read: int, err: linux.Errno) {
	retained_history_on_record_read((^Retained_History_Context)(user), read, err)
}

retained_history_read_discard_raw :: proc(user: rawptr) {
	destroy_retained_history_context((^Retained_History_Context)(user), false)
}

retained_history_on_record_read :: proc(ctx: ^Retained_History_Context, read: int, err: linux.Errno) {
	if err != .NONE || (read <= 0 && ctx.record_bytes_read < len(ctx.record_storage)) {
		retained_history_clear_record_batch(ctx)
		retained_history_fail(ctx)
		return
	}
	ctx.record_bytes_read += read
	if ctx.record_bytes_read < len(ctx.record_storage) {
		_ = nrc_io_read_file_at(
			ctx.wal_file,
			ctx.record_storage[ctx.record_bytes_read:],
			ctx.record_span_offset + u64(ctx.record_bytes_read),
			ctx,
			retained_history_on_record_read_raw,
			retained_history_read_discard_raw,
		)
		return
	}
	when NRC_SIMULATION {
		if ctx.profile.enabled && ctx.profile.retrieval == 0 do ctx.profile.retrieval = time.since(ctx.profile.started)
	}
	retained_history_process_record_batch(ctx)
}

retained_history_on_parallel_record_read_raw :: proc(user: rawptr, read: int, err: linux.Errno) {
	retained_history_on_parallel_record_read((^Retained_Parallel_Read)(user), read, err)
}

retained_history_parallel_read_discard_raw :: proc(user: rawptr) {
	parallel := (^Retained_Parallel_Read)(user)
	if parallel == nil || parallel.done do return
	ctx := (^Retained_History_Context)(parallel.parent)
	parallel.done = true
	ctx.parallel_discarded = true
	ctx.parallel_pending -= 1
	if ctx.parallel_pending == 0 do destroy_retained_history_context(ctx, false)
}

retained_history_on_parallel_record_read :: proc(parallel: ^Retained_Parallel_Read, read: int, err: linux.Errno) {
	ctx := (^Retained_History_Context)(parallel.parent)
	if parallel.done do return
	if ctx.parallel_discarded {
		parallel.done = true
		ctx.parallel_pending -= 1
		if ctx.parallel_pending == 0 do destroy_retained_history_context(ctx, false)
		return
	}
	if err != .NONE || (read <= 0 && parallel.bytes_read < len(parallel.storage)) {
		parallel.done = true
		ctx.parallel_failed = true
		ctx.parallel_pending -= 1
	} else {
		parallel.bytes_read += read
		if parallel.bytes_read < len(parallel.storage) {
			_ = nrc_io_read_file_at(
				ctx.wal_file,
				parallel.storage[parallel.bytes_read:],
				parallel.offset + u64(parallel.bytes_read),
				parallel,
				retained_history_on_parallel_record_read_raw,
				retained_history_parallel_read_discard_raw,
			)
			return
		}
		parallel.done = true
		ctx.parallel_pending -= 1
	}
	if ctx.parallel_pending > 0 do return
	if ctx.parallel_failed {
		retained_history_clear_record_batch(ctx)
		retained_history_fail(ctx)
		return
	}
	retained_history_process_record_batch(ctx)
}

retained_history_submit_parallel_record_batch :: proc(ctx: ^Retained_History_Context, batch_count: int) {
	ctx.record_batch_count = batch_count
	ctx.parallel_reads = make([]Retained_Parallel_Read, batch_count)
	ctx.parallel_pending = batch_count
	for &parallel, i in ctx.parallel_reads {
		spec := ctx.specs[ctx.spec_index + i]
		parallel.parent = ctx
		parallel.offset = spec.offset
		parallel.storage, _ = mem.alloc_bytes_non_zeroed(int(spec.length), 1, mem.dynamic_arena_allocator(&ctx.message_arena))
		if parallel.storage == nil {
			retained_history_clear_record_batch(ctx)
			retained_history_fail(ctx)
			return
		}
	}
	for &parallel in ctx.parallel_reads {
		_ = nrc_io_read_file_at(
			ctx.wal_file,
			parallel.storage,
			parallel.offset,
			&parallel,
			retained_history_on_parallel_record_read_raw,
			retained_history_parallel_read_discard_raw,
		)
	}
}

retained_history_submit_record_batch :: proc(ctx: ^Retained_History_Context) {
	if ctx.spec_index >= len(ctx.specs) {
		delete(ctx.specs); ctx.specs = nil; ctx.spec_index = 0
		if (ctx.index_file != nil || len(ctx.cached_message_index) > 0) && ctx.range_start < ctx.range_end {
			retained_history_submit_entry_chunk(ctx)
			return
		}
		retained_history_next_segment(ctx); return
	}
	remaining_count := len(ctx.specs) - ctx.spec_index
	first_spec := ctx.specs[ctx.spec_index]
	if len(first_spec.cached_payload) > 0 {
		batch_count := 1
		for batch_count < remaining_count && len(ctx.specs[ctx.spec_index + batch_count].cached_payload) > 0 do batch_count += 1
		ctx.record_batch_count = batch_count
		retained_history_process_record_batch(ctx)
		return
	}
	span_start := first_spec.offset
	span_end := first_spec.offset + u64(first_spec.length)
	total_bytes := 0
	batch_count := 0
	batch_limit := remaining_count
	if !ctx.records_clustered do batch_limit = min(batch_limit, RETAINED_HISTORY_MAX_PARALLEL_READS)
	for i in 0 ..< batch_limit {
		spec := ctx.specs[ctx.spec_index + i]
		if len(spec.cached_payload) > 0 do break
		record_length := int(spec.length)
		record_end := spec.offset + u64(spec.length)
		if record_length < persistence.LOG_HEADER_SIZE || record_end < spec.offset {
			retained_history_clear_record_batch(ctx)
			retained_history_fail(ctx)
			return
		}
		next_span_start := min(span_start, spec.offset)
		next_span_end := max(span_end, record_end)
		if ctx.records_clustered && batch_count > 0 && next_span_end - next_span_start > RETAINED_HISTORY_MAX_COALESCED_READ_BYTES do break
		total_bytes += record_length
		span_start = next_span_start
		span_end = next_span_end
		batch_count += 1
	}
	span_bytes := span_end - span_start
	if span_bytes <= RETAINED_HISTORY_MAX_COALESCED_READ_BYTES &&
	   (ctx.records_clustered || span_bytes <= u64(total_bytes * RETAINED_HISTORY_MAX_READ_AMPLIFICATION)) {
		ctx.record_batch_count = batch_count
		ctx.record_coalesced = true
		ctx.record_span_offset = span_start
		ctx.record_storage, _ = mem.alloc_bytes_non_zeroed(int(span_bytes), 1, mem.dynamic_arena_allocator(&ctx.message_arena))
		if ctx.record_storage == nil {
			retained_history_clear_record_batch(ctx)
			retained_history_fail(ctx)
			return
		}
	} else {
		retained_history_submit_parallel_record_batch(ctx, batch_count)
		return
	}
	_ = nrc_io_read_file_at(
		ctx.wal_file,
		ctx.record_storage,
		ctx.record_span_offset,
		ctx,
		retained_history_on_record_read_raw,
		retained_history_read_discard_raw,
	)
}

retained_history_collect_entries :: proc(ctx: ^Retained_History_Context) -> bool {
	workspace_hash := message_string_hash(ctx.workspace)
	for i in 0 ..< ctx.chunk_count {
		entry_index := ctx.ascending ? i : ctx.chunk_count - 1 - i
		entry := ctx.entry_buffer[entry_index * MESSAGE_INDEX_ENTRY_SIZE:]
		if message_get_u64(entry) != workspace_hash || message_get_u64(entry[8:]) != ctx.conversation_id do continue
		accepted := i64(message_get_u64(entry[24:])); if accepted < ctx.cutoff_ns do continue
		spec := Retained_Read_Spec{message_get_u64(entry[32:]), message_get_u32(entry[40:]), message_get_u64(entry[16:]), accepted, nil}
		if _, err := append(&ctx.specs, spec); err != nil {retained_history_fail(ctx); return false}
	}
	return true
}

retained_history_process_entries :: proc(ctx: ^Retained_History_Context) {
	if !retained_history_collect_entries(ctx) do return
	retained_history_submit_record_batch(ctx)
}

retained_history_submit_entry_chunk :: proc(ctx: ^Retained_History_Context) {
	for {
		remaining := ctx.range_end - ctx.range_start
		if remaining == 0 {retained_history_next_segment(ctx); return}
		ctx.chunk_count = min(int(remaining), len(ctx.entry_buffer) / MESSAGE_INDEX_ENTRY_SIZE)
		if ctx.ascending {
			ctx.chunk_start = ctx.range_start; ctx.range_start += u64(ctx.chunk_count)
		} else {
			ctx.chunk_start = ctx.range_end - u64(ctx.chunk_count); ctx.range_end = ctx.chunk_start
		}
		ctx.phase = .Entries
		buf := ctx.entry_buffer[:ctx.chunk_count * MESSAGE_INDEX_ENTRY_SIZE]
		if len(ctx.cached_message_index) > 0 {
			start := int(ctx.chunk_start) * MESSAGE_INDEX_ENTRY_SIZE
			copy(buf, ctx.cached_message_index[start:start + len(buf)])
			if !retained_history_collect_entries(ctx) do return
			if len(ctx.specs) == 0 do continue
			retained_history_submit_record_batch(ctx)
			return
		}
		_ = nrc_io_read_file_at(
			ctx.index_file,
			buf,
			MESSAGE_INDEX_HEADER_SIZE + ctx.chunk_start * MESSAGE_INDEX_ENTRY_SIZE,
			ctx,
			retained_history_on_read_raw,
			retained_history_read_discard_raw,
		)
		return
	}
}

retained_history_submit_probe :: proc(ctx: ^Retained_History_Context) {
	if ctx.low >= ctx.high {
		if ctx.ascending {
			ctx.range_start = ctx.low
			ctx.range_end = ctx.conversation_end
		} else {
			ctx.range_start = ctx.conversation_start
			ctx.range_end = ctx.low
		}
		retained_history_submit_entry_chunk(ctx)
		return
	}
	ctx.probe = ctx.low + (ctx.high - ctx.low) / 2
	_ = nrc_io_read_file_at(
		ctx.index_file,
		ctx.entry[:],
		MESSAGE_INDEX_HEADER_SIZE + ctx.probe * MESSAGE_INDEX_ENTRY_SIZE,
		ctx,
		retained_history_on_read_raw,
		retained_history_read_discard_raw,
	)
}

retained_history_entry_before_target :: proc(ctx: ^Retained_History_Context) -> bool {
	sequence := message_get_u64(ctx.entry[16:])
	return sequence < ctx.target_sequence || ctx.target_upper && sequence == ctx.target_sequence
}

retained_history_cached_sequence_bound :: proc(index: []byte, start, end, target_sequence: u64, upper: bool) -> u64 {
	low, high := start, end
	for low < high {
		probe := low + (high - low) / 2
		entry := index[int(probe) * MESSAGE_INDEX_ENTRY_SIZE:]
		sequence := message_get_u64(entry[16:])
		if sequence < target_sequence || upper && sequence == target_sequence {
			low = probe + 1
		} else {
			high = probe
		}
	}
	return low
}

retained_history_conversation_range :: proc(segment: ^Message_Segment_Descriptor, workspace_hash, conversation_id: u64) -> (u64, u64, bool) {
	low := 0
	high := len(segment.conversation_ranges)
	for low < high {
		probe := low + (high - low) / 2
		range := segment.conversation_ranges[probe]
		if range.workspace_hash < workspace_hash || (range.workspace_hash == workspace_hash && range.conversation_id < conversation_id) {
			low = probe + 1
		} else {
			high = probe
		}
	}
	if low >= len(segment.conversation_ranges) do return 0, 0, false
	range := segment.conversation_ranges[low]
	if range.workspace_hash != workspace_hash || range.conversation_id != conversation_id do return 0, 0, false
	return range.start, range.end, true
}

retained_history_open_active_wal :: proc(ctx: ^Retained_History_Context, source: ^Message_Store = nil) -> bool {
	owner := source; if owner == nil do owner = ctx.store
	if owner.active_read_file == nil {
		path := message_store_path(owner.directory, owner.active_generation, "wal"); defer delete(path)
		owner.active_read_file, _ = storage_io.open(owner.storage, path, {.Read})
	}
	ctx.wal_file = owner.active_read_file
	ctx.owns_wal_file = false
	ctx.records_clustered = false
	return ctx.wal_file != nil
}

retained_history_active_sequence_bound :: proc(entries: []Message_Offset_Entry, sequence: u64, upper: bool) -> int {
	low, high := 0, len(entries)
	for low < high {
		probe := low + (high - low) / 2
		if entries[probe].sequence < sequence || upper && entries[probe].sequence == sequence {
			low = probe + 1
		} else {
			high = probe
		}
	}
	return low
}

retained_history_open_sealed :: proc(ctx: ^Retained_History_Context) {
	segment: ^Message_Segment_Descriptor
	conversation_start, conversation_end: u64
	for {
		// A virtual slot between sealed history and B visits the snapshot's A,
		// even if A has since been published into the live sealed descriptor list.
		if ctx.segment_index == ctx.sealed_count {
			if len(ctx.frozen_specs) > 0 {
				ctx.specs = ctx.frozen_specs; ctx.frozen_specs = nil
				if retained_history_specs_need_wal(ctx.specs[:]) && !retained_history_open_active_wal(ctx, ctx.frozen) {retained_history_fail(ctx); return}
				retained_history_submit_record_batch(ctx); return
			}
			ctx.segment_index += ctx.segment_step
			continue
		}
		if ctx.segment_index < 0 || ctx.segment_index > ctx.sealed_count {
			if ctx.ascending && !ctx.active_processed && len(ctx.active_specs) > 0 {
				ctx.active_processed = true; ctx.specs = ctx.active_specs; ctx.active_specs = nil
				if retained_history_specs_need_wal(ctx.specs[:]) && !retained_history_open_active_wal(ctx) {retained_history_fail(ctx); return}
				retained_history_submit_record_batch(ctx); return
			}
			retained_history_finish(ctx); return
		}
		segment = &ctx.store.segments[ctx.segment_index]
		if segment.max_time < ctx.cutoff_ns || segment.first_seq > ctx.high_water {
			ctx.segment_index += ctx.segment_step
			continue
		}
		found: bool
		conversation_start, conversation_end, found = retained_history_conversation_range(segment, message_string_hash(ctx.workspace), ctx.conversation_id)
		if !found {ctx.segment_index += ctx.segment_step; continue}
		break
	}
	index_path := message_store_path(
		ctx.store.directory,
		segment.generation,
		"idx",
	); defer delete(index_path); wal_path := message_store_path(ctx.store.directory, segment.generation, "wal")
	capacity: bool
	ctx.wal_file, ctx.owns_wal_file, capacity = open_message_segment_read_file(ctx.store, segment, wal_path); delete(wal_path)
	if capacity {retained_history_capacity(ctx); return}
	if ctx.wal_file == nil {retained_history_fail(ctx); return}
	if !ctx.owns_wal_file do ctx.wal_segment = segment
	ctx.cached_message_index = segment.cached_message_index
	if len(ctx.cached_message_index) == 0 do ctx.index_file, _ = storage_io.open(ctx.store.storage, index_path, {.Read})
	if len(ctx.cached_message_index) == 0 && ctx.index_file == nil {retained_history_fail(ctx); return}
	ctx.records_clustered = true
	ctx.conversation_start = conversation_start
	ctx.conversation_end = conversation_end
	ctx.low = conversation_start
	ctx.high = conversation_end
	ctx.range_start = 0
	ctx.range_end = 0
	ctx.phase = .Probe
	// Use an upper bound directly: adding one would wrap at max(u64).
	ctx.target_sequence = ctx.ascending ? ctx.after : (ctx.before > 0 ? ctx.before : ctx.high_water)
	ctx.target_upper = ctx.ascending || ctx.before == 0
	if len(ctx.cached_message_index) > 0 {
		bound := retained_history_cached_sequence_bound(ctx.cached_message_index, conversation_start, conversation_end, ctx.target_sequence, ctx.target_upper)
		if ctx.ascending {
			ctx.range_start = bound
			ctx.range_end = conversation_end
		} else {
			ctx.range_start = conversation_start
			ctx.range_end = bound
		}
		retained_history_submit_entry_chunk(ctx)
		return
	}
	retained_history_submit_probe(ctx)
}

retained_history_specs_need_wal :: proc(specs: []Retained_Read_Spec) -> bool {
	for spec in specs do if len(spec.cached_payload) == 0 do return true
	return false
}

retained_history_next_segment :: proc(ctx: ^Retained_History_Context) {
	if ctx.index_file != nil {storage_io.discard(ctx.index_file); ctx.index_file = nil}
	ctx.cached_message_index = nil
	if ctx.wal_segment != nil {release_message_segment_read_borrow(ctx.wal_segment); ctx.wal_segment = nil}
	if ctx.wal_file != nil && ctx.owns_wal_file do storage_io.discard(ctx.wal_file)
	ctx.wal_file = nil; ctx.owns_wal_file = false
	ctx.segment_index += ctx.segment_step; retained_history_open_sealed(ctx)
}

retained_history_on_read_raw :: proc(user: rawptr, read: int, err: linux.Errno) {
	retained_history_on_read((^Retained_History_Context)(user), read, err)
}

retained_history_on_read :: proc(ctx: ^Retained_History_Context, read: int, err: linux.Errno) {
	if err != .NONE {retained_history_fail(ctx); return}
	switch ctx.phase {
	case .Probe:
		if read != MESSAGE_INDEX_ENTRY_SIZE {retained_history_fail(ctx); return}
		if retained_history_entry_before_target(ctx) {
			ctx.low = ctx.probe + 1
		} else {
			ctx.high = ctx.probe
		}
		retained_history_submit_probe(ctx)
	case .Entries:
		if read != ctx.chunk_count * MESSAGE_INDEX_ENTRY_SIZE {retained_history_fail(ctx); return}
		retained_history_process_entries(ctx)
	}
}

process_message_history :: proc(c: ^NRC_Connection, req: pr.MessageRangeRequest, ascending: bool) {
	if req.conv_id == pr.WORKSPACE_DATA_ID {
		send_error_response(c, ascending ? .C_ReplayMessagesAfter : .C_ListMessagesBefore, "Workspace data scope is not a chat", req.correlation_id)
		return
	}
	if c.retained_io >=
	   MAX_RETAINED_IO_PER_CONNECTION {send_error_response(c, ascending ? .C_ReplayMessagesAfter : .C_ListMessagesBefore, "too many retained message operations", req.correlation_id); return}
	if pr.is_dm_conversation(
		req.conv_id,
	) {send_error_response(c, ascending ? .C_ReplayMessagesAfter : .C_ListMessagesBefore, "retained direct messages are not enabled", req.correlation_id); return}
	ws := get_connection_workspace(c); conv := get_conversation(ws, req.conv_id)
	if conv == nil ||
	   !conversation_has_subscriber(
			   conv,
			   c.sock,
		   ) {send_error_response(c, ascending ? .C_ReplayMessagesAfter : .C_ListMessagesBefore, "conversation subscription required", req.correlation_id); return}
	store := message_store_for_workspace(&td.message_stores, transmute([]byte)c.workspace_id)
	if store ==
	   nil {send_error_response(c, ascending ? .C_ReplayMessagesAfter : .C_ListMessagesBefore, "message retention is disabled", req.correlation_id); return}
	ctx := new(Retained_History_Context); ctx.store = store; ctx.conversation_id = u64(req.conv_id); ctx.correlation_id = req.correlation_id
	when NRC_SIMULATION {
		if retained_history_profile_enabled {
			ctx.profile.enabled = true
			ctx.profile.started = time.now()
		}
	}
	pool_allocator := byte_pool.allocator(td.spool)
	mem.dynamic_arena_init(
		&ctx.message_arena,
		block_allocator = pool_allocator,
		array_allocator = pool_allocator,
		block_size = RETAINED_PAGE_ARENA_BLOCK_BYTES,
		out_band_size = RETAINED_PAGE_ARENA_BLOCK_BYTES,
	)
	ctx.message_arena_ready = true
	ctx.before = ascending ? 0 : u64(req.cursor); ctx.after = ascending ? u64(req.cursor) : 0; ctx.limit = int(req.limit); ctx.ascending = ascending
	ctx.high_water, ctx.cutoff_ns, _ = message_store_high_water_cutoff(store)
	ctx.workspace, _ = strings.clone(c.workspace_id)
	for segment in store.segments {if segment.max_time >= ctx.cutoff_ns {ctx.cutoff_seq = segment.first_seq; break}}
	if ctx.cutoff_seq == 0 && store.frozen != nil && !store.frozen_published do ctx.cutoff_seq = store.frozen.active_first_seq
	if ctx.cutoff_seq == 0 do ctx.cutoff_seq = store.active_first_seq
	if !connection_io_pin(c) {destroy_retained_history_context(ctx); return}; ctx.io_ctx = connection_io_context_make(c); ctx.io_ctx.pinned = true
	c.retained_io += 1; ctx.counts_connection_io = true
	store.async_readers += 1; ctx.holds_store_reader = true
	ctx.sealed_count = len(store.segments)
	ctx.segment_step = ascending ? 1 : -1; ctx.segment_index = ascending ? -1 : ctx.sealed_count + 1
	if store.frozen != nil && !store.frozen_published {
		ctx.frozen = store.frozen
		ctx.frozen.async_readers += 1
		retained_history_snapshot_active(ctx, ctx.frozen, &ctx.frozen_specs)
	}
	retained_history_snapshot_active(ctx, store, ascending ? &ctx.active_specs : &ctx.specs)
	if !ascending && len(ctx.specs) > 0 {
		if retained_history_specs_need_wal(ctx.specs[:]) && !retained_history_open_active_wal(ctx) {retained_history_fail(ctx); return}
		retained_history_submit_record_batch(ctx); _ = nbio.submit_pending(&td.io); return
	}
	retained_history_next_segment(ctx); _ = nbio.submit_pending(&td.io)
}

retained_history_snapshot_active :: proc(ctx: ^Retained_History_Context, source: ^Message_Store, specs: ^[dynamic]Retained_Read_Spec) {
	entries := source.active_offsets[Message_Conversation_Key{ctx.workspace, ctx.conversation_id}]
	i := ctx.ascending ? retained_history_active_sequence_bound(entries[:], ctx.after, true) : len(entries) - 1
	if !ctx.ascending && ctx.before > 0 do i = retained_history_active_sequence_bound(entries[:], ctx.before, false) - 1
	for i >= 0 && i < len(entries) && len(specs^) < ctx.limit + 1 {
		entry := entries[i]
		if entry.sequence <= ctx.high_water && entry.accepted_at_ns >= ctx.cutoff_ns {
			append(specs, Retained_Read_Spec{entry.offset, entry.length, entry.sequence, entry.accepted_at_ns, entry.cached_payload})
		}
		i += ctx.ascending ? 1 : -1
	}
}

process_subscribe_conversations_v2 :: proc(c: ^NRC_Connection, req: pr.SubscribeConvsV2Request) {
	for conv_id in req.conv_ids {
		if pr.is_dm_conversation(conv_id) || conv_id == pr.WORKSPACE_DATA_ID {
			send_error_response(c, .C_SubscribeConvsV2, "retained subscriptions require a public chat room", req.correlation_id)
			return
		}
	}
	store := message_store_for_workspace(&td.message_stores, transmute([]byte)c.workspace_id)
	entries: [pr.MAX_SUBSCRIBE_CONVS]pr.SubscriptionReadyEntry
	count := 0
	for conv_id in req.conv_ids {
		subscribe_to_conversation(c, conv_id)
		ws := get_connection_workspace(c); conv := get_conversation(ws, conv_id)
		if store != nil && conv != nil && conversation_has_subscriber(conv, c.sock) {high, _, _ := message_store_high_water_cutoff(store); entries[count] = {
				conv_id        = conv_id,
				high_water_seq = pr.MessageSeq(high),
			}; count += 1}
	}
	ready := pr.SubscriptionReady {
		correlation_id = req.correlation_id,
		entries        = entries[:count],
	}
	protocol_size := pr.getSizeSubscriptionReady(
		ready,
	); buf, header_len := allocate_websocket_frame_buffer(protocol_size, "subscription ready"); if buf == nil do return
	written := pr.serializeSubscriptionReady(ready, buf[header_len:]); if written <= 0 {byte_pool.release(td.spool, buf); return}
	_ = send_pooled_buffer_priority(c, buf[:header_len + written])
}
