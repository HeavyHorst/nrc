package protocol_fuzz

import pr "../../protocol"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"

// Wire input includes the real two-byte opcode. The target covers every
// client-to-server opcode in Opcode; each one is parsed through the same
// function the server dispatches to.
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
	last_error = exercise(data[:int(size)])
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
