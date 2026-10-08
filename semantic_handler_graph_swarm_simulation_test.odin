package main

import "core:fmt"
import "core:testing"

import "btree"
import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: fmt.eprintf
	_ :: testing.T
	_ :: btree.count
	_ :: hgl.run
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	SEMANTIC_HANDLER_SWARM_MAX_OPS :: 6
	SEMANTIC_HANDLER_SWARM_MAX_TASKS :: 5
	SEMANTIC_HANDLER_SWARM_MAX_ASSETS :: 4
	SEMANTIC_HANDLER_SWARM_MAX_EDGES :: 9

	Semantic_Handler_Swarm_Kind :: enum u8 {
		Update_Task,
		Delete_Edge,
		Delete_Asset,
		Delete_Task,
		Create_Task,
		Create_Edge,
		Create_Asset,
		Move_Task,
		Update_Asset,
	}

	Semantic_Handler_Swarm_Op :: struct {
		kind:           Semantic_Handler_Swarm_Kind,
		kind_ticket:    int,
		selector:       u8,
		query_selector: u16,
		split_a:        u8,
		split_b:        u8,
	}

	// Rows are requested kinds, columns are successfully executed kinds.
	// Excludes foundation writes, rejected probes and post-recovery continuation.
	Semantic_Handler_Swarm_Counts :: [len(Semantic_Handler_Swarm_Kind)][len(Semantic_Handler_Swarm_Kind)]int

	Semantic_Handler_Swarm_Edge :: struct {
		live:        bool,
		source_type: pr.TargetType,
		source_id:   u64,
		target_type: pr.TargetType,
		target_id:   u64,
		relation:    pr.RelationType,
		created_at:  i64,
	}

	Semantic_Handler_Swarm_Asset :: struct {
		live:           bool,
		update_variant: u8,
		asset_type:     pr.AssetType,
		note_project:   u8,
		note_tags:      u8,
		parent_type:    pr.ParentType,
		parent_id:      u64,
		created_at:     i64,
		updated_at:     i64,
	}

	Semantic_Handler_Swarm_Model :: struct {
		task_live:            [SEMANTIC_HANDLER_SWARM_MAX_TASKS]bool,
		task_created_at:      [SEMANTIC_HANDLER_SWARM_MAX_TASKS]i64,
		task_updated_at:      [SEMANTIC_HANDLER_SWARM_MAX_TASKS]i64,
		task_completed_at:    [SEMANTIC_HANDLER_SWARM_MAX_TASKS]i64,
		task_content_updated: [SEMANTIC_HANDLER_SWARM_MAX_TASKS]bool,
		task_status:          [SEMANTIC_HANDLER_SWARM_MAX_TASKS]pr.TaskStatus,
		task_order:           [SEMANTIC_HANDLER_SWARM_MAX_TASKS]u16,
		task_high:            u64,
		assets:               [SEMANTIC_HANDLER_SWARM_MAX_ASSETS]Semantic_Handler_Swarm_Asset,
		asset_high:           u64,
		edges:                [SEMANTIC_HANDLER_SWARM_MAX_EDGES]Semantic_Handler_Swarm_Edge,
		edge_high:            u64,
	}

	Semantic_Handler_Swarm_Neighborhood :: struct {
		visited:      [3][SEMANTIC_HANDLER_SWARM_MAX_TASKS]bool,
		depths:       [3][SEMANTIC_HANDLER_SWARM_MAX_TASKS]u8,
		edge_present: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]bool,
		node_count:   int,
		edge_count:   int,
	}

	Semantic_Handler_Swarm_Common_Neighbors :: struct {
		common:       [3][SEMANTIC_HANDLER_SWARM_MAX_TASKS]bool,
		edge_present: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]bool,
		node_count:   int,
		edge_count:   int,
	}

	Semantic_Handler_Swarm_Task_Page :: struct {
		ids:                 [SEMANTIC_HANDLER_SWARM_MAX_TASKS]pr.TaskID,
		count:               int,
		total_count:         u32,
		has_more:            bool,
		next_cursor_sort_at: i64,
		next_cursor_task_id: pr.TaskID,
	}

	Semantic_Handler_Swarm_Note_Page_Scope :: enum u8 {
		Global,
		Project,
		Tag,
	}

	Semantic_Handler_Swarm_Note_Page_Request :: struct {
		scope:             Semantic_Handler_Swarm_Note_Page_Scope,
		filter:            string,
		limit:             u16,
		has_cursor:        bool,
		cursor_updated_at: i64,
		cursor_asset_id:   pr.AssetID,
		correlation_id:    u32,
	}

	Semantic_Handler_Swarm_Note_Page :: struct {
		ids:                    [SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.AssetID,
		count:                  int,
		total_count:            u32,
		has_more:               bool,
		next_cursor_updated_at: i64,
		next_cursor_asset_id:   pr.AssetID,
	}

	Semantic_Handler_Swarm_Output_Recipient :: enum u8 {
		Requester,
		Peer,
	}

	Semantic_Handler_Swarm_Output :: struct {
		recipient: Semantic_Handler_Swarm_Output_Recipient,
		group:     int,
		payload:   []byte,
	}

	Semantic_Handler_Swarm_Output_Ledger :: struct {
		entries: [dynamic]Semantic_Handler_Swarm_Output,
	}

	semantic_handler_swarm_initial_model :: proc() -> Semantic_Handler_Swarm_Model {
		model := Semantic_Handler_Swarm_Model {
			task_live       = {false, true, true, false, false},
			task_created_at = {0, NRC_SIM_TIME_EPOCH_NANOS, NRC_SIM_TIME_EPOCH_NANOS, 0, 0},
			task_status     = {.Backlog, .Todo, .Todo, .Backlog, .Backlog},
			task_order      = {0, 0, 1, 0, 0},
			task_high       = 2,
			asset_high      = 1,
			edge_high       = 2,
		}
		model.assets[1] = {
			live        = true,
			asset_type  = .Document,
			parent_type = .Task,
			parent_id   = 1,
			created_at  = NRC_SIM_TIME_EPOCH_NANOS,
			updated_at  = NRC_SIM_TIME_EPOCH_NANOS,
		}
		model.edges[1] = {
			live        = true,
			source_type = .Task,
			source_id   = 1,
			target_type = .Asset,
			target_id   = 1,
			relation    = .References,
			created_at  = NRC_SIM_TIME_EPOCH_NANOS,
		}
		model.edges[2] = {
			live        = true,
			source_type = .Asset,
			source_id   = 1,
			target_type = .Task,
			target_id   = 2,
			relation    = .References,
			created_at  = NRC_SIM_TIME_EPOCH_NANOS,
		}
		return model
	}

	semantic_handler_swarm_live_task_count :: proc(model: ^Semantic_Handler_Swarm_Model) -> int {
		count := 0
		for live in model.task_live do if live do count += 1
		return count
	}

	semantic_handler_swarm_select_task :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u8) -> pr.TaskID {
		count := semantic_handler_swarm_live_task_count(model)
		if count == 0 do return 0
		wanted := int(selector) % count
		for id in 1 ..< len(model.task_live) {
			if !model.task_live[id] do continue
			if wanted == 0 do return pr.TaskID(id)
			wanted -= 1
		}
		return 0
	}

	semantic_handler_swarm_select_edge :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u8) -> pr.EdgeID {
		count := 0
		for edge in model.edges do if edge.live do count += 1
		if count == 0 do return 0
		wanted := int(selector) % count
		for id in 1 ..< len(model.edges) {
			if !model.edges[id].live do continue
			if wanted == 0 do return pr.EdgeID(id)
			wanted -= 1
		}
		return 0
	}

	semantic_handler_swarm_update_request :: proc(task_id: pr.TaskID) -> pr.UpdateTaskRequest {
		titles := [?]string{"", "swarm updated first", "swarm updated second", "swarm updated third", "swarm updated fourth"}
		descriptions := [?]string {
			"",
			"generated update for task one",
			"generated update for task two",
			"generated update for task three",
			"generated update for task four",
		}
		external_refs := [?]string{"", "SWARM-1", "SWARM-2", "SWARM-3", "SWARM-4"}
		return {
			conv_id = pr.WORKSPACE_DATA_ID,
			task_id = task_id,
			title = transmute([]byte)titles[int(task_id)],
			description = transmute([]byte)descriptions[int(task_id)],
			status = .InProgress,
			assignee = transmute([]byte)string("peer"),
			priority = 6 + u8(task_id),
			color = .Cyan,
			external_ref = transmute([]byte)external_refs[int(task_id)],
			due_at = NRC_SIM_TIME_EPOCH_NANOS + i64(task_id) * 300_000_000_000,
			preserve_attachments = true,
			project = transmute([]byte)string("swarm-updated"),
			correlation_id = 0xDA00 + u32(task_id),
		}
	}

	semantic_handler_swarm_move_request :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u8, op_index: int) -> pr.MoveTaskRequest {
		count := semantic_handler_swarm_live_task_count(model)
		task_id := semantic_handler_swarm_select_task(model, selector)
		status_choice := 0
		if count > 0 do status_choice = int(selector) / count % 5
		return {
			conv_id = pr.WORKSPACE_DATA_ID,
			task_id = task_id,
			status = pr.TaskStatus(status_choice),
			order_index = u16((int(selector) * 17 + op_index * 13 + int(task_id)) % 1_000),
			correlation_id = 0xD880 + u32(op_index),
		}
	}

	semantic_handler_swarm_create_task_request :: proc(task_id: pr.TaskID) -> pr.CreateTaskRequest {
		titles := [?]string{"", "", "", "generated third task", "generated fourth task"}
		descriptions := [?]string{"", "", "", "dynamic graph endpoint three", "dynamic graph endpoint four"}
		external_refs := [?]string{"", "", "", "CREATED-3", "CREATED-4"}
		return {
			conv_id = pr.WORKSPACE_DATA_ID,
			title = transmute([]byte)titles[int(task_id)],
			description = transmute([]byte)descriptions[int(task_id)],
			priority = 2 + u8(task_id),
			color = .Gold,
			external_ref = transmute([]byte)external_refs[int(task_id)],
			due_at = NRC_SIM_TIME_EPOCH_NANOS + i64(task_id) * 600_000_000_000,
			status = .Todo,
			project = transmute([]byte)string("swarm-created"),
			correlation_id = 0xD900 + u32(task_id),
		}
	}

	semantic_handler_swarm_updated_task_exact :: proc(task: ^pr.Task, task_id: pr.TaskID, created_at, updated_at: i64, order_index: u16) -> bool {
		if task == nil do return false
		req := semantic_handler_swarm_update_request(task_id)
		return(
			task.id == task_id &&
			task.conv_id == pr.WORKSPACE_DATA_ID &&
			string(task.title) == string(req.title) &&
			string(task.description) == string(req.description) &&
			task.status == req.status &&
			task.order_index == order_index &&
			string(task.assignee) == string(req.assignee) &&
			task.priority == req.priority &&
			task.color == req.color &&
			string(task.created_by) == "requester" &&
			task.created_at == created_at &&
			task.updated_at == updated_at &&
			string(task.external_ref) == string(req.external_ref) &&
			task.due_at == req.due_at &&
			task.blocked_by == 0 &&
			task.completed_at == 0 &&
			len(task.completed_by) == 0 &&
			string(task.project) == string(req.project) &&
			len(task.attachments) == 0 \
		)
	}

	semantic_handler_swarm_created_task_exact :: proc(task: ^pr.Task, task_id: pr.TaskID, created_at: i64, order_index: u16) -> bool {
		if task == nil do return false
		req := semantic_handler_swarm_create_task_request(task_id)
		return(
			task.id == task_id &&
			task.conv_id == pr.WORKSPACE_DATA_ID &&
			string(task.title) == string(req.title) &&
			string(task.description) == string(req.description) &&
			task.status == req.status &&
			task.order_index == order_index &&
			len(task.assignee) == 0 &&
			task.priority == req.priority &&
			task.color == req.color &&
			string(task.created_by) == "requester" &&
			task.created_at == created_at &&
			task.updated_at == created_at &&
			string(task.external_ref) == string(req.external_ref) &&
			task.due_at == req.due_at &&
			task.blocked_by == 0 &&
			task.completed_at == 0 &&
			len(task.completed_by) == 0 &&
			string(task.project) == string(req.project) &&
			len(task.attachments) == 0 \
		)
	}

	semantic_handler_swarm_live_asset_count :: proc(model: ^Semantic_Handler_Swarm_Model) -> int {
		count := 0
		for asset in model.assets do if asset.live do count += 1
		return count
	}

	semantic_handler_swarm_select_asset :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u8) -> pr.AssetID {
		count := semantic_handler_swarm_live_asset_count(model)
		if count == 0 do return 0
		wanted := int(selector) % count
		for id in 1 ..< len(model.assets) {
			if !model.assets[id].live do continue
			if wanted == 0 do return pr.AssetID(id)
			wanted -= 1
		}
		return 0
	}

	semantic_handler_swarm_note_scope :: proc(asset_id: pr.AssetID, variant: u8) -> (project, tags: u8) {
		if asset_id == 2 {
			switch variant {
			case 0:
				return 1, 0b101
			case 1:
				return 2, 0b010
			case:
				return 0, 0b100
			}
		}
		switch variant {
		case 0:
			return 2, 0b011
		case 1:
			return 1, 0b001
		case:
			return 2, 0b110
		}
	}

	semantic_handler_swarm_note_preview :: proc(asset_id: pr.AssetID, variant: u8) -> string {
		if asset_id == 2 {
			switch variant {
			case 0:
				return `{"project":"alpha","tags":["shared","odin"]}`
			case 1:
				return `{"project":"beta","tags":["graph"]}`
			case:
				return `{"tags":["odin"]}`
			}
		}
		switch variant {
		case 0:
			return `{"project":"beta","tags":["shared","graph"]}`
		case 1:
			return `{"project":"alpha","tags":["shared"]}`
		case:
			return `{"project":"beta","tags":["graph","odin"]}`
		}
	}

	semantic_handler_swarm_create_asset_request :: proc(asset_id: pr.AssetID, parent_type: pr.ParentType, parent_id: u64) -> pr.CreateAssetRequest {
		previews := [?]string{"", "", semantic_handler_swarm_note_preview(2, 0), semantic_handler_swarm_note_preview(3, 0)}
		payloads := [?]string{"", "", "durable generated payload two", "durable generated payload three"}
		payload := payloads[int(asset_id)]
		return {
			conv_id = pr.WORKSPACE_DATA_ID,
			asset_type = .Note,
			parent_type = parent_type,
			parent_id = parent_id,
			payload_encoding = .Plain,
			payload_raw_len = u32(len(payload)),
			preview = transmute([]byte)previews[int(asset_id)],
			payload = transmute([]byte)payload,
			correlation_id = 0xD940 + u32(asset_id),
		}
	}

	semantic_handler_swarm_update_asset_request :: proc(
		asset_id: pr.AssetID,
		asset_type: pr.AssetType,
		variant: u8,
		attachment: ^[1]pr.Attachment,
	) -> pr.UpdateAssetRequest {
		plain_previews := [?]string{"", "updated foundation asset", "updated generated asset two", "updated generated asset three"}
		plain_payloads := [?]string{"", "replacement payload one", "replacement payload two", "replacement payload three"}
		zstd_previews := [?]string{"", "compressed foundation asset", "compressed generated asset two", "compressed generated asset three"}
		zstd_payloads := [?]string{"", "zstd-payload-one", "zstd-payload-two", "zstd-payload-three"}
		file_ids := [?]string{"", "swarm-asset-file-1", "swarm-asset-file-2", "swarm-asset-file-3"}
		filenames := [?]string{"", "asset-one.zst", "asset-two.zst", "asset-three.zst"}
		preview := plain_previews[int(asset_id)]
		if asset_type == .Note do preview = semantic_handler_swarm_note_preview(asset_id, variant)
		if variant == 2 {
			attachment[0] = {
				file_id     = transmute([]byte)file_ids[int(asset_id)],
				filename    = transmute([]byte)filenames[int(asset_id)],
				size        = 8_192 + u64(asset_id),
				mime_type   = transmute([]byte)string("application/zstd"),
				uploaded_at = 7_000 + i64(asset_id),
			}
			return {
				conv_id = pr.WORKSPACE_DATA_ID,
				asset_id = asset_id,
				payload_encoding = .Zstd,
				payload_raw_len = 128 + u32(asset_id),
				preview = transmute([]byte)(asset_type == .Note ? preview : zstd_previews[int(asset_id)]),
				payload = transmute([]byte)zstd_payloads[int(asset_id)],
				attachments = attachment[:],
				correlation_id = 0xD960 + u32(asset_id),
			}
		}
		payload := plain_payloads[int(asset_id)]
		return {
			conv_id = pr.WORKSPACE_DATA_ID,
			asset_id = asset_id,
			payload_encoding = .Plain,
			payload_raw_len = u32(len(payload)),
			preview = transmute([]byte)preview,
			payload = transmute([]byte)payload,
			correlation_id = 0xD950 + u32(asset_id),
		}
	}

	semantic_handler_swarm_attachments_exact :: proc(actual, expected: []pr.Attachment) -> bool {
		if len(actual) != len(expected) do return false
		for attachment, index in actual {
			other := expected[index]
			if string(attachment.file_id) != string(other.file_id) ||
			   string(attachment.filename) != string(other.filename) ||
			   attachment.size != other.size ||
			   string(attachment.mime_type) != string(other.mime_type) ||
			   attachment.uploaded_at != other.uploaded_at {
				return false
			}
		}
		return true
	}

	semantic_handler_swarm_asset_exact :: proc(asset: ^pr.Asset, asset_id: pr.AssetID, expected: ^Semantic_Handler_Swarm_Asset) -> bool {
		if asset == nil do return false
		if expected.update_variant == 0 {
			if asset_id == 1 do return semantic_global_compaction_asset_exact(asset)
			return semantic_handler_swarm_created_asset_exact(asset, asset_id, expected)
		}
		attachment: [1]pr.Attachment
		req := semantic_handler_swarm_update_asset_request(asset_id, expected.asset_type, expected.update_variant, &attachment)
		return(
			asset.asset_type == expected.asset_type &&
			asset.asset_id == asset_id &&
			asset.parent_type == expected.parent_type &&
			asset.parent_id == expected.parent_id &&
			string(asset.owner) == "requester" &&
			asset.created_at == expected.created_at &&
			asset.updated_at == expected.updated_at &&
			asset.conv_id == pr.WORKSPACE_DATA_ID &&
			asset.payload_encoding == req.payload_encoding &&
			asset.payload_raw_len == req.payload_raw_len &&
			string(asset.preview) == string(req.preview) &&
			string(asset.payload) == string(req.payload) &&
			semantic_handler_swarm_attachments_exact(asset.attachments, req.attachments) \
		)
	}

	semantic_handler_swarm_created_asset_exact :: proc(asset: ^pr.Asset, asset_id: pr.AssetID, expected: ^Semantic_Handler_Swarm_Asset) -> bool {
		req := semantic_handler_swarm_create_asset_request(asset_id, expected.parent_type, expected.parent_id)
		return(
			asset.asset_type == req.asset_type &&
			asset.asset_id == asset_id &&
			asset.parent_type == req.parent_type &&
			asset.parent_id == req.parent_id &&
			string(asset.owner) == "requester" &&
			asset.created_at == expected.created_at &&
			asset.updated_at == expected.updated_at &&
			asset.conv_id == pr.WORKSPACE_DATA_ID &&
			asset.payload_encoding == req.payload_encoding &&
			asset.payload_raw_len == req.payload_raw_len &&
			string(asset.preview) == string(req.preview) &&
			string(asset.payload) == string(req.payload) &&
			len(asset.attachments) == 0 \
		)
	}

	semantic_handler_swarm_note_scope_list_exact :: proc(
		conv: ^Conversation_State,
		model: ^Semantic_Handler_Swarm_Model,
		project: u8 = 0,
		tag: u8 = 0,
	) -> (
		exact, nonempty: bool,
	) {
		expected: [SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.AssetID
		count := 0
		for id in 1 ..< len(model.assets) {
			asset := &model.assets[id]
			if !asset.live || asset.asset_type != .Note do continue
			if project != 0 && asset.note_project != project do continue
			if tag != 0 && asset.note_tags & tag == 0 do continue
			insert_at := count
			for insert_at > 0 {
				previous_id := int(expected[insert_at - 1])
				previous := &model.assets[previous_id]
				if previous.updated_at > asset.updated_at || (previous.updated_at == asset.updated_at && previous_id > id) do break
				expected[insert_at] = expected[insert_at - 1]
				insert_at -= 1
			}
			expected[insert_at] = pr.AssetID(id)
			count += 1
		}
		actual: [dynamic]pr.AssetID
		if project != 0 {
			projects := [?]string{"", "alpha", "beta"}
			actual = note_secondary_index_asset_ids(conv.note_project_assets[projects[project]])
		} else {
			tags := [?]string{"", "shared", "graph", "", "odin"}
			actual = note_secondary_index_asset_ids(conv.note_tag_assets[tags[tag]])
		}
		defer delete(actual)
		if len(actual) != count do return false, count > 0
		for id, index in actual do if id != expected[index] do return false, count > 0
		return true, count > 0
	}

	semantic_handler_swarm_note_indexes_exact :: proc(conv: ^Conversation_State, model: ^Semantic_Handler_Swarm_Model) -> bool {
		if conv == nil do return false
		note_count := 0
		for id in 1 ..< len(model.assets) {
			asset := &model.assets[id]
			key, present := conv.note_index_keys[pr.AssetID(id)]
			should_exist := asset.live && asset.asset_type == .Note
			if present != should_exist do return false
			if should_exist {
				expected := Note_Sort_Key {
					updated_at = asset.updated_at,
					asset_id   = pr.AssetID(id),
				}
				if key != expected || !btree.contains(&conv.note_index, expected) do return false
				note_count += 1
			}
		}
		if len(conv.note_index_keys) != note_count || btree.count(&conv.note_index) != note_count do return false
		project_count, tag_count := 0, 0
		for project: u8 = 1; project <= 2; project += 1 {
			exact, nonempty := semantic_handler_swarm_note_scope_list_exact(conv, model, project = project)
			if !exact do return false
			if nonempty do project_count += 1
		}
		for tag: u8 = 1; tag <= 4; tag *= 2 {
			exact, nonempty := semantic_handler_swarm_note_scope_list_exact(conv, model, tag = tag)
			if !exact do return false
			if nonempty do tag_count += 1
		}
		return len(conv.note_project_assets) == project_count && len(conv.note_tag_assets) == tag_count
	}

	semantic_handler_swarm_task_indexes_exact :: proc(conv: ^Conversation_State, model: ^Semantic_Handler_Swarm_Model) -> bool {
		if conv == nil ||
		   len(conv.task_index_keys) != semantic_handler_swarm_live_task_count(model) ||
		   btree.count(&conv.task_index) != semantic_handler_swarm_live_task_count(model) {
			return false
		}
		for id in 1 ..< len(model.task_live) {
			if !model.task_live[id] do continue
			sort_at := model.task_created_at[id]
			if model.task_updated_at[id] != 0 do sort_at = model.task_updated_at[id]
			if model.task_status[id] == .Done do sort_at = model.task_completed_at[id]
			expected := Task_Sort_Key {
				sort_at = sort_at,
				task_id = pr.TaskID(id),
			}
			actual, indexed := conv.task_index_keys[pr.TaskID(id)]
			if !indexed || actual != expected || !btree.contains(&conv.task_index, expected) do return false
		}
		return true
	}

	semantic_handler_swarm_edge_exact :: proc(edge: ^pr.Edge, edge_id: pr.EdgeID, expected: ^Semantic_Handler_Swarm_Edge) -> bool {
		return(
			edge != nil &&
			edge.edge_id == edge_id &&
			edge.conv_id == pr.WORKSPACE_DATA_ID &&
			edge.source_type == expected.source_type &&
			edge.source_id == expected.source_id &&
			edge.target_type == expected.target_type &&
			edge.target_id == expected.target_id &&
			edge.relation == expected.relation &&
			edge.created_at == expected.created_at &&
			string(edge.created_by) == "requester" \
		)
	}

	semantic_handler_swarm_adjacency_exact :: proc(
		conv: ^Conversation_State,
		model: ^Semantic_Handler_Swarm_Model,
		key: Edge_Entity_Key,
	) -> (
		present: bool,
		exact: bool,
	) {
		expected: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]pr.EdgeID
		expected_count := 0
		for edge, edge_id in model.edges {
			if !edge.live do continue
			if (edge.source_type == key.target_type && edge.source_id == key.target_id) ||
			   (edge.target_type == key.target_type && edge.target_id == key.target_id) {
				expected[expected_count] = pr.EdgeID(edge_id)
				expected_count += 1
			}
		}
		actual := conv.edges_by_entity[key]
		if len(actual) != expected_count do return expected_count > 0, false
		for expected_id in expected[:expected_count] {
			matches := 0
			for edge_id in actual do if edge_id == expected_id do matches += 1
			if matches != 1 do return expected_count > 0, false
		}
		return expected_count > 0, true
	}

	semantic_handler_swarm_task_exact :: proc(model: ^Semantic_Handler_Swarm_Model, id: int, task: ^pr.Task) -> bool {
		if task == nil || id <= 0 || id >= len(model.task_live) || !model.task_live[id] do return false
		expected_updated_at := model.task_created_at[id]
		if model.task_updated_at[id] != 0 do expected_updated_at = model.task_updated_at[id]
		if task.status != model.task_status[id] ||
		   task.order_index != model.task_order[id] ||
		   task.updated_at != expected_updated_at ||
		   task.completed_at != model.task_completed_at[id] ||
		   (model.task_completed_at[id] != 0 && string(task.completed_by) != "requester") ||
		   (model.task_completed_at[id] == 0 && len(task.completed_by) != 0) {
			return false
		}
		normalized := task^
		normalized.completed_at = 0
		normalized.completed_by = nil
		if model.task_content_updated[id] {
			normalized.status = .InProgress
			return semantic_handler_swarm_updated_task_exact(&normalized, pr.TaskID(id), model.task_created_at[id], expected_updated_at, model.task_order[id])
		}
		normalized.status = .Todo
		normalized.updated_at = normalized.created_at
		if id == 1 {
			normalized.order_index = 0
			return semantic_transport_persistence_task_exact(&normalized)
		}
		if id == 2 {
			normalized.order_index = 1
			return semantic_multihop_task_two_exact(&normalized, false)
		}
		return semantic_handler_swarm_created_task_exact(&normalized, pr.TaskID(id), model.task_created_at[id], model.task_order[id])
	}

	semantic_handler_swarm_task_sort_key :: proc(model: ^Semantic_Handler_Swarm_Model, id: int) -> Task_Sort_Key {
		sort_at := model.task_created_at[id]
		if model.task_updated_at[id] != 0 do sort_at = model.task_updated_at[id]
		if model.task_status[id] == .Done do sort_at = model.task_completed_at[id]
		return {sort_at = sort_at, task_id = pr.TaskID(id)}
	}

	semantic_handler_swarm_task_page_request :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u16, correlation_id: u32) -> pr.ListTasksPagedRequest {
		choice := u64(selector)
		mask_slot := choice % 7
		choice /= 7
		status_mask: u8
		if mask_slot == 0 {
			status_mask = 0x1f
		} else if mask_slot == 6 {
			status_mask = (u8(1) << u8(pr.TaskStatus.Backlog)) | (u8(1) << u8(pr.TaskStatus.Todo)) | (u8(1) << u8(pr.TaskStatus.InProgress))
		} else {
			status_mask = u8(1) << u8(mask_slot - 1)
		}
		limit := u16(1 + choice % 3)
		choice /= 3
		cursor_mode := choice % 3
		choice /= 3
		req := pr.ListTasksPagedRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			status_mask    = status_mask,
			limit          = limit,
			correlation_id = correlation_id,
		}
		if cursor_mode != 0 {
			cursor_id := 1 + int(choice % model.task_high)
			cursor := semantic_handler_swarm_task_sort_key(model, cursor_id)
			req.has_cursor = true
			req.cursor_sort_at = cursor.sort_at
			req.cursor_task_id = cursor.task_id
			if cursor_mode == 2 do req.cursor_task_id += 1
		}
		return req
	}

	semantic_handler_swarm_task_page :: proc(model: ^Semantic_Handler_Swarm_Model, req: ^pr.ListTasksPagedRequest) -> Semantic_Handler_Swarm_Task_Page {
		result: Semantic_Handler_Swarm_Task_Page
		matching: [SEMANTIC_HANDLER_SWARM_MAX_TASKS]pr.TaskID
		matching_count := 0
		for id in 1 ..< len(model.task_live) {
			if !model.task_live[id] || req.status_mask & (u8(1) << u8(model.task_status[id])) == 0 do continue
			result.total_count += 1
			key := semantic_handler_swarm_task_sort_key(model, id)
			if req.has_cursor && !(key.sort_at < req.cursor_sort_at || (key.sort_at == req.cursor_sort_at && key.task_id < req.cursor_task_id)) {
				continue
			}
			insert_at := matching_count
			for existing_id, index in matching[:matching_count] {
				existing := semantic_handler_swarm_task_sort_key(model, int(existing_id))
				if key.sort_at > existing.sort_at || (key.sort_at == existing.sort_at && key.task_id > existing.task_id) {
					insert_at = index
					break
				}
			}
			for index := matching_count; index > insert_at; index -= 1 do matching[index] = matching[index - 1]
			matching[insert_at] = pr.TaskID(id)
			matching_count += 1
		}
		result.count = min(matching_count, int(req.limit))
		copy(result.ids[:result.count], matching[:result.count])
		result.has_more = matching_count > result.count
		if result.count > 0 {
			last := semantic_handler_swarm_task_sort_key(model, int(result.ids[result.count - 1]))
			result.next_cursor_sort_at = last.sort_at
			result.next_cursor_task_id = last.task_id
		}
		return result
	}

	semantic_handler_swarm_note_page_request :: proc(
		model: ^Semantic_Handler_Swarm_Model,
		selector: u16,
		correlation_id: u32,
	) -> Semantic_Handler_Swarm_Note_Page_Request {
		choice := u64(selector)
		scope := Semantic_Handler_Swarm_Note_Page_Scope(choice % 3)
		choice /= 3
		filters := [?]string{"alpha", "beta", "missing"}
		if scope == .Tag do filters = {"shared", "graph", "odin"}
		filter := ""
		if scope != .Global do filter = filters[choice % len(filters)]
		choice /= u64(len(filters))
		req := Semantic_Handler_Swarm_Note_Page_Request {
			scope          = scope,
			filter         = filter,
			limit          = u16(1 + choice % 2),
			correlation_id = correlation_id,
		}
		choice /= 2
		cursor_mode := choice % 4
		choice /= 4
		if cursor_mode != 0 {
			asset_id := pr.AssetID(1 + choice % model.asset_high)
			asset := &model.assets[int(asset_id)]
			req.has_cursor = true
			req.cursor_updated_at = asset.updated_at
			req.cursor_asset_id = asset_id
			if cursor_mode == 2 do req.cursor_asset_id += 1
			if cursor_mode == 3 do req.cursor_updated_at += 1
		}
		return req
	}

	semantic_handler_swarm_note_matches_scope :: proc(asset: ^Semantic_Handler_Swarm_Asset, req: ^Semantic_Handler_Swarm_Note_Page_Request) -> bool {
		if asset == nil || !asset.live || asset.asset_type != .Note do return false
		switch req.scope {
		case .Global:
			return true
		case .Project:
			if req.filter == "alpha" do return asset.note_project == 1
			if req.filter == "beta" do return asset.note_project == 2
		case .Tag:
			if req.filter == "shared" do return asset.note_tags & 0b001 != 0
			if req.filter == "graph" do return asset.note_tags & 0b010 != 0
			if req.filter == "odin" do return asset.note_tags & 0b100 != 0
		}
		return false
	}

	semantic_handler_swarm_note_page :: proc(
		model: ^Semantic_Handler_Swarm_Model,
		req: ^Semantic_Handler_Swarm_Note_Page_Request,
	) -> Semantic_Handler_Swarm_Note_Page {
		result: Semantic_Handler_Swarm_Note_Page
		matching: [SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.AssetID
		matching_count := 0
		for id in 1 ..< len(model.assets) {
			asset := &model.assets[id]
			if !semantic_handler_swarm_note_matches_scope(asset, req) do continue
			result.total_count += 1
			if req.has_cursor &&
			   (pr.AssetID(id) == req.cursor_asset_id ||
					   !(asset.updated_at < req.cursor_updated_at || (asset.updated_at == req.cursor_updated_at && pr.AssetID(id) < req.cursor_asset_id))) {
				continue
			}
			insert_at := matching_count
			for existing_id, index in matching[:matching_count] {
				existing := &model.assets[int(existing_id)]
				if asset.updated_at > existing.updated_at || (asset.updated_at == existing.updated_at && pr.AssetID(id) > existing_id) {
					insert_at = index
					break
				}
			}
			for index := matching_count; index > insert_at; index -= 1 do matching[index] = matching[index - 1]
			matching[insert_at] = pr.AssetID(id)
			matching_count += 1
		}
		result.count = min(matching_count, int(req.limit))
		copy(result.ids[:result.count], matching[:result.count])
		result.has_more = matching_count > result.count
		if result.count > 0 {
			last_id := result.ids[result.count - 1]
			result.next_cursor_updated_at = model.assets[int(last_id)].updated_at
			result.next_cursor_asset_id = last_id
		}
		return result
	}

	semantic_handler_swarm_check :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, model: ^Semantic_Handler_Swarm_Model) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if writer == nil ||
		   writer.floors != (Shard_High_Water_Requirements{task = model.task_high, asset = model.asset_high, edge = model.edge_high}) ||
		   td.task_seq != model.task_high ||
		   td.asset_seq != model.asset_high ||
		   td.edge_seq != model.edge_high ||
		   conv == nil ||
		   len(conv.tasks) != semantic_handler_swarm_live_task_count(model) ||
		   !semantic_handler_swarm_task_indexes_exact(conv, model) ||
		   !semantic_handler_swarm_note_indexes_exact(conv, model) {
			return "handler swarm task/index/floor state differs from model"
		}
		for id in 1 ..< len(model.task_live) {
			task := conv.tasks[pr.TaskID(id)]
			if (task != nil) != model.task_live[id] do return "handler swarm task membership differs from model"
			if task != nil && !semantic_handler_swarm_task_exact(model, id, task) do return "handler swarm task state differs from model"
		}
		if len(conv.assets) != semantic_handler_swarm_live_asset_count(model) do return "handler swarm asset cardinality differs from model"
		for id in 1 ..< len(model.assets) {
			asset := conv.assets[pr.AssetID(id)]
			if (asset != nil) != model.assets[id].live do return "handler swarm asset membership differs from model"
			if asset != nil && !semantic_handler_swarm_asset_exact(asset, pr.AssetID(id), &model.assets[id]) {
				return "handler swarm asset state differs from model"
			}
		}
		expected_edges := 0
		for id in 1 ..< len(model.edges) {
			edge := conv.edges[pr.EdgeID(id)]
			if (edge != nil) != model.edges[id].live do return "handler swarm edge membership differs from model"
			if edge != nil && !semantic_handler_swarm_edge_exact(edge, pr.EdgeID(id), &model.edges[id]) do return "handler swarm edge state differs from model"
			if model.edges[id].live do expected_edges += 1
		}
		if len(conv.edges) != expected_edges do return "handler swarm edge cardinality differs from model"
		expected_adjacency_entries := 0
		for id in 1 ..< len(model.task_live) {
			present, exact := semantic_handler_swarm_adjacency_exact(conv, model, {target_type = .Task, target_id = u64(id)})
			if !exact do return "handler swarm task adjacency differs from model"
			if present do expected_adjacency_entries += 1
		}
		for id in 1 ..< len(model.assets) {
			present, exact := semantic_handler_swarm_adjacency_exact(conv, model, {target_type = .Asset, target_id = u64(id)})
			if !exact do return "handler swarm asset adjacency differs from model"
			if present do expected_adjacency_entries += 1
		}
		if len(conv.edges_by_entity) != expected_adjacency_entries do return "handler swarm adjacency key set differs from model"
		return ""
	}

	semantic_handler_swarm_enqueue_delete_edge :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		edge_id: pr.EdgeID,
		correlation_id: u32,
		split_a, split_b: int,
	) -> bool {
		request_buf: [32]byte
		request_len := pr.serializeDeleteEdgeRequest(pr.WORKSPACE_DATA_ID, edge_id, request_buf[:], correlation_id)
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		boundaries := [4]int{0, split_a, split_b, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[boundaries[index]:boundaries[index + 1]]) do return false
		}
		return true
	}

	semantic_handler_swarm_live_entity_count :: proc(model: ^Semantic_Handler_Swarm_Model) -> int {
		return semantic_handler_swarm_live_task_count(model) + semantic_handler_swarm_live_asset_count(model)
	}

	semantic_handler_swarm_select_entity :: proc(model: ^Semantic_Handler_Swarm_Model, ordinal: int) -> (pr.TargetType, u64, bool) {
		if ordinal < 0 || ordinal >= semantic_handler_swarm_live_entity_count(model) do return {}, 0, false
		wanted := ordinal
		for id in 1 ..< len(model.task_live) {
			if !model.task_live[id] do continue
			if wanted == 0 do return .Task, u64(id), true
			wanted -= 1
		}
		for id in 1 ..< len(model.assets) {
			if !model.assets[id].live do continue
			if wanted == 0 do return .Asset, u64(id), true
			wanted -= 1
		}
		return {}, 0, false
	}

	semantic_handler_swarm_known_entity_count :: proc(model: ^Semantic_Handler_Swarm_Model) -> int {
		return int(model.task_high + model.asset_high)
	}

	semantic_handler_swarm_select_known_entity :: proc(model: ^Semantic_Handler_Swarm_Model, ordinal: int) -> (pr.TargetType, u64, bool) {
		if ordinal < 0 || ordinal >= semantic_handler_swarm_known_entity_count(model) do return {}, 0, false
		if ordinal < int(model.task_high) do return .Task, u64(ordinal + 1), true
		return .Asset, u64(ordinal - int(model.task_high) + 1), true
	}

	semantic_handler_swarm_query_request :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u16, correlation_id: u32) -> pr.GraphShortestPathRequest {
		count := semantic_handler_swarm_known_entity_count(model)
		choice := u64(selector)
		from_ordinal := int(choice % u64(count))
		choice /= u64(count)
		to_offset := 1 + int(choice % u64(count - 1))
		choice /= u64(count - 1)
		to_ordinal := (from_ordinal + to_offset) % count
		from_type, from_id, _ := semantic_handler_swarm_select_known_entity(model, from_ordinal)
		to_type, to_id, _ := semantic_handler_swarm_select_known_entity(model, to_ordinal)
		direction := pr.Direction(choice % 3)
		choice /= 3
		max_depth := u8(1 + choice % 4)
		choice /= 4
		relation_slot := u16(choice % (u64(max(pr.RelationType)) + 1))
		relation_mask: u16
		if relation_slot > 0 do relation_mask = u16(1) << (relation_slot - 1)
		return {
			conv_id = pr.WORKSPACE_DATA_ID,
			from_type = from_type,
			from_id = from_id,
			to_type = to_type,
			to_id = to_id,
			relation_mask = relation_mask,
			direction = direction,
			max_depth = max_depth,
			correlation_id = correlation_id,
		}
	}

	semantic_handler_swarm_neighborhood_request :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u16, correlation_id: u32) -> pr.GraphQueryRequest {
		path_req := semantic_handler_swarm_query_request(model, selector, correlation_id)
		return {
			conv_id = path_req.conv_id,
			start_type = path_req.from_type,
			start_id = path_req.from_id,
			max_depth = path_req.max_depth,
			relation_mask = path_req.relation_mask,
			direction = path_req.direction,
			correlation_id = path_req.correlation_id,
		}
	}

	semantic_handler_swarm_common_neighbors_request :: proc(
		model: ^Semantic_Handler_Swarm_Model,
		selector: u16,
		correlation_id: u32,
	) -> pr.GraphCommonNeighborsRequest {
		path_req := semantic_handler_swarm_query_request(model, selector, correlation_id)
		return {
			conv_id = path_req.conv_id,
			a_type = path_req.from_type,
			a_id = path_req.from_id,
			b_type = path_req.to_type,
			b_id = path_req.to_id,
			relation_mask = path_req.relation_mask,
			direction = path_req.direction,
			correlation_id = path_req.correlation_id,
		}
	}

	semantic_handler_swarm_query_fixture_exact :: proc(
		model: ^Semantic_Handler_Swarm_Model,
		selector: u16,
		from_type: pr.TargetType,
		from_id: u64,
		to_type: pr.TargetType,
		to_id: u64,
		direction: pr.Direction,
		max_depth: u8,
		relation_mask: u16,
		found: bool,
		distance: u8,
	) -> bool {
		req := semantic_handler_swarm_query_request(model, selector, 0)
		actual_distance, actual_found := semantic_handler_swarm_shortest_distance(model, &req)
		return(
			req.from_type == from_type &&
			req.from_id == from_id &&
			req.to_type == to_type &&
			req.to_id == to_id &&
			req.direction == direction &&
			req.max_depth == max_depth &&
			req.relation_mask == relation_mask &&
			actual_found == found &&
			actual_distance == distance \
		)
	}

	semantic_handler_swarm_select_edge_endpoints :: proc(
		model: ^Semantic_Handler_Swarm_Model,
		selector: u8,
	) -> (
		pr.TargetType,
		u64,
		pr.TargetType,
		u64,
		bool,
	) {
		count := semantic_handler_swarm_live_entity_count(model)
		if count < 2 do return {}, 0, {}, 0, false
		source_ordinal := int(selector) % count
		target_ordinal := (source_ordinal + 1 + (int(selector) / count) % (count - 1)) % count
		source_type, source_id, source_ok := semantic_handler_swarm_select_entity(model, source_ordinal)
		target_type, target_id, target_ok := semantic_handler_swarm_select_entity(model, target_ordinal)
		return source_type, source_id, target_type, target_id, source_ok && target_ok
	}

	semantic_handler_swarm_next_todo_order :: proc(model: ^Semantic_Handler_Swarm_Model) -> u16 {
		next: u16
		for id in 1 ..< len(model.task_live) {
			if model.task_live[id] && model.task_status[id] == .Todo && model.task_order[id] >= next {
				next = model.task_order[id] + 1
			}
		}
		return next
	}

	semantic_handler_swarm_remove_incident_edges :: proc(model: ^Semantic_Handler_Swarm_Model, target_type: pr.TargetType, target_id: u64) {
		for &edge in model.edges {
			if !edge.live do continue
			if (edge.source_type == target_type && edge.source_id == target_id) || (edge.target_type == target_type && edge.target_id == target_id) {
				edge.live = false
			}
		}
	}

	semantic_handler_swarm_select_asset_parent :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u8) -> (pr.ParentType, u64, bool) {
		if selector & 0x80 != 0 {
			asset_id := semantic_handler_swarm_select_asset(model, selector & 0x7f)
			if asset_id != 0 do return .Asset, u64(asset_id), true
		}
		task_id := semantic_handler_swarm_select_task(model, selector & 0x7f)
		return .Task, u64(task_id), task_id != 0
	}

	semantic_handler_swarm_remove_asset_tree :: proc(model: ^Semantic_Handler_Swarm_Model, root_id: pr.AssetID) {
		for child_id in 1 ..< len(model.assets) {
			child := &model.assets[child_id]
			if child.live && child.parent_type == .Asset && child.parent_id == u64(root_id) {
				semantic_handler_swarm_remove_asset_tree(model, pr.AssetID(child_id))
			}
		}
		model.assets[int(root_id)].live = false
		semantic_handler_swarm_remove_incident_edges(model, .Asset, u64(root_id))
	}

	semantic_handler_swarm_output_ledger_init :: proc(ledger: ^Semantic_Handler_Swarm_Output_Ledger) {
		ledger.entries = make([dynamic]Semantic_Handler_Swarm_Output, 0, 64)
	}

	semantic_handler_swarm_output_ledger_destroy :: proc(ledger: ^Semantic_Handler_Swarm_Output_Ledger) {
		for entry in ledger.entries do delete(entry.payload)
		delete(ledger.entries)
		ledger^ = {}
	}

	semantic_handler_swarm_output_append :: proc(
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		recipient: Semantic_Handler_Swarm_Output_Recipient,
		group: int,
		payload: []byte,
	) -> bool {
		if ledger == nil || len(payload) == 0 do return false
		stored := make([]byte, len(payload))
		copy(stored, payload)
		append(&ledger.entries, Semantic_Handler_Swarm_Output{recipient = recipient, group = group, payload = stored})
		return true
	}

	semantic_handler_swarm_output_append_task :: proc(
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		recipient: Semantic_Handler_Swarm_Output_Recipient,
		group: int,
		opcode: pr.Opcode,
		task: ^pr.Task,
		correlation_id: u32,
	) -> bool {
		if task == nil do return false
		buf: [4_096]byte
		written := -1
		#partial switch opcode {
		case .S_TaskCreated:
			written = pr.serializeTaskCreated({task = task^, correlation_id = correlation_id}, buf[:])
		case .S_TaskUpdated:
			written = pr.serializeTaskUpdated({task = task^, correlation_id = correlation_id}, buf[:])
		case .S_TaskMoved:
			written = pr.serializeTaskMoved(
				{
					task_id = task.id,
					conv_id = task.conv_id,
					status = task.status,
					order_index = task.order_index,
					completed_at = task.completed_at,
					completed_by = task.completed_by,
					correlation_id = correlation_id,
				},
				buf[:],
			)
		case:
			return false
		}
		return written > 0 && semantic_handler_swarm_output_append(ledger, recipient, group, buf[:written])
	}

	semantic_handler_swarm_output_append_task_deleted :: proc(
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		recipient: Semantic_Handler_Swarm_Output_Recipient,
		group: int,
		task_id: pr.TaskID,
		correlation_id: u32,
	) -> bool {
		buf: [64]byte
		written := pr.serializeTaskDeleted({task_id = task_id, conv_id = pr.WORKSPACE_DATA_ID, correlation_id = correlation_id}, buf[:])
		return written > 0 && semantic_handler_swarm_output_append(ledger, recipient, group, buf[:written])
	}

	semantic_handler_swarm_output_append_asset :: proc(
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		recipient: Semantic_Handler_Swarm_Output_Recipient,
		group: int,
		opcode: pr.Opcode,
		asset: ^pr.Asset,
		correlation_id: u32,
	) -> bool {
		if asset == nil do return false
		buf: [4_096]byte
		written := -1
		if opcode == .S_AssetCreated {
			written = pr.serializeAssetCreatedMessage({asset = asset^, correlation_id = correlation_id}, buf[:])
		} else {
			written = pr.serializeAssetUpdatedMessage({asset = asset^, correlation_id = correlation_id}, buf[:])
		}
		return written > 0 && semantic_handler_swarm_output_append(ledger, recipient, group, buf[:written])
	}

	semantic_handler_swarm_output_append_asset_deleted :: proc(
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		recipient: Semantic_Handler_Swarm_Output_Recipient,
		group: int,
		asset_id: pr.AssetID,
		correlation_id: u32,
	) -> bool {
		buf: [64]byte
		written := pr.serializeAssetDeletedMessage({conv_id = pr.WORKSPACE_DATA_ID, asset_id = asset_id, correlation_id = correlation_id}, buf[:])
		return written > 0 && semantic_handler_swarm_output_append(ledger, recipient, group, buf[:written])
	}

	semantic_handler_swarm_output_append_edge :: proc(
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		recipient: Semantic_Handler_Swarm_Output_Recipient,
		group: int,
		edge: ^pr.Edge,
		correlation_id: u32,
	) -> bool {
		if edge == nil do return false
		buf: [1_024]byte
		written := pr.serializeEdgeCreatedMessage({edge = edge^, correlation_id = correlation_id}, buf[:])
		return written > 0 && semantic_handler_swarm_output_append(ledger, recipient, group, buf[:written])
	}

	semantic_handler_swarm_output_append_edge_deleted :: proc(
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		recipient: Semantic_Handler_Swarm_Output_Recipient,
		group: int,
		edge_id: pr.EdgeID,
		correlation_id: u32,
	) -> bool {
		buf: [64]byte
		written := pr.serializeEdgeDeletedMessage({conv_id = pr.WORKSPACE_DATA_ID, edge_id = edge_id, correlation_id = correlation_id}, buf[:])
		return written > 0 && semantic_handler_swarm_output_append(ledger, recipient, group, buf[:written])
	}

	semantic_handler_swarm_edge_touches_deleted_asset :: proc(
		before, after: ^Semantic_Handler_Swarm_Model,
		edge: ^Semantic_Handler_Swarm_Edge,
		excluded_root: pr.AssetID = 0,
	) -> bool {
		for id in 1 ..< len(before.assets) {
			if pr.AssetID(id) == excluded_root || !before.assets[id].live || after.assets[id].live do continue
			if (edge.source_type == .Asset && edge.source_id == u64(id)) || (edge.target_type == .Asset && edge.target_id == u64(id)) do return true
		}
		return false
	}

	semantic_handler_swarm_output_record :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		before, after: ^Semantic_Handler_Swarm_Model,
		kind: Semantic_Handler_Swarm_Kind,
		entity_id: u64,
		correlation_id: u32,
		group: int,
	) -> bool {
		conv := get_conversation(get_workspace(campaign.workspace), pr.WORKSPACE_DATA_ID)
		if conv == nil do return false
		switch kind {
		case .Create_Task, .Update_Task, .Move_Task:
			task := conv.tasks[pr.TaskID(entity_id)]
			opcode := kind == .Create_Task ? pr.Opcode.S_TaskCreated : (kind == .Update_Task ? .S_TaskUpdated : .S_TaskMoved)
			return(
				semantic_handler_swarm_output_append_task(ledger, .Requester, group, opcode, task, correlation_id) &&
				semantic_handler_swarm_output_append_task(ledger, .Peer, group, opcode, task, 0) \
			)
		case .Create_Asset, .Update_Asset:
			asset := conv.assets[pr.AssetID(entity_id)]
			opcode := kind == .Create_Asset ? pr.Opcode.S_AssetCreated : .S_AssetUpdated
			return(
				semantic_handler_swarm_output_append_asset(ledger, .Requester, group, opcode, asset, correlation_id) &&
				semantic_handler_swarm_output_append_asset(ledger, .Peer, group, opcode, asset, 0) \
			)
		case .Create_Edge:
			edge := conv.edges[pr.EdgeID(entity_id)]
			return(
				semantic_handler_swarm_output_append_edge(ledger, .Requester, group, edge, correlation_id) &&
				semantic_handler_swarm_output_append_edge(ledger, .Peer, group, edge, 0) \
			)
		case .Delete_Edge:
			return(
				semantic_handler_swarm_output_append_edge_deleted(ledger, .Requester, group, pr.EdgeID(entity_id), correlation_id) &&
				semantic_handler_swarm_output_append_edge_deleted(ledger, .Peer, group, pr.EdgeID(entity_id), 0) \
			)
		case .Delete_Asset, .Delete_Task:
			excluded_root := pr.AssetID(0)
			if kind == .Delete_Asset do excluded_root = pr.AssetID(entity_id)
			for &edge, id in before.edges {
				if !edge.live || after.edges[id].live do continue
				if semantic_handler_swarm_edge_touches_deleted_asset(before, after, &edge, excluded_root) &&
				   !semantic_handler_swarm_output_append_edge_deleted(ledger, .Requester, group, pr.EdgeID(id), 0) {
					return false
				}
				if !semantic_handler_swarm_output_append_edge_deleted(ledger, .Peer, group, pr.EdgeID(id), 0) do return false
			}
			for asset, id in before.assets {
				if !asset.live || after.assets[id].live || pr.AssetID(id) == excluded_root do continue
				if !semantic_handler_swarm_output_append_asset_deleted(ledger, .Requester, group, pr.AssetID(id), 0) ||
				   !semantic_handler_swarm_output_append_asset_deleted(ledger, .Peer, group, pr.AssetID(id), 0) {
					return false
				}
			}
			if kind == .Delete_Asset {
				return(
					semantic_handler_swarm_output_append_asset_deleted(ledger, .Requester, group, pr.AssetID(entity_id), correlation_id) &&
					semantic_handler_swarm_output_append_asset_deleted(ledger, .Peer, group, pr.AssetID(entity_id), 0) \
				)
			}
			return(
				semantic_handler_swarm_output_append_task_deleted(ledger, .Requester, group, pr.TaskID(entity_id), correlation_id) &&
				semantic_handler_swarm_output_append_task_deleted(ledger, .Peer, group, pr.TaskID(entity_id), 0) \
			)
		}
		return false
	}

	semantic_handler_swarm_output_payload_equal :: proc(a, b: []byte) -> bool {
		if len(a) != len(b) do return false
		for value, index in a do if value != b[index] do return false
		return true
	}

	semantic_handler_swarm_is_ledger_output :: proc(opcode: pr.Opcode) -> bool {
		return(
			opcode == .S_ErrorResponse ||
			opcode == .S_TaskListResponse ||
			opcode >= .S_TaskCreated && opcode <= .S_TaskMoved ||
			opcode >= .S_AssetCreated && opcode <= .S_AssetDeleted ||
			opcode >= .S_EdgeCreated && opcode <= .S_EdgeDeleted \
		)
	}

	semantic_handler_swarm_output_check :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, ledger: ^Semantic_Handler_Swarm_Output_Ledger) -> string {
		matched := make([]bool, len(ledger.entries))
		defer delete(matched)
		last_group := [2]int{-1, -1}
		connections := [?]^NRC_Connection{campaign.requester, campaign.peer}
		for conn, recipient_index in connections {
			for frame_index in 0 ..< nrc_sim_client_frame_count(&campaign.ctx.sim, conn.sock) {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, conn.sock, frame_index))
				if !payload_ok || !semantic_handler_swarm_is_ledger_output(pr.get_opcode(payload)) do continue
				found := -1
				for entry, index in ledger.entries {
					if !matched[index] && int(entry.recipient) == recipient_index && semantic_handler_swarm_output_payload_equal(entry.payload, payload) {
						found = index
						break
					}
				}
				if found < 0 do return fmt.tprintf("handler swarm emitted unexpected mutation output: recipient=%d opcode=%v", recipient_index, pr.get_opcode(payload))
				if ledger.entries[found].group < last_group[recipient_index] do return "handler swarm mutation output crossed operation order"
				last_group[recipient_index] = ledger.entries[found].group
				matched[found] = true
			}
			for queue_index in 0 ..< send_queue_len(conn) {
				item := semantic_transport_persistence_pending_item(conn, queue_index)
				if item == nil || outbox_item_is_durable(item) do continue
				payload, payload_ok := nrc_sim_frame_protocol_payload(frame_lease_data(item.lease))
				if !payload_ok || !semantic_handler_swarm_is_ledger_output(pr.get_opcode(payload)) do continue
				found := -1
				for entry, index in ledger.entries {
					if !matched[index] && int(entry.recipient) == recipient_index && semantic_handler_swarm_output_payload_equal(entry.payload, payload) {
						found = index
						break
					}
				}
				if found < 0 do return fmt.tprintf("handler swarm queued unexpected mutation output: recipient=%d opcode=%v", recipient_index, pr.get_opcode(payload))
				if ledger.entries[found].group < last_group[recipient_index] do return "handler swarm queued mutation output crossed operation order"
				last_group[recipient_index] = ledger.entries[found].group
				matched[found] = true
			}
		}
		for was_matched, index in matched do if !was_matched do return fmt.tprintf("handler swarm omitted mutation output: recipient=%v group=%d opcode=%v", ledger.entries[index].recipient, ledger.entries[index].group, pr.get_opcode(ledger.entries[index].payload))
		return ""
	}

	semantic_handler_swarm_apply :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: ^Semantic_Handler_Swarm_Model,
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		op: Semantic_Handler_Swarm_Op,
		op_index: int,
		counts: ^Semantic_Handler_Swarm_Counts = nil,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "handler swarm mutation writer missing"
		before := model^
		record_count_before := writer.wal.record_count + writer.wal.buffered_record_count
		kind := op.kind
		entity_id: u64
		correlation_id: u32
		if kind == .Delete_Task && semantic_handler_swarm_live_task_count(model) <= 1 do kind = .Update_Task
		if kind == .Delete_Asset && semantic_handler_swarm_select_asset(model, op.selector) == 0 do kind = .Update_Task
		if kind == .Update_Asset && semantic_handler_swarm_select_asset(model, op.selector) == 0 do kind = .Update_Task
		if kind == .Delete_Edge && semantic_handler_swarm_select_edge(model, op.selector) == 0 do kind = .Update_Task
		if kind == .Create_Task && model.task_high + 1 >= len(model.task_live) do kind = .Update_Task
		if kind == .Create_Asset && model.asset_high + 1 >= len(model.assets) do kind = .Update_Task
		if kind == .Create_Edge {
			_, _, _, _, endpoints_ok := semantic_handler_swarm_select_edge_endpoints(model, op.selector)
			if model.edge_high + 1 >= len(model.edges) {
				kind = .Update_Task
			} else if !endpoints_ok {
				kind = model.task_high + 1 < len(model.task_live) ? .Create_Task : .Update_Task
			}
		}
		first := semantic_multihop_split(op.split_a, false)
		second := semantic_multihop_split(op.split_b, true)
		switch kind {
		case .Update_Task:
			task_id := semantic_handler_swarm_select_task(model, op.selector)
			req := semantic_handler_swarm_update_request(task_id)
			campaign.ctx.sim.world.now += 1
			if task_id == 0 || !semantic_transport_persistence_enqueue_update(campaign, req, first, second) {
				return "handler swarm task update failed to enqueue"
			}
			entity_id, correlation_id = u64(task_id), req.correlation_id
			model.task_updated_at[int(task_id)] = NRC_SIM_TIME_EPOCH_NANOS + i64(campaign.ctx.sim.world.now)
			model.task_completed_at[int(task_id)] = 0
			model.task_content_updated[int(task_id)] = true
			model.task_status[int(task_id)] = .InProgress
		case .Delete_Edge:
			edge_id := semantic_handler_swarm_select_edge(model, op.selector)
			correlation_id = 0xDB00 + u32(op_index)
			if edge_id == 0 || !semantic_handler_swarm_enqueue_delete_edge(campaign, edge_id, correlation_id, first, second) {
				return "handler swarm edge delete failed to enqueue"
			}
			entity_id = u64(edge_id)
			model.edges[int(edge_id)].live = false
		case .Delete_Asset:
			asset_id := semantic_handler_swarm_select_asset(model, op.selector)
			correlation_id = 0xDC00 + u32(op_index)
			if asset_id == 0 || !semantic_transport_persistence_enqueue_delete_asset(campaign, pr.WORKSPACE_DATA_ID, asset_id, correlation_id, first, second) {
				return "handler swarm asset delete failed to enqueue"
			}
			entity_id = u64(asset_id)
			semantic_handler_swarm_remove_asset_tree(model, asset_id)
		case .Delete_Task:
			task_id := semantic_handler_swarm_select_task(model, op.selector)
			correlation_id = 0xDD00 + u32(op_index)
			if task_id == 0 || !semantic_transport_persistence_enqueue_delete(campaign, pr.WORKSPACE_DATA_ID, task_id, correlation_id, first, second) {
				return "handler swarm task delete failed to enqueue"
			}
			entity_id = u64(task_id)
			model.task_live[int(task_id)] = false
			semantic_handler_swarm_remove_incident_edges(model, .Task, u64(task_id))
			for &asset, asset_id in model.assets {
				if !asset.live || asset.parent_type != .Task || asset.parent_id != u64(task_id) do continue
				semantic_handler_swarm_remove_asset_tree(model, pr.AssetID(asset_id))
			}
		case .Create_Task:
			task_id := pr.TaskID(model.task_high + 1)
			order_index := semantic_handler_swarm_next_todo_order(model)
			req := semantic_handler_swarm_create_task_request(task_id)
			campaign.ctx.sim.world.now += 1
			if !semantic_transport_persistence_enqueue_create(campaign, req, first, second) {
				return "handler swarm task create failed to enqueue"
			}
			entity_id, correlation_id = u64(task_id), req.correlation_id
			model.task_high = u64(task_id)
			model.task_live[int(task_id)] = true
			model.task_created_at[int(task_id)] = NRC_SIM_TIME_EPOCH_NANOS + i64(campaign.ctx.sim.world.now)
			model.task_status[int(task_id)] = .Todo
			model.task_order[int(task_id)] = order_index
		case .Create_Edge:
			source_type, source_id, target_type, target_id, endpoints_ok := semantic_handler_swarm_select_edge_endpoints(model, op.selector)
			edge_id := pr.EdgeID(model.edge_high + 1)
			relation := pr.RelationType(u8(min(pr.RelationType)) + op.selector % u8(len(pr.RelationType)))
			if relation == .MemberOf {
				for edge in model.edges {
					if !edge.live || edge.relation != .MemberOf do continue
					same := edge.source_type == source_type && edge.source_id == source_id && edge.target_type == target_type && edge.target_id == target_id
					reverse := edge.source_type == target_type && edge.source_id == target_id && edge.target_type == source_type && edge.target_id == source_id
					// This accepted-write model requires a new record. Membership
					// pairs are sets; generic references may repeat.
					if same || reverse do relation = .References
				}
			}
			req := pr.CreateEdgeRequest {
				conv_id        = pr.WORKSPACE_DATA_ID,
				source_type    = source_type,
				source_id      = source_id,
				target_type    = target_type,
				target_id      = target_id,
				relation       = relation,
				correlation_id = 0xD980 + u32(op_index),
			}
			campaign.ctx.sim.world.now += 1
			if !endpoints_ok || !semantic_transport_persistence_enqueue_create_edge(campaign, req, first, second) {
				return "handler swarm edge create failed to enqueue"
			}
			entity_id, correlation_id = u64(edge_id), req.correlation_id
			model.edge_high = u64(edge_id)
			model.edges[int(edge_id)] = {
				live        = true,
				source_type = source_type,
				source_id   = source_id,
				target_type = target_type,
				target_id   = target_id,
				relation    = relation,
				created_at  = NRC_SIM_TIME_EPOCH_NANOS + i64(campaign.ctx.sim.world.now),
			}
		case .Create_Asset:
			asset_id := pr.AssetID(model.asset_high + 1)
			parent_type, parent_id, parent_ok := semantic_handler_swarm_select_asset_parent(model, op.selector)
			req := semantic_handler_swarm_create_asset_request(asset_id, parent_type, parent_id)
			project, tags := semantic_handler_swarm_note_scope(asset_id, 0)
			campaign.ctx.sim.world.now += 1
			if !parent_ok || !semantic_transport_persistence_enqueue_create_asset(campaign, req, first, second) {
				return "handler swarm asset create failed to enqueue"
			}
			entity_id, correlation_id = u64(asset_id), req.correlation_id
			model.asset_high = u64(asset_id)
			model.assets[int(asset_id)] = {
				live         = true,
				asset_type   = req.asset_type,
				note_project = project,
				note_tags    = tags,
				parent_type  = parent_type,
				parent_id    = parent_id,
				created_at   = NRC_SIM_TIME_EPOCH_NANOS + i64(campaign.ctx.sim.world.now),
				updated_at   = NRC_SIM_TIME_EPOCH_NANOS + i64(campaign.ctx.sim.world.now),
			}
		case .Move_Task:
			req := semantic_handler_swarm_move_request(model, op.selector, op_index)
			previous_status := model.task_status[int(req.task_id)]
			campaign.ctx.sim.world.now += 1
			if req.task_id == 0 || !semantic_transport_persistence_enqueue_move(campaign, req, first, second) {
				return "handler swarm task move failed to enqueue"
			}
			entity_id, correlation_id = u64(req.task_id), req.correlation_id
			moved_at := NRC_SIM_TIME_EPOCH_NANOS + i64(campaign.ctx.sim.world.now)
			model.task_status[int(req.task_id)] = req.status
			model.task_order[int(req.task_id)] = req.order_index
			model.task_updated_at[int(req.task_id)] = moved_at
			if req.status == .Done && previous_status != .Done {
				model.task_completed_at[int(req.task_id)] = moved_at
			} else if req.status != .Done && previous_status == .Done {
				model.task_completed_at[int(req.task_id)] = 0
			}
		case .Update_Asset:
			asset_id := semantic_handler_swarm_select_asset(model, op.selector)
			variant: u8 = 1
			if model.assets[int(asset_id)].update_variant == 1 do variant = 2
			attachment: [1]pr.Attachment
			req := semantic_handler_swarm_update_asset_request(asset_id, model.assets[int(asset_id)].asset_type, variant, &attachment)
			campaign.ctx.sim.world.now += 1
			if asset_id == 0 || !semantic_transport_persistence_enqueue_update_asset(campaign, req, first, second) {
				return "handler swarm asset update failed to enqueue"
			}
			entity_id, correlation_id = u64(asset_id), req.correlation_id
			model.assets[int(asset_id)].update_variant = variant
			model.assets[int(asset_id)].updated_at = NRC_SIM_TIME_EPOCH_NANOS + i64(campaign.ctx.sim.world.now)
			if model.assets[int(asset_id)].asset_type == .Note {
				model.assets[int(asset_id)].note_project, model.assets[int(asset_id)].note_tags = semantic_handler_swarm_note_scope(asset_id, variant)
			}
		}
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm mutation was not three-way segmented"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		if writer.wal.record_count + writer.wal.buffered_record_count != record_count_before + 1 do return "handler swarm mutation did not append exactly one WAL record"
		if !semantic_handler_swarm_output_record(campaign, ledger, &before, model, kind, entity_id, correlation_id, op_index * 2) {
			return "handler swarm mutation output ledger failed to record"
		}
		diagnostic := semantic_handler_swarm_check(campaign, model)
		if diagnostic == "" && counts != nil do counts[int(op.kind)][int(kind)] += 1
		return diagnostic
	}

	semantic_handler_swarm_first_missing_task :: proc(model: ^Semantic_Handler_Swarm_Model) -> pr.TaskID {
		for id in 1 ..= int(model.task_high) do if !model.task_live[id] do return pr.TaskID(id)
		return pr.TaskID(model.task_high + 1)
	}

	semantic_handler_swarm_first_missing_edge :: proc(model: ^Semantic_Handler_Swarm_Model) -> pr.EdgeID {
		for id in 1 ..= int(model.edge_high) do if !model.edges[id].live do return pr.EdgeID(id)
		return pr.EdgeID(model.edge_high + 1)
	}

	semantic_handler_swarm_observe_rejected_mutation :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: ^Semantic_Handler_Swarm_Model,
		ledger: ^Semantic_Handler_Swarm_Output_Ledger,
		selector: u16,
		correlation_id: u32,
		group: int,
		split_a, split_b: int,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "handler swarm rejected mutation writer missing"
		record_count_before := writer.wal.record_count
		durable_count_before := writer.wal.durable_record_count
		pending_bytes_before := writer.wal.pending_bytes
		last_hash_before := writer.wal.last_hash
		floors_before := writer.floors
		requester_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
		peer_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		expected: [256]byte
		expected_len := -1
		enqueued := false
		switch selector % 4 {
		case 0:
			req := semantic_handler_swarm_update_request(1)
			req.task_id = semantic_handler_swarm_first_missing_task(model)
			req.correlation_id = correlation_id
			if semantic_handler_swarm_entity_live(model, .Task, u64(req.task_id)) {
				return "handler swarm rejected task update selected a live task"
			}
			enqueued = semantic_transport_persistence_enqueue_update(campaign, req, split_a, split_b)
			expected_len = pr.serializeTaskListResponse(
				{conv_id = pr.WORKSPACE_DATA_ID, success = false, error = transmute([]byte)string("Task not found"), correlation_id = correlation_id},
				expected[:],
			)
		case 1:
			edge_id := semantic_handler_swarm_first_missing_edge(model)
			if int(edge_id) < len(model.edges) && model.edges[int(edge_id)].live {
				return "handler swarm rejected edge delete selected a live edge"
			}
			enqueued = semantic_handler_swarm_enqueue_delete_edge(campaign, edge_id, correlation_id, split_a, split_b)
			expected_len = pr.serializeErrorResponse(
				{origin_opcode = .C_DeleteEdge, error_msg = transmute([]byte)string("Edge not found"), correlation_id = correlation_id},
				expected[:],
			)
		case 2:
			target_id := semantic_handler_swarm_select_task(model, u8(selector))
			if target_id == 0 ||
			   !semantic_handler_swarm_entity_live(model, .Task, u64(target_id)) ||
			   semantic_handler_swarm_entity_live(model, .Task, model.task_high + 1) {
				return "handler swarm rejected edge create did not select live-target/unknown-source endpoints"
			}
			req := pr.CreateEdgeRequest {
				conv_id        = pr.WORKSPACE_DATA_ID,
				source_type    = .Task,
				source_id      = model.task_high + 1,
				target_type    = .Task,
				target_id      = u64(target_id),
				relation       = .References,
				correlation_id = correlation_id,
			}
			enqueued = semantic_transport_persistence_enqueue_create_edge(campaign, req, split_a, split_b)
			expected_len = pr.serializeErrorResponse(
				{origin_opcode = .C_CreateEdge, error_msg = transmute([]byte)string("Edge source entity not found"), correlation_id = correlation_id},
				expected[:],
			)
		case 3:
			asset_id := pr.AssetID(model.asset_high + 1)
			if u64(asset_id) != td.asset_seq + 1 || semantic_handler_swarm_entity_live(model, .Asset, u64(asset_id)) {
				return "handler swarm rejected asset create did not select the next absent self-parent"
			}
			payload := "rejected self-parent"
			req := pr.CreateAssetRequest {
				conv_id          = pr.WORKSPACE_DATA_ID,
				asset_type       = .Note,
				parent_type      = .Asset,
				parent_id        = u64(asset_id),
				payload_encoding = .Plain,
				payload_raw_len  = u32(len(payload)),
				preview          = transmute([]byte)string(`{"project":"rejected","tags":["cycle"]}`),
				payload          = transmute([]byte)payload,
				correlation_id   = correlation_id,
			}
			enqueued = semantic_transport_persistence_enqueue_create_asset(campaign, req, split_a, split_b)
			expected_len = pr.serializeErrorResponse(
				{origin_opcode = .C_CreateAsset, error_msg = transmute([]byte)string("Asset parent cycle not allowed"), correlation_id = correlation_id},
				expected[:],
			)
		}
		if !enqueued || expected_len <= 0 do return "handler swarm rejected mutation failed to enqueue"
		if !semantic_handler_swarm_output_append(ledger, .Requester, group, expected[:expected_len]) {
			return "handler swarm rejected mutation ledger failed to record"
		}
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm rejected mutation was not three-way segmented"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		matches := 0
		queued_response := writer.wal.durable_record_count < writer.wal.record_count
		if queued_response {
			payload, ok := semantic_transport_persistence_pending_payload(campaign.requester, pr.get_opcode(expected[:expected_len]))
			if ok && semantic_handler_swarm_output_payload_equal(payload, expected[:expected_len]) do matches = 1
		}
		next_frame_index := requester_frames_before
		for _ in 0 ..< (queued_response ? 0 : 32) {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
			for next_frame_index < frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, next_frame_index))
				if payload_ok && semantic_handler_swarm_output_payload_equal(payload, expected[:expected_len]) do matches += 1
				next_frame_index += 1
			}
			if matches > 0 do break
			completion_index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if completion_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, completion_index) {
				return "handler swarm rejected mutation response remained blocked"
			}
		}
		if matches != 1 ||
		   (queued_response && nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != requester_frames_before) ||
		   writer.wal.record_count != record_count_before ||
		   writer.wal.durable_record_count != durable_count_before ||
		   writer.wal.pending_bytes != pending_bytes_before ||
		   writer.wal.last_hash != last_hash_before ||
		   writer.floors != floors_before ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != peer_frames_before {
			return "handler swarm rejected mutation changed persistence, fanout, or exact response"
		}
		return semantic_handler_swarm_check(campaign, model)
	}

	semantic_handler_swarm_entity_live :: proc(model: ^Semantic_Handler_Swarm_Model, target_type: pr.TargetType, target_id: u64) -> bool {
		switch target_type {
		case .Task:
			return target_id < len(model.task_live) && model.task_live[target_id]
		case .Asset:
			return target_id < len(model.assets) && model.assets[target_id].live
		case:
			return false
		}
	}

	semantic_handler_swarm_relation_matches :: proc(relation: pr.RelationType, mask: u16) -> bool {
		if mask == 0 do return true
		value := u16(relation)
		return value >= u16(min(pr.RelationType)) && value <= u16(max(pr.RelationType)) && mask & (u16(1) << (value - 1)) != 0
	}

	semantic_handler_swarm_resolve_neighbor :: proc(
		edge: ^Semantic_Handler_Swarm_Edge,
		current: pr.GraphPathNode,
		direction: pr.Direction,
	) -> (
		pr.GraphPathNode,
		bool,
	) {
		if edge.source_type == current.target_type && edge.source_id == current.target_id && direction != .Incoming {
			return {target_type = edge.target_type, target_id = edge.target_id}, true
		}
		if edge.target_type == current.target_type && edge.target_id == current.target_id && direction != .Outgoing {
			return {target_type = edge.source_type, target_id = edge.source_id}, true
		}
		return {}, false
	}

	semantic_handler_swarm_shortest_distance :: proc(model: ^Semantic_Handler_Swarm_Model, req: ^pr.GraphShortestPathRequest) -> (distance: u8, found: bool) {
		if !semantic_handler_swarm_entity_live(model, req.from_type, req.from_id) || !semantic_handler_swarm_entity_live(model, req.to_type, req.to_id) {
			return
		}
		visited: [3][SEMANTIC_HANDLER_SWARM_MAX_TASKS]bool
		queue: [SEMANTIC_HANDLER_SWARM_MAX_TASKS + SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.GraphPathNode
		depths: [SEMANTIC_HANDLER_SWARM_MAX_TASKS + SEMANTIC_HANDLER_SWARM_MAX_ASSETS]u8
		queue[0] = {
			target_type = req.from_type,
			target_id   = req.from_id,
		}
		visited[int(req.from_type)][req.from_id] = true
		queue_count := 1
		for queue_index := 0; queue_index < queue_count; queue_index += 1 {
			current := queue[queue_index]
			depth := depths[queue_index]
			if current == (pr.GraphPathNode{target_type = req.to_type, target_id = req.to_id}) do return depth, true
			if depth >= req.max_depth do continue
			for &edge in model.edges {
				if !edge.live || !semantic_handler_swarm_relation_matches(edge.relation, req.relation_mask) do continue
				neighbor, resolved := semantic_handler_swarm_resolve_neighbor(&edge, current, req.direction)
				if !resolved || !semantic_handler_swarm_entity_live(model, neighbor.target_type, neighbor.target_id) do continue
				if visited[int(neighbor.target_type)][neighbor.target_id] do continue
				visited[int(neighbor.target_type)][neighbor.target_id] = true
				queue[queue_count] = neighbor
				depths[queue_count] = depth + 1
				queue_count += 1
			}
		}
		return
	}

	semantic_handler_swarm_neighborhood :: proc(model: ^Semantic_Handler_Swarm_Model, req: ^pr.GraphQueryRequest) -> Semantic_Handler_Swarm_Neighborhood {
		result: Semantic_Handler_Swarm_Neighborhood
		queue: [SEMANTIC_HANDLER_SWARM_MAX_TASKS + SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.GraphPathNode
		queue_depths: [SEMANTIC_HANDLER_SWARM_MAX_TASKS + SEMANTIC_HANDLER_SWARM_MAX_ASSETS]u8
		queue[0] = {
			target_type = req.start_type,
			target_id   = req.start_id,
		}
		result.visited[int(req.start_type)][req.start_id] = true
		result.node_count = 1
		queue_count := 1
		for queue_index := 0; queue_index < queue_count; queue_index += 1 {
			current := queue[queue_index]
			depth := queue_depths[queue_index]
			if depth >= req.max_depth do continue
			for &edge, edge_id in model.edges {
				if !edge.live || !semantic_handler_swarm_relation_matches(edge.relation, req.relation_mask) do continue
				neighbor, resolved := semantic_handler_swarm_resolve_neighbor(&edge, current, req.direction)
				if !resolved || !semantic_handler_swarm_entity_live(model, neighbor.target_type, neighbor.target_id) do continue
				if !result.visited[int(neighbor.target_type)][neighbor.target_id] {
					result.visited[int(neighbor.target_type)][neighbor.target_id] = true
					result.depths[int(neighbor.target_type)][neighbor.target_id] = depth + 1
					result.node_count += 1
					queue[queue_count] = neighbor
					queue_depths[queue_count] = depth + 1
					queue_count += 1
				}
				if !result.edge_present[edge_id] {
					result.edge_present[edge_id] = true
					result.edge_count += 1
				}
			}
		}
		return result
	}

	semantic_handler_swarm_neighborhood_fixture_exact :: proc(model: ^Semantic_Handler_Swarm_Model, selector: u16, node_count, edge_count: int) -> bool {
		req := semantic_handler_swarm_neighborhood_request(model, selector, 0)
		result := semantic_handler_swarm_neighborhood(model, &req)
		return result.node_count == node_count && result.edge_count == edge_count
	}

	semantic_handler_swarm_common_neighbors :: proc(
		model: ^Semantic_Handler_Swarm_Model,
		req: ^pr.GraphCommonNeighborsRequest,
	) -> Semantic_Handler_Swarm_Common_Neighbors {
		result: Semantic_Handler_Swarm_Common_Neighbors
		a := pr.GraphPathNode {
			target_type = req.a_type,
			target_id   = req.a_id,
		}
		b := pr.GraphPathNode {
			target_type = req.b_type,
			target_id   = req.b_id,
		}
		a_neighbors: [3][SEMANTIC_HANDLER_SWARM_MAX_TASKS]bool
		for &edge in model.edges {
			if !edge.live || !semantic_handler_swarm_relation_matches(edge.relation, req.relation_mask) do continue
			neighbor, resolved := semantic_handler_swarm_resolve_neighbor(&edge, a, req.direction)
			if !resolved || neighbor == b || !semantic_handler_swarm_entity_live(model, neighbor.target_type, neighbor.target_id) do continue
			a_neighbors[int(neighbor.target_type)][neighbor.target_id] = true
		}
		for &edge, edge_id in model.edges {
			if !edge.live || !semantic_handler_swarm_relation_matches(edge.relation, req.relation_mask) do continue
			neighbor, resolved := semantic_handler_swarm_resolve_neighbor(&edge, b, req.direction)
			if !resolved ||
			   !semantic_handler_swarm_entity_live(model, neighbor.target_type, neighbor.target_id) ||
			   !a_neighbors[int(neighbor.target_type)][neighbor.target_id] {
				continue
			}
			if !result.common[int(neighbor.target_type)][neighbor.target_id] {
				result.common[int(neighbor.target_type)][neighbor.target_id] = true
				result.node_count += 1
			}
			if !result.edge_present[edge_id] {
				result.edge_present[edge_id] = true
				result.edge_count += 1
			}
		}
		for &edge, edge_id in model.edges {
			if !edge.live || !semantic_handler_swarm_relation_matches(edge.relation, req.relation_mask) do continue
			neighbor, resolved := semantic_handler_swarm_resolve_neighbor(&edge, a, req.direction)
			if !resolved || !result.common[int(neighbor.target_type)][neighbor.target_id] do continue
			if !result.edge_present[edge_id] {
				result.edge_present[edge_id] = true
				result.edge_count += 1
			}
		}
		return result
	}

	semantic_handler_swarm_common_neighbors_fixture_exact :: proc(
		model: ^Semantic_Handler_Swarm_Model,
		selector: u16,
		a_type: pr.TargetType,
		a_id: u64,
		b_type: pr.TargetType,
		b_id: u64,
		direction: pr.Direction,
		relation_mask: u16,
		common_type: pr.TargetType,
		common_id: u64,
		first_edge, second_edge: pr.EdgeID,
	) -> bool {
		req := semantic_handler_swarm_common_neighbors_request(model, selector, 0)
		result := semantic_handler_swarm_common_neighbors(model, &req)
		expected_nodes := common_type != pr.TargetType(0) ? 1 : 0
		expected_edges := (first_edge != 0 ? 1 : 0) + (second_edge != 0 ? 1 : 0)
		if req.a_type != a_type ||
		   req.a_id != a_id ||
		   req.b_type != b_type ||
		   req.b_id != b_id ||
		   req.direction != direction ||
		   req.relation_mask != relation_mask ||
		   result.node_count != expected_nodes ||
		   result.edge_count != expected_edges {
			return false
		}
		for nodes, target_type in result.common {
			for present, target_id in nodes {
				expected := common_type != pr.TargetType(0) && common_type == pr.TargetType(target_type) && common_id == u64(target_id)
				if present != expected do return false
			}
		}
		for present, edge_id in result.edge_present {
			expected := (first_edge != 0 && pr.EdgeID(edge_id) == first_edge) || (second_edge != 0 && pr.EdgeID(edge_id) == second_edge)
			if present != expected do return false
		}
		return true
	}

	semantic_handler_swarm_observe_neighborhood :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: ^Semantic_Handler_Swarm_Model,
		query_selector: u16,
		correlation_id: u32,
		split_a, split_b: int,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "handler swarm neighborhood writer missing"
		record_count_before := writer.wal.record_count
		durable_count_before := writer.wal.durable_record_count
		floors_before := writer.floors
		requester_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
		peer_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		req := semantic_handler_swarm_neighborhood_request(model, query_selector, correlation_id)
		if !semantic_transport_persistence_enqueue_graph_query(campaign, req, split_a, split_b) {
			return "handler swarm neighborhood query failed to enqueue"
		}
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm neighborhood query was not three-way segmented"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		response_frame_index := -1
		queued_response := writer.wal.durable_record_count < writer.wal.record_count
		queued_payload, queued_payload_ok := semantic_transport_persistence_pending_payload(campaign.requester, .S_GraphQueryResult)
		next_frame_index := requester_frames_before
		for _ in 0 ..< (queued_response ? 0 : 32) {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
			for next_frame_index < frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, next_frame_index))
				if payload_ok && pr.get_opcode(payload) == .S_GraphQueryResult {
					nodes: [SEMANTIC_HANDLER_SWARM_MAX_TASKS + SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.GraphQueryNode
					edges: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]pr.Edge
					candidate, candidate_err := pr.parseGraphQueryResult(payload, nodes[:], edges[:])
					if candidate_err == nil && candidate.correlation_id == correlation_id {
						response_frame_index = next_frame_index
						break
					}
				}
				next_frame_index += 1
			}
			if response_frame_index >= 0 do break
			completion_index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if completion_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, completion_index) {
				return "handler swarm neighborhood response remained blocked"
			}
		}
		if (!queued_response && response_frame_index < requester_frames_before) ||
		   (queued_response && (!queued_payload_ok || nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != requester_frames_before)) ||
		   writer.wal.record_count != record_count_before ||
		   writer.wal.durable_record_count != durable_count_before ||
		   writer.floors != floors_before ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != peer_frames_before ||
		   (!queued_response && send_queue_len(campaign.requester) != 0) ||
		   (!queued_response && semantic_transport_persistence_send_completion_index(campaign, campaign.requester) < 0) {
			return "handler swarm neighborhood query mutated state or fanout"
		}

		payload, payload_ok := queued_payload, queued_payload_ok
		if !queued_response do payload, payload_ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, response_frame_index))
		nodes: [SEMANTIC_HANDLER_SWARM_MAX_TASKS + SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.GraphQueryNode
		edges: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]pr.Edge
		result, parse_err := pr.parseGraphQueryResult(payload, nodes[:], edges[:])
		expected := semantic_handler_swarm_neighborhood(model, &req)
		if !payload_ok ||
		   parse_err != nil ||
		   result.conv_id != req.conv_id ||
		   result.start_type != req.start_type ||
		   result.start_id != req.start_id ||
		   result.truncated ||
		   result.correlation_id != req.correlation_id ||
		   len(result.nodes) != expected.node_count ||
		   len(result.edges) != expected.edge_count {
			return "handler swarm neighborhood response metadata differs from model"
		}
		seen_nodes: [3][SEMANTIC_HANDLER_SWARM_MAX_TASKS]bool
		for node in result.nodes {
			if int(node.target_type) >= len(seen_nodes) ||
			   node.target_id >= len(seen_nodes[int(node.target_type)]) ||
			   !expected.visited[int(node.target_type)][node.target_id] ||
			   node.depth != expected.depths[int(node.target_type)][node.target_id] ||
			   seen_nodes[int(node.target_type)][node.target_id] {
				return "handler swarm neighborhood node depths differ from model"
			}
			seen_nodes[int(node.target_type)][node.target_id] = true
		}
		seen_edges: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]bool
		for &edge in result.edges {
			if edge.edge_id == 0 ||
			   int(edge.edge_id) >= len(model.edges) ||
			   !expected.edge_present[int(edge.edge_id)] ||
			   seen_edges[int(edge.edge_id)] ||
			   !semantic_handler_swarm_edge_exact(&edge, edge.edge_id, &model.edges[int(edge.edge_id)]) {
				return "handler swarm neighborhood edge set differs from model"
			}
			seen_edges[int(edge.edge_id)] = true
		}
		return semantic_handler_swarm_check(campaign, model)
	}

	semantic_handler_swarm_observe_common_neighbors :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: ^Semantic_Handler_Swarm_Model,
		query_selector: u16,
		correlation_id: u32,
		split_a, split_b: int,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "handler swarm common-neighbor writer missing"
		record_count_before := writer.wal.record_count
		durable_count_before := writer.wal.durable_record_count
		floors_before := writer.floors
		requester_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
		peer_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		req := semantic_handler_swarm_common_neighbors_request(model, query_selector, correlation_id)
		if !semantic_transport_persistence_enqueue_common_neighbors(campaign, req, split_a, split_b) {
			return "handler swarm common-neighbor query failed to enqueue"
		}
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm common-neighbor query was not three-way segmented"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		response_frame_index := -1
		queued_response := writer.wal.durable_record_count < writer.wal.record_count
		queued_payload, queued_payload_ok := semantic_transport_persistence_pending_payload(campaign.requester, .S_GraphCommonNeighborsResult)
		next_frame_index := requester_frames_before
		for _ in 0 ..< (queued_response ? 0 : 32) {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
			for next_frame_index < frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, next_frame_index))
				if payload_ok && pr.get_opcode(payload) == .S_GraphCommonNeighborsResult {
					nodes: [SEMANTIC_HANDLER_SWARM_MAX_TASKS + SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.GraphPathNode
					edges: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]pr.Edge
					candidate, candidate_err := pr.parseGraphCommonNeighborsResult(payload, nodes[:], edges[:])
					if candidate_err == nil && candidate.correlation_id == correlation_id {
						response_frame_index = next_frame_index
						break
					}
				}
				next_frame_index += 1
			}
			if response_frame_index >= 0 do break
			completion_index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if completion_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, completion_index) {
				return "handler swarm common-neighbor response remained blocked"
			}
		}
		if (!queued_response && response_frame_index < requester_frames_before) ||
		   (queued_response && (!queued_payload_ok || nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != requester_frames_before)) ||
		   writer.wal.record_count != record_count_before ||
		   writer.wal.durable_record_count != durable_count_before ||
		   writer.floors != floors_before ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != peer_frames_before ||
		   (!queued_response && send_queue_len(campaign.requester) != 0) ||
		   (!queued_response && semantic_transport_persistence_send_completion_index(campaign, campaign.requester) < 0) {
			return "handler swarm common-neighbor query mutated state or fanout"
		}

		payload, payload_ok := queued_payload, queued_payload_ok
		if !queued_response do payload, payload_ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, response_frame_index))
		nodes: [SEMANTIC_HANDLER_SWARM_MAX_TASKS + SEMANTIC_HANDLER_SWARM_MAX_ASSETS]pr.GraphPathNode
		edges: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]pr.Edge
		result, parse_err := pr.parseGraphCommonNeighborsResult(payload, nodes[:], edges[:])
		expected := semantic_handler_swarm_common_neighbors(model, &req)
		if !payload_ok ||
		   parse_err != nil ||
		   result.conv_id != req.conv_id ||
		   result.a_type != req.a_type ||
		   result.a_id != req.a_id ||
		   result.b_type != req.b_type ||
		   result.b_id != req.b_id ||
		   result.correlation_id != req.correlation_id ||
		   len(result.nodes) != expected.node_count ||
		   len(result.edges) != expected.edge_count {
			return "handler swarm common-neighbor response metadata differs from model"
		}
		seen_nodes: [3][SEMANTIC_HANDLER_SWARM_MAX_TASKS]bool
		for node in result.nodes {
			if int(node.target_type) >= len(seen_nodes) ||
			   node.target_id >= len(seen_nodes[int(node.target_type)]) ||
			   !expected.common[int(node.target_type)][node.target_id] ||
			   seen_nodes[int(node.target_type)][node.target_id] {
				return "handler swarm common-neighbor node set differs from model"
			}
			seen_nodes[int(node.target_type)][node.target_id] = true
		}
		seen_edges: [SEMANTIC_HANDLER_SWARM_MAX_EDGES]bool
		for &edge in result.edges {
			if edge.edge_id == 0 ||
			   int(edge.edge_id) >= len(model.edges) ||
			   !expected.edge_present[int(edge.edge_id)] ||
			   seen_edges[int(edge.edge_id)] ||
			   !semantic_handler_swarm_edge_exact(&edge, edge.edge_id, &model.edges[int(edge.edge_id)]) {
				return "handler swarm common-neighbor edge set differs from model"
			}
			seen_edges[int(edge.edge_id)] = true
		}
		return semantic_handler_swarm_check(campaign, model)
	}

	semantic_handler_swarm_observe_task_page :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: ^Semantic_Handler_Swarm_Model,
		query_selector: u16,
		correlation_id: u32,
		split_a, split_b: int,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "handler swarm task-page writer missing"
		record_count_before := writer.wal.record_count
		durable_count_before := writer.wal.durable_record_count
		floors_before := writer.floors
		requester_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
		peer_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		req := semantic_handler_swarm_task_page_request(model, query_selector, correlation_id)
		if !semantic_transport_persistence_enqueue_task_page(campaign, req, split_a, split_b) {
			return "handler swarm task-page query failed to enqueue"
		}
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm task-page query was not three-way segmented"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		response_frame_index := -1
		queued_response := writer.wal.durable_record_count < writer.wal.record_count
		queued_payload, queued_payload_ok := semantic_transport_persistence_pending_payload(campaign.requester, .S_TaskListPage)
		next_frame_index := requester_frames_before
		for _ in 0 ..< (queued_response ? 0 : 32) {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
			for next_frame_index < frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, next_frame_index))
				if payload_ok && pr.get_opcode(payload) == .S_TaskListPage {
					tasks: [SEMANTIC_HANDLER_SWARM_MAX_TASKS]pr.Task
					attachments: [SEMANTIC_HANDLER_SWARM_MAX_TASKS * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
					candidate, candidate_err := pr.parseTaskListPage(payload, tasks[:], attachments[:])
					if candidate_err == nil && candidate.correlation_id == correlation_id {
						response_frame_index = next_frame_index
						break
					}
				}
				next_frame_index += 1
			}
			if response_frame_index >= 0 do break
			completion_index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if completion_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, completion_index) {
				return "handler swarm task-page response remained blocked"
			}
		}
		if (!queued_response && response_frame_index < requester_frames_before) ||
		   (queued_response && (!queued_payload_ok || nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != requester_frames_before)) ||
		   writer.wal.record_count != record_count_before ||
		   writer.wal.durable_record_count != durable_count_before ||
		   writer.floors != floors_before ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != peer_frames_before ||
		   (!queued_response && send_queue_len(campaign.requester) != 0) ||
		   (!queued_response && semantic_transport_persistence_send_completion_index(campaign, campaign.requester) < 0) {
			return "handler swarm task-page query mutated state or fanout"
		}

		payload, payload_ok := queued_payload, queued_payload_ok
		if !queued_response do payload, payload_ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, response_frame_index))
		tasks: [SEMANTIC_HANDLER_SWARM_MAX_TASKS]pr.Task
		attachments: [SEMANTIC_HANDLER_SWARM_MAX_TASKS * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		result, parse_err := pr.parseTaskListPage(payload, tasks[:], attachments[:])
		expected := semantic_handler_swarm_task_page(model, &req)
		if !payload_ok ||
		   parse_err != nil ||
		   result.conv_id != req.conv_id ||
		   !result.success ||
		   len(result.error) != 0 ||
		   result.correlation_id != req.correlation_id ||
		   len(result.tasks) != expected.count ||
		   result.has_more != expected.has_more ||
		   result.next_cursor_sort_at != expected.next_cursor_sort_at ||
		   result.next_cursor_task_id != expected.next_cursor_task_id ||
		   result.total_count != expected.total_count {
			return "handler swarm task-page response metadata differs from model"
		}
		for &task, index in result.tasks {
			expected_id := expected.ids[index]
			if task.id != expected_id || !semantic_handler_swarm_task_exact(model, int(expected_id), &task) {
				return "handler swarm task-page ordering or task payload differs from model"
			}
		}
		return semantic_handler_swarm_check(campaign, model)
	}

	semantic_handler_swarm_enqueue_note_page :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		req: ^Semantic_Handler_Swarm_Note_Page_Request,
		split_a, split_b: int,
	) -> bool {
		request_buf: [128]byte
		request_len := -1
		switch req.scope {
		case .Global:
			request_len = pr.serializeListAssetsPagedRequest(
				pr.WORKSPACE_DATA_ID,
				.Note,
				true,
				req.limit,
				req.has_cursor,
				req.cursor_updated_at,
				req.cursor_asset_id,
				request_buf[:],
				req.correlation_id,
			)
		case .Project:
			request_len = pr.serializeListAssetsPagedByProjectRequest(
				pr.WORKSPACE_DATA_ID,
				.Note,
				true,
				req.limit,
				req.has_cursor,
				req.cursor_updated_at,
				req.cursor_asset_id,
				req.filter,
				request_buf[:],
				req.correlation_id,
			)
		case .Tag:
			request_len = pr.serializeListAssetsPagedByTagRequest(
				pr.WORKSPACE_DATA_ID,
				.Note,
				true,
				req.limit,
				req.has_cursor,
				req.cursor_updated_at,
				req.cursor_asset_id,
				req.filter,
				request_buf[:],
				req.correlation_id,
			)
		}
		if request_len <= 0 do return false
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		interior_count := len(frame) - 1
		first := 1 + split_a % interior_count
		second := 1 + split_b % interior_count
		if first == second do second = 1 + second % interior_count
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			if !nrc_sim_enqueue_receive(&campaign.ctx.sim, campaign.requester, frame[boundaries[index]:boundaries[index + 1]]) do return false
		}
		return true
	}

	semantic_handler_swarm_observe_note_page :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: ^Semantic_Handler_Swarm_Model,
		query_selector: u16,
		correlation_id: u32,
		split_a, split_b: int,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "handler swarm Note-page writer missing"
		record_count_before := writer.wal.record_count
		durable_count_before := writer.wal.durable_record_count
		floors_before := writer.floors
		requester_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
		peer_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		req := semantic_handler_swarm_note_page_request(model, query_selector, correlation_id)
		if !semantic_handler_swarm_enqueue_note_page(campaign, &req, split_a, split_b) do return "handler swarm Note-page query failed to enqueue"
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm Note-page query was not three-way segmented"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		response_frame_index := -1
		queued_response := writer.wal.durable_record_count < writer.wal.record_count
		queued_payload, queued_payload_ok := semantic_transport_persistence_pending_payload(campaign.requester, .S_AssetListPage)
		next_frame_index := requester_frames_before
		attachments: [SEMANTIC_HANDLER_SWARM_MAX_ASSETS * pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
		for _ in 0 ..< (queued_response ? 0 : 32) {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
			for next_frame_index < frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, next_frame_index))
				if payload_ok && pr.get_opcode(payload) == .S_AssetListPage {
					candidate, candidate_err := pr.parseAssetListPageMessage(payload, attachments = attachments[:])
					matches := candidate_err == nil && candidate.correlation_id == correlation_id
					if len(candidate.assets) > 0 do delete(candidate.assets)
					if matches {
						response_frame_index = next_frame_index
						break
					}
				}
				next_frame_index += 1
			}
			if response_frame_index >= 0 do break
			completion_index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if completion_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, completion_index) {
				return "handler swarm Note-page response remained blocked"
			}
		}
		if (!queued_response && response_frame_index < requester_frames_before) ||
		   (queued_response && (!queued_payload_ok || nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != requester_frames_before)) ||
		   writer.wal.record_count != record_count_before ||
		   writer.wal.durable_record_count != durable_count_before ||
		   writer.floors != floors_before ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != peer_frames_before ||
		   (!queued_response && send_queue_len(campaign.requester) != 0) ||
		   (!queued_response && semantic_transport_persistence_send_completion_index(campaign, campaign.requester) < 0) {
			return "handler swarm Note-page query mutated state or fanout"
		}
		payload, payload_ok := queued_payload, queued_payload_ok
		if !queued_response do payload, payload_ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, response_frame_index))
		result, parse_err := pr.parseAssetListPageMessage(payload, attachments = attachments[:])
		defer if len(result.assets) > 0 do delete(result.assets)
		expected := semantic_handler_swarm_note_page(model, &req)
		if !payload_ok ||
		   parse_err != nil ||
		   result.conv_id != pr.WORKSPACE_DATA_ID ||
		   !result.full_content ||
		   result.correlation_id != req.correlation_id ||
		   len(result.assets) != expected.count ||
		   result.has_more != expected.has_more ||
		   result.next_cursor_updated_at != expected.next_cursor_updated_at ||
		   result.next_cursor_asset_id != expected.next_cursor_asset_id ||
		   result.total_count != expected.total_count {
			return fmt.tprintf(
				"handler swarm Note-page response metadata differs from model: scope=%v filter=%s cursor=%v:(%d,%d) count=%d/%d more=%v/%v next=(%d,%d)/(%d,%d) total=%d/%d",
				req.scope,
				req.filter,
				req.has_cursor,
				req.cursor_updated_at,
				req.cursor_asset_id,
				len(result.assets),
				expected.count,
				result.has_more,
				expected.has_more,
				result.next_cursor_updated_at,
				result.next_cursor_asset_id,
				expected.next_cursor_updated_at,
				expected.next_cursor_asset_id,
				result.total_count,
				expected.total_count,
			)
		}
		for &asset, index in result.assets {
			expected_id := expected.ids[index]
			if asset.asset_id != expected_id || !semantic_handler_swarm_asset_exact(&asset, expected_id, &model.assets[int(expected_id)]) {
				return "handler swarm Note-page ordering or asset payload differs from model"
			}
		}
		return semantic_handler_swarm_check(campaign, model)
	}

	semantic_handler_swarm_observe_shortest_path :: proc(
		campaign: ^Semantic_Transport_Persistence_Campaign,
		model: ^Semantic_Handler_Swarm_Model,
		query_selector: u16,
		correlation_id: u32,
		split_a, split_b: int,
	) -> string {
		writer := semantic_transport_persistence_writer(campaign)
		if writer == nil do return "handler swarm query writer missing"
		record_count_before := writer.wal.record_count
		durable_count_before := writer.wal.durable_record_count
		floors_before := writer.floors
		requester_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
		peer_frames_before := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock)
		req := semantic_handler_swarm_query_request(model, query_selector, correlation_id)
		if !semantic_transport_persistence_enqueue_shortest_path(campaign, req, split_a, split_b) {
			return "handler swarm shortest-path query failed to enqueue"
		}
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm shortest-path query was not three-way segmented"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		response_frame_index := -1
		queued_response := writer.wal.durable_record_count < writer.wal.record_count
		queued_payload, queued_payload_ok := semantic_transport_persistence_pending_payload(campaign.requester, .S_GraphShortestPathResult)
		next_frame_index := requester_frames_before
		for _ in 0 ..< (queued_response ? 0 : 32) {
			frame_count := nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock)
			for next_frame_index < frame_count {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, next_frame_index))
				if payload_ok && pr.get_opcode(payload) == .S_GraphShortestPathResult {
					nodes: [5]pr.GraphPathNode
					edges: [4]pr.Edge
					candidate, candidate_err := pr.parseGraphShortestPathResult(payload, nodes[:], edges[:])
					if candidate_err == nil && candidate.correlation_id == correlation_id {
						response_frame_index = next_frame_index
						break
					}
				}
				next_frame_index += 1
			}
			if response_frame_index >= 0 do break
			completion_index := semantic_transport_persistence_send_completion_index(campaign, campaign.requester)
			if completion_index < 0 || !nrc_sim_run_send_completion_at(&campaign.ctx.sim, completion_index) {
				return "handler swarm shortest-path response remained blocked"
			}
		}
		if (!queued_response && response_frame_index < requester_frames_before) ||
		   (queued_response && (!queued_payload_ok || nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.requester.sock) != requester_frames_before)) ||
		   writer.wal.record_count != record_count_before ||
		   writer.wal.durable_record_count != durable_count_before ||
		   writer.floors != floors_before ||
		   nrc_sim_client_frame_count(&campaign.ctx.sim, campaign.peer.sock) != peer_frames_before ||
		   (!queued_response && semantic_transport_persistence_send_completion_index(campaign, campaign.requester) < 0) {
			return "handler swarm shortest-path query mutated state or fanout"
		}
		payload, payload_ok := queued_payload, queued_payload_ok
		if !queued_response do payload, payload_ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&campaign.ctx.sim, campaign.requester.sock, response_frame_index))
		nodes: [5]pr.GraphPathNode
		edges: [4]pr.Edge
		result, parse_err := pr.parseGraphShortestPathResult(payload, nodes[:], edges[:])
		expected_distance, expected_found := semantic_handler_swarm_shortest_distance(model, &req)
		expected_nodes := expected_found ? int(expected_distance) + 1 : 0
		if !payload_ok ||
		   parse_err != nil ||
		   result.conv_id != pr.WORKSPACE_DATA_ID ||
		   result.from_type != req.from_type ||
		   result.from_id != req.from_id ||
		   result.to_type != req.to_type ||
		   result.to_id != req.to_id ||
		   result.found != expected_found ||
		   result.path_length != expected_distance ||
		   result.correlation_id != correlation_id ||
		   len(result.nodes) != expected_nodes ||
		   len(result.edges) != int(expected_distance) {
			return "handler swarm shortest-path response differs from model distance"
		}
		if expected_found {
			if result.nodes[0] != (pr.GraphPathNode{target_type = req.from_type, target_id = req.from_id}) ||
			   result.nodes[len(result.nodes) - 1] != (pr.GraphPathNode{target_type = req.to_type, target_id = req.to_id}) {
				return "handler swarm shortest-path endpoints differ from model"
			}
			for node, index in result.nodes {
				if !semantic_handler_swarm_entity_live(model, node.target_type, node.target_id) do return "handler swarm shortest-path contains deleted node"
				for prior in result.nodes[:index] do if node == prior do return "handler swarm shortest-path repeats a node"
			}
			for &edge, index in result.edges {
				if edge.edge_id == 0 || int(edge.edge_id) >= len(model.edges) {
					return "handler swarm shortest-path contains unknown edge"
				}
				current := result.nodes[index]
				next := result.nodes[index + 1]
				resolved, resolves := semantic_handler_swarm_resolve_neighbor(&model.edges[int(edge.edge_id)], current, req.direction)
				if !model.edges[int(edge.edge_id)].live ||
				   !semantic_handler_swarm_relation_matches(edge.relation, req.relation_mask) ||
				   !semantic_handler_swarm_edge_exact(&edge, edge.edge_id, &model.edges[int(edge.edge_id)]) ||
				   !resolves ||
				   resolved != next {
					return "handler swarm shortest-path sequence violates query filters"
				}
			}
		}
		return semantic_handler_swarm_check(campaign, model)
	}

	semantic_handler_swarm_setup :: proc(campaign: ^Semantic_Transport_Persistence_Campaign, choices: []u8) -> string {
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		task_two := semantic_multihop_task_two_create()
		payload := "owned cascade"
		asset := pr.CreateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_type       = .Document,
			parent_type      = .Task,
			parent_id        = 1,
			payload_encoding = .Plain,
			payload_raw_len  = u32(len(payload)),
			preview          = transmute([]byte)payload,
			payload          = transmute([]byte)payload,
			correlation_id   = 0xDE01,
		}
		edge_one := pr.CreateEdgeRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			source_type    = .Task,
			source_id      = 1,
			target_type    = .Asset,
			target_id      = 1,
			relation       = .References,
			correlation_id = 0xDE02,
		}
		edge_two := pr.CreateEdgeRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			source_type    = .Asset,
			source_id      = 1,
			target_type    = .Task,
			target_id      = 2,
			relation       = .References,
			correlation_id = 0xDE03,
		}
		requests_ok := semantic_transport_persistence_enqueue_create(
			campaign,
			task_two,
			semantic_multihop_split(choices[2], false),
			semantic_multihop_split(choices[3], true),
		)
		if !requests_ok || nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm second task setup failed"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		requests_ok = semantic_transport_persistence_enqueue_create_asset(
			campaign,
			asset,
			semantic_multihop_split(choices[4], false),
			semantic_multihop_split(choices[5], true),
		)
		if !requests_ok || nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm asset setup failed"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		requests_ok = semantic_transport_persistence_enqueue_create_edge(
			campaign,
			edge_one,
			semantic_multihop_split(choices[6], false),
			semantic_multihop_split(choices[7], true),
		)
		if !requests_ok || nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm first edge setup failed"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		requests_ok = semantic_transport_persistence_enqueue_create_edge(
			campaign,
			edge_two,
			semantic_multihop_split(choices[8], false),
			semantic_multihop_split(choices[9], true),
		)
		if !requests_ok || nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm second edge setup failed"
		nrc_sim_run_all_receives(&campaign.ctx.sim)
		return ""
	}

	// Filter the distribution against the reference model, never server state.
	semantic_handler_swarm_available_weights :: proc(
		model: ^Semantic_Handler_Swarm_Model,
		weights: []int,
	) -> (
		available: [len(Semantic_Handler_Swarm_Kind)]int,
		total: int,
	) {
		for weight, index in weights {
			possible := true
			switch Semantic_Handler_Swarm_Kind(index) {
			case .Update_Task, .Move_Task:
				possible = semantic_handler_swarm_live_task_count(model) > 0
			case .Delete_Task:
				possible = semantic_handler_swarm_live_task_count(model) > 1
			case .Delete_Asset, .Update_Asset:
				possible = semantic_handler_swarm_select_asset(model, 0) != 0
			case .Delete_Edge:
				possible = semantic_handler_swarm_select_edge(model, 0) != 0
			case .Create_Task:
				possible = model.task_high + 1 < len(model.task_live)
			case .Create_Asset:
				possible = model.asset_high + 1 < len(model.assets)
			case .Create_Edge:
				possible = model.edge_high + 1 < len(model.edges) && semantic_handler_swarm_live_entity_count(model) >= 2
			}
			if possible {
				available[index] = weight
				total += weight
			}
		}
		return
	}

	semantic_handler_swarm_run :: proc(
		input_ops: []Semantic_Handler_Swarm_Op,
		requested_durable_after: int,
		counts: ^Semantic_Handler_Swarm_Counts = nil,
		weights: []int = nil,
		trace_execution: bool = false,
	) -> string {
		ops := input_ops
		durable_after := requested_durable_after
		attempted := 0
		defer {
			if trace_execution do fmt.eprintf("handler swarm execution: effective_length=%d effective_durable_after=%d attempted_ops=%v\n", len(ops), durable_after, ops[:attempted])
		}
		if len(ops) < 1 || len(ops) > SEMANTIC_HANDLER_SWARM_MAX_OPS || durable_after < 0 || durable_after > len(ops) {
			return "handler swarm choices are incomplete"
		}
		campaign: Semantic_Transport_Persistence_Campaign
		base_choices: [10]u8
		for index in 0 ..< min(len(ops), 5) {
			base_choices[index * 2] = ops[index].split_a
			base_choices[index * 2 + 1] = ops[index].split_b
		}
		diagnostic := semantic_transport_persistence_campaign_begin(
			&campaign,
			"handler-graph-swarm",
			semantic_multihop_split(base_choices[0], false),
			semantic_multihop_split(base_choices[1], true),
			virtual_storage = true,
		)
		defer semantic_transport_persistence_campaign_end(&campaign)
		defer shard_replay_state_destroy()
		if diagnostic != "" do return diagnostic
		if nrc_sim_receive_event_count(&campaign.ctx.sim) != 3 do return "handler swarm foundation was not segmented"
		if diagnostic = semantic_handler_swarm_setup(&campaign, base_choices[:]); diagnostic != "" do return diagnostic
		writer := semantic_transport_persistence_writer(&campaign)
		model := semantic_handler_swarm_initial_model()
		if writer == nil || writer.wal.record_count + writer.wal.buffered_record_count != 5 do return "handler swarm foundation WAL differs"
		if diagnostic = semantic_handler_swarm_check(&campaign, &model); diagnostic != "" do return diagnostic
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != 5 {
			return "handler swarm foundation fsync failed"
		}
		if diagnostic = semantic_handler_swarm_observe_shortest_path(&campaign, &model, 60, 0xDEFF, semantic_multihop_split(base_choices[8], false), semantic_multihop_split(base_choices[9], true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_neighborhood(&campaign, &model, 60, 0xEEFF, semantic_multihop_split(base_choices[9], false), semantic_multihop_split(base_choices[8], true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_common_neighbors(&campaign, &model, 0, 0xFEFF, semantic_multihop_split(base_choices[8], false), semantic_multihop_split(base_choices[9], true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_task_page(&campaign, &model, 0, 0xBEFF, semantic_multihop_split(base_choices[9], false), semantic_multihop_split(base_choices[8], true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_note_page(&campaign, &model, 0, 0xAEFF, semantic_multihop_split(base_choices[8], false), semantic_multihop_split(base_choices[9], true)); diagnostic != "" do return diagnostic
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		ledger: Semantic_Handler_Swarm_Output_Ledger
		semantic_handler_swarm_output_ledger_init(&ledger)
		defer semantic_handler_swarm_output_ledger_destroy(&ledger)

		models: [SEMANTIC_HANDLER_SWARM_MAX_OPS + 1]Semantic_Handler_Swarm_Model
		models[0] = model
		fsync_submitted := false
		if durable_after == 0 {
			fsync_submitted = true
		}
		for op_index := 0; op_index < len(ops); op_index += 1 {
			if len(weights) > 0 {
				available, total := semantic_handler_swarm_available_weights(&model, weights)
				if total == 0 do return "handler swarm has no initial enabled operation"
				ops[op_index].kind = semantic_handler_swarm_pick_kind(available[:], ops[op_index].kind_ticket % total)
			}
			op := ops[op_index]
			attempted = op_index + 1
			if durable_after > 0 && fsync_submitted && op_index >= durable_after && !writer.fsync_in_flight {
				return "handler swarm selected-prefix fsync did not overlap later mutation"
			}
			if diagnostic = semantic_handler_swarm_apply(&campaign, &model, &ledger, op, op_index, counts); diagnostic != "" do return diagnostic
			models[op_index + 1] = model
			if len(weights) > 0 {
				_, remaining := semantic_handler_swarm_available_weights(&model, weights)
				if remaining == 0 {
					ops = ops[:op_index + 1]
					durable_after = min(durable_after, len(ops))
				}
			}
			if diagnostic = semantic_handler_swarm_observe_rejected_mutation(&campaign, &model, &ledger, op.query_selector, 0xA000 + u32(op_index), op_index * 2 + 1, semantic_multihop_split(op.split_b, false), semantic_multihop_split(op.split_a, true)); diagnostic != "" do return diagnostic
			if diagnostic = semantic_handler_swarm_observe_shortest_path(&campaign, &model, op.query_selector, 0xDF00 + u32(op_index), semantic_multihop_split(op.split_b, false), semantic_multihop_split(op.split_a, true)); diagnostic != "" do return diagnostic
			if diagnostic = semantic_handler_swarm_observe_neighborhood(&campaign, &model, op.query_selector, 0xEF00 + u32(op_index), semantic_multihop_split(op.split_a, false), semantic_multihop_split(op.split_b, true)); diagnostic != "" do return diagnostic
			if diagnostic = semantic_handler_swarm_observe_common_neighbors(&campaign, &model, op.query_selector, 0xFF00 + u32(op_index), semantic_multihop_split(op.split_b, false), semantic_multihop_split(op.split_a, true)); diagnostic != "" do return diagnostic
			if diagnostic = semantic_handler_swarm_observe_task_page(&campaign, &model, op.query_selector, 0xBF00 + u32(op_index), semantic_multihop_split(op.split_a, false), semantic_multihop_split(op.split_b, true)); diagnostic != "" do return diagnostic
			if diagnostic = semantic_handler_swarm_observe_note_page(&campaign, &model, op.query_selector, 0xAF00 + u32(op_index), semantic_multihop_split(op.split_b, false), semantic_multihop_split(op.split_a, true)); diagnostic != "" do return diagnostic
			if durable_after > 0 && fsync_submitted && op_index >= durable_after && !writer.fsync_in_flight {
				return "handler swarm selected-prefix fsync did not overlap later queries"
			}
			if op_index + 1 == durable_after {
				writer.commit_started = {}
				did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
				if !sync_ok || !did_work || !writer.fsync_in_flight || writer.fsync_snapshot.record_count != u64(5 + durable_after) {
					return "handler swarm selected-prefix fsync submission failed"
				}
				fsync_submitted = true
			}
		}
		if !fsync_submitted do return "handler swarm selected-prefix fsync was not submitted"
		if durable_after > 0 && (!nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != u64(5 + durable_after)) {
			return "handler swarm selected-prefix fsync completion failed"
		}
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if diagnostic = semantic_handler_swarm_output_check(&campaign, &ledger); diagnostic != "" do return diagnostic
		semantic_handler_swarm_output_ledger_destroy(&ledger)
		semantic_handler_swarm_output_ledger_init(&ledger)
		expected := models[durable_after]
		expected_records := u64(5 + durable_after)
		floors, replay_ok, crash_diagnostic := semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		if !replay_ok ||
		   writer == nil ||
		   floors != (Shard_High_Water_Requirements{task = expected.task_high, asset = expected.asset_high, edge = expected.edge_high}) ||
		   writer.wal.record_count != expected_records ||
		   writer.wal.durable_record_count != expected_records {
			return "handler swarm recovery differs from selected durable prefix"
		}
		if diagnostic = semantic_handler_swarm_check(&campaign, &expected); diagnostic != "" do return diagnostic
		if !semantic_multihop_install_clients(&campaign) do return "handler swarm recovered query clients failed"
		recovered_query := ops[durable_after % len(ops)]
		if diagnostic = semantic_handler_swarm_observe_shortest_path(&campaign, &expected, recovered_query.query_selector, 0xDFFE, semantic_multihop_split(recovered_query.split_a, false), semantic_multihop_split(recovered_query.split_b, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_neighborhood(&campaign, &expected, recovered_query.query_selector, 0xEFFE, semantic_multihop_split(recovered_query.split_b, false), semantic_multihop_split(recovered_query.split_a, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_common_neighbors(&campaign, &expected, recovered_query.query_selector, 0xFFFE, semantic_multihop_split(recovered_query.split_a, false), semantic_multihop_split(recovered_query.split_b, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_task_page(&campaign, &expected, recovered_query.query_selector, 0xBFFE, semantic_multihop_split(recovered_query.split_b, false), semantic_multihop_split(recovered_query.split_a, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_note_page(&campaign, &expected, recovered_query.query_selector, 0xAFFE, semantic_multihop_split(recovered_query.split_a, false), semantic_multihop_split(recovered_query.split_b, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_rejected_mutation(&campaign, &expected, &ledger, recovered_query.query_selector, 0xA0FE, 0, semantic_multihop_split(recovered_query.split_b, false), semantic_multihop_split(recovered_query.split_a, true)); diagnostic != "" do return diagnostic
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if diagnostic = semantic_handler_swarm_output_check(&campaign, &ledger); diagnostic != "" do return diagnostic
		nrc_sim_clear_inboxes(&campaign.ctx.sim)
		semantic_handler_swarm_output_ledger_destroy(&ledger)
		semantic_handler_swarm_output_ledger_init(&ledger)
		continuation := Semantic_Handler_Swarm_Op {
			kind     = .Update_Task,
			selector = ops[len(ops) - 1].selector,
			split_a  = ops[len(ops) - 1].split_b,
			split_b  = ops[0].split_a,
		}
		if diagnostic = semantic_handler_swarm_apply(&campaign, &expected, &ledger, continuation, len(ops)); diagnostic != "" do return diagnostic
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work || !nrc_sim_run_next_fsync_completion(&campaign.ctx.sim) || writer.wal.durable_record_count != expected_records + 1 {
			return "handler swarm continuation fsync failed"
		}
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if diagnostic = semantic_handler_swarm_output_check(&campaign, &ledger); diagnostic != "" do return diagnostic
		floors, replay_ok, crash_diagnostic = semantic_transport_persistence_virtual_crash_reopen(&campaign)
		if crash_diagnostic != "" do return crash_diagnostic
		writer = semantic_transport_persistence_writer(&campaign)
		if !replay_ok || writer == nil || writer.wal.record_count != expected_records + 1 || writer.wal.durable_record_count != expected_records + 1 {
			return "handler swarm second recovery differs from continuation"
		}
		if diagnostic = semantic_handler_swarm_check(&campaign, &expected); diagnostic != "" do return diagnostic
		if !semantic_multihop_install_clients(&campaign) do return "handler swarm final query clients failed"
		if diagnostic = semantic_handler_swarm_observe_shortest_path(&campaign, &expected, ops[len(ops) - 1].query_selector, 0xDFFF, semantic_multihop_split(ops[0].split_b, false), semantic_multihop_split(ops[len(ops) - 1].split_a, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_neighborhood(&campaign, &expected, ops[len(ops) - 1].query_selector, 0xEFFF, semantic_multihop_split(ops[len(ops) - 1].split_b, false), semantic_multihop_split(ops[0].split_a, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_common_neighbors(&campaign, &expected, ops[len(ops) - 1].query_selector, 0xFFFF, semantic_multihop_split(ops[0].split_a, false), semantic_multihop_split(ops[len(ops) - 1].split_b, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_task_page(&campaign, &expected, ops[len(ops) - 1].query_selector, 0xBFFF, semantic_multihop_split(ops[len(ops) - 1].split_a, false), semantic_multihop_split(ops[0].split_b, true)); diagnostic != "" do return diagnostic
		if diagnostic = semantic_handler_swarm_observe_note_page(&campaign, &expected, ops[len(ops) - 1].query_selector, 0xAFFF, semantic_multihop_split(ops[0].split_a, false), semantic_multihop_split(ops[len(ops) - 1].split_b, true)); diagnostic != "" do return diagnostic
		nrc_sim_run_all_send_completions(&campaign.ctx.sim)
		if connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before ||
		   td.spool.invalid_release_count != campaign.invalid_releases_before {
			return "handler swarm final query did not release pooled ownership"
		}
		return ""
	}

	// A ticket selects a half-open weight interval; zero-weight kinds are disabled.
	semantic_handler_swarm_pick_kind :: proc(weights: []int, ticket: int) -> Semantic_Handler_Swarm_Kind {
		remaining := ticket
		for weight, index in weights {
			if remaining < weight do return Semantic_Handler_Swarm_Kind(index)
			remaining -= weight
		}
		unreachable()
	}

	prop_semantic_handler_swarm :: proc(tc: ^hgl.Test_Case, user_data: rawptr) -> hgl.Body_Result {
		// Choose the distribution once per history, so repeated operations and
		// small feature combinations are common rather than diluted by all kinds.
		// One randomly chosen kind is always enabled (including singleton swarms).
		// The runner filters these weights against the evolving reference model.
		weights: [len(Semantic_Handler_Swarm_Kind)]int
		anchor, anchor_err := hgl.draw_i64(tc, 0, i64(len(weights) - 1))
		if anchor_err == .Stop_Test do return hgl.abort()
		if anchor_err != nil do return hgl.interesting("draw handler swarm anchor")
		for &weight, index in weights {
			enabled, enabled_err := hgl.draw_i64(tc, 0, 1)
			if enabled_err == .Stop_Test do return hgl.abort()
			if enabled_err != nil do return hgl.interesting("draw handler swarm enabled kind")
			if enabled == 0 && index != int(anchor) do continue
			raw_weight, weight_err := hgl.draw_i64(tc, 1, 100)
			if weight_err == .Stop_Test do return hgl.abort()
			if weight_err != nil do return hgl.interesting("draw handler swarm weight")
			weight = int(raw_weight)
		}
		// A tiny, per-history alphabet repeats target choices. Zero selects the
		// original full domain. Keep byte values unrestricted: selectors also
		// encode move status, asset parent and edge relation choices. These are
		// live-entity ordinals, not stable IDs across deletions or creations.
		pool_size, pool_err := hgl.draw_i64(tc, 0, 4)
		if pool_err == .Stop_Test do return hgl.abort()
		if pool_err != nil do return hgl.interesting("draw handler swarm selector pool size")
		alphabet: [256]u8
		for &value, index in alphabet do value = u8(index)
		for index in 0 ..< int(pool_size) {
			pick, pick_err := hgl.draw_i64(tc, i64(index), 255)
			if pick_err == .Stop_Test do return hgl.abort()
			if pick_err != nil do return hgl.interesting("draw handler swarm selector pool member")
			alphabet[index], alphabet[int(pick)] = alphabet[int(pick)], alphabet[index]
		}
		selector_count := pool_size == 0 ? 256 : int(pool_size)
		op_count_raw, count_err := hgl.draw_i64(tc, 1, SEMANTIC_HANDLER_SWARM_MAX_OPS)
		if count_err == .Stop_Test do return hgl.abort()
		if count_err != nil do return hgl.interesting("draw handler swarm operation count")
		op_count := int(op_count_raw)
		ops: [SEMANTIC_HANDLER_SWARM_MAX_OPS]Semantic_Handler_Swarm_Op
		for &op in ops[:op_count] {
			// Resolve the ticket only when the current model is known. The large
			// range keeps modulo bias negligible for at most 900 total weight.
			kind, kind_err := hgl.draw_i64(tc, 0, 0x7fff_ffff)
			if kind_err == .Stop_Test do return hgl.abort()
			if kind_err != nil do return hgl.interesting("draw handler swarm operation kind")
			selector, selector_err := hgl.draw_i64(tc, 0, i64(selector_count - 1))
			if selector_err == .Stop_Test do return hgl.abort()
			if selector_err != nil do return hgl.interesting("draw handler swarm selector")
			query_selector, query_selector_err := hgl.draw_i64(tc, 0, 65_535)
			if query_selector_err == .Stop_Test do return hgl.abort()
			if query_selector_err != nil do return hgl.interesting("draw handler swarm query selector")
			split_a, split_a_err := hgl.draw_i64(tc, 0, 255)
			if split_a_err == .Stop_Test do return hgl.abort()
			if split_a_err != nil do return hgl.interesting("draw handler swarm first split")
			split_b, split_b_err := hgl.draw_i64(tc, 0, 255)
			if split_b_err == .Stop_Test do return hgl.abort()
			if split_b_err != nil do return hgl.interesting("draw handler swarm second split")
			op = {
				kind_ticket    = int(kind),
				selector       = alphabet[int(selector)],
				query_selector = u16(query_selector),
				split_a        = u8(split_a),
				split_b        = u8(split_b),
			}
		}
		durable_raw, durable_err := hgl.draw_i64(tc, 0, i64(op_count))
		if durable_err == .Stop_Test do return hgl.abort()
		if durable_err != nil do return hgl.interesting("draw handler swarm durable prefix")
		counts: Semantic_Handler_Swarm_Counts
		if tc.is_final do fmt.eprintf("handler swarm inputs: weights=%v selector_pool_size=%d selector_pool=%v requested_length=%d requested_durable_after=%d\n", weights, selector_count, alphabet[:int(pool_size)], op_count, durable_raw)
		if diagnostic := semantic_handler_swarm_run(ops[:op_count], int(durable_raw), &counts, weights[:], trace_execution = tc.is_final); diagnostic != "" {
			if tc.is_final do fmt.eprintf("handler swarm failure: reason=%s counts=%v\n", diagnostic, counts)
			return hgl.interesting(diagnostic)
		}
		for row, requested in counts {
			for count, executed in row {
				if count > 0 && (requested != executed || weights[requested] == 0) {
					if tc.is_final do fmt.eprintf("handler swarm invalid operation: requested=%v executed=%v count=%d\n", Semantic_Handler_Swarm_Kind(requested), Semantic_Handler_Swarm_Kind(executed), count)
					return hgl.interesting("handler swarm executed a substituted or disabled operation")
				}
			}
		}
		// Count only fully successful histories. On a failing run this can include
		// successful shrink candidates; final failure replay is never counted.
		if user_data != nil && !tc.is_final {
			totals := cast(^Semantic_Handler_Swarm_Counts)user_data
			for row, requested in counts {
				for count, executed in row do totals[requested][executed] += count
			}
		}
		return hgl.valid()
	}
}

@(test)
test_semantic_handler_graph_swarm_fixtures :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		query_model := semantic_handler_swarm_initial_model()
		testing.expect_value(t, semantic_handler_swarm_query_fixture_exact(&query_model, 60, .Task, 1, .Task, 2, .Outgoing, 4, 0, true, 2), true)
		testing.expect_value(t, semantic_handler_swarm_query_fixture_exact(&query_model, 6, .Task, 1, .Task, 2, .Outgoing, 1, 0, false, 0), true)
		testing.expect_value(t, semantic_handler_swarm_query_fixture_exact(&query_model, 34, .Task, 2, .Task, 1, .Incoming, 2, 0, true, 2), true)
		testing.expect_value(t, semantic_handler_swarm_query_fixture_exact(&query_model, 90, .Task, 1, .Task, 2, .Both, 2, 1, true, 2), true)
		testing.expect_value(t, semantic_handler_swarm_query_fixture_exact(&query_model, 204, .Task, 1, .Task, 2, .Outgoing, 4, 2, false, 0), true)
		testing.expect_value(t, semantic_handler_swarm_neighborhood_fixture_exact(&query_model, 60, 3, 2), true)
		testing.expect_value(t, semantic_handler_swarm_neighborhood_fixture_exact(&query_model, 6, 2, 1), true)
		testing.expect_value(t, semantic_handler_swarm_neighborhood_fixture_exact(&query_model, 34, 3, 2), true)
		testing.expect_value(t, semantic_handler_swarm_neighborhood_fixture_exact(&query_model, 90, 3, 2), true)
		testing.expect_value(t, semantic_handler_swarm_neighborhood_fixture_exact(&query_model, 204, 1, 0), true)
		page_req := semantic_handler_swarm_task_page_request(&query_model, 0, 0xB100)
		page := semantic_handler_swarm_task_page(&query_model, &page_req)
		testing.expect_value(t, page_req, pr.ListTasksPagedRequest{conv_id = pr.WORKSPACE_DATA_ID, status_mask = 0x1f, limit = 1, correlation_id = 0xB100})
		testing.expect_value(t, page.count, 1)
		testing.expect_value(t, page.ids[0], pr.TaskID(2))
		testing.expect_value(t, page.total_count, u32(2))
		testing.expect_value(t, page.has_more, true)
		testing.expect_value(t, page.next_cursor_sort_at, NRC_SIM_TIME_EPOCH_NANOS)
		testing.expect_value(t, page.next_cursor_task_id, pr.TaskID(2))
		page_req = semantic_handler_swarm_task_page_request(&query_model, 42, 0xB101)
		page = semantic_handler_swarm_task_page(&query_model, &page_req)
		testing.expect_value(t, page_req.has_cursor, true)
		testing.expect_value(t, page_req.cursor_sort_at, NRC_SIM_TIME_EPOCH_NANOS)
		testing.expect_value(t, page_req.cursor_task_id, pr.TaskID(2))
		testing.expect_value(t, page.count, 1)
		testing.expect_value(t, page.ids[0], pr.TaskID(1))
		testing.expect_value(t, page.has_more, false)
		project, tags := semantic_handler_swarm_note_scope(2, 0)
		testing.expect_value(t, project, u8(1))
		testing.expect_value(t, tags, u8(0b101))
		project, tags = semantic_handler_swarm_note_scope(2, 1)
		testing.expect_value(t, project, u8(2))
		testing.expect_value(t, tags, u8(0b010))
		project, tags = semantic_handler_swarm_note_scope(2, 2)
		testing.expect_value(t, project, u8(0))
		testing.expect_value(t, tags, u8(0b100))
		parent_type, parent_id, parent_ok := semantic_handler_swarm_select_asset_parent(&query_model, 128)
		testing.expect_value(t, parent_type, pr.ParentType.Asset)
		testing.expect_value(t, parent_id, u64(1))
		testing.expect_value(t, parent_ok, true)
		testing.expect_value(t, semantic_handler_swarm_common_neighbors_fixture_exact(&query_model, 0, .Task, 1, .Task, 2, .Both, 0, .Asset, 1, 1, 2), true)
		testing.expect_value(
			t,
			semantic_handler_swarm_common_neighbors_fixture_exact(&query_model, 60, .Task, 1, .Task, 2, .Outgoing, 0, pr.TargetType(0), 0, 0, 0),
			true,
		)
		testing.expect_value(t, semantic_handler_swarm_common_neighbors_fixture_exact(&query_model, 90, .Task, 1, .Task, 2, .Both, 1, .Asset, 1, 1, 2), true)
		testing.expect_value(
			t,
			semantic_handler_swarm_common_neighbors_fixture_exact(&query_model, 204, .Task, 1, .Task, 2, .Outgoing, 2, pr.TargetType(0), 0, 0, 0),
			true,
		)
		triangle_query_model := query_model
		triangle_query_model.edge_high = 3
		triangle_query_model.edges[3] = {
			live        = true,
			source_type = .Task,
			source_id   = 1,
			target_type = .Task,
			target_id   = 2,
			relation    = .References,
		}
		testing.expect_value(t, semantic_handler_swarm_query_fixture_exact(&triangle_query_model, 18, .Task, 1, .Task, 2, .Both, 2, 0, true, 1), true)
		testing.expect_value(t, semantic_handler_swarm_neighborhood_fixture_exact(&triangle_query_model, 18, 3, 3), true)
		testing.expect_value(
			t,
			semantic_handler_swarm_common_neighbors_fixture_exact(&triangle_query_model, 9, .Task, 1, .Asset, 1, .Outgoing, 0, .Task, 2, 2, 3),
			true,
		)
		testing.expect_value(
			t,
			semantic_handler_swarm_common_neighbors_fixture_exact(&triangle_query_model, 17, .Asset, 1, .Task, 2, .Incoming, 0, .Task, 1, 1, 3),
			true,
		)
		testing.expect_value(
			t,
			semantic_handler_swarm_common_neighbors_fixture_exact(&triangle_query_model, 18, .Task, 1, .Task, 2, .Both, 0, .Asset, 1, 1, 2),
			true,
		)
		deleted_query_model := query_model
		deleted_query_model.assets[1].live = false
		deleted_query_model.edges[1].live = false
		deleted_query_model.edges[2].live = false
		testing.expect_value(t, semantic_handler_swarm_query_fixture_exact(&deleted_query_model, 2, .Asset, 1, .Task, 1, .Both, 1, 0, false, 0), true)
		testing.expect_value(t, semantic_handler_swarm_neighborhood_fixture_exact(&deleted_query_model, 2, 1, 0), true)
		testing.expect_value(
			t,
			semantic_handler_swarm_common_neighbors_fixture_exact(&deleted_query_model, 2, .Asset, 1, .Task, 1, .Both, 0, pr.TargetType(0), 0, 0, 0),
			true,
		)
		testing.expect_value(
			t,
			semantic_handler_swarm_move_request(&query_model, 6, 0),
			pr.MoveTaskRequest{conv_id = pr.WORKSPACE_DATA_ID, task_id = 1, status = .Done, order_index = 103, correlation_id = 0xD880},
		)
		testing.expect_value(
			t,
			semantic_handler_swarm_move_request(&query_model, 0, 1),
			pr.MoveTaskRequest{conv_id = pr.WORKSPACE_DATA_ID, task_id = 1, status = .Backlog, order_index = 14, correlation_id = 0xD881},
		)
		testing.expect_value(
			t,
			semantic_handler_swarm_move_request(&query_model, 9, 2),
			pr.MoveTaskRequest{conv_id = pr.WORKSPACE_DATA_ID, task_id = 2, status = .Note, order_index = 181, correlation_id = 0xD882},
		)
		testing.expect_value(
			t,
			semantic_handler_swarm_move_request(&query_model, 5, 3),
			pr.MoveTaskRequest{conv_id = pr.WORKSPACE_DATA_ID, task_id = 2, status = .InProgress, order_index = 126, correlation_id = 0xD883},
		)
		oldest := [?]Semantic_Handler_Swarm_Op{{kind = .Update_Task}, {kind = .Delete_Edge}, {kind = .Delete_Asset}}
		overlap := [?]Semantic_Handler_Swarm_Op {
			{kind = .Update_Task, selector = 1, split_a = 7, split_b = 11},
			{kind = .Delete_Edge, selector = 0, split_a = 3, split_b = 17},
			{kind = .Delete_Task, selector = 1, split_a = 15, split_b = 23},
		}
		growth := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Task, selector = 1, split_a = 9, split_b = 21},
			{kind = .Create_Edge, selector = 2, split_a = 4, split_b = 19},
			{kind = .Update_Task, selector = 2, split_a = 13, split_b = 27},
		}
		asset_growth := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Task, selector = 2, split_a = 3, split_b = 18},
			{kind = .Create_Asset, selector = 2, split_a = 7, split_b = 20},
			{kind = .Create_Edge, selector = 4, split_a = 12, split_b = 23},
			{kind = .Delete_Task, selector = 2, split_a = 15, split_b = 25},
		}
		edge_saturation := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Edge, selector = 0, split_a = 2, split_b = 17},
			{kind = .Create_Edge, selector = 1, split_a = 4, split_b = 19},
			{kind = .Create_Edge, selector = 2, split_a = 6, split_b = 21},
			{kind = .Create_Edge, selector = 3, split_a = 8, split_b = 23},
			{kind = .Create_Edge, selector = 4, split_a = 10, split_b = 25},
			{kind = .Create_Edge, selector = 5, split_a = 12, split_b = 27},
		}
		query_growth := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Edge, selector = 0, query_selector = 18, split_a = 5, split_b = 18},
			{kind = .Delete_Edge, selector = 0, query_selector = 6, split_a = 9, split_b = 21},
			{kind = .Delete_Edge, selector = 1, query_selector = 60, split_a = 13, split_b = 25},
		}
		common_directions := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Edge, selector = 0, query_selector = 9, split_a = 4, split_b = 18},
			{kind = .Update_Task, selector = 0, query_selector = 17, split_a = 8, split_b = 22},
			{kind = .Update_Task, selector = 1, query_selector = 18, split_a = 12, split_b = 26},
		}
		move_lifecycle := [?]Semantic_Handler_Swarm_Op {
			{kind = .Move_Task, selector = 6, query_selector = 4, split_a = 3, split_b = 18},
			{kind = .Move_Task, selector = 6, query_selector = 9, split_a = 6, split_b = 20},
			{kind = .Move_Task, selector = 0, query_selector = 17, split_a = 9, split_b = 22},
			{kind = .Move_Task, selector = 9, query_selector = 18, split_a = 12, split_b = 25},
			{kind = .Move_Task, selector = 5, query_selector = 90, split_a = 15, split_b = 27},
		}
		move_todo_create := [?]Semantic_Handler_Swarm_Op {
			{kind = .Move_Task, selector = 2, query_selector = 0, split_a = 4, split_b = 18},
			{kind = .Create_Task, selector = 0, query_selector = 9, split_a = 8, split_b = 22},
			{kind = .Update_Task, selector = 2, query_selector = 17, split_a = 12, split_b = 26},
		}
		asset_update_lifecycle := [?]Semantic_Handler_Swarm_Op {
			{kind = .Update_Asset, selector = 0, query_selector = 0, split_a = 3, split_b = 18},
			{kind = .Update_Asset, selector = 0, query_selector = 9, split_a = 6, split_b = 20},
			{kind = .Create_Asset, selector = 1, query_selector = 17, split_a = 9, split_b = 22},
			{kind = .Update_Asset, selector = 1, query_selector = 18, split_a = 12, split_b = 25},
			{kind = .Update_Asset, selector = 1, query_selector = 108, split_a = 15, split_b = 27},
			{kind = .Update_Asset, selector = 0, query_selector = 204, split_a = 17, split_b = 29},
		}
		note_scope_delete := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Asset, selector = 0, query_selector = 1, split_a = 4, split_b = 18},
			{kind = .Update_Asset, selector = 1, query_selector = 4, split_a = 8, split_b = 22},
			{kind = .Delete_Asset, selector = 1, query_selector = 17, split_a = 12, split_b = 26},
		}
		note_two_page_cursor := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Asset, selector = 0, query_selector = 1, split_a = 5, split_b = 19},
			{kind = .Create_Asset, selector = 1, query_selector = 0, split_a = 9, split_b = 23},
			{kind = .Update_Asset, selector = 1, query_selector = 130, split_a = 13, split_b = 27},
		}
		nested_asset_cascade := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Asset, selector = 128, query_selector = 1, split_a = 3, split_b = 18},
			{kind = .Create_Asset, selector = 129, query_selector = 0, split_a = 6, split_b = 20},
			{kind = .Create_Edge, selector = 3, query_selector = 18, split_a = 9, split_b = 22},
			{kind = .Update_Asset, selector = 1, query_selector = 130, split_a = 12, split_b = 25},
			{kind = .Delete_Asset, selector = 0, query_selector = 17, split_a = 15, split_b = 27},
		}
		rejection_families := [?]Semantic_Handler_Swarm_Op {
			{kind = .Update_Task, selector = 0, query_selector = 0, split_a = 3, split_b = 18},
			{kind = .Update_Task, selector = 1, query_selector = 1, split_a = 6, split_b = 20},
			{kind = .Update_Task, selector = 0, query_selector = 2, split_a = 9, split_b = 22},
			{kind = .Update_Task, selector = 1, query_selector = 3, split_a = 12, split_b = 25},
		}
		query_parameters := [?]Semantic_Handler_Swarm_Op {
			{kind = .Update_Task, query_selector = 60, split_a = 1, split_b = 17},
			{kind = .Update_Task, selector = 1, query_selector = 6, split_a = 3, split_b = 19},
			{kind = .Update_Task, query_selector = 34, split_a = 5, split_b = 21},
			{kind = .Update_Task, selector = 1, query_selector = 90, split_a = 7, split_b = 23},
			{kind = .Update_Task, query_selector = 204, split_a = 9, split_b = 25},
			{kind = .Delete_Asset, query_selector = 2, split_a = 11, split_b = 27},
		}
		singleton_growth := [?]Semantic_Handler_Swarm_Op {
			{kind = .Create_Task, split_a = 2, split_b = 18},
			{kind = .Delete_Task, selector = 0, split_a = 6, split_b = 20},
			{kind = .Delete_Task, selector = 0, split_a = 10, split_b = 22},
			{kind = .Create_Edge, selector = 7, split_a = 14, split_b = 24},
		}
		newest := [?]Semantic_Handler_Swarm_Op {
			{kind = .Delete_Task, selector = 255, split_a = 255, split_b = 255},
			{kind = .Delete_Edge, selector = 255, split_a = 255, split_b = 255},
			{kind = .Delete_Asset, selector = 255, split_a = 255, split_b = 255},
			{kind = .Update_Task, selector = 255, split_a = 255, split_b = 255},
		}
		testing.expect_value(t, semantic_handler_swarm_run(oldest[:], 0), "")
		testing.expect_value(t, semantic_handler_swarm_run(overlap[:], 1), "")
		testing.expect_value(t, semantic_handler_swarm_run(growth[:], 2), "")
		testing.expect_value(t, semantic_handler_swarm_run(asset_growth[:], 3), "")
		testing.expect_value(t, semantic_handler_swarm_run(edge_saturation[:], 3), "")
		testing.expect_value(t, semantic_handler_swarm_run(query_growth[:], 1), "")
		testing.expect_value(t, semantic_handler_swarm_run(common_directions[:], 1), "")
		testing.expect_value(t, semantic_handler_swarm_run(move_lifecycle[:], 2), "")
		testing.expect_value(t, semantic_handler_swarm_run(move_todo_create[:], 2), "")
		testing.expect_value(t, semantic_handler_swarm_run(asset_update_lifecycle[:], 4), "")
		testing.expect_value(t, semantic_handler_swarm_run(note_scope_delete[:], 2), "")
		testing.expect_value(t, semantic_handler_swarm_run(note_two_page_cursor[:], 2), "")
		testing.expect_value(t, semantic_handler_swarm_run(nested_asset_cascade[:], 4), "")
		testing.expect_value(t, semantic_handler_swarm_run(rejection_families[:], 2), "")
		testing.expect_value(t, semantic_handler_swarm_run(query_parameters[:], 3), "")
		testing.expect_value(t, semantic_handler_swarm_run(singleton_growth[:], 3), "")
		testing.expect_value(t, semantic_handler_swarm_run(newest[:], len(newest)), "")
	}
}

@(test)
test_semantic_handler_swarm_weight_intervals :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		weights := [len(Semantic_Handler_Swarm_Kind)]int{0, 2, 0, 5, 0, 0, 0, 0, 1}
		expected := [?]Semantic_Handler_Swarm_Kind {
			.Delete_Edge,
			.Delete_Edge,
			.Delete_Task,
			.Delete_Task,
			.Delete_Task,
			.Delete_Task,
			.Delete_Task,
			.Update_Asset,
		}
		for kind, ticket in expected {
			testing.expect_value(t, semantic_handler_swarm_pick_kind(weights[:], ticket), kind)
		}
		weights = {0, 0, 0, 0, 0, 0, 0, 0, 3}
		for ticket in 0 ..< 3 {
			testing.expect_value(t, semantic_handler_swarm_pick_kind(weights[:], ticket), Semantic_Handler_Swarm_Kind.Update_Asset)
		}
	}
}

@(test)
test_semantic_handler_swarm_operation_counts :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		// The initial model has two tasks. Only the first delete executes as
		// requested; subsequent deletes become updates to preserve one task.
		ops := [?]Semantic_Handler_Swarm_Op{{kind = .Delete_Task, selector = 0}, {kind = .Delete_Task, selector = 0}, {kind = .Delete_Task, selector = 0}}
		counts: Semantic_Handler_Swarm_Counts
		testing.expect_value(t, semantic_handler_swarm_run(ops[:], 2, &counts), "")
		expected: Semantic_Handler_Swarm_Counts
		expected[int(Semantic_Handler_Swarm_Kind.Delete_Task)][int(Semantic_Handler_Swarm_Kind.Delete_Task)] = 1
		expected[int(Semantic_Handler_Swarm_Kind.Delete_Task)][int(Semantic_Handler_Swarm_Kind.Update_Task)] = 2
		testing.expect_value(t, counts, expected)
		// A second run accumulates only its generated writes, not setup or the
		// extra mutation after recovery, even when the durable prefix changes.
		testing.expect_value(t, semantic_handler_swarm_run(ops[:], 0, &counts), "")
		expected[int(Semantic_Handler_Swarm_Kind.Delete_Task)][int(Semantic_Handler_Swarm_Kind.Delete_Task)] = 2
		expected[int(Semantic_Handler_Swarm_Kind.Delete_Task)][int(Semantic_Handler_Swarm_Kind.Update_Task)] = 4
		testing.expect_value(t, counts, expected)
	}
}

@(test)
test_semantic_handler_swarm_exhausted_histories :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		// Deleting preserves the last task; creating exhausts the two spare
		// slots. Check crash cuts before, at, and beyond the shortened history.
		for kind in ([2]Semantic_Handler_Swarm_Kind{.Delete_Task, .Create_Task}) {
			weights: [len(Semantic_Handler_Swarm_Kind)]int
			weights[int(kind)] = 7
			for durable_after in 0 ..= 3 {
				ops: [3]Semantic_Handler_Swarm_Op
				counts: Semantic_Handler_Swarm_Counts
				testing.expect_value(t, semantic_handler_swarm_run(ops[:], durable_after, &counts, weights[:]), "")
				expected: Semantic_Handler_Swarm_Counts
				expected[int(kind)][int(kind)] = kind == .Delete_Task ? 1 : 2
				testing.expect_value(t, counts, expected)
			}
		}
		model := semantic_handler_swarm_initial_model()
		model.task_live[2] = false
		model.task_high = len(model.task_live) - 1
		model.asset_high = len(model.assets) - 1
		model.assets = {}
		model.edges = {}
		weights := [len(Semantic_Handler_Swarm_Kind)]int{2, 3, 5, 7, 11, 13, 17, 19, 23}
		available, total := semantic_handler_swarm_available_weights(&model, weights[:])
		testing.expect_value(t, available, [len(Semantic_Handler_Swarm_Kind)]int{2, 0, 0, 0, 0, 0, 0, 19, 0})
		testing.expect_value(t, total, 21)
	}
}

// Keep generated discovery separate from exact fixtures: a mutation audit of
// this test must be caught by a generated history, not a hand-written example.
@(test)
test_hegel_semantic_handler_graph_swarm :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		if !hgl.can_run() do return
		counts: Semantic_Handler_Swarm_Counts
		result, err := hgl.run(prop_semantic_handler_swarm, &counts, {test_cases = 24})
		if hgl.diagnostics_enabled() {
			for row, requested in counts {
				for count, executed in row {
					if count > 0 do fmt.eprintf("[handler swarm] successful-history operations requested=%v executed=%v count=%d\n", Semantic_Handler_Swarm_Kind(requested), Semantic_Handler_Swarm_Kind(executed), count)
				}
			}
		}
		testing.expectf(t, err == nil, "semantic handler graph swarm failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
