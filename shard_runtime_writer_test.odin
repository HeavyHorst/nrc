package main

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sync/chan"
import "core:sys/linux"
import "core:sys/posix"
import "core:testing"
import "core:time"

import hgl "hegel"
import "nbio"
import "persistence"
import pr "protocol"
import "storage_io"
import "ulid"

when !NRC_SIMULATION {
	_ :: hgl.Test_Case
}

@(test)
test_shard_storage_probe_uses_cache_and_rejects_stale_or_failed_samples :: proc(t: ^testing.T) {
	old_server, old_registry := td.server, td.shard_writers
	defer {td.server = old_server; td.shard_writers = old_registry}
	td.shard_writers = {}
	server: NRC_Server
	channel_err: mem.Allocator_Error
	server.shard_compaction_jobs, channel_err = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
	testing.expect(t, channel_err == .None)
	defer chan.destroy(server.shard_compaction_jobs)
	td.server = &server
	for &index in td.shard_writers.writer_index do index = -1
	append(&td.shard_writers.writers, Shard_Transaction_Writer{})
	defer delete(td.shard_writers.writers)
	td.shard_writers.writer_index[7] = 0
	writer := &td.shard_writers.writers[0]
	writer^ = {
		batch_writes         = true,
		shard                = 7,
		shard_dir            = "/nrc-storage-probe-missing-directory",
		storage              = storage_io.host_context(),
		space_known          = true,
		space_checked_at     = time.time_add(ulid.time_now(), -1500 * time.Millisecond),
		available_disk_bytes = 123456,
	}
	// A synchronous statfs on the missing directory would fail instead.
	testing.expect(t, refresh_shard_writer_storage_space(writer))
	testing.expect_value(t, writer.available_disk_bytes, u64(123456))
	job, received := chan.try_recv(server.shard_compaction_jobs)
	testing.expect(t, received && job.storage_space_probe && job.shard == 7)
	result := run_shard_compaction_job(job)
	testing.expect(t, !result.ok)
	testing.expect(t, process_shard_compaction_result(result))
	testing.expect(t, !writer.space_known)
	testing.expect(t, !refresh_shard_writer_storage_space(writer))
	_, received = chan.try_recv(server.shard_compaction_jobs)
	testing.expect(t, !received, "probe retries must be rate limited")
	sample := ulid.time_now()
	testing.expect(
		t,
		process_shard_compaction_result({storage_space_probe = true, shard = 7, ok = true, available_disk_bytes = 654321, space_checked_at = sample}),
	)
	testing.expect(
		t,
		process_shard_compaction_result({storage_space_probe = true, shard = 7, ok = false, space_checked_at = time.time_add(sample, -time.Second)}),
	)
	testing.expect(t, writer.space_known && refresh_shard_writer_storage_space(writer))
	testing.expect_value(t, writer.available_disk_bytes, u64(654321))
	writer.space_checked_at = time.time_add(ulid.time_now(), -3 * time.Second)
	testing.expect(t, !refresh_shard_writer_storage_space(writer), "old samples must not admit writes")
}

Shard_Writer_Test_Data :: struct {
	tx:        Shard_Transaction,
	mutations: [3]Shard_Mutation,
	storage:   [3][]byte,
}

@(test)
test_stale_shard_space_probe_replies_busy_instead_of_dropping_request :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 189)
		defer simulation_test_end(&ctx)
		workspace := "stale-probe-busy"
		path, ok := task_handler_test_init_sim_writer(workspace, "stale-probe-busy.log")
		defer os.remove(path)
		if !testing.expect(t, ok) do return
		defer shutdown_shard_writer_registry(&td.shard_writers)
		server: NRC_Server
		channel_err: mem.Allocator_Error
		server.shard_compaction_jobs, channel_err = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
		testing.expect(t, channel_err == .None)
		defer chan.destroy(server.shard_compaction_jobs)
		td.server = &server
		defer td.server = nil
		writer := &td.shard_writers.writers[0]
		writer.batch_writes = true; writer.managed = true
		writer.shard_dir = fmt.aprintf("/missing-probe-%d", td.thread_index)
		writer.space_known = true
		writer.space_checked_at = time.time_add(ulid.time_now(), -3 * time.Second)
		conn := simulation_test_install_client(&ctx.sim, 0, workspace, "writer", init_send_queue = true)
		ctx.conns[0] = conn
		payload: [512]byte
		length := pr.serializeCreateTaskRequest(
			{conv_id = pr.WORKSPACE_DATA_ID, title = transmute([]byte)string("must not vanish"), correlation_id = 83},
			payload[:],
		)
		process_protocol_payload(conn, payload[:length])
		testing.expect(t, conn.state >= .Will_Close, "backpressure must explicitly close with busy status")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
		frame := nrc_sim_client_frame(&ctx.sim, conn.sock, 0)
		testing.expect(t, len(frame) >= 4 && frame[0] & 0x0f == 8 && frame[2] == 3 && frame[3] == 0xF5, "expected WebSocket close code 1013")
		testing.expect_value(t, writer.wal.write_offset, 0)
		testing.expect(t, !writer.poisoned)
		job, received := chan.try_recv(server.shard_compaction_jobs)
		testing.expect(t, received && job.storage_space_probe)
		if received do destroy_shard_compaction_job(&job)
	}
}

shard_writer_test_transaction_init :: proc(data: ^Shard_Writer_Test_Data, workspace: string) {
	task := pr.Task {
		id      = 10,
		conv_id = 77,
		title   = transmute([]byte)string("task"),
		status  = .Todo,
	}
	data.storage[0] = make([]byte, calculate_task_fields_size(task))
	serialize_task_fields(task, data.storage[0])
	asset := pr.Asset {
		asset_type       = .Document,
		asset_id         = 20,
		parent_type      = .Task,
		parent_id        = 10,
		owner            = transmute([]byte)string("owner"),
		conv_id          = 77,
		payload_encoding = .Plain,
		payload_raw_len  = 4,
		payload          = transmute([]byte)string("body"),
	}
	asset_record := make([]byte, persistence.LOG_HEADER_SIZE + calculate_asset_payload_size(workspace, &asset))
	serialize_asset_to_record(asset_record, workspace, &asset)
	_, asset_offset, _ := persistence.parse_workspace_prefix(asset_record[persistence.LOG_HEADER_SIZE:])
	data.storage[1] = make([]byte, len(asset_record) - persistence.LOG_HEADER_SIZE - asset_offset)
	copy(data.storage[1], asset_record[persistence.LOG_HEADER_SIZE + asset_offset:])
	delete(asset_record)
	edge := pr.Edge {
		edge_id     = 30,
		conv_id     = 77,
		source_type = .Task,
		source_id   = 10,
		target_type = .Asset,
		target_id   = 20,
		relation    = .References,
		created_by  = transmute([]byte)string("author"),
	}
	edge_record := make([]byte, persistence.LOG_HEADER_SIZE + calculate_edge_payload_size(workspace, &edge))
	serialize_edge_to_record(edge_record, workspace, &edge)
	_, edge_offset, _ := persistence.parse_workspace_prefix(edge_record[persistence.LOG_HEADER_SIZE:])
	data.storage[2] = make([]byte, len(edge_record) - persistence.LOG_HEADER_SIZE - edge_offset)
	copy(data.storage[2], edge_record[persistence.LOG_HEADER_SIZE + edge_offset:])
	delete(edge_record)
	data.mutations = {
		{domain = .Task, op = u8(Task_Log_Op.Create), entity_record_version = 1, payload = data.storage[0]},
		{domain = .Asset, op = u8(Asset_Log_Op.Create), entity_record_version = 3, payload = data.storage[1]},
		{domain = .Edge, op = u8(Edge_Log_Op.Create), entity_record_version = 1, payload = data.storage[2]},
	}
	data.tx = {
		workspace        = transmute([]byte)workspace,
		task_high_water  = 10,
		asset_high_water = 20,
		edge_high_water  = 30,
		mutations        = data.mutations[:],
	}
}

shard_writer_test_transaction_destroy :: proc(data: ^Shard_Writer_Test_Data) {
	for storage in data.storage do delete(storage)
	data^ = {}
}

