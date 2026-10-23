package protocol_fuzz

import pr "../../protocol"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"

// Wire input includes the real two-byte opcode. The target covers every
// client-to-server opcode in Opcode plus every server-to-client response that
// has an Odin parser; each one is parsed through the same function its caller
// dispatches to.
// All returned byte fields must borrow from the input, never fabricated memory.
check_bytes :: proc(input, field: []byte) {
	if len(field) == 0 do return
	start := uintptr(raw_data(input))
	ptr := uintptr(raw_data(field))
	assert(ptr >= start && ptr - start <= uintptr(len(input)))
	assert(uintptr(len(field)) <= uintptr(len(input)) - (ptr - start))
}

check_string :: proc(input: []byte, field: string) {
	check_bytes(input, transmute([]byte)field)
}

check_attachments :: proc(input: []byte, attachments: []pr.Attachment) {
	assert(len(attachments) <= pr.MAX_ATTACHMENTS_PER_TASK)
	for a in attachments {
		check_bytes(input, a.file_id)
		check_bytes(input, a.filename)
		check_bytes(input, a.mime_type)
	}
}

exercise :: proc(input: []byte) -> pr.ProtocolParseError {
	if len(input) < 2 do return .TooShort
	data := input[2:]
	attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
	#partial switch pr.get_opcode(input) {
	// Retained chat and message history.
	case .C_SendMessageV2:
		r, err := pr.parseSendMessageV2Request(data)
		if err != nil do return err
		check_bytes(input, r.content)
	case .C_SubscribeConvsV2:
		r, err := pr.parseSubscribeConvsV2Request(data)
		if err != nil do return err
		assert(len(r.conv_ids) <= pr.MAX_SUBSCRIBE_CONVS)
	case .C_ListMessagesBefore, .C_ReplayMessagesAfter:
		_, err := pr.parseMessageRangeRequest(data)
		return err

	// Legacy chat, presence and direct messages.
	case .C_SendMessage:
		r, err := pr.parseSendMessageRequest(data)
		if err != nil do return err
		check_bytes(input, r.content)
	case .C_SubscribeConvs:
		r, err := pr.parseSubscribeConvsRequest(data)
		if err != nil do return err
		assert(len(r.conv_ids) <= pr.MAX_SUBSCRIBE_CONVS)
	case .C_UnsubscribeConvs:
		r, err := pr.parseUnsubscribeConvsRequest(data)
		if err != nil do return err
		assert(len(r.conv_ids) <= pr.MAX_SUBSCRIBE_CONVS)
	case .C_Stats:
		_, err := pr.parseStatsRequest(data)
		return err
	case .C_Ping:
		_, err := pr.parsePingRequest(data)
		return err
	case .C_StartDM:
		r, err := pr.parseStartDMRequest(data)
		if err != nil do return err
		check_string(input, r.username)
	case .C_ListDMs:
		_, err := pr.parseListDMsRequest(data)
		return err
	case .C_LeaveDM:
		_, err := pr.parseLeaveDMRequest(data)
		return err

	// Tasks.
	case .C_CreateTask:
		r, err := pr.parseCreateTaskRequest(data, attachments[:])
		if err != nil do return err
		check_bytes(input, r.title)
		check_bytes(input, r.description)
		check_bytes(input, r.external_ref)
		check_bytes(input, r.project)
		check_attachments(input, r.attachments)
	case .C_UpdateTask:
		r, err := pr.parseUpdateTaskRequest(data, attachments[:])
		if err != nil do return err
		check_bytes(input, r.title)
		check_bytes(input, r.description)
		check_bytes(input, r.assignee)
		check_bytes(input, r.external_ref)
		check_bytes(input, r.project)
		check_attachments(input, r.attachments)
	case .C_DeleteTask:
		_, err := pr.parseDeleteTaskRequest(data)
		return err
	case .C_MoveTask:
		_, err := pr.parseMoveTaskRequest(data)
		return err
	case .C_GetTasks:
		_, err := pr.parseGetTasksRequest(data)
		return err
	case .C_ListTasksPaged:
		_, err := pr.parseListTasksPagedRequest(data)
		return err
	case .C_GetTask:
		_, err := pr.parseGetTaskRequest(data)
		return err
	case .C_QueryTasks:
		r, err := pr.parseTaskQueryRequest(data)
		if err != nil do return err
		check_bytes(input, r.assignee)
		check_bytes(input, r.project)
		check_bytes(input, r.cursor_text)
	case .C_ListTaskProjects, .C_ListTaskAssignees, .C_ListSliceOwners, .C_ListTicketAssignees, .C_ListCalendarPeople, .C_GetWorkspaceOverview:
		// The server parses all of these with the project-register request.
		_, err := pr.parseListTaskProjectsRequest(data)
		return err
	case .C_ListTaskSlices:
		r, err := pr.parseListTaskSlicesRequest(data)
		if err != nil do return err
		check_bytes(input, r.owner)
		check_bytes(input, r.name)
	case .C_QueryCalendar:
		r, err := pr.parseCalendarRequest(data)
		if err != nil do return err
		check_bytes(input, r.assignee)
		check_bytes(input, r.project)
	case .C_GetTasksByIDs, .C_GetAssetsByIDs:
		ids: [pr.MAX_ID_BATCH_SIZE]u64
		r, err := pr.parseGetRecordsByIDsRequest(data, ids[:])
		if err != nil do return err
		assert(len(r.ids) <= pr.MAX_ID_BATCH_SIZE)
	case .C_ListTaskDependents:
		_, err := pr.parseListTaskDependentsRequest(data)
		return err
	case .C_ApplyTransaction:
		operations: [pr.MAX_TRANSACTION_OPERATIONS]pr.TransactionOperation
		r, err := pr.parseApplyTransactionRequest(data, operations[:])
		if err != nil do return err
		for op in r.operations {
			check_bytes(input, op.body)
			// The envelope parser only validates framing. Exercise the body codecs
			// too, as the transaction validator does before applying operations,
			// and hold their borrowed fields to the same input-lifetime contract.
			switch op.op_type {
			case .TaskCreate:
				body, body_err := pr.parseTransactionTaskCreate(op.body)
				err = body_err
				if err == nil {
					check_bytes(input, body.title)
					check_bytes(input, body.description)
					check_bytes(input, body.external_ref)
					check_bytes(input, body.project)
				}
			case .TaskPatch:
				body, body_err := pr.parseTransactionTaskPatch(op.body)
				err = body_err
				if err == nil {
					check_bytes(input, body.title)
					check_bytes(input, body.description)
					check_bytes(input, body.assignee)
					check_bytes(input, body.external_ref)
					check_bytes(input, body.project)
				}
			case .AssetCreate:
				body, body_err := pr.parseTransactionAssetCreate(op.body)
				err = body_err
				if err == nil {
					check_bytes(input, body.preview)
					check_bytes(input, body.payload)
				}
			case .AssetPatch:
				body, body_err := pr.parseTransactionAssetPatch(op.body)
				err = body_err
				if err == nil {
					check_bytes(input, body.preview)
					check_bytes(input, body.payload)
				}
			case .EdgeCreate:
				_, err = pr.parseTransactionEdgeCreate(op.body)
			case .TaskDelete:
				_, err = pr.parseTransactionDelete(op.body, .Task)
			case .AssetDelete:
				_, err = pr.parseTransactionDelete(op.body, .Asset)
			case .EdgeDelete:
				_, err = pr.parseTransactionDelete(op.body, .Edge)
			}
			if err != nil do return err
		}

	// Assets.
	case .C_CreateAsset:
		r, err := pr.parseCreateAssetRequest(data, attachments[:])
		if err != nil do return err
		check_bytes(input, r.preview)
		check_bytes(input, r.payload)
		check_attachments(input, r.attachments)
	case .C_UpdateAsset:
		r, err := pr.parseUpdateAssetRequest(data, attachments[:])
		if err != nil do return err
		check_bytes(input, r.preview)
		check_bytes(input, r.payload)
		check_attachments(input, r.attachments)
	case .C_DeleteAsset:
		_, err := pr.parseDeleteAssetRequest(data)
		return err
	case .C_GetAsset:
		_, err := pr.parseGetAssetRequest(data)
		return err
	case .C_ListAssets:
		_, err := pr.parseListAssetsRequest(data)
		return err
	case .C_ListAssetsPaged:
		_, err := pr.parseListAssetsPagedRequest(data)
		return err
	case .C_ListAssetsPagedByProject:
		r, err := pr.parseListAssetsPagedByProjectRequest(data)
		if err != nil do return err
		check_string(input, r.project)
	case .C_ListAssetsPagedByTag:
		r, err := pr.parseListAssetsPagedByTagRequest(data)
		if err != nil do return err
		check_string(input, r.tag)
	case .C_ListNoteProjects:
		_, err := pr.parseListNoteProjectsRequest(data)
		return err
	case .C_ListNoteTags:
		_, err := pr.parseListNoteTagsRequest(data)
		return err

	// Edges and customers.
	case .C_CreateEdge:
		_, err := pr.parseCreateEdgeRequest(data)
		return err
	case .C_DeleteEdge:
		_, err := pr.parseDeleteEdgeRequest(data)
		return err
	case .C_ListEdges:
		_, err := pr.parseListEdgesRequest(data)
		return err
	case .C_ListAllEdges:
		_, err := pr.parseListAllEdgesRequest(data)
		return err
	case .C_ListAllEdgesPaged:
		_, err := pr.parseListAllEdgesPagedRequest(data)
		return err
	case .C_ListEdgesPaged:
		_, err := pr.parseListEdgesPagedRequest(data)
		return err
	case .C_SearchCustomers:
		r, err := pr.parseSearchCustomersRequest(data)
		if err != nil do return err
		check_bytes(input, r.query)

	// Graph.
	case .C_GraphQuery:
		_, err := pr.parseGraphQueryRequest(data)
		return err
	case .C_GraphShortestPath:
		_, err := pr.parseGraphShortestPathRequest(data)
		return err
	case .C_GraphDegree:
		_, err := pr.parseGraphDegreeRequest(data)
		return err
	case .C_GraphCommonNeighbors:
		_, err := pr.parseGraphCommonNeighborsRequest(data)
		return err
	case .C_GraphRank:
		_, err := pr.parseGraphRankRequest(data)
		return err

	// History. The request carries the workspace-data scope, an entity filter and
	// a page limit; there are no borrowed byte fields to check.
	case .C_ListHistory:
		_, err := pr.parseListHistoryRequest(data)
		return err

	// Tickets.
	case .C_QueryTickets:
		r, err := pr.parseTicketQueryRequest(data)
		if err != nil do return err
		check_bytes(input, r.query)

	case:
		return .InvalidOpcode
	}
	return nil
}

