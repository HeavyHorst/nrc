package protocol_fuzz

import pr "../../protocol"
import "core:fmt"
import "core:os"
import "core:strings"

// The corpus is generated from the protocol package's own client serializers and
// re-parsed before it is written. A serializer/parser drift therefore fails the
// generator loudly instead of silently producing seeds that never reach a
// handler. Every request and every transaction body below goes through a
// serializer; this file carries no wire layout of its own.

SEED_DIR_FLAG :: "-nrc-write-seeds="
MAX_SEED_BYTES :: 64 * 1024

Seed :: struct {
	name:  string,
	bytes: []byte,
}

// A string literal has the same {ptr, len} layout as a byte slice.
bstr :: proc "contextless" (s: string) -> []byte {return transmute([]byte)s}

SEED_ATTACHMENTS := [?]pr.Attachment {
	{file_id = bstr("01H8Z3W0Q4"), filename = bstr("spec.pdf"), size = 2048, mime_type = bstr("application/pdf"), uploaded_at = 1_700_000_000_000_000_000},
	{file_id = bstr("01H8Z3W0Q5"), filename = bstr("shot.png"), size = 512, mime_type = bstr("image/png"), uploaded_at = 1_700_000_100_000_000_000},
}

add_seed :: proc(seeds: ^[dynamic]Seed, name: string, bytes: []byte) {
	clone := make([]byte, len(bytes), context.allocator)
	copy(clone, bytes)
	append(seeds, Seed{name = name, bytes = clone})
}

build_task_and_asset_seeds :: proc(seeds: ^[dynamic]Seed, buf: []byte) {
	task_create := pr.CreateTaskRequest {
		conv_id        = 42,
		title          = bstr("Ship protocol fuzzing"),
		description    = bstr("Exercise the request parsers"),
		priority       = 3,
		color          = .Gold,
		external_ref   = bstr("NRC-300"),
		due_at         = 1_700_000_200_000_000_000,
		status         = .Note,
		project        = bstr("tooling"),
		correlation_id = 0xdeadbeef,
	}
	n := pr.serializeCreateTaskRequest(task_create, buf)
	assert(n > 0)
	add_seed(seeds, "create_task_min", buf[:n])

	task_create.attachments = SEED_ATTACHMENTS[:]
	task_create.description = bstr("")
	task_create.project = bstr("")
	n = pr.serializeCreateTaskRequest(task_create, buf)
	assert(n > 0)
	add_seed(seeds, "create_task_attachments", buf[:n])

	task_update := pr.UpdateTaskRequest {
		conv_id        = 42,
		task_id        = 7,
		title          = bstr("Updated title"),
		description    = bstr("Updated description"),
		status         = .InProgress,
		assignee       = bstr("rene"),
		priority       = 2,
		color          = .Red,
		external_ref   = bstr("NRC-301"),
		due_at         = 1_700_000_300_000_000_000,
		blocked_by     = 5,
		project        = bstr("tooling"),
		correlation_id = 0x01020304,
	}
	n = pr.serializeUpdateTaskRequest(task_update, buf)
	assert(n > 0)
	add_seed(seeds, "update_task_min", buf[:n])

	task_update.attachments = SEED_ATTACHMENTS[:]
	n = pr.serializeUpdateTaskRequest(task_update, buf)
	assert(n > 0)
	add_seed(seeds, "update_task_attachments", buf[:n])

	task_update.preserve_attachments = true
	n = pr.serializeUpdateTaskRequest(task_update, buf)
	assert(n > 0)
	add_seed(seeds, "update_task_preserve", buf[:n])

	asset_create := pr.CreateAssetRequest {
		conv_id          = 42,
		asset_type       = .Note,
		parent_type      = .Task,
		parent_id        = 7,
		payload_encoding = .Plain,
		preview          = bstr("A note preview"),
		payload          = bstr("# Heading\n\nBody text.\n"),
		correlation_id   = 0x0a0b0c0d,
	}
	asset_create.payload_raw_len = u32(len(asset_create.payload))
	n = pr.serializeCreateAssetRequest(asset_create, buf)
	assert(n > 0)
	add_seed(seeds, "create_asset_min", buf[:n])

	asset_create.asset_type = .Document
	asset_create.parent_type = .Asset
	asset_create.parent_id = 3
	asset_create.payload_encoding = .Zstd
	asset_create.payload = bstr("\x28\xb5\x2f\xfd\x00\x58\x25\x00\x00")
	asset_create.payload_raw_len = 4096
	asset_create.attachments = SEED_ATTACHMENTS[:]
	asset_create.if_parent_updated_at = 1_700_000_000_000_000_000
	n = pr.serializeCreateAssetRequest(asset_create, buf)
	assert(n > 0)
	add_seed(seeds, "create_asset_parent_version", buf[:n])

	asset_update := pr.UpdateAssetRequest {
		conv_id          = 42,
		asset_id         = 11,
		payload_encoding = .Plain,
		preview          = bstr("Updated preview"),
		payload          = bstr("updated payload"),
		correlation_id   = 0x11223344,
	}
	asset_update.payload_raw_len = u32(len(asset_update.payload))
	n = pr.serializeUpdateAssetRequest(asset_update, buf)
	assert(n > 0)
	add_seed(seeds, "update_asset_min", buf[:n])

	asset_update.attachments = SEED_ATTACHMENTS[:]
	n = pr.serializeUpdateAssetRequest(asset_update, buf)
	assert(n > 0)
	add_seed(seeds, "update_asset_attachments", buf[:n])
}