shard_writer_test_write_task_wal :: proc(path, workspace: string, shard: int, task_id: pr.TaskID, title: string) -> bool {
	if os.write_entire_file(path, nil) != nil do return false
	writer: Shard_Transaction_Writer
	if !init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT) do return false
	task := pr.Task {
		id      = task_id,
		conv_id = 77,
		title   = transmute([]byte)title,
		status  = .Todo,
	}
	built, built_ok := build_shard_task_mutation(transmute([]byte)workspace, .Create, &task, writer.floors)
	appended := built_ok && append_shard_transaction(&writer, &built.tx)
	destroy_shard_mutation_transaction(&built)
	shutdown_ok := shutdown_shard_transaction_writer(&writer)
	return appended && shutdown_ok
}

SHARD_RECOVERY_FAULT_RECORD_COUNT :: 3

Shard_Recovery_Fault_Fixture :: struct {
	workspace:   string,
	wal_bytes:   []byte,
	record_ends: [SHARD_RECOVERY_FAULT_RECORD_COUNT]int,
}

shard_recovery_fault_fixture_destroy :: proc(fixture: ^Shard_Recovery_Fault_Fixture) {
	delete(fixture.wal_bytes)
	fixture^ = {}
}

shard_recovery_fault_fixture_init :: proc(fixture: ^Shard_Recovery_Fault_Fixture, name: string) -> bool {
	path := test_wal_path(name)
	defer os.remove(path)
	if os.write_entire_file(path, nil) != nil do return false

	fixture.workspace = "shard-recovery-fault-workspace"
	workspace_bytes := transmute([]byte)fixture.workspace
	shard := int(shard_for_workspace(workspace_bytes))
	writer: Shard_Transaction_Writer
	if !init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT) do return false
	defer shutdown_shard_transaction_writer(&writer)

	initial: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&initial, fixture.workspace)
	defer shard_writer_test_transaction_destroy(&initial)
	if !append_shard_transaction(&writer, &initial.tx) do return false
	if size, size_err := storage_io.file_size(writer.wal.file); size_err == nil {
		fixture.record_ends[0] = int(size)
	} else {
		return false
	}

	watermarks := [2]Shard_High_Water_Requirements{{task = 40, asset = 50, edge = 60}, {task = 70, asset = 80, edge = 90}}
	for watermark, i in watermarks {
		tx := Shard_Transaction {
			workspace        = workspace_bytes,
			task_high_water  = watermark.task,
			asset_high_water = watermark.asset,
			edge_high_water  = watermark.edge,
		}
		if !append_shard_transaction(&writer, &tx) do return false
		size, size_err := storage_io.file_size(writer.wal.file)
		if size_err != nil do return false
		fixture.record_ends[i + 1] = int(size)
	}

	bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil || len(bytes) != fixture.record_ends[SHARD_RECOVERY_FAULT_RECORD_COUNT - 1] {
		delete(bytes)
		return false
	}
	fixture.wal_bytes = bytes
	return true
}

when NRC_SIMULATION {
	shard_recovery_fault_property :: proc(tc: ^hgl.Test_Case, user_data: rawptr) -> hgl.Body_Result {
		fixture := cast(^Shard_Recovery_Fault_Fixture)user_data
		durable_count_i64, durable_err := hgl.draw_i64(tc, 0, SHARD_RECOVERY_FAULT_RECORD_COUNT)
		if durable_err == .Stop_Test do return hgl.abort()
		if durable_err != nil do return hgl.interesting("durable-count-draw")
		durable_count := int(durable_count_i64)

		stable_end := 0
		if durable_count > 0 do stable_end = fixture.record_ends[durable_count - 1]
		cut_len := 0
		if durable_count < SHARD_RECOVERY_FAULT_RECORD_COUNT {
			next_end := fixture.record_ends[durable_count]
			cut_i64, cut_err := hgl.draw_i64(tc, 0, i64(next_end - stable_end - 1))
			if cut_err == .Stop_Test do return hgl.abort()
			if cut_err != nil do return hgl.interesting("partial-write-draw")
			cut_len = int(cut_i64)
		}

		device: persistence.Virtual_WAL_Device
		persistence.virtual_wal_device_init(&device)
		defer persistence.virtual_wal_device_destroy(&device)
		virtual_file := persistence.virtual_wal_open_file(&device, "shard/recovery")
		if virtual_file == nil do return hgl.interesting("virtual-open")
		start := 0
		for i in 0 ..< durable_count {
			end := fixture.record_ends[i]
			if !persistence.virtual_wal_write(virtual_file, fixture.wal_bytes[start:end]) do return hgl.interesting("virtual-write")
			persistence.virtual_wal_sync(virtual_file)
			start = end
		}
		if durable_count < SHARD_RECOVERY_FAULT_RECORD_COUNT {
			next_end := fixture.record_ends[durable_count]
			if !persistence.virtual_wal_write(virtual_file, fixture.wal_bytes[stable_end:next_end]) do return hgl.interesting("pending-write")
			persistence.virtual_wal_crash(virtual_file, cut_len)
		}

		case_name := fmt.tprintf("shard-recovery-fault-%d-%d", durable_count, cut_len)
		data_dir := storage_layout_test_setup(case_name)
		defer os.remove_all(data_dir)
		generation: u64 = 1
		generation_dir := sharded_generation_path(data_dir, generation)
		defer delete(generation_dir)
		if os.make_directory(generation_dir) != nil do return hgl.interesting("generation-directory")
		shard := int(shard_for_workspace(transmute([]byte)fixture.workspace))
		shard_dir := sharded_shard_path(generation_dir, shard)
		defer delete(shard_dir)
		if os.make_directory(shard_dir) != nil do return hgl.interesting("shard-directory")
		active_path := sharded_active_wal_path(generation_dir, shard)
		defer delete(active_path)
		if os.write_entire_file(active_path, persistence.virtual_wal_durable_bytes(virtual_file)) != nil do return hgl.interesting("materialize")

		previous_logger := context.logger
		context.logger = log.nil_logger()
		defer {context.logger = previous_logger}
		shard_replay_state_init()
		defer shard_replay_state_destroy()
		td.thread_index = shard
		started := init_active_sharded_worker_persistence(data_dir, generation, shard, LOGICAL_SHARD_COUNT)
		defer shutdown_shard_writer_registry(&td.shard_writers)
		if !started do return hgl.interesting("startup")

		expected_floors_by_count := [4]Shard_High_Water_Requirements {
			{},
			{task = 10, asset = 20, edge = 30},
			{task = 40, asset = 50, edge = 60},
			{task = 70, asset = 80, edge = 90},
		}
		expected_floors := expected_floors_by_count[durable_count]
		if td.task_seq != expected_floors.task || td.asset_seq != expected_floors.asset || td.edge_seq != expected_floors.edge {
			return hgl.interesting("high-water")
		}
		workspace := get_workspace(fixture.workspace)
		if durable_count == 0 {
			if workspace != nil do return hgl.interesting("empty-prefix-state")
		} else {
			conv := get_conversation(workspace, pr.WORKSPACE_DATA_ID)
			if conv == nil || len(conv.tasks) != 1 || len(conv.assets) != 1 || len(conv.edges) != 1 {
				return hgl.interesting("transaction-atomicity")
			}
		}
		writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)fixture.workspace)
		if writer == nil || writer.wal.record_count != u64(durable_count) do return hgl.interesting("writer-head")
		recovered_file, open_err := os.open(active_path)
		if open_err != nil do return hgl.interesting("recovered-open")
		recovered_size, size_err := os.file_size(recovered_file)
		os.close(recovered_file)
		if size_err != nil || recovered_size != i64(stable_end) do return hgl.interesting("tail-truncation")
		return hgl.valid()
	}

	@(test)
	test_hegel_sharded_startup_recovers_exact_durable_prefix_across_write_and_fsync_crashes :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		fixture: Shard_Recovery_Fault_Fixture
		testing.expect(t, shard_recovery_fault_fixture_init(&fixture, "shard-recovery-hegel-fixture.log"))
		defer shard_recovery_fault_fixture_destroy(&fixture)
		if len(fixture.wal_bytes) == 0 do return
		result, err := hgl.run(shard_recovery_fault_property, &fixture, {test_cases = 160})
		testing.expectf(t, err == nil, "sharded WAL filesystem-fault property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_shard_recovery_exhaustively_covers_every_representative_record_cut :: proc(t: ^testing.T) {
	fixture: Shard_Recovery_Fault_Fixture
	testing.expect(t, shard_recovery_fault_fixture_init(&fixture, "shard-recovery-exhaustive-fixture.log"))
	defer shard_recovery_fault_fixture_destroy(&fixture)
	if len(fixture.wal_bytes) == 0 do return

	path := test_wal_path("shard-recovery-exhaustive-cut.log")
	defer os.remove(path)
	shard := int(shard_for_workspace(transmute([]byte)fixture.workspace))
	expected_floors_by_count := [4]Shard_High_Water_Requirements {
		{},
		{task = 10, asset = 20, edge = 30},
		{task = 40, asset = 50, edge = 60},
		{task = 70, asset = 80, edge = 90},
	}
	stable_end := 0
	for record_index in 0 ..< SHARD_RECOVERY_FAULT_RECORD_COUNT {
		next_end := fixture.record_ends[record_index]
		record_size := next_end - stable_end
		for cut_len in 0 ..= record_size {
			materialized_end := stable_end + cut_len
			testing.expect(t, os.write_entire_file(path, fixture.wal_bytes[:materialized_end]) == nil)
			shard_replay_state_init()
			previous_logger := context.logger
			context.logger = log.nil_logger()
			inspection, floors, replay_ok := scan_shard_transaction_wal(path, shard, {}, true, true)
			context.logger = previous_logger
			expected_count := record_index
			expected_end := stable_end
			if cut_len == record_size {
				expected_count += 1
				expected_end = next_end
			}
			testing.expectf(t, replay_ok, "record=%d cut=%d/%d should recover", record_index, cut_len, record_size)
			testing.expectf(
				t,
				inspection.record_count == u64(expected_count),
				"record=%d cut=%d count=%d want=%d",
				record_index,
				cut_len,
				inspection.record_count,
				expected_count,
			)
			testing.expectf(
				t,
				floors == expected_floors_by_count[expected_count],
				"record=%d cut=%d floors=%v want=%v",
				record_index,
				cut_len,
				floors,
				expected_floors_by_count[expected_count],
			)
			recovered_file, open_err := os.open(path)
			testing.expect(t, open_err == nil)
			if open_err == nil {
				recovered_size, size_err := os.file_size(recovered_file)
				os.close(recovered_file)
				testing.expectf(
					t,
					size_err == nil && recovered_size == i64(expected_end),
					"record=%d cut=%d size=%d want=%d",
					record_index,
					cut_len,
					recovered_size,
					expected_end,
				)
			}
			workspace := get_workspace(fixture.workspace)
			if expected_count == 0 {
				testing.expectf(t, workspace == nil, "record=%d cut=%d unexpectedly applied state", record_index, cut_len)
			} else {
				conv := get_conversation(workspace, pr.WORKSPACE_DATA_ID)
				testing.expectf(
					t,
					conv != nil && len(conv.tasks) == 1 && len(conv.assets) == 1 && len(conv.edges) == 1,
					"record=%d cut=%d violated transaction atomicity",
					record_index,
					cut_len,
				)
			}
			shard_replay_state_destroy()
		}
		stable_end = next_end
	}
}