check_task :: proc(input: []byte, task: pr.Task) {
	check_bytes(input, task.title)
	check_bytes(input, task.description)
	check_bytes(input, task.assignee)
	check_bytes(input, task.created_by)
	check_bytes(input, task.completed_by)
	check_bytes(input, task.project)
	check_bytes(input, task.external_ref)
	check_attachments(input, task.attachments)
}

check_asset :: proc(input: []byte, asset: pr.Asset) {
	check_bytes(input, asset.owner)
	check_bytes(input, asset.preview)
	check_bytes(input, asset.payload)
	check_attachments(input, asset.attachments)
}

check_edge :: proc(input: []byte, edge: pr.Edge) {
	check_bytes(input, edge.created_by)
}

// Response parsers take the full message including its opcode, except the two
// retained-chat parsers whose callers pass the payload behind the opcode.
// Records are parsed into caller-provided slices, so the fixed capacities bound
// how many records one input can reach; a larger count is a normal .TooMany.
RESPONSE_RECORD_CAPACITY :: 64

exercise_response :: proc(input: []byte) -> pr.ProtocolParseError {
	if len(input) < 2 do return .TooShort
	payload := input[2:]

	// The allocating parsers own their result for the duration of this call.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return .InvalidValue
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
	tasks: [RESPONSE_RECORD_CAPACITY]pr.Task
	edges: [RESPONSE_RECORD_CAPACITY]pr.Edge
	dm_entries: [RESPONSE_RECORD_CAPACITY]pr.DMEntry
	nodes: [RESPONSE_RECORD_CAPACITY]pr.GraphQueryNode
	path_nodes: [RESPONSE_RECORD_CAPACITY]pr.GraphPathNode
	degree_entries: [RESPONSE_RECORD_CAPACITY]pr.GraphDegreeEntry

	#partial switch pr.get_opcode(input) {
	// Handshake, chat and presence.
	case .S_ServerReady:
		r, err := pr.parseServerReadyMessage(input)
		if err != nil do return err
		check_bytes(input, r.build_version)
		check_bytes(input, r.cpu_model)
		check_bytes(input, r.username)
	case .S_NewMessage:
		r, err := pr.parseNewMessageEventMessage(input)
		if err != nil do return err
		check_bytes(input, r.author_username)
		check_bytes(input, r.content)
	case .S_AckSendMessage:
		_, err := pr.parseAckSendMessageMessage(input)
		return err
	case .S_ErrorResponse:
		r, err := pr.parseErrorResponseMessage(input)
		if err != nil do return err
		check_bytes(input, r.error_msg)
	case .S_RoomPresenceUpdate:
		r, err := pr.parseRoomPresenceUpdateMessage(input, allocator)
		if err != nil do return err
		check_bytes(input, r.username)
		check_bytes(input, r.old_username)
		for user in r.user_list do check_bytes(input, user)
	case .S_StatsResponse:
		_, err := pr.parseStatsResponseMessage(input)
		return err
	case .S_AuthResponse:
		r, err := pr.parseAuthenticateResponseMessage(input)
		if err != nil do return err
		check_bytes(input, r.user_id)
		check_bytes(input, r.nickname)
		check_bytes(input, r.error_msg)

	// Direct messages.
	case .S_DMStarted:
		r, err := pr.parseDMStartedMessage(input)
		if err != nil do return err
		check_string(input, r.username)
	case .S_DMList:
		r, err := pr.parseDMListMessage(input, dm_entries[:])
		if err != nil do return err
		for entry in r.entries do check_string(input, entry.username)
	case .S_DMError:
		r, err := pr.parseDMErrorMessage(input)
		if err != nil do return err
		check_string(input, r.target_username)
		check_string(input, r.message)
	case .S_DMLeft:
		_, err := pr.parseDMLeftMessage(input)
		return err
	case .S_DMPartnerStatus:
		r, err := pr.parseDMPartnerStatusMessage(input)
		if err != nil do return err
		check_string(input, r.username)
	case .S_Pong:
		_, err := pr.parsePongResponseMessage(input)
		return err
	case .S_AckUnsubscribeConvs:
		_, err := pr.parseAckUnsubscribeConvsMessage(input)
		return err

	// Retained chat.
	case .S_SubscriptionReady:
		r, err := pr.parseSubscriptionReady(payload)
		if err != nil do return err
		assert(len(r.entries) <= pr.MAX_SUBSCRIBE_CONVS)
	case .S_MessagePage:
		r, err := pr.parseMessagePage(payload)
		if err != nil do return err
		for message in r.messages {
			check_bytes(input, message.author_username)
			check_bytes(input, message.content)
		}

	// Tasks.
	case .S_TaskCreated:
		r, err := pr.parseTaskCreated(input, attachments[:])
		if err != nil do return err
		check_task(input, r.task)
	case .S_TaskUpdated:
		r, err := pr.parseTaskUpdated(input, attachments[:])
		if err != nil do return err
		check_task(input, r.task)
	case .S_TaskDeleted:
		_, err := pr.parseTaskDeleted(input)
		return err
	case .S_TaskMoved:
		r, err := pr.parseTaskMoved(input)
		if err != nil do return err
		check_bytes(input, r.completed_by)
	case .S_TaskListResponse:
		r, err := pr.parseTaskListResponse(input, tasks[:], attachments[:])
		if err != nil do return err
		for task in r.tasks do check_task(input, task)
		check_bytes(input, r.error)
	case .S_TaskListPage:
		r, err := pr.parseTaskListPage(input, tasks[:], attachments[:])
		if err != nil do return err
		for task in r.tasks do check_task(input, task)
		check_bytes(input, r.error)
	case .S_TaskFull:
		r, err := pr.parseTaskFull(input, attachments[:])
		if err != nil do return err
		if r.has_task do check_task(input, r.task)
		check_bytes(input, r.error)
	case .S_TaskSliceList:
		r, err := pr.parseTaskSliceList(input, allocator)
		if err != nil do return err
		for slice in r.slices {
			check_bytes(input, slice.name)
			check_bytes(input, slice.owner)
		}
		check_bytes(input, r.error)

	// Assets.
	case .S_AssetCreated:
		r, err := pr.parseAssetCreatedMessage(input, attachments[:])
		if err != nil do return err
		check_asset(input, r.asset)
	case .S_AssetUpdated:
		r, err := pr.parseAssetUpdatedMessage(input, attachments[:])
		if err != nil do return err
		check_asset(input, r.asset)
	case .S_AssetDeleted:
		_, err := pr.parseAssetDeletedMessage(input)
		return err
	case .S_AssetFull:
		r, err := pr.parseAssetFullMessage(input, attachments[:])
		if err != nil do return err
		check_asset(input, r.asset)
	case .S_AssetList:
		r, err := pr.parseAssetListMessage(input, allocator, attachments[:])
		if err != nil do return err
		for asset in r.assets do check_asset(input, asset)
	case .S_AssetListPage:
		r, err := pr.parseAssetListPageMessage(input, allocator, attachments[:])
		if err != nil do return err
		for asset in r.assets do check_asset(input, asset)
	case .S_NoteProjectList:
		r, err := pr.parseNoteProjectListMessage(input, allocator)
		if err != nil do return err
		for project in r.projects do check_string(input, project)
	case .S_NoteTagList:
		r, err := pr.parseNoteTagListMessage(input, allocator)
		if err != nil do return err
		for tag in r.tags do check_string(input, tag)

	// Edges.
	case .S_EdgeCreated:
		r, err := pr.parseEdgeCreatedMessage(input)
		if err != nil do return err
		check_edge(input, r.edge)
	case .S_EdgeDeleted:
		_, err := pr.parseEdgeDeletedMessage(input)
		return err
	case .S_EdgeList:
		r, err := pr.parseEdgeListMessage(input, edges[:])
		if err != nil do return err
		for edge in r.edges do check_edge(input, edge)
	case .S_AllEdgeList:
		r, err := pr.parseAllEdgeListMessage(input, edges[:])
		if err != nil do return err
		for edge in r.edges do check_edge(input, edge)
	case .S_AllEdgeListPage:
		r, err := pr.parseAllEdgeListPageMessage(input, edges[:])
		if err != nil do return err
		for edge in r.edges do check_edge(input, edge)

	// Graph queries.
	case .S_GraphQueryResult:
		r, err := pr.parseGraphQueryResult(input, nodes[:], edges[:])
		if err != nil do return err
		for edge in r.edges do check_edge(input, edge)
	case .S_GraphShortestPathResult:
		r, err := pr.parseGraphShortestPathResult(input, path_nodes[:], edges[:])
		if err != nil do return err
		for edge in r.edges do check_edge(input, edge)
	case .S_GraphDegreeResult:
		_, err := pr.parseGraphDegreeResult(input, degree_entries[:])
		return err
	case .S_GraphCommonNeighborsResult:
		r, err := pr.parseGraphCommonNeighborsResult(input, path_nodes[:], edges[:])
		if err != nil do return err
		for edge in r.edges do check_edge(input, edge)

	// Responses without an Odin parser: S_TransactionResult, S_TaskQueryPage,
	// S_TaskProjects, S_TaskAssignees, S_CalendarPage, S_WorkspaceOverview,
	// S_HistoryPage, S_TaskDependentsPage, S_SliceOwners, S_TicketAssignees,
	// S_CalendarPeople, S_EdgeListPage, S_CustomerSearchPage, S_TicketPage and
	// S_GraphRankResult are decoded by the Go CLI and the JS client.
	case:
		return .InvalidOpcode
	}
	return nil
}