build_message_seeds :: proc(seeds: ^[dynamic]Seed, buf: []byte) {
	message := pr.SendMessageV2Request {
		conv_id           = 42,
		client_message_id = {'0', '1', 'H', '8', 'Z', '3', 'W', '0', 'Q', '6', 'A', 'B', 'C', 'D', 'E', 'F'},
		correlation_id    = 0x55667788,
		content_type      = .Markdown,
		content           = bstr("**hello** from the fuzzer"),
	}
	n := pr.serializeSendMessageV2Request(message, buf)
	assert(n > 0)
	add_seed(seeds, "send_message_v2", buf[:n])

	conv_ids := [?]pr.ConversationID{1, 42, 9001}
	subscribe := pr.SubscribeConvsV2Request {
		conv_ids       = conv_ids[:],
		correlation_id = 0x99aabbcc,
	}
	n = pr.serializeSubscribeConvsV2Request(subscribe, buf)
	assert(n > 0)
	add_seed(seeds, "subscribe_convs_v2", buf[:n])

	graph := pr.GraphQueryRequest {
		conv_id        = 42,
		start_type     = pr.TargetType.Task,
		start_id       = 7,
		max_depth      = 3,
		relation_mask  = 0x000f,
		direction      = .Both,
		flags          = 0,
		correlation_id = 0xddeeff00,
	}
	n = pr.serializeGraphQueryRequest(graph, buf)
	assert(n > 0)
	add_seed(seeds, "graph_query", buf[:n])
}