@(test)
test_shard_recovery_rejects_representative_complete_record_corruption_without_truncation :: proc(t: ^testing.T) {
	fixture: Shard_Recovery_Fault_Fixture
	testing.expect(t, shard_recovery_fault_fixture_init(&fixture, "shard-recovery-corruption-fixture.log"))
	defer shard_recovery_fault_fixture_destroy(&fixture)
	if len(fixture.wal_bytes) == 0 do return

	path := test_wal_path("shard-recovery-complete-corruption.log")
	defer os.remove(path)
	shard := int(shard_for_workspace(transmute([]byte)fixture.workspace))
	first_record_end := fixture.record_ends[0]
	corruption_offsets := [?]int{0, 7, 12, 44, persistence.LOG_HEADER_SIZE}
	for offset in corruption_offsets {
		corrupted := make([]byte, first_record_end)
		copy(corrupted, fixture.wal_bytes[:first_record_end])
		corrupted[offset] = corrupted[offset] ~ 0xff
		testing.expect(t, os.write_entire_file(path, corrupted) == nil)
		delete(corrupted)
		shard_replay_state_init()
		previous_logger := context.logger
		context.logger = log.nil_logger()
		_, _, replay_ok := scan_shard_transaction_wal(path, shard, {}, true, true)
		context.logger = previous_logger
		testing.expectf(t, !replay_ok, "complete corruption at offset %d must fail closed", offset)
		testing.expect(t, get_workspace(fixture.workspace) == nil)
		shard_replay_state_destroy()
		file, open_err := os.open(path)
		testing.expect(t, open_err == nil)
		if open_err == nil {
			size, size_err := os.file_size(file)
			os.close(file)
			testing.expectf(t, size_err == nil && size == i64(first_record_end), "complete corruption at offset %d was truncated", offset)
		}
	}
}

@(test)
test_active_sharded_startup_keeps_complete_semantic_corruption_fatal_and_unmodified :: proc(t: ^testing.T) {
	fixture: Shard_Recovery_Fault_Fixture
	testing.expect(t, shard_recovery_fault_fixture_init(&fixture, "shard-recovery-semantic-fixture.log"))
	defer shard_recovery_fault_fixture_destroy(&fixture)
	if len(fixture.wal_bytes) == 0 do return

	data_dir := storage_layout_test_setup("shard-semantic-corruption-startup")
	defer os.remove_all(data_dir)
	generation: u64 = 1
	generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
	testing.expect(t, os.make_directory(generation_dir) == nil)
	shard := int(shard_for_workspace(transmute([]byte)fixture.workspace))
	shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)
	testing.expect(t, os.make_directory(shard_dir) == nil)
	active_path := sharded_active_wal_path(generation_dir, shard); defer delete(active_path)

	builder: persistence.WAL_File_Builder
	testing.expect(t, persistence.create_wal_file_builder(&builder, active_path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION))
	first_end := fixture.record_ends[0]
	first_payload_size, _ := endian.get_u32(fixture.wal_bytes[8:], .Big)
	first_record := make([]byte, persistence.LOG_HEADER_SIZE + int(first_payload_size)); defer delete(first_record)
	copy(first_record[persistence.LOG_HEADER_SIZE:], fixture.wal_bytes[persistence.LOG_HEADER_SIZE:first_end])
	testing.expect(t, persistence.append_wal_file_builder(&builder, u8(Shard_Log_Op.Transaction), first_record))
	regression := Shard_Transaction {
		workspace        = transmute([]byte)fixture.workspace,
		task_high_water  = 9,
		asset_high_water = 19,
		edge_high_water  = 29,
	}
	regression_size, regression_size_err := shard_transaction_size(&regression)
	testing.expect_value(t, regression_size_err, Shard_Transaction_Error.None)
	regression_record := make([]byte, persistence.LOG_HEADER_SIZE + regression_size); defer delete(regression_record)
	testing.expect_value(t, encode_shard_transaction(&regression, regression_record[persistence.LOG_HEADER_SIZE:]), Shard_Transaction_Error.None)
	testing.expect(t, persistence.append_wal_file_builder(&builder, u8(Shard_Log_Op.Transaction), regression_record))
	testing.expect(t, persistence.finish_wal_file_builder(&builder))
	before, before_open_err := os.open(active_path)
	testing.expect(t, before_open_err == nil)
	before_size, _ := os.file_size(before)
	os.close(before)

	shard_replay_state_init(); defer shard_replay_state_destroy()
	td.thread_index = shard
	previous_logger := context.logger; context.logger = log.nil_logger()
	started := init_active_sharded_worker_persistence(data_dir, generation, shard, LOGICAL_SHARD_COUNT)
	context.logger = previous_logger
	testing.expect(t, !started)
	testing.expect(t, td.shard_writers.mode == .Inactive)
	testing.expect(t, get_workspace(fixture.workspace) == nil)
	after, after_open_err := os.open(active_path)
	testing.expect(t, after_open_err == nil)
	after_size, _ := os.file_size(after)
	os.close(after)
	testing.expect_value(t, after_size, before_size)
}