// A seed or fuzz input is either a client request or a server response; the
// opcode decides which direction's parser runs.
exercise_message :: proc(input: []byte) -> pr.ProtocolParseError {
	if len(input) < 2 do return .TooShort
	if u16(pr.get_opcode(input)) >= 100 do return exercise_response(input)
	return exercise(input)
}

// Keep the parse result observable even in optimized builds.
@(export)
last_error: pr.ProtocolParseError

// libFuzzer supplies the loop but not the entry point: Odin's generated `main`
// owns `__$startup_runtime`, which installs the thread-local context that every
// Odin call needs. `main` therefore hands control to libFuzzer's driver, which
// test/run_protocol_fuzz.sh links from libclang_rt.fuzzer_no_main.
@(export)
LLVMFuzzerTestOneInput :: proc "c" (data: [^]u8, size: uint) -> i32 {
	context = runtime.default_context()
	context.logger = log.nil_logger()
	context.allocator = mem.nil_allocator()
	context.temp_allocator = mem.nil_allocator()
	if size > 128 * 1024 do return 0
	last_error = exercise_message(data[:int(size)])
	return 0
}

// Without the define this package still builds as an ordinary Odin program, so
// `odin check` and the seed generator work without the LLVM fuzzing runtime.
LIBFUZZER_DRIVER :: #config(NRC_LIBFUZZER, false)

when LIBFUZZER_DRIVER {
	foreign _ {
		LLVMFuzzerRunDriver :: proc "c" (argc: ^i32, argv: ^[^]cstring, callback: proc "c" (data: [^]u8, size: uint) -> i32) -> i32 ---
	}
}

main :: proc() {
	if dir, requested := seed_dir_from_args(os.args); requested {
		if !write_seeds(dir) do os.exit(1)
		return
	}
	argv := make([]cstring, len(os.args), context.allocator)
	for arg, i in os.args {
		argv[i] = strings.clone_to_cstring(arg, context.allocator)
	}
	argc := i32(len(argv))
	when LIBFUZZER_DRIVER {
		argv_ptr := raw_data(argv)
		os.exit(int(LLVMFuzzerRunDriver(&argc, &argv_ptr, LLVMFuzzerTestOneInput)))
	} else {
		fmt.eprintf("no fuzzing driver for %d arguments; run ./test/run_protocol_fuzz.sh\n", argc)
		os.exit(1)
	}
}