build_transaction_seeds :: proc(seeds: ^[dynamic]Seed, buf: []byte) {
	bodies := make([]byte, 8 * 1024, context.allocator)
	defer delete(bodies, context.allocator)

	task_create := pr.TransactionTaskCreate {
		conv_id = 42,
		status = .Note,
		priority = 4,
		color = .Gold,
		due_at = 1_700_000_200_000_000_000,
		blocked_by = {kind = .Existing, entity_type = .Task, value = 0},
		title = bstr("Fuzzed task"),
		description = bstr("Created by the transaction codec"),
		external_ref = bstr("NRC-300"),
		project = bstr("tooling"),
	}
	create_size := pr.serializeTransactionTaskCreate(task_create, bodies)
	assert(create_size > 0)
	single := [?]pr.TransactionOperation{{op_type = .TaskCreate, body = bodies[:create_size]}}
	n := pr.serializeApplyTransactionRequest(0x12345678, single[:], buf)
	assert(n > 0)
	add_seed(seeds, "transaction_task_create", buf[:n])

	// Each body is serialized into its own slice so the envelope can reference
	// them together.
	body_offsets: [7]int
	body_lengths: [7]int
	offset := 0

	body_offsets[0] = offset
	body_lengths[0] = pr.serializeTransactionTaskCreate(task_create, bodies[offset:])
	offset += body_lengths[0]

	task_patch := pr.TransactionTaskPatch {
		conv_id = 42,
		task = {kind = .Existing, entity_type = .Task, value = 9},
		if_updated_at = 1_700_000_000_000_000_000,
		present = pr.TRANSACTION_TASK_PATCH_TITLE | pr.TRANSACTION_TASK_PATCH_STATUS | pr.TRANSACTION_TASK_PATCH_ASSIGNEE | pr.TRANSACTION_TASK_PATCH_PROJECT,
		status = .InProgress,
		title = bstr("Renamed task"),
		assignee = bstr("rene"),
		project = bstr("fuzzing"),
	}
	body_offsets[1] = offset
	body_lengths[1] = pr.serializeTransactionTaskPatch(task_patch, bodies[offset:])
	offset += body_lengths[1]

	asset_create := pr.TransactionAssetCreate {
		conv_id = 42,
		asset_type = .Note,
		parent_type = .Asset,
		parent = {kind = .Existing, entity_type = .Asset, value = 7},
		payload_encoding = .Zstd,
		payload_raw_len = 512,
		preview = bstr("Compressed note preview"),
		payload = bstr("\x28\xb5\x2f\xfd\x00\x58\x25\x00\x00"),
	}
	body_offsets[2] = offset
	body_lengths[2] = pr.serializeTransactionAssetCreate(asset_create, bodies[offset:])
	offset += body_lengths[2]

	asset_patch := pr.TransactionAssetPatch {
		conv_id = 42,
		asset = {kind = .Existing, entity_type = .Asset, value = 11},
		if_updated_at = 0,
		present = pr.TRANSACTION_ASSET_PATCH_PREVIEW | pr.TRANSACTION_ASSET_PATCH_PAYLOAD,
		payload_encoding = .Plain,
		payload_raw_len = 11,
		preview = bstr("Patched preview"),
		payload = bstr("plain bytes"),
	}
	body_offsets[3] = offset
	body_lengths[3] = pr.serializeTransactionAssetPatch(asset_patch, bodies[offset:])
	offset += body_lengths[3]

	edge_create := pr.TransactionEdgeCreate {
		conv_id = 42,
		source = {kind = .Existing, entity_type = .Task, value = 3},
		target = {kind = .CreatedBy, entity_type = .Asset, value = 0},
		relation = .MemberOf,
	}
	body_offsets[4] = offset
	body_lengths[4] = pr.serializeTransactionEdgeCreate(edge_create, bodies[offset:])
	offset += body_lengths[4]

	task_delete := pr.TransactionDelete {
		conv_id = 42,
		entity = {kind = .Existing, entity_type = .Task, value = 5},
		if_updated_at = 1_700_000_000_000_000_000,
	}
	body_offsets[5] = offset
	body_lengths[5] = pr.serializeTransactionDelete(task_delete, bodies[offset:], .Task)
	offset += body_lengths[5]

	edge_delete := pr.TransactionDelete {
		conv_id = 42,
		entity = {kind = .Existing, entity_type = .Edge, value = 5},
	}
	body_offsets[6] = offset
	body_lengths[6] = pr.serializeTransactionDelete(edge_delete, bodies[offset:], .Edge)
	offset += body_lengths[6]

	op_types := [?]pr.TransactionOperationType{.TaskCreate, .TaskPatch, .AssetCreate, .AssetPatch, .EdgeCreate, .TaskDelete, .EdgeDelete}
	mixed: [7]pr.TransactionOperation
	for op_type, i in op_types {
		assert(body_lengths[i] > 0)
		mixed[i] = {
			op_type = op_type,
			body    = bodies[body_offsets[i]:body_offsets[i] + body_lengths[i]],
		}
	}
	n = pr.serializeApplyTransactionRequest(0x87654321, mixed[:], buf)
	assert(n > 0)
	add_seed(seeds, "transaction_mixed", buf[:n])
}