@(test)
test_multi_shard_startup_failure_discards_earlier_replay_and_closes_all_writers :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("multi-shard-startup-failure-isolation")
	defer os.remove_all(data_dir)
	generation: u64 = 1
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
	worker, worker_count := 0, 2
	early_shard, failing_shard := 0, 2
	workspaces: [2]string
	for candidate_index in 0 ..< 10_000 {
		candidate := fmt.aprintf("multi-shard-startup-%d", candidate_index)
		shard := int(shard_for_workspace(transmute([]byte)candidate))
		if shard == early_shard && workspaces[0] == "" {
			workspaces[0] = candidate
		} else if shard == failing_shard && workspaces[1] == "" {
			workspaces[1] = candidate
		} else {
			delete(candidate)
		}
		if workspaces[0] != "" && workspaces[1] != "" do break
	}
	defer for workspace in workspaces do delete(workspace)
	testing.expect(t, workspaces[0] != "" && workspaces[1] != "")
	if workspaces[0] == "" || workspaces[1] == "" do return

	for workspace, index in workspaces {
		shard := index == 0 ? early_shard : failing_shard
		path := sharded_active_wal_path(generation_dir, shard)
		writer: Shard_Transaction_Writer
		testing.expect(t, init_shard_transaction_writer(&writer, path, shard, worker, worker_count))
		delete(path)
		test_data: Shard_Writer_Test_Data
		shard_writer_test_transaction_init(&test_data, workspace)
		testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
		shard_writer_test_transaction_destroy(&test_data)
		shutdown_shard_transaction_writer(&writer)
	}

	failing_path := sharded_active_wal_path(generation_dir, failing_shard)
	defer delete(failing_path)
	prefix, prefix_err := os.read_entire_file(failing_path, context.allocator)
	assert(prefix_err == nil)
	defer delete(prefix)
	faults := [3]persistence.WAL_Recovery_Fault{.None, .Truncate, .Sync}
	defer persistence.set_wal_recovery_failure_for_test(.None)
	defer clear_shard_replay_apply_failure_for_test()
	for fault in faults {
		if fault != .None {
			// Both shards' valid records have been applied before recovery I/O.
			// A failed sync may follow a successful truncate; do not assume the
			// on-disk suffix survives that failure.
			torn_file, open_err := os.open(failing_path, {.Write, .Append})
			assert(open_err == nil)
			torn_suffix: [17]byte
			written, write_err := os.write(torn_file, torn_suffix[:])
			assert(write_err == nil && written == len(torn_suffix))
			assert(os.sync(torn_file) == nil)
			os.close(torn_file)
		}
		shard_replay_state_init()
		td.thread_index = worker
		if fault == .None {
			set_shard_replay_apply_failure_for_test(failing_shard)
		} else {
			persistence.set_wal_recovery_failure_for_test(fault)
		}
		testing.expect(t, !init_active_sharded_worker_persistence(data_dir, generation, worker, worker_count))
		testing.expect(t, !shard_replay_apply_fault.armed)
		testing.expect_value(t, persistence.wal_recovery_fault_for_test, persistence.WAL_Recovery_Fault.None)
		testing.expect(t, td.shard_writers.mode == .Inactive && len(td.shard_writers.writers) == 0)
		testing.expect(t, len(td.workspaces) == 0)
		testing.expect(t, get_workspace(workspaces[0]) == nil && get_workspace(workspaces[1]) == nil)
		testing.expect_value(t, td.task_seq, u64(0))
		testing.expect_value(t, td.asset_seq, u64(0))
		testing.expect_value(t, td.edge_seq, u64(0))
		failed_bytes, read_err := os.read_entire_file(failing_path, context.allocator)
		assert(read_err == nil)
		testing.expect_value(t, len(failed_bytes), len(prefix) + (fault == .Truncate ? 17 : 0))
		testing.expect(t, bytes.equal(failed_bytes[:len(prefix)], prefix))
		delete(failed_bytes)

		// Listener publication remains blocked on failure. Every writer must
		// reopen on retry, and each shard must replay exactly once.
		testing.expect(t, init_active_sharded_worker_persistence(data_dir, generation, worker, worker_count))
		for workspace in workspaces {
			conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
			testing.expect(t, conv != nil && len(conv.tasks) == 1 && len(conv.assets) == 1 && len(conv.edges) == 1)
		}
		testing.expect_value(t, td.task_seq, u64(10))
		testing.expect_value(t, td.asset_seq, u64(20))
		testing.expect_value(t, td.edge_seq, u64(30))
		shutdown_shard_writer_registry(&td.shard_writers)
		shard_replay_state_destroy()
	}
}

@(test)
test_worker_durability_sweep_fsyncs_idle_batched_writes :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("worker-durability-sweep")
	defer os.remove_all(data_dir)
	testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
	defer nbio.destroy(&td.io)
	generation: u64 = 1
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
	workspace := "worker-durability-sweep"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	registry: Shard_Writer_Registry
	testing.expect(t, init_shard_writer_registry(&registry, generation_dir, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_writer_registry(&registry)
	writer := shard_writer_for_workspace(&registry, transmute([]byte)workspace)
	testing.expect(t, writer != nil)
	if writer == nil do return
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(writer, &test_data.tx))
	testing.expect_value(t, writer.wal.record_count, u64(0))
	testing.expect_value(t, writer.wal.buffered_record_count, u64(1))
	testing.expect_value(t, writer.wal.durable_record_count, u64(0))
	testing.expect(t, writer.wal.write_offset > 0)

	writer.commit_started = {}
	did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&registry)
	testing.expect(t, sync_ok && did_work)
	testing.expect(t, writer.write_in_flight && !writer.fsync_in_flight)
	testing.expect_value(t, writer.wal.durable_record_count, u64(0))
	testing.expect(t, !rotate_shard_writer_for_compaction(writer))
	testing.expect(t, !writer.poisoned && writer.compaction == .Idle)
	testing.expect(t, !append_shard_transaction(writer, &test_data.tx), "leased batch cannot be changed")
	testing.expect(t, consume_shard_append_backpressure())
	write_started := ulid.time_now()
	for writer.write_in_flight && time.since(write_started) < time.Second {
		testing.expect_value(t, nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true), linux.Errno.NONE)
	}
	testing.expect(t, !writer.write_in_flight)

	// Writes may continue while fsync is in flight. Completion advances the
	// conservative durable watermark only through the submitted snapshot.
	testing.expect(t, append_shard_transaction(writer, &test_data.tx))
	fsync_started := time.now()
	for writer.fsync_in_flight && time.since(fsync_started) < time.Second {
		testing.expect_value(t, nbio.tick(&td.io, time.Millisecond), linux.Errno.NONE)
	}
	testing.expect(t, !writer.fsync_in_flight)
	testing.expect_value(t, writer.wal.record_count, u64(1))
	testing.expect_value(t, writer.wal.buffered_record_count, u64(1))
	testing.expect_value(t, writer.wal.durable_record_count, u64(1))
	testing.expect(t, writer.wal.write_offset > 0)

	writer.commit_started = {}
	did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&registry)
	testing.expect(t, sync_ok && did_work)
	fsync_started = time.now()
	for (writer.write_in_flight || writer.fsync_in_flight) && time.since(fsync_started) < time.Second {
		testing.expect_value(t, nbio.tick(&td.io, time.Millisecond), linux.Errno.NONE)
	}
	testing.expect(t, !writer.write_in_flight && !writer.fsync_in_flight)
	testing.expect_value(t, writer.wal.durable_record_count, u64(2))
	testing.expect_value(t, writer.wal.pending_bytes, u64(0))
	testing.expect(t, rotate_shard_writer_for_compaction(writer))
}

@(test)
test_shard_writer_preemptive_rotation_reserves_largest_record :: proc(t: ^testing.T) {
	when SHARD_WAL_SEGMENT_MAX_BYTES <= persistence.MAX_WAL_PAYLOAD_SIZE + persistence.LOG_HEADER_SIZE {
		return
	} else {
		path := test_wal_path("shard-preemptive-rotation-reserve.log")
		defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, nil) == nil)
		writer := Shard_Transaction_Writer {
			managed = true,
		}
		testing.expect(t, persistence.init_wal(&writer.wal, path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION, 0, nrc_wal_time_now))
		defer persistence.shutdown_wal(&writer.wal)

		rotation_reserve := u64(persistence.MAX_WAL_PAYLOAD_SIZE + persistence.LOG_HEADER_SIZE)
		writer.wal.file_size_bytes = SHARD_WAL_SEGMENT_MAX_BYTES - rotation_reserve - 1
		testing.expect(t, !shard_writer_should_rotate_before_async_fsync(&writer))
		writer.wal.file_size_bytes = SHARD_WAL_SEGMENT_MAX_BYTES - rotation_reserve
		testing.expect(t, shard_writer_should_rotate_before_async_fsync(&writer))
	}
}

@(test)
test_shard_async_fsync_failure_poisons_writer_and_is_shutdown_safe :: proc(t: ^testing.T) {
	path := test_wal_path("shard-async-fsync-failure.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "shard-async-fsync-failure"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
	writer.wal.last_fsync = {}
	snapshot, due := persistence.prepare_async_fsync(&writer.wal)
	testing.expect(t, due)
	writer.fsync_in_flight = due
	writer.fsync_snapshot = snapshot
	writer.fsync_started = time.now()
	previous_logger := context.logger
	context.logger = log.nil_logger()
	shard_writer_fsync_complete(&writer, .EIO)
	context.logger = previous_logger
	testing.expect(t, writer.poisoned && !writer.wal.enabled)
	testing.expect(t, !writer.fsync_in_flight)
	testing.expect(t, shutdown_shard_transaction_writer(&writer))
}

test_shard_writer_roundtrip_and_task_cascade_single_record :: proc(t: ^testing.T) {
	path := test_wal_path("shard-writer-roundtrip.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "shard-writer-workspace"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	owner, owner_ok := logical_shard_worker(shard, 3)
	testing.expect(t, owner_ok)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, owner, 3))
	shard_replay_state_init()
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
	for mutation in test_data.tx.mutations do testing.expect(t, apply_shard_mutation(test_data.tx.workspace, mutation))
	conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 1 && len(conv.assets) == 1 && len(conv.edges) == 1)
	shutdown_shard_transaction_writer(&writer)
	shard_replay_state_destroy()

	shard_replay_state_init()
	first_inspection, first_floors, first_ok := replay_shard_transaction_wal(path, shard)
	testing.expect(t, first_ok)
	testing.expect_value(t, first_inspection.record_count, u64(1))
	testing.expect_value(t, first_floors, Shard_High_Water_Requirements{task = 10, asset = 20, edge = 30})
	conv = get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 1 && len(conv.assets) == 1 && len(conv.edges) == 1)

	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, owner, 3))
	assets := []pr.AssetID{20}
	asset_edges := []pr.EdgeID{30}
	cascade, cascade_ok := build_shard_task_delete_transaction(transmute([]byte)workspace, 77, 10, assets, asset_edges, nil, writer.floors)
	testing.expect(t, cascade_ok); defer destroy_shard_task_delete_transaction(&cascade)
	testing.expect_value(t, len(cascade.tx.mutations), 3)
	testing.expect(t, persist_and_apply_shard_delete_transaction(&writer, &cascade.tx))
	testing.expect_value(t, len(conv.tasks), 0)
	testing.expect_value(t, len(conv.assets), 0)
	testing.expect_value(t, len(conv.edges), 0)
	shutdown_shard_transaction_writer(&writer)
	shard_replay_state_destroy()

	shard_replay_state_init()
	final_inspection, final_floors, final_ok := replay_shard_transaction_wal(path, shard)
	testing.expect(t, final_ok)
	testing.expect_value(t, final_inspection.record_count, u64(2))
	testing.expect_value(t, final_floors, first_floors)
	conv = get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 0 && len(conv.assets) == 0 && len(conv.edges) == 0)
	shard_replay_state_destroy()
}

@(test)
test_shard_writer_failure_poisoning_precedes_apply :: proc(t: ^testing.T) {
	path := test_wal_path("shard-writer-failure.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "shard-writer-failure"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	owner, _ := logical_shard_worker(shard, 2)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, owner, 2))
	defer shutdown_shard_transaction_writer(&writer)
	shard_replay_state_init(); defer shard_replay_state_destroy()
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, apply_shard_mutation(test_data.tx.workspace, test_data.tx.mutations[0]))
	cascade, cascade_ok := build_shard_task_delete_transaction(test_data.tx.workspace, 77, 10, nil, nil, nil, writer.floors)
	testing.expect(t, cascade_ok); defer destroy_shard_task_delete_transaction(&cascade)

	persistence.clear_wal_write_fault_for_test()
	defer persistence.clear_wal_write_fault_for_test()
	persistence.set_wal_short_write_for_test(1)
	previous_logger := context.logger; context.logger = log.nil_logger()
	persisted := persist_and_apply_shard_delete_transaction(&writer, &cascade.tx)
	context.logger = previous_logger
	testing.expect(t, !persisted)
	testing.expect(t, persistence.wal_write_fault_triggered_for_test())
	testing.expect(t, writer.poisoned && !writer.wal.enabled)
	conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && conv.tasks[10] != nil)
	context.logger = log.nil_logger()
	persisted_again := persist_and_apply_shard_delete_transaction(&writer, &cascade.tx)
	context.logger = previous_logger
	testing.expect(t, !persisted_again)
}

@(test)
test_shard_writer_disk_errors_poison_before_apply_and_restart_cleanly :: proc(t: ^testing.T) {
	errors := [?]posix.Errno{.ENOSPC, .EROFS}
	for write_errno, case_index in errors {
		path := test_wal_path(fmt.tprintf("shard-writer-disk-error-%d.log", case_index)); defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, nil) == nil)
		workspace := fmt.tprintf("shard-writer-disk-error-%d", case_index)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		owner, _ := logical_shard_worker(shard, 2)
		writer: Shard_Transaction_Writer
		testing.expect(t, init_shard_transaction_writer(&writer, path, shard, owner, 2))
		shard_replay_state_init()
		test_data: Shard_Writer_Test_Data
		shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
		testing.expect(t, apply_shard_mutation(test_data.tx.workspace, test_data.tx.mutations[0]))
		cascade, cascade_ok := build_shard_task_delete_transaction(test_data.tx.workspace, 77, 10, nil, nil, nil, writer.floors)
		testing.expect(t, cascade_ok); defer destroy_shard_task_delete_transaction(&cascade)
		persistence.clear_wal_write_fault_for_test(); defer persistence.clear_wal_write_fault_for_test()
		previous_logger := context.logger; context.logger = log.nil_logger()
		persistence.set_wal_write_error_for_test(os.Platform_Error(write_errno))
		persisted := persist_and_apply_shard_delete_transaction(&writer, &cascade.tx)
		context.logger = previous_logger
		testing.expect(t, !persisted)
		testing.expect(t, persistence.wal_write_fault_triggered_for_test())
		testing.expect(t, writer.poisoned && !writer.wal.enabled)
		conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
		testing.expect(t, conv != nil && conv.tasks[10] != nil)
		shutdown_shard_transaction_writer(&writer)
		shard_replay_state_destroy()

		restarted: Shard_Transaction_Writer
		testing.expect(t, init_shard_transaction_writer(&restarted, path, shard, owner, 2))
		testing.expect_value(t, restarted.wal.record_count, u64(0))
		testing.expect_value(t, restarted.floors, Shard_High_Water_Requirements{})
		shutdown_shard_transaction_writer(&restarted)

		shard_replay_state_init()
		inspection, floors, replay_ok := replay_shard_transaction_wal(path, shard)
		testing.expect(t, replay_ok)
		testing.expect_value(t, inspection.record_count, u64(0))
		testing.expect_value(t, floors, Shard_High_Water_Requirements{})
		testing.expect(t, get_workspace(workspace) == nil)
		shard_replay_state_destroy()
	}
}