build_request_seeds :: proc(seeds: ^[dynamic]Seed, buf: []byte) {
	n: int

	// Legacy chat and presence.
	n = pr.serializeSendMessageRequest(42, 7, .PlainText, bstr("hello from the fuzzer"), buf)
	assert(n > 0)
	add_seed(seeds, "send_message_legacy", buf[:n])

	convs := [?]pr.ConversationID{1, 42, 9001}
	n = pr.serializeSubscribeConvsRequest(convs[:], buf)
	assert(n > 0)
	add_seed(seeds, "subscribe_convs", buf[:n])
	n = pr.serializeUnsubscribeConvsRequest(convs[:], buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "unsubscribe_convs", buf[:n])

	n = pr.serializeStatsRequest(1_700_000_000_000_000_000, buf)
	assert(n > 0)
	add_seed(seeds, "stats", buf[:n])
	n = pr.serializePingRequest(1_700_000_000_000_000_000, buf)
	assert(n > 0)
	add_seed(seeds, "ping", buf[:n])

	// Direct messages.
	n = pr.serializeStartDMRequest("rene", 0x01020304, buf)
	assert(n > 0)
	add_seed(seeds, "start_dm", buf[:n])
	n = pr.serializeListDMsRequest(0x01020304, buf)
	assert(n > 0)
	add_seed(seeds, "list_dms", buf[:n])
	n = pr.serializeLeaveDMRequest(42, 0x01020304, buf)
	assert(n > 0)
	add_seed(seeds, "leave_dm", buf[:n])

	// Task requests.
	n = pr.serializeDeleteTaskRequest(42, 7, buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "delete_task", buf[:n])
	move := pr.MoveTaskRequest {
		conv_id        = 42,
		task_id        = 7,
		status         = .InProgress,
		flags          = {},
		order_index    = 2,
		correlation_id = 0x01020304,
	}
	n = pr.serializeMoveTaskRequest(move, buf)
	assert(n > 0)
	add_seed(seeds, "move_task", buf[:n])
	n = pr.serializeGetTasksRequest({conv_id = 42, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "get_tasks", buf[:n])
	n = pr.serializeListTasksPagedRequest({conv_id = 42, status_mask = 0x0f, limit = 25, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "list_tasks_paged", buf[:n])
	n = pr.serializeGetTaskRequest({conv_id = 42, task_id = 7, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "get_task", buf[:n])
	n = pr.serializeTaskQueryRequest(
		{
			conv_id = 42,
			status_mask = 0x0f,
			limit = 25,
			sort = .Priority,
			color = 255,
			has_assignee = true,
			assignee = bstr("rene"),
			has_project = true,
			project = bstr("tooling"),
			correlation_id = 0x01020304,
		},
		buf,
	)
	assert(n > 0)
	add_seed(seeds, "query_tasks", buf[:n])

	// The project register backs six opcodes with one wire format.
	for entry in ([?]struct {
			op:   pr.Opcode,
			name: string,
		}{{.C_ListTaskProjects, "list_task_projects"}, {.C_ListTaskAssignees, "list_task_assignees"}, {.C_ListSliceOwners, "list_slice_owners"}, {.C_ListTicketAssignees, "list_ticket_assignees"}, {.C_ListCalendarPeople, "list_calendar_people"}, {.C_GetWorkspaceOverview, "workspace_overview"}}) {
		n = pr.serializeListTaskProjectsRequest(42, 0x01020304, buf, entry.op)
		assert(n > 0)
		add_seed(seeds, entry.name, buf[:n])
	}

	n = pr.serializeListTaskSlicesRequest(
		{conv_id = 42, has_owner = true, owner = bstr("rene"), has_name = true, name = bstr("tooling"), limit = 25, correlation_id = 0x01020304},
		buf,
	)
	assert(n > 0)
	add_seed(seeds, "list_task_slices", buf[:n])

	calendar_start := i64(1_700_000_000_000_000_000)
	n = pr.serializeCalendarRequest(
		{
			conv_id = 42,
			start = calendar_start,
			end = calendar_start + 86_400_000_000_000,
			limit = 50,
			assignee = bstr("rene"),
			project = bstr("tooling"),
			correlation_id = 0x01020304,
		},
		buf,
	)
	assert(n > 0)
	add_seed(seeds, "query_calendar", buf[:n])

	// Batch reads share one format; the opcode selects the entity type.
	ids := [?]u64{7, 9}
	for entry in ([?]struct {
			op:   pr.Opcode,
			name: string,
		}{{.C_GetTasksByIDs, "get_tasks_by_ids"}, {.C_GetAssetsByIDs, "get_assets_by_ids"}}) {
		n = pr.serializeGetRecordsByIDsRequest({conv_id = 42, correlation_id = 0x01020304, full_content = true, ids = ids[:]}, buf, entry.op)
		assert(n > 0)
		add_seed(seeds, entry.name, buf[:n])
	}

	n = pr.serializeListTaskDependentsRequest({conv_id = 42, task_id = 7, limit = 25, after_task_id = 0, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "list_task_dependents", buf[:n])

	// Assets.
	n = pr.serializeDeleteAssetRequest(42, 11, buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "delete_asset", buf[:n])
	n = pr.serializeGetAssetRequest(42, 11, buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "get_asset", buf[:n])
	n = pr.serializeListAssetsRequest(42, true, .Note, false, buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "list_assets", buf[:n])
	n = pr.serializeListAssetsPagedRequest(42, .Note, false, 25, false, 0, 0, buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "list_assets_paged", buf[:n])
	n = pr.serializeListAssetsPagedByProjectRequest(42, .Note, false, 25, false, 0, 0, "tooling", buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "list_assets_by_project", buf[:n])
	n = pr.serializeListNoteProjectsRequest(42, buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "list_note_projects", buf[:n])
	n = pr.serializeListAssetsPagedByTagRequest(42, .Note, false, 25, false, 0, 0, "fuzzing", buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "list_assets_by_tag", buf[:n])
	n = pr.serializeListNoteTagsRequest(42, buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "list_note_tags", buf[:n])

	// Edges.
	n = pr.serializeCreateEdgeRequest(
		{conv_id = 42, source_type = .Task, source_id = 7, target_type = .Asset, target_id = 11, relation = .MemberOf, correlation_id = 0x01020304},
		buf,
	)
	assert(n > 0)
	add_seed(seeds, "create_edge", buf[:n])
	n = pr.serializeDeleteEdgeRequest(42, 3, buf, 0x01020304)
	assert(n > 0)
	add_seed(seeds, "delete_edge", buf[:n])
	n = pr.serializeListEdgesRequest({conv_id = 42, target_type = .Task, target_id = 7, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "list_edges", buf[:n])
	n = pr.serializeListAllEdgesRequest({conv_id = 42, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "list_all_edges", buf[:n])
	n = pr.serializeListAllEdgesPagedRequest({conv_id = 42, limit = 25, after_edge_id = 0, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "list_all_edges_paged", buf[:n])
	n = pr.serializeListEdgesPagedRequest({conv_id = 42, target_type = .Task, target_id = 7, limit = 25, after_edge_id = 0, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "list_edges_paged", buf[:n])
	n = pr.serializeSearchCustomersRequest({conv_id = 42, limit = 25, after_company_id = 0, query = bstr("acme"), correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "search_customers", buf[:n])

	// Graph.
	n = pr.serializeGraphShortestPathRequest(
		{
			conv_id = 42,
			from_type = .Task,
			from_id = 7,
			to_type = .Asset,
			to_id = 11,
			relation_mask = 0x000f,
			direction = .Both,
			max_depth = 3,
			flags = 0,
			correlation_id = 0x01020304,
		},
		buf,
	)
	assert(n > 0)
	add_seed(seeds, "graph_shortest_path", buf[:n])
	n = pr.serializeGraphDegreeRequest({conv_id = 42, top_n = 10, type_filter = 0, relation_mask = 0x000f, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "graph_degree", buf[:n])
	n = pr.serializeGraphCommonNeighborsRequest(
		{conv_id = 42, a_type = .Task, a_id = 7, b_type = .Task, b_id = 9, relation_mask = 0x000f, direction = .Both, correlation_id = 0x01020304},
		buf,
	)
	assert(n > 0)
	add_seed(seeds, "graph_common_neighbors", buf[:n])

	rank := pr.GraphRankRequest {
		conv_id         = 42,
		anchor_count    = 1,
		candidate_count = 1,
		max_depth       = 3,
		relation_mask   = 0x000f,
		direction       = .Both,
		top_n           = 10,
		correlation_id  = 0x01020304,
	}
	rank.anchors[0] = {
		target_type = .Task,
		target_id   = 7,
	}
	rank.candidates[0] = {
		target_type = .Asset,
		target_id   = 11,
	}
	n = pr.serializeGraphRankRequest(rank, buf)
	assert(n > 0)
	add_seed(seeds, "graph_rank", buf[:n])

	// Retained message ranges.
	range := pr.MessageRangeRequest {
		conv_id        = 42,
		cursor         = 100,
		limit          = 25,
		correlation_id = 0x01020304,
	}
	n = pr.serializeMessageRangeRequest(.C_ListMessagesBefore, range, buf)
	assert(n > 0)
	add_seed(seeds, "list_messages_before", buf[:n])
	n = pr.serializeMessageRangeRequest(.C_ReplayMessagesAfter, range, buf)
	assert(n > 0)
	add_seed(seeds, "replay_messages_after", buf[:n])

	// History: workspace-data scope, entity filter, page limit.
	n = pr.serializeListHistoryRequest({conv_id = pr.WORKSPACE_DATA_ID, kind = 1, entity = 7, before = 100, limit = 25, correlation_id = 0x01020304}, buf)
	assert(n > 0)
	add_seed(seeds, "list_history", buf[:n])

	// Tickets: the body is the raw query payload behind a correlation id.
	n = pr.serializeTicketQueryRequest(0x01020304, bstr(`{"ticket":1}`), buf)
	assert(n > 0)
	add_seed(seeds, "query_tickets", buf[:n])
}

build_seeds :: proc() -> []Seed {
	seeds: [dynamic]Seed
	buf := make([]byte, MAX_SEED_BYTES, context.allocator)
	defer delete(buf, context.allocator)

	build_task_and_asset_seeds(&seeds, buf)
	build_message_seeds(&seeds, buf)
	build_transaction_seeds(&seeds, buf)
	build_request_seeds(&seeds, buf)

	return seeds[:]
}

// write_seeds regenerates the committed corpus. Every seed must parse without
// error, so a protocol change that invalidates the corpus fails here.
write_seeds :: proc(dir: string) -> bool {
	// An already existing directory is fine; only writing a seed can fail.
	os.make_directory(dir)
	seeds := build_seeds()
	defer {
		for seed in seeds do delete(seed.bytes, context.allocator)
		delete(seeds, context.allocator)
	}
	ok := true
	for seed in seeds {
		if err := exercise(seed.bytes); err != nil {
			fmt.eprintf("seed %q does not parse: %v\n", seed.name, err)
			ok = false
			continue
		}
		path := fmt.aprintf("%s/%s.bin", dir, seed.name)
		if err := os.write_entire_file_from_bytes(path, seed.bytes); err != nil {
			fmt.eprintln("write", path, os.error_string(err))
			ok = false
		}
		delete(path)
	}
	if ok do fmt.printf("wrote %d seeds to %s\n", len(seeds), dir)
	return ok
}

// seed_dir_from_args reports whether the caller asked to regenerate the corpus
// instead of fuzzing.
seed_dir_from_args :: proc(args: []string) -> (string, bool) {
	for arg in args {
		if strings.has_prefix(arg, SEED_DIR_FLAG) {
			return arg[len(SEED_DIR_FLAG):], true
		}
	}
	return "", false
}