@(test)
test_shard_mutation_builders_append_and_replay :: proc(t: ^testing.T) {
	path := test_wal_path("shard-mutation-builders.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "shard-mutation-builders"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	owner, _ := logical_shard_worker(shard, 2)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, owner, 2))

	task := pr.Task {
		id      = 10,
		conv_id = 77,
		title   = transmute([]byte)string("created"),
		status  = .Todo,
	}
	task_ops := [3]Task_Log_Op{.Create, .Update, .Move}
	for op in task_ops {
		built, ok := build_shard_task_mutation(transmute([]byte)workspace, op, &task, writer.floors)
		testing.expect(t, ok)
		if ok do testing.expect(t, append_shard_transaction(&writer, &built.tx))
		destroy_shard_mutation_transaction(&built)
	}
	asset := pr.Asset {
		asset_type       = .Document,
		asset_id         = 20,
		parent_type      = .Task,
		parent_id        = 10,
		conv_id          = 77,
		payload_encoding = .Plain,
	}
	asset_ops := [2]Asset_Log_Op{.Create, .Update}
	for op in asset_ops {
		built, ok := build_shard_asset_mutation(transmute([]byte)workspace, op, &asset, writer.floors)
		testing.expect(t, ok)
		if ok do testing.expect(t, append_shard_transaction(&writer, &built.tx))
		destroy_shard_mutation_transaction(&built)
	}
	edge := pr.Edge {
		edge_id     = 30,
		conv_id     = 77,
		source_type = .Task,
		source_id   = 10,
		target_type = .Asset,
		target_id   = 20,
		relation    = .References,
	}
	edge_create, edge_ok := build_shard_edge_mutation(transmute([]byte)workspace, .Create, &edge, writer.floors)
	testing.expect(t, edge_ok)
	if edge_ok do testing.expect(t, append_shard_transaction(&writer, &edge_create.tx))
	destroy_shard_mutation_transaction(&edge_create)

	edge_delete, edge_delete_ok := build_shard_edge_delete_mutation(transmute([]byte)workspace, 77, 30, writer.floors)
	testing.expect(t, edge_delete_ok)
	if edge_delete_ok do testing.expect(t, append_shard_transaction(&writer, &edge_delete.tx))
	destroy_shard_mutation_transaction(&edge_delete)
	asset_delete, asset_delete_ok := build_shard_asset_delete_mutation(transmute([]byte)workspace, 77, 20, writer.floors)
	testing.expect(t, asset_delete_ok)
	if asset_delete_ok do testing.expect(t, append_shard_transaction(&writer, &asset_delete.tx))
	destroy_shard_mutation_transaction(&asset_delete)
	task_delete, task_delete_ok := build_shard_task_delete_mutation(transmute([]byte)workspace, 77, 10, writer.floors)
	testing.expect(t, task_delete_ok)
	if task_delete_ok do testing.expect(t, append_shard_transaction(&writer, &task_delete.tx))
	destroy_shard_mutation_transaction(&task_delete)
	shutdown_shard_transaction_writer(&writer)

	shard_replay_state_init(); defer shard_replay_state_destroy()
	inspection, floors, replay_ok := replay_shard_transaction_wal(path, shard)
	testing.expect(t, replay_ok)
	testing.expect_value(t, inspection.record_count, u64(9))
	testing.expect_value(t, floors, Shard_High_Water_Requirements{task = 10, asset = 20, edge = 30})
	conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 0 && len(conv.assets) == 0 && len(conv.edges) == 0)
}

@(test)
test_shard_registry_is_inert_until_initialized_and_routes_only_owner :: proc(t: ^testing.T) {
	workspace := "shard-registry-owner"
	workspace_bytes := transmute([]byte)workspace
	shard := int(shard_for_workspace(workspace_bytes))
	registry: Shard_Writer_Registry
	testing.expect(t, shard_writer_for_workspace(&registry, workspace_bytes) == nil)

	dir := test_wal_path("shard-registry-generation"); defer os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	shard_dir := sharded_shard_path(dir, shard)
	testing.expect(t, os.make_directory(shard_dir) == nil)
	delete(shard_dir)
	path := sharded_active_wal_path(dir, shard)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	delete(path)
	testing.expect(t, init_shard_writer_registry(&registry, dir, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_writer_registry(&registry)
	writer := shard_writer_for_workspace(&registry, workspace_bytes)
	testing.expect(t, writer != nil && writer.shard == shard)
	registry.worker = (shard + 1) % LOGICAL_SHARD_COUNT
	testing.expect(t, shard_writer_for_workspace(&registry, workspace_bytes) == nil)
}

@(test)
test_active_sharded_restart_reassigns_and_replays_after_worker_count_change :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("active-shard-worker-resize")
	defer os.remove_all(data_dir)
	generation: u64 = 2
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))

	workspace := ""
	for i in 0 ..< 1000 {
		candidate := fmt.aprintf("active-resize-%d", i)
		shard := int(shard_for_workspace(transmute([]byte)candidate))
		owner_three, _ := logical_shard_worker(shard, 3)
		owner_five, _ := logical_shard_worker(shard, 5)
		if owner_three != owner_five {
			workspace = candidate
			break
		}
		delete(candidate)
	}
	defer delete(workspace)
	testing.expect(t, len(workspace) > 0)
	if len(workspace) == 0 do return

	shard := int(shard_for_workspace(transmute([]byte)workspace))
	owner_three, _ := logical_shard_worker(shard, 3)
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	path := sharded_active_wal_path(generation_dir, shard)
	defer delete(path)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, owner_three, 3))
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace)
	defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
	shutdown_shard_transaction_writer(&writer)

	shard_replay_state_init()
	td.thread_index = owner_three
	testing.expect(t, init_active_sharded_worker_persistence(data_dir, generation, owner_three, 3))
	task := get_task(workspace, pr.WORKSPACE_DATA_ID, 10)
	testing.expect(t, task != nil)
	if task != nil {
		task.title = transmute([]byte)string("after-resize")
		task.updated_at = 999
		testing.expect(t, persist_task_updated(workspace, task))
	}
	shutdown_shard_writer_registry(&td.shard_writers)
	shard_replay_state_destroy()

	owner_five, _ := logical_shard_worker(shard, 5)
	shard_replay_state_init()
	td.thread_index = owner_five
	testing.expect(t, init_active_sharded_worker_persistence(data_dir, generation, owner_five, 5))
	replayed := get_task(workspace, pr.WORKSPACE_DATA_ID, 10)
	testing.expect(t, replayed != nil)
	if replayed != nil {
		testing.expect_value(t, string(replayed.title), "after-resize")
		testing.expect_value(t, replayed.updated_at, i64(999))
	}
	shutdown_shard_writer_registry(&td.shard_writers)
	shard_replay_state_destroy()
}

@(test)
test_active_sharded_startup_recovers_torn_wal_tail_before_replay :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("active-shard-torn-tail")
	defer os.remove_all(data_dir)
	generation: u64 = 3
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))

	workspace := "active-shard-torn-tail"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	path := sharded_active_wal_path(generation_dir, shard)
	defer delete(path)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace)
	defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
	shutdown_shard_transaction_writer(&writer)

	valid_inspection := persistence.inspect_wal_file_strict(path, SHARD_WAL_MAGIC, shard, proc(_: u8, _: u16, _: []byte) -> bool {return true})
	testing.expect(t, valid_inspection.ok && valid_inspection.record_count == 1)
	valid_file, valid_open_err := os.open(path)
	testing.expect(t, valid_open_err == nil)
	valid_size: i64
	if valid_open_err == nil {
		valid_size, _ = os.file_size(valid_file)
		os.close(valid_file)
	}
	testing.expect(t, valid_size > 0)

	torn_file, torn_open_err := os.open(path, {.Write, .Append})
	testing.expect(t, torn_open_err == nil)
	if torn_open_err == nil {
		torn_suffix_text: string = "incomplete-shard-record"
		torn_suffix := transmute([]byte)torn_suffix_text
		written, write_err := os.write(torn_file, torn_suffix)
		testing.expect(t, write_err == nil && written == len(torn_suffix))
		testing.expect(t, os.sync(torn_file) == nil)
		os.close(torn_file)
	}

	shard_replay_state_init()
	defer shard_replay_state_destroy()
	td.thread_index = shard
	testing.expect(t, init_active_sharded_worker_persistence(data_dir, generation, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_writer_registry(&td.shard_writers)

	recovered := get_task(workspace, pr.WORKSPACE_DATA_ID, 10)
	testing.expect(t, recovered != nil)
	testing.expect_value(t, td.task_seq, u64(10))
	testing.expect_value(t, td.asset_seq, u64(20))
	testing.expect_value(t, td.edge_seq, u64(30))

	recovered_file, recovered_open_err := os.open(path)
	testing.expect(t, recovered_open_err == nil)
	if recovered_open_err == nil {
		recovered_size, size_err := os.file_size(recovered_file)
		testing.expect(t, size_err == nil)
		testing.expect_value(t, recovered_size, valid_size)
		os.close(recovered_file)
	}
	// The reused inspection must describe the durable prefix, not the torn
	// suffix. Appending and strict reinspection exercise the continued chain.
	reopened := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)workspace)
	testing.expect(t, reopened != nil)
	if reopened != nil {
		testing.expect_value(t, reopened.wal.record_count, u64(1))
		testing.expect_value(t, reopened.wal.durable_record_count, u64(1))
		testing.expect_value(t, reopened.wal.last_hash, valid_inspection.last_hash)
		testing.expect(t, shard_compaction_test_append_task(reopened, workspace, 11, "after recovered tail"))
		testing.expect(t, persistence.flush_write_batch(&reopened.wal))
		inspection, floors, ok := scan_shard_transaction_wal(path, shard, {}, false, false)
		testing.expect(t, ok)
		testing.expect_value(t, inspection.record_count, u64(2))
		testing.expect_value(t, floors, Shard_High_Water_Requirements{task = 11, asset = 20, edge = 30})
	}
}

@(test)
test_single_shard_mutation_short_write_never_replays :: proc(t: ^testing.T) {
	path := test_wal_path("single-shard-short-write.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "single-shard-short-write"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	owner, _ := logical_shard_worker(shard, 2)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, owner, 2))
	task := pr.Task {
		id      = 10,
		conv_id = 77,
		title   = transmute([]byte)string("not-durable"),
	}
	built, built_ok := build_shard_task_mutation(transmute([]byte)workspace, .Create, &task, writer.floors)
	testing.expect(t, built_ok); defer destroy_shard_mutation_transaction(&built)
	persistence.clear_wal_write_fault_for_test(); defer persistence.clear_wal_write_fault_for_test()
	persistence.set_wal_short_write_for_test(1)
	previous_logger := context.logger; context.logger = log.nil_logger()
	appended := append_shard_transaction(&writer, &built.tx)
	context.logger = previous_logger
	testing.expect(t, !appended)
	testing.expect(t, writer.poisoned && !writer.wal.enabled)
	shutdown_shard_transaction_writer(&writer)

	shard_replay_state_init(); defer shard_replay_state_destroy()
	// Strict replay rejects the torn record; writer startup recovers its tail.
	_, _, strict_ok := replay_shard_transaction_wal(path, shard)
	testing.expect(t, !strict_ok)
	recovered: Shard_Transaction_Writer
	if !testing.expect(t, init_shard_transaction_writer(&recovered, path, shard, owner, 2)) do return
	defer shutdown_shard_transaction_writer(&recovered)
	inspection, floors, replay_ok := replay_shard_transaction_wal(path, shard)
	testing.expect(t, replay_ok)
	testing.expect_value(t, inspection.record_count, u64(0))
	testing.expect_value(t, floors, Shard_High_Water_Requirements{})
	testing.expect(t, get_workspace(workspace) == nil)
}

@(test)
test_shard_asset_cascade_is_one_record_and_replays_atomically :: proc(t: ^testing.T) {
	path := test_wal_path("shard-asset-cascade.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "shard-asset-cascade"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	owner, _ := logical_shard_worker(shard, 3)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, owner, 3))
	shard_replay_state_init()
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace); defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, append_shard_transaction(&writer, &test_data.tx))
	for mutation in test_data.tx.mutations do testing.expect(t, apply_shard_mutation(test_data.tx.workspace, mutation))

	asset_ids := []pr.AssetID{20}
	edge_ids := []pr.EdgeID{30}
	cascade, cascade_ok := build_shard_asset_delete_transaction(test_data.tx.workspace, 77, asset_ids, edge_ids, nil, writer.floors)
	testing.expect(t, cascade_ok); defer destroy_shard_asset_delete_transaction(&cascade)
	testing.expect_value(t, len(cascade.tx.mutations), 2)
	testing.expect(t, persist_and_apply_shard_delete_transaction(&writer, &cascade.tx))
	conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 1 && len(conv.assets) == 0 && len(conv.edges) == 0)
	shutdown_shard_transaction_writer(&writer)
	shard_replay_state_destroy()

	shard_replay_state_init(); defer shard_replay_state_destroy()
	inspection, floors, replay_ok := replay_shard_transaction_wal(path, shard)
	testing.expect(t, replay_ok)
	testing.expect_value(t, inspection.record_count, u64(2))
	testing.expect_value(t, floors, Shard_High_Water_Requirements{task = 10, asset = 20, edge = 30})
	conv = get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 1 && len(conv.assets) == 0 && len(conv.edges) == 0)
}

@(test)
test_legacy_checkpoint_sealed_and_active_wals_replay_in_manifest_order :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("legacy-checkpoint-sealed-active-order")
	defer os.remove_all(data_dir)
	generation: u64 = 1
	testing.expect(t, storage_layout_test_create_generation(data_dir, generation))
	workspace := "legacy-checkpoint-sealed-active-order"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	checkpoint_path := shard_checkpoint_wal_path(shard_dir, 1)
	defer delete(checkpoint_path)
	sealed_path := shard_generation_wal_path(shard_dir, 2)
	defer delete(sealed_path)
	active_path := shard_generation_wal_path(shard_dir, 3)
	defer delete(active_path)
	testing.expect(t, shard_writer_test_write_task_wal(checkpoint_path, workspace, shard, 10, "checkpoint"))
	testing.expect(t, shard_writer_test_write_task_wal(sealed_path, workspace, shard, 20, "sealed"))
	testing.expect(t, shard_writer_test_write_task_wal(active_path, workspace, shard, 30, "active"))

	manifest := Shard_Compaction_Manifest {
		shard                 = shard,
		manifest_generation   = 4,
		checkpoint_present    = true,
		checkpoint_generation = 1,
		sealed_present        = true,
		sealed_generation     = 2,
		active_generation     = 3,
		segmented             = false,
	}
	manifest_data: [SHARD_COMPACTION_MANIFEST_SIZE]byte
	testing.expect(t, encode_shard_compaction_manifest(manifest, manifest_data[:]))
	manifest_path := shard_compaction_manifest_path(shard_dir)
	defer delete(manifest_path)
	testing.expect(t, os.write_entire_file(manifest_path, manifest_data[:]) == nil)

	shard_replay_state_init()
	td.thread_index = shard
	testing.expect(t, init_active_sharded_worker_persistence(data_dir, generation, shard, LOGICAL_SHARD_COUNT))
	conv := get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 3)
	if conv != nil {
		expected_task_ids := [3]pr.TaskID{10, 20, 30}
		for task_id in expected_task_ids do testing.expect(t, conv.tasks[task_id] != nil)
	}
	testing.expect_value(t, td.task_seq, u64(30))
	writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)workspace)
	testing.expect(t, writer != nil)
	if writer != nil {
		// Three sequence records but only one active record. Each file starts
		// its own hash chain; neither cumulative count nor sealed hash is valid
		// append state for the active file.
		// Prefix floors exclude active, even when captured by the same scan.
		testing.expect_value(t, writer.catalog_floors, Shard_High_Water_Requirements{task = 20})
		testing.expect_value(t, writer.compaction_floors, Shard_High_Water_Requirements{task = 20})
		testing.expect_value(t, writer.floors, Shard_High_Water_Requirements{task = 30})
		active := persistence.inspect_wal_file_strict(active_path, SHARD_WAL_MAGIC, shard, proc(_: u8, _: u16, _: []byte) -> bool {return true})
		sealed := persistence.inspect_wal_file_strict(sealed_path, SHARD_WAL_MAGIC, shard, proc(_: u8, _: u16, _: []byte) -> bool {return true})
		testing.expect(t, active.ok && sealed.ok && active.last_hash != sealed.last_hash)
		testing.expect_value(t, writer.wal.record_count, u64(1))
		testing.expect_value(t, writer.wal.last_hash, active.last_hash)
		continuation := pr.Task {
			id      = 40,
			conv_id = 77,
			title   = transmute([]byte)string("continuation"),
			status  = .Todo,
		}
		built, built_ok := build_shard_task_mutation(transmute([]byte)workspace, .Create, &continuation, writer.floors)
		testing.expect(t, built_ok)
		if built_ok {
			testing.expect(t, append_shard_transaction(writer, &built.tx))
			testing.expect(t, apply_shard_mutation(built.tx.workspace, built.tx.mutations[0]))
		}
		destroy_shard_mutation_transaction(&built)
	}
	shutdown_shard_writer_registry(&td.shard_writers)
	shard_replay_state_destroy()

	shard_replay_state_init()
	td.thread_index = shard
	testing.expect(t, init_active_sharded_worker_persistence(data_dir, generation, shard, LOGICAL_SHARD_COUNT))
	conv = get_conversation(get_workspace(workspace), pr.WORKSPACE_DATA_ID)
	testing.expect(t, conv != nil && len(conv.tasks) == 4)
	if conv != nil {
		expected_task_ids := [4]pr.TaskID{10, 20, 30, 40}
		for task_id in expected_task_ids do testing.expect(t, conv.tasks[task_id] != nil)
	}
	testing.expect_value(t, td.task_seq, u64(40))
	shutdown_shard_writer_registry(&td.shard_writers)
	shard_replay_state_destroy()
}

@(test)
test_shard_append_only_classification_requires_advancing_create_ids :: proc(t: ^testing.T) {
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, "shard-append-only-classification")
	defer shard_writer_test_transaction_destroy(&test_data)
	testing.expect(t, shard_transaction_is_append_only(&test_data.tx, {}))

	duplicate_mutations := [2]Shard_Mutation{test_data.mutations[0], test_data.mutations[0]}
	duplicate := test_data.tx
	duplicate.mutations = duplicate_mutations[:]
	testing.expect(t, !shard_transaction_is_append_only(&duplicate, {}))

	reused := test_data.tx
	reused.mutations = test_data.mutations[0:1]
	testing.expect(t, !shard_transaction_is_append_only(&reused, {task = 10}))
}

@(test)
test_shard_append_backpressure_rejects_without_poisoning_writer :: proc(t: ^testing.T) {
	disk_pressure_writer := Shard_Transaction_Writer {
		managed              = true,
		available_disk_bytes = SHARD_DISK_HARD_AVAILABLE_BYTES,
		space_known          = true,
		space_checked_at     = ulid.time_now(),
	}
	testing.expect(t, shard_writer_backpressured(&disk_pressure_writer))
	unknown_space_writer := Shard_Transaction_Writer {
		managed   = true,
		storage   = {},
		shard_dir = "/unavailable",
	}
	testing.expect(t, shard_writer_backpressured(&unknown_space_writer))

	path := test_wal_path("shard-backpressure.log"); defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "shard-backpressure"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)
	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace)
	defer shard_writer_test_transaction_destroy(&test_data)
	writer.clean_backlog_bytes = SHARD_CLEAN_BACKLOG_HARD_BYTES
	testing.expect(t, !append_shard_transaction(&writer, &test_data.tx))
	testing.expect(t, consume_shard_append_backpressure())
	testing.expect(t, !writer.poisoned && writer.wal.enabled)
	testing.expect_value(t, writer.wal.record_count, u64(0))
}

@(test)
test_full_shard_wal_defers_protocol_request_while_fsync_is_in_flight :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 117)
	defer worker_state_destroy_core_for_test()

	data_dir := storage_layout_test_setup("shard-deferred-request")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 1))
	workspace := "shard-deferred-request"
	workspace_bytes := transmute([]byte)workspace
	shard := int(shard_for_workspace(workspace_bytes))
	generation_dir := sharded_generation_path(data_dir, 1)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)

	c := connection_test_install_fake(Fake_Connection_Options{sock = connection_test_fake_socket(117), state = .Idle, workspace_id = workspace})
	testing.expect(t, c != nil)
	if c == nil do return
	defer connection_test_uninstall(c)

	payload := []byte{0x12, 0x34, 0x56}
	previous_dispatch := shard_protocol_dispatch_context
	shard_protocol_dispatch_context = {
		connection = c,
		payload    = payload,
	}
	defer shard_protocol_dispatch_context = previous_dispatch

	test_data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&test_data, workspace)
	defer shard_writer_test_transaction_destroy(&test_data)
	writer.wal.file_size_bytes = SHARD_WAL_SEGMENT_MAX_BYTES
	writer.fsync_in_flight = true

	testing.expect(t, !append_shard_transaction(&writer, &test_data.tx))
	testing.expect(t, consume_shard_append_deferred())
	testing.expect_value(t, len(writer.deferred_requests), 1)
	testing.expect_value(t, writer.deferred_request_bytes, len(payload))
	testing.expect_value(t, c.pending_io, 1)
	testing.expect_value(t, c.deferred_shard_requests, u16(1))
	testing.expect(t, &writer.deferred_requests[0].payload[0] != &payload[0], "deferred request must own its protocol payload")
	testing.expect(t, writer.deferred_requests[0].payload[2] == payload[2])
	testing.expect_value(t, writer.wal.record_count, u64(0))
	testing.expect(t, !writer.poisoned)

	writer.fsync_in_flight = false
	discard_shard_deferred_requests(&writer)
	testing.expect_value(t, len(writer.deferred_requests), 0)
	testing.expect_value(t, writer.deferred_request_bytes, 0)
	testing.expect_value(t, c.pending_io, 0)
	testing.expect_value(t, c.deferred_shard_requests, u16(0))

	writer.deferred_request_bytes = SHARD_DEFERRED_REQUEST_MAX_BYTES
	testing.expect(t, !defer_current_shard_protocol_request(&writer), "bounded queue must reject requests beyond its byte cap")
	testing.expect_value(t, c.pending_io, 0)
	writer.deferred_request_bytes = 0
	testing.expect(t, defer_current_shard_protocol_request(&writer))
	testing.expect_value(t, c.pending_io, 1)
	testing.expect_value(t, c.deferred_shard_requests, u16(1))
	c.state = .Will_Close
	drain_shard_deferred_requests(&writer)
	testing.expect_value(t, c.pending_io, 0)
	testing.expect_value(t, c.deferred_shard_requests, u16(0))
	testing.expect_value(t, len(writer.deferred_requests), 0)
	c.state = .Idle
}

@(test)
test_group_commit_cap_deferred_request_shutdown_without_inflight_fsync :: proc(t: ^testing.T) {
	worker_state_init_core(nil, 118)
	defer worker_state_destroy_core_for_test()
	testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
	defer nbio.destroy(&td.io)
	data_dir := storage_layout_test_setup("group-commit-cap-shutdown")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 1))
	generation_dir := sharded_generation_path(data_dir, 1)
	defer delete(generation_dir)
	workspace := "group-commit-cap-shutdown"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	testing.expect(t, init_shard_writer_registry(&td.shard_writers, generation_dir, shard, LOGICAL_SHARD_COUNT))
	writer := &td.shard_writers.writers[0]
	c, allocated := connection_alloc()
	testing.expect(t, allocated)
	if !allocated do return
	c.state = .Idle
	payload := []byte{0x12, 0x34}
	previous_dispatch := shard_protocol_dispatch_context
	shard_protocol_dispatch_context = {
		connection = c,
		payload    = payload,
	}
	defer shard_protocol_dispatch_context = previous_dispatch
	data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&data, workspace)
	defer shard_writer_test_transaction_destroy(&data)
	writer.wal.pending_bytes = SHARD_COMMIT_PENDING_MAX_BYTES
	testing.expect(t, !append_shard_transaction(writer, &data.tx))
	testing.expect(t, consume_shard_append_deferred())
	testing.expect_value(t, c.pending_io, u32(1))
	testing.expect_value(t, len(writer.deferred_requests), 1)
	testing.expect(t, !writer.fsync_in_flight)
	writer.wal.pending_bytes = 0
	// Socket close has completed, but the cap-deferred request still retains
	// this connection. Shutdown must release that pin before its drain loop.
	c.state = .Closed
	c.close_completed = true
	_server_thread_shutdown(nil)
	testing.expect_value(t, td.retained_connection_count, 0)
	testing.expect_value(t, td.state, Server_State.Closed)
}

@(test)
test_shard_append_rechecks_backlog_after_threshold_rotation :: proc(t: ^testing.T) {
	when SHARD_WAL_SEGMENT_MAX_BYTES > 1024 || SHARD_CLEAN_BACKLOG_HARD_BYTES > 1024 {
		return
	} else {
		data_dir := storage_layout_test_setup("shard-post-rotation-backpressure")
		defer os.remove_all(data_dir)
		testing.expect(t, storage_layout_test_create_generation(data_dir, 10))
		workspace := "shard-post-rotation-backpressure"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		generation_dir := sharded_generation_path(data_dir, 10)
		defer delete(generation_dir)
		shard_dir := sharded_shard_path(generation_dir, shard)
		defer delete(shard_dir)
		writer: Shard_Transaction_Writer
		testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
		defer shutdown_shard_transaction_writer(&writer)
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "first"))
		testing.expect(t, !shard_compaction_test_append_task(&writer, workspace, 11, "rejected"))
		testing.expect(t, consume_shard_append_backpressure())
		testing.expect(t, !writer.poisoned && writer.wal.enabled)
		testing.expect_value(t, writer.catalog_segments, 1)
		testing.expect_value(t, writer.wal.record_count, u64(0))
	}
}
