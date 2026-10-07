package main

// Generated state-machine coverage for the production transactional shard WAL.
// Handler setup couples persistence to connection fanout and makes an in-process
// restart unsafe, so this property uses the same builders, append/apply path, and
// replay dispatch as the handlers. Delete operations use the production cascade
// transaction builders rather than reproducing mutation behavior in the test.

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import "btree"
import "byte_pool"
import hgl "hegel"
import "persistence"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: btree.count
	_ :: byte_pool.release
	_ :: fmt.eprintf
	_ :: virtual.arena_init_growing
	_ :: os.remove
	_ :: strings.clone
	_ :: hgl.run
	_ :: persistence.force_fsync
	_ :: pr.TaskID
}

when NRC_SIMULATION {
	GENERATED_SHARD_MAX_ENTITIES :: 32
	GENERATED_SHARD_CASES :: 24
	GENERATED_SHARD_MAX_OPS :: 18
	GENERATED_SHARD_CONV :: pr.WORKSPACE_DATA_ID

	Generated_Shard_Op_Kind :: enum u8 {
		Create_Task,
		Update_Task,
		Move_Task,
		Query_Tasks_Paged,
		Create_Asset,
		Create_Slice,
		Create_File,
		Create_Customer,
		Create_Contact,
		Update_Asset,
		Query_Assets_Paged,
		Create_Edge,
		Create_Membership,
		Query_Graph,
		Query_Slices,
		Delete_Asset,
		Delete_Task,
		Delete_Edge,
		Crash_Restart,
		Rotate,
		Compact,
	}

	Generated_Shard_Op :: struct {
		kind:     Generated_Shard_Op_Kind,
		selector: u64,
	}

	Generated_Shard_Model_Task :: struct {
		live:           bool,
		update_variant: u8,
		status:         pr.TaskStatus,
		order_index:    u16,
		updated_at:     i64,
		completed_at:   i64,
	}

	Generated_Shard_Model_Asset :: struct {
		live:           bool,
		update_variant: u8,
		asset_type:     pr.AssetType,
		parent_type:    pr.ParentType,
		parent_id:      u64,
		created_at:     i64,
		updated_at:     i64,
	}

	Generated_Shard_Model_Edge :: struct {
		live:        bool,
		source_type: pr.TargetType,
		source_id:   u64,
		target_type: pr.TargetType,
		target_id:   u64,
		relation:    pr.RelationType,
		created_at:  i64,
		created_by:  string,
	}

	Generated_Shard_Graph_Node :: struct {
		target_type: pr.TargetType,
		target_id:   u64,
		depth:       u8,
	}

	Generated_Shard_Slice_Expected :: struct {
		id:               pr.AssetID,
		closed:           bool,
		backlog:          u16,
		todo:             u16,
		in_progress:      u16,
		done:             u16,
		blocked:          u16,
		notes:            u16,
		files:            u16,
		oldest_active_at: i64,
		last_moved_at:    i64,
		sort_at:          i64,
	}

	generated_shard_slice_name :: proc(id: u64) -> string {
		return fmt.tprintf("slice-%02d", id)
	}

	generated_shard_slice_owner :: proc(state: Generated_Shard_Model_Asset, id: u64) -> string {
		if state.update_variant == 2 do return "other-owner"
		return id % 2 == 0 ? "generated-owner" : ""
	}

	Generated_Shard_Model :: struct {
		tasks:                   [GENERATED_SHARD_MAX_ENTITIES]Generated_Shard_Model_Task,
		assets:                  [GENERATED_SHARD_MAX_ENTITIES]Generated_Shard_Model_Asset,
		edges:                   [GENERATED_SHARD_MAX_ENTITIES]Generated_Shard_Model_Edge,
		task_high:               u64,
		asset_high:              u64,
		edge_high:               u64,
		task_mutation_sequence:  i64,
		asset_mutation_sequence: i64,
	}

	generated_shard_task_snapshot :: proc(state: Generated_Shard_Model_Task, id: u64, attachments: ^[1]pr.Attachment) -> pr.Task {
		attachments[0] = pr.Attachment {
			file_id     = transmute([]byte)string("generated-file-id"),
			filename    = transmute([]byte)string("generated-file.txt"),
			size        = 1_024 + id,
			mime_type   = transmute([]byte)string("text/plain"),
			uploaded_at = 2_000 + i64(id),
		}
		task := pr.Task {
			id           = pr.TaskID(id),
			conv_id      = GENERATED_SHARD_CONV,
			title        = transmute([]byte)string("generated-task"),
			status       = state.status,
			order_index  = state.order_index,
			created_by   = transmute([]byte)string("generated-creator"),
			created_at   = 1_000 + i64(id),
			updated_at   = state.updated_at,
			blocked_by   = pr.TaskID(id),
			completed_at = state.completed_at,
			attachments  = attachments[:],
		}
		if state.status == .Done {
			task.completed_by = transmute([]byte)string("generated-completer")
		}
		switch state.update_variant {
		case 1:
			task.title = transmute([]byte)string("generated-task-updated-a")
			task.description = transmute([]byte)string("generated-description-a")
			task.assignee = transmute([]byte)string("generated-assignee-a")
			task.priority = 2
			task.color = .Cyan
			task.external_ref = transmute([]byte)string("generated-ref-a")
			task.due_at = 3_000 + i64(id)
			task.project = transmute([]byte)string("generated-project-a")
		case 2:
			task.title = transmute([]byte)string("generated-task-updated-b")
			task.description = transmute([]byte)string("generated-description-b")
			task.assignee = transmute([]byte)string("generated-assignee-b")
			task.priority = 4
			task.color = .Green
			task.external_ref = transmute([]byte)string("generated-ref-b")
			task.due_at = 6_000 + i64(id)
			task.project = transmute([]byte)string("generated-project-b")
		case:
		}
		return task
	}

	generated_shard_asset_snapshot :: proc(state: Generated_Shard_Model_Asset, id: u64, attachments: ^[1]pr.Attachment) -> pr.Asset {
		attachments[0] = pr.Attachment {
			file_id     = transmute([]byte)string("generated-asset-file-0"),
			filename    = transmute([]byte)string("generated-asset-0.txt"),
			size        = 2_048 + id,
			mime_type   = transmute([]byte)string("text/plain"),
			uploaded_at = 5_000 + i64(id),
		}
		asset := pr.Asset {
			asset_type       = state.asset_type,
			asset_id         = pr.AssetID(id),
			parent_type      = state.parent_type,
			parent_id        = state.parent_id,
			owner            = transmute([]byte)string("generated-owner"),
			created_at       = state.created_at != 0 ? state.created_at : 3_000 + i64(id),
			updated_at       = state.updated_at,
			conv_id          = GENERATED_SHARD_CONV,
			payload_encoding = .Plain,
			payload_raw_len  = 16,
			payload          = transmute([]byte)string("generated-data-0"),
			attachments      = attachments[:],
		}
		if state.asset_type == .Slice {
			asset.preview = transmute([]byte)fmt.tprintf(
				`{{"version":1,"name":"%s","owner":"%s","closed":false}}`,
				generated_shard_slice_name(id),
				generated_shard_slice_owner(state, id),
			)
		} else if state.asset_type == .CustomerCompany {
			asset.preview = transmute([]byte)string(`{"version":1,"title":"generated-company"}`)
		} else if state.asset_type == .Note {
			asset.preview = transmute([]byte)string(`{"project":"alpha","tags":["odin","shared"]}`)
		} else {
			asset.preview = transmute([]byte)string("generated-preview-0")
		}
		switch state.update_variant {
		case 1:
			attachments[0] = pr.Attachment {
				file_id     = transmute([]byte)string("generated-asset-file-1"),
				filename    = transmute([]byte)string("generated-asset-1.bin"),
				size        = 4_096 + id,
				mime_type   = transmute([]byte)string("application/octet-stream"),
				uploaded_at = 6_000 + i64(id),
			}
			if state.asset_type == .Slice {
				asset.preview = transmute([]byte)fmt.tprintf(
					`{{"version":1,"name":"%s","owner":"%s","closed":true,"closed_at":21000,"closed_by":"generated"}}`,
					generated_shard_slice_name(id),
					generated_shard_slice_owner(state, id),
				)
			} else if state.asset_type == .CustomerCompany {
				asset.preview = transmute([]byte)string(`{"version":1,"title":"generated-company-updated"}`)
			} else if state.asset_type == .Note {
				asset.preview = transmute([]byte)string(`{"project":"beta","tags":["shared","graph"]}`)
			} else {
				asset.preview = transmute([]byte)string("generated-preview-1")
			}
			asset.payload = transmute([]byte)string("generated-data-1")
			asset.payload_raw_len = 16
		case 2:
			attachments[0] = pr.Attachment {
				file_id     = transmute([]byte)string("generated-asset-file-2"),
				filename    = transmute([]byte)string("generated-asset-2.zst"),
				size        = 8_192 + id,
				mime_type   = transmute([]byte)string("application/zstd"),
				uploaded_at = 7_000 + i64(id),
			}
			if state.asset_type == .Slice {
				asset.preview = transmute([]byte)fmt.tprintf(
					`{{"version":1,"name":"%s","owner":"other-owner","closed":false}}`,
					generated_shard_slice_name(id),
				)
			} else if state.asset_type == .CustomerCompany {
				asset.preview = transmute([]byte)string(`{"version":1,"title":"generated-company-reopened"}`)
			} else if state.asset_type == .Note {
				asset.preview = transmute([]byte)string(`{"tags":["shared","graph"]}`)
			} else {
				asset.preview = transmute([]byte)string("generated-preview-2")
			}
			asset.payload = transmute([]byte)string("generated-zstd-2")
			asset.payload_encoding = .Zstd
			asset.payload_raw_len = 128
		case:
		}
		if state.asset_type == .CustomerContact {
			asset.preview = transmute([]byte)string(`{"version":1,"title":"generated-contact","email":"person@example.test"}`)
		}
		return asset
	}

	generated_shard_asset_project :: proc(state: Generated_Shard_Model_Asset) -> string {
		if !state.live || state.asset_type != .Note do return ""
		switch state.update_variant {
		case 0:
			return "alpha"
		case 1:
			return "beta"
		case:
			return ""
		}
	}

	generated_shard_asset_has_tag :: proc(state: Generated_Shard_Model_Asset, tag: string) -> bool {
		if !state.live || state.asset_type != .Note do return false
		switch state.update_variant {
		case 0:
			return tag == "odin" || tag == "shared"
		case 1:
			return tag == "shared" || tag == "graph"
		case 2:
			return tag == "shared" || tag == "graph"
		case:
			return false
		}
	}

	generated_shard_endpoint_live :: proc(model: ^Generated_Shard_Model, entity_type: pr.TargetType, id: u64) -> bool {
		if id == 0 || id >= GENERATED_SHARD_MAX_ENTITIES do return false
		switch entity_type {
		case .Task:
			return model.tasks[id].live
		case .Asset:
			return model.assets[id].live
		}
		return false
	}

	generated_shard_asset_descends_from :: proc(model: ^Generated_Shard_Model, asset_id, root_id: u64) -> bool {
		current := asset_id
		for _ in 0 ..< GENERATED_SHARD_MAX_ENTITIES {
			if current == root_id do return true
			if current == 0 || current >= GENERATED_SHARD_MAX_ENTITIES || !model.assets[current].live do return false
			asset := model.assets[current]
			if asset.parent_type != .Asset do return false
			current = asset.parent_id
		}
		return false
	}

	generated_shard_asset_owned_by_task :: proc(model: ^Generated_Shard_Model, asset_id, task_id: u64) -> bool {
		current := asset_id
		for _ in 0 ..< GENERATED_SHARD_MAX_ENTITIES {
			if current == 0 || current >= GENERATED_SHARD_MAX_ENTITIES || !model.assets[current].live do return false
			asset := model.assets[current]
			if asset.parent_type == .Task do return asset.parent_id == task_id
			if asset.parent_type != .Asset do return false
			current = asset.parent_id
		}
		return false
	}

	generated_shard_note_filter_matches :: proc(state: Generated_Shard_Model_Asset, filter: string, is_tag: bool) -> bool {
		if is_tag do return generated_shard_asset_has_tag(state, filter)
		return generated_shard_asset_project(state) == filter
	}

	generated_shard_note_filter_count :: proc(model: ^Generated_Shard_Model, filter: string, is_tag: bool) -> int {
		count := 0
		for state in model.assets do if generated_shard_note_filter_matches(state, filter, is_tag) do count += 1
		return count
	}

	generated_shard_note_list_matches :: proc(model: ^Generated_Shard_Model, index: ^Note_Secondary_Index, filter: string, is_tag: bool) -> bool {
		list := note_secondary_index_asset_ids(index)
		defer delete(list)
		if len(list) != generated_shard_note_filter_count(model, filter, is_tag) do return false
		for asset_id, list_index in list {
			id := int(asset_id)
			if id <= 0 || id >= GENERATED_SHARD_MAX_ENTITIES do return false
			state := model.assets[id]
			if !generated_shard_note_filter_matches(state, filter, is_tag) do return false
			for previous_id in list[:list_index] do if previous_id == asset_id do return false
			if list_index > 0 {
				previous_id := list[list_index - 1]
				previous := model.assets[int(previous_id)]
				if previous.updated_at < state.updated_at || (previous.updated_at == state.updated_at && previous_id < asset_id) {
					return false
				}
			}
		}
		return true
	}

	generated_shard_compare :: proc(model: ^Generated_Shard_Model, workspace_id: string, floors: Shard_High_Water_Requirements) -> (string, bool) {
		if floors.task != model.task_high || floors.asset != model.asset_high || floors.edge != model.edge_high {
			return "high-water floors differ from generated model", false
		}
		live_task_count := generated_shard_live_task_count(model)
		live_asset_count := generated_shard_live_asset_count(model)
		live_edge_count := generated_shard_live_edge_count(model)
		for id, state in td.workspaces {
			if id != workspace_id do return "unexpected workspace exists outside generated model", false
			for conv_id in state.conversations {
				if conv_id != GENERATED_SHARD_CONV do return "unexpected conversation exists outside generated model", false
			}
		}
		workspace := get_workspace(workspace_id)
		if workspace == nil {
			if live_task_count == 0 && live_asset_count == 0 && live_edge_count == 0 do return "", true
			return "workspace missing from live state", false
		}
		conv := get_conversation(workspace, GENERATED_SHARD_CONV)
		if conv == nil {
			if live_task_count == 0 && live_asset_count == 0 && live_edge_count == 0 do return "", true
			return "conversation missing from live state", false
		}
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			task := conv.tasks[pr.TaskID(id)]
			if (task != nil) != model.tasks[id].live do return "task membership differs from generated model", false
			if task != nil {
				expected_attachments: [1]pr.Attachment
				expected := generated_shard_task_snapshot(model.tasks[id], u64(id), &expected_attachments)
				if task.id != expected.id ||
				   task.conv_id != expected.conv_id ||
				   string(task.title) != string(expected.title) ||
				   string(task.description) != string(expected.description) ||
				   task.status != expected.status ||
				   task.order_index != expected.order_index ||
				   string(task.assignee) != string(expected.assignee) ||
				   task.priority != expected.priority ||
				   task.color != expected.color ||
				   string(task.created_by) != string(expected.created_by) ||
				   task.created_at != expected.created_at ||
				   task.updated_at != expected.updated_at ||
				   string(task.external_ref) != string(expected.external_ref) ||
				   task.due_at != expected.due_at ||
				   task.blocked_by != expected.blocked_by ||
				   task.completed_at != expected.completed_at ||
				   string(task.completed_by) != string(expected.completed_by) ||
				   string(task.project) != string(expected.project) ||
				   len(task.attachments) != len(expected.attachments) {
					return "task state differs from generated model", false
				}
				for attachment, attachment_index in task.attachments {
					expected_attachment := expected.attachments[attachment_index]
					if string(attachment.file_id) != string(expected_attachment.file_id) ||
					   string(attachment.filename) != string(expected_attachment.filename) ||
					   attachment.size != expected_attachment.size ||
					   string(attachment.mime_type) != string(expected_attachment.mime_type) ||
					   attachment.uploaded_at != expected_attachment.uploaded_at {
						return "task attachment differs from generated model", false
					}
				}
				expected_sort_at := expected.updated_at
				if expected.status == .Done do expected_sort_at = expected.completed_at
				key, key_ok := conv.task_index_keys[expected.id]
				if !key_ok || key != (Task_Sort_Key{sort_at = expected_sort_at, task_id = expected.id}) {
					return "task paging index key differs from generated model", false
				}
				if !btree.contains(&conv.task_index, key) do return "task paging B-tree is missing expected key", false
			}
			asset := conv.assets[pr.AssetID(id)]
			if (asset != nil) != model.assets[id].live do return "asset membership differs from generated model", false
			if asset != nil {
				expected_attachments: [1]pr.Attachment
				expected := generated_shard_asset_snapshot(model.assets[id], u64(id), &expected_attachments)
				if asset.asset_type != expected.asset_type ||
				   asset.asset_id != expected.asset_id ||
				   asset.parent_type != expected.parent_type ||
				   asset.parent_id != expected.parent_id ||
				   string(asset.owner) != string(expected.owner) ||
				   asset.created_at != expected.created_at ||
				   asset.updated_at != expected.updated_at ||
				   asset.conv_id != expected.conv_id ||
				   asset.payload_encoding != expected.payload_encoding ||
				   asset.payload_raw_len != expected.payload_raw_len ||
				   string(asset.preview) != string(expected.preview) ||
				   string(asset.payload) != string(expected.payload) ||
				   len(asset.attachments) != len(expected.attachments) {
					return "asset state or ownership differs from generated model", false
				}
				for attachment, attachment_index in asset.attachments {
					expected_attachment := expected.attachments[attachment_index]
					if string(attachment.file_id) != string(expected_attachment.file_id) ||
					   string(attachment.filename) != string(expected_attachment.filename) ||
					   attachment.size != expected_attachment.size ||
					   string(attachment.mime_type) != string(expected_attachment.mime_type) ||
					   attachment.uploaded_at != expected_attachment.uploaded_at {
						return "asset attachment differs from generated model", false
					}
				}
				note_key, note_key_ok := conv.note_index_keys[asset.asset_id]
				if expected.asset_type == .Note {
					expected_note_key := Note_Sort_Key {
						updated_at = expected.updated_at,
						asset_id   = expected.asset_id,
					}
					if !note_key_ok || note_key != expected_note_key || !btree.contains(&conv.note_index, expected_note_key) {
						return "note paging index key differs from generated model", false
					}
				} else if note_key_ok {
					return "non-note asset exists in note paging index", false
				}
			}
			edge := conv.edges[pr.EdgeID(id)]
			if (edge != nil) != model.edges[id].live do return "edge membership differs from generated model", false
			if edge != nil &&
			   (u64(edge.edge_id) != u64(id) ||
					   edge.conv_id != GENERATED_SHARD_CONV ||
					   edge.source_type != model.edges[id].source_type ||
					   u64(edge.source_id) != model.edges[id].source_id ||
					   edge.target_type != model.edges[id].target_type ||
					   u64(edge.target_id) != model.edges[id].target_id ||
					   edge.relation != model.edges[id].relation ||
					   edge.created_at != model.edges[id].created_at ||
					   string(edge.created_by) != (model.edges[id].created_by != "" ? model.edges[id].created_by : "generated")) {
				return "edge state or endpoints differ from generated model", false
			}
		}
		if len(conv.tasks) != int(live_task_count) do return "unexpected task map entries", false
		if len(conv.task_index_keys) != int(live_task_count) || btree.count(&conv.task_index) != int(live_task_count) {
			return "task paging index cardinality differs from generated model", false
		}
		if len(conv.assets) != int(live_asset_count) do return "unexpected asset map entries", false
		live_note_count := 0
		for state in model.assets do if state.live && state.asset_type == .Note do live_note_count += 1
		if len(conv.note_index_keys) != live_note_count || btree.count(&conv.note_index) != live_note_count {
			return "note paging index cardinality differs from generated model", false
		}
		note_iterator := btree.iter(&conv.note_index)
		defer btree.iter_destroy(&note_iterator)
		previous_note_key: Note_Sort_Key
		has_previous_note_key := false
		for has_note := btree.iter_first(&note_iterator); has_note; has_note = btree.iter_next(&note_iterator) {
			key := btree.item(&note_iterator)
			id := int(key.asset_id)
			if id <= 0 ||
			   id >= GENERATED_SHARD_MAX_ENTITIES ||
			   !model.assets[id].live ||
			   model.assets[id].asset_type != .Note ||
			   model.assets[id].updated_at != key.updated_at {
				return "note paging B-tree entry differs from generated model", false
			}
			if has_previous_note_key &&
			   (previous_note_key.updated_at > key.updated_at ||
					   (previous_note_key.updated_at == key.updated_at && previous_note_key.asset_id > key.asset_id)) {
				return "note paging B-tree order differs from generated model", false
			}
			previous_note_key = key
			has_previous_note_key = true
		}
		expected_project_keys := 0
		project_keys := [?]string{"alpha", "beta"}
		for project in project_keys {
			expected_count := generated_shard_note_filter_count(model, project, false)
			list, present := conv.note_project_assets[project]
			if present != (expected_count > 0) do return "note project index key set differs from generated model", false
			if present && !generated_shard_note_list_matches(model, list, project, false) do return "note project index differs from generated model", false
			if expected_count > 0 do expected_project_keys += 1
		}
		if len(conv.note_project_assets) != expected_project_keys do return "note project index key set differs from generated model", false
		expected_tag_keys := 0
		tag_keys := [?]string{"odin", "shared", "graph"}
		for tag in tag_keys {
			expected_count := generated_shard_note_filter_count(model, tag, true)
			list, present := conv.note_tag_assets[tag]
			if present != (expected_count > 0) do return "note tag index key set differs from generated model", false
			if present && !generated_shard_note_list_matches(model, list, tag, true) do return "note tag index differs from generated model", false
			if expected_count > 0 do expected_tag_keys += 1
		}
		if len(conv.note_tag_assets) != expected_tag_keys do return "note tag index key set differs from generated model", false
		if len(conv.edges) != int(live_edge_count) do return "unexpected edge map entries", false
		adjacency_invalid := false
		for key, edge_ids in conv.edges_by_entity {
			if len(edge_ids) == 0 do adjacency_invalid = true
			for edge_id in edge_ids {
				edge := conv.edges[edge_id]
				if edge == nil {
					adjacency_invalid = true
					continue
				}
				if (edge.source_type != key.target_type || u64(edge.source_id) != key.target_id) &&
				   (edge.target_type != key.target_type || u64(edge.target_id) != key.target_id) {
					adjacency_invalid = true
				}
			}
		}
		for _, edge in conv.edges {
			keys := [2]Edge_Entity_Key {
				{target_type = edge.source_type, target_id = u64(edge.source_id)},
				{target_type = edge.target_type, target_id = u64(edge.target_id)},
			}
			for key in keys {
				matches := 0
				for adjacent_id in conv.edges_by_entity[key] do if adjacent_id == edge.edge_id do matches += 1
				if matches != 1 do adjacency_invalid = true
			}
		}
		if adjacency_invalid do return "adjacency differs from generated model", false
		// Every durable-prefix/replay/compaction comparison also checks the
		// derived register, not just that its underlying records survived.
		for selector in 0 ..< 2 {
			if !generated_shard_query_slices(model, transmute([]byte)workspace_id, u64(selector)) {
				return "slice register differs from generated model", false
			}
		}
		return "", true
	}

	generated_shard_live_task_count :: proc(model: ^Generated_Shard_Model) -> u64 {
		count: u64
		for item in model.tasks do if item.live do count += 1
		return count
	}

	generated_shard_live_asset_count :: proc(model: ^Generated_Shard_Model) -> u64 {
		count: u64
		for item in model.assets do if item.live do count += 1
		return count
	}

	generated_shard_live_edge_count :: proc(model: ^Generated_Shard_Model) -> u64 {
		count: u64
		for item in model.edges do if item.live do count += 1
		return count
	}

	generated_shard_append_apply :: proc(writer: ^Shard_Transaction_Writer, built: ^Shard_Mutation_Transaction) -> bool {
		if !append_shard_transaction(writer, &built.tx) do return false
		return apply_shard_mutation(built.tx.workspace, built.mutation[0])
	}

	generated_shard_create_task :: proc(model: ^Generated_Shard_Model, writer: ^Shard_Transaction_Writer, workspace: []byte) -> bool {
		id := model.task_high + 1
		if id >= GENERATED_SHARD_MAX_ENTITIES do return true
		state := Generated_Shard_Model_Task {
			live   = true,
			status = .Todo,
		}
		attachments: [1]pr.Attachment
		task := generated_shard_task_snapshot(state, id, &attachments)
		built, ok := build_shard_task_mutation(workspace, .Create, &task, writer.floors)
		if !ok do return false
		defer destroy_shard_mutation_transaction(&built)
		if !generated_shard_append_apply(writer, &built) do return false
		model.task_high = id
		model.tasks[id] = state
		return true
	}

	generated_shard_select_live_task :: proc(model: ^Generated_Shard_Model, selector: u64) -> u64 {
		live_count := generated_shard_live_task_count(model)
		if live_count == 0 do return 0
		wanted := selector % live_count
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			if model.tasks[id].live {
				if wanted == 0 do return u64(id)
				wanted -= 1
			}
		}
		return 0
	}

	generated_shard_model_task_matches_mask :: proc(state: Generated_Shard_Model_Task, status_mask: u8) -> bool {
		return state.live && status_mask & (u8(1) << u8(state.status)) != 0
	}

	generated_shard_model_task_sort_key :: proc(state: Generated_Shard_Model_Task, id: u64) -> Task_Sort_Key {
		sort_at := state.updated_at
		if state.status == .Done do sort_at = state.completed_at
		return Task_Sort_Key{sort_at = sort_at, task_id = pr.TaskID(id)}
	}

	generated_shard_task_key_is_before_cursor :: proc(key, cursor: Task_Sort_Key) -> bool {
		return key.sort_at < cursor.sort_at || (key.sort_at == cursor.sort_at && key.task_id < cursor.task_id)
	}

	generated_shard_query_tasks_paged :: proc(model: ^Generated_Shard_Model, workspace: []byte, selector: u64) -> bool {
		status_mask := u8(1) << u8(selector % 5)
		if selector & 16 != 0 do status_mask = 0x1f
		limit := int(selector % 3) + 1
		cursor: Task_Sort_Key
		has_cursor := selector & 8 != 0
		if has_cursor {
			cursor_id := generated_shard_select_live_task(model, selector)
			if cursor_id == 0 {
				has_cursor = false
			} else {
				cursor = generated_shard_model_task_sort_key(model.tasks[cursor_id], cursor_id)
			}
		}

		expected_ids: [GENERATED_SHARD_MAX_ENTITIES]pr.TaskID
		expected_count := 0
		total_count: u32
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			state := model.tasks[id]
			if !generated_shard_model_task_matches_mask(state, status_mask) do continue
			total_count += 1
			key := generated_shard_model_task_sort_key(state, u64(id))
			if has_cursor && !generated_shard_task_key_is_before_cursor(key, cursor) do continue
			insert_at := expected_count
			for existing_id, index in expected_ids[:expected_count] {
				existing := generated_shard_model_task_sort_key(model.tasks[int(existing_id)], u64(existing_id))
				if key.sort_at > existing.sort_at || (key.sort_at == existing.sort_at && key.task_id > existing.task_id) {
					insert_at = index
					break
				}
			}
			for index := expected_count; index > insert_at; index -= 1 do expected_ids[index] = expected_ids[index - 1]
			expected_ids[insert_at] = pr.TaskID(id)
			expected_count += 1
		}

		ws := get_workspace(string(workspace))
		conv := get_conversation(ws, GENERATED_SHARD_CONV)
		req := pr.ListTasksPagedRequest {
			conv_id        = GENERATED_SHARD_CONV,
			status_mask    = status_mask,
			limit          = u16(limit),
			has_cursor     = has_cursor,
			cursor_sort_at = cursor.sort_at,
			cursor_task_id = cursor.task_id,
		}
		actual := make([dynamic]pr.Task, 0, limit)
		defer delete(actual)
		result := collect_task_page(conv, req, &actual)
		expected_page_count := min(expected_count, limit)
		if len(actual) != expected_page_count || result.total_count != total_count || result.has_more != (expected_count > expected_page_count) {
			return false
		}
		for task, index in actual do if task.id != expected_ids[index] do return false
		if expected_page_count == 0 {
			return result.next_cursor_sort_at == 0 && result.next_cursor_task_id == 0
		}
		expected_cursor_id := expected_ids[expected_page_count - 1]
		expected_cursor := generated_shard_model_task_sort_key(model.tasks[int(expected_cursor_id)], u64(expected_cursor_id))
		return result.next_cursor_sort_at == expected_cursor.sort_at && result.next_cursor_task_id == expected_cursor.task_id
	}

	generated_shard_mutate_task :: proc(
		model: ^Generated_Shard_Model,
		writer: ^Shard_Transaction_Writer,
		workspace: []byte,
		op: Task_Log_Op,
		selector: u64,
	) -> bool {
		id := generated_shard_select_live_task(model, selector)
		if id == 0 do return true
		next := model.tasks[id]
		previous_status := next.status
		model_sequence := model.task_mutation_sequence + 1
		next.status = pr.TaskStatus(selector % 5)
		next.updated_at = 10_000 + model_sequence
		if next.status == .Done {
			if previous_status != .Done do next.completed_at = next.updated_at
		} else {
			next.completed_at = 0
		}
		if op == .Update {
			next.update_variant = next.update_variant == 1 ? 2 : 1
		} else {
			next.order_index = u16((selector * 17 + id + u64(model_sequence)) % 1_000)
		}
		attachments: [1]pr.Attachment
		task := generated_shard_task_snapshot(next, id, &attachments)
		built, ok := build_shard_task_mutation(workspace, op, &task, writer.floors)
		if !ok do return false
		defer destroy_shard_mutation_transaction(&built)
		if !generated_shard_append_apply(writer, &built) do return false
		model.tasks[id] = next
		model.task_mutation_sequence = model_sequence
		return true
	}

	generated_shard_create_asset :: proc(
		model: ^Generated_Shard_Model,
		writer: ^Shard_Transaction_Writer,
		workspace: []byte,
		prefer_asset_parent: bool,
		explicit_type: pr.AssetType = {},
	) -> bool {
		id := model.asset_high + 1
		if id >= GENERATED_SHARD_MAX_ENTITIES do return true
		parent_type := pr.ParentType.None
		parent_id: u64
		if prefer_asset_parent {
			for candidate in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.assets[candidate].live {parent_type = .Asset; parent_id = u64(candidate); break}
		}
		if parent_type == .None {
			for candidate in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.tasks[candidate].live {parent_type = .Task; parent_id = u64(candidate); break}
		}
		asset_type := explicit_type
		if asset_type == {} do asset_type = id & 1 == 1 ? .Note : .Document
		// Explicit register/customer records are roots. This keeps ownership
		// cascades from deleting containers merely because a prior random asset exists.
		if explicit_type != {} {
			parent_type = .None
			parent_id = 0
		}
		state := Generated_Shard_Model_Asset {
			live        = true,
			asset_type  = asset_type,
			parent_type = parent_type,
			parent_id   = parent_id,
			updated_at  = id & 1 == 1 ? 4_000 : 4_000 + i64(id),
		}
		attachments: [1]pr.Attachment
		asset := generated_shard_asset_snapshot(state, id, &attachments)
		built, ok := build_shard_asset_mutation(workspace, .Create, &asset, writer.floors)
		if !ok do return false
		defer destroy_shard_mutation_transaction(&built)
		if !generated_shard_append_apply(writer, &built) do return false
		model.asset_high = id
		model.assets[id] = state
		return true
	}

	generated_shard_select_live_asset :: proc(model: ^Generated_Shard_Model, selector: u64) -> u64 {
		live_count := generated_shard_live_asset_count(model)
		if live_count == 0 do return 0
		wanted := selector % live_count
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			if model.assets[id].live {
				if wanted == 0 do return u64(id)
				wanted -= 1
			}
		}
		return 0
	}

	generated_shard_update_asset :: proc(model: ^Generated_Shard_Model, writer: ^Shard_Transaction_Writer, workspace: []byte, selector: u64) -> bool {
		id := generated_shard_select_live_asset(model, selector)
		if id == 0 do return true
		next := model.assets[id]
		next.update_variant = next.update_variant == 1 ? 2 : 1
		model_sequence := model.asset_mutation_sequence + 1
		next.updated_at = 20_000 + model_sequence
		attachments: [1]pr.Attachment
		asset := generated_shard_asset_snapshot(next, id, &attachments)
		built, ok := build_shard_asset_mutation(workspace, .Update, &asset, writer.floors)
		if !ok do return false
		defer destroy_shard_mutation_transaction(&built)
		if !generated_shard_append_apply(writer, &built) do return false
		model.assets[id] = next
		model.asset_mutation_sequence = model_sequence
		return true
	}

	generated_shard_asset_matches_scope :: proc(state: Generated_Shard_Model_Asset, scope: Note_Page_Scope, filter: string) -> bool {
		if !state.live || state.asset_type != .Note do return false
		switch scope {
		case .Project:
			return generated_shard_asset_project(state) == filter
		case .Tag:
			return generated_shard_asset_has_tag(state, filter)
		case .Global:
			return true
		}
		return false
	}

	generated_shard_query_assets_paged :: proc(model: ^Generated_Shard_Model, workspace: []byte, selector: u64) -> bool {
		scope := Note_Page_Scope(selector % 3)
		filter := ""
		if scope == .Project do filter = selector & 4 == 0 ? "alpha" : "beta"
		if scope == .Tag do filter = selector & 4 == 0 ? "shared" : "graph"
		limit := int(selector % 2) + 1

		expected_ids: [GENERATED_SHARD_MAX_ENTITIES]pr.AssetID
		expected_count := 0
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			state := model.assets[id]
			if !generated_shard_asset_matches_scope(state, scope, filter) do continue
			insert_at := expected_count
			for existing_id, index in expected_ids[:expected_count] {
				existing := model.assets[int(existing_id)]
				if state.updated_at > existing.updated_at || (state.updated_at == existing.updated_at && pr.AssetID(id) > existing_id) {
					insert_at = index
					break
				}
			}
			for index := expected_count; index > insert_at; index -= 1 do expected_ids[index] = expected_ids[index - 1]
			expected_ids[insert_at] = pr.AssetID(id)
			expected_count += 1
		}

		has_cursor := selector & 8 != 0 && expected_count > 0
		cursor_index := -1
		cursor_updated_at: i64
		cursor_asset_id: pr.AssetID
		if has_cursor {
			cursor_index = int(selector % u64(expected_count))
			cursor_asset_id = expected_ids[cursor_index]
			cursor_updated_at = model.assets[int(cursor_asset_id)].updated_at
		}
		start_index := cursor_index + 1
		remaining := expected_count - start_index
		expected_page_count := min(remaining, limit)

		ws := get_workspace(string(workspace))
		conv := get_conversation(ws, GENERATED_SHARD_CONV)
		actual := make([dynamic]pr.Asset, 0, limit)
		defer delete(actual)
		result := collect_note_page(conv, scope, filter, u16(limit), has_cursor, cursor_updated_at, cursor_asset_id, &actual)
		if len(actual) != expected_page_count || result.total_count != u32(expected_count) || result.has_more != (remaining > expected_page_count) {
			return false
		}
		for asset, index in actual do if asset.asset_id != expected_ids[start_index + index] do return false
		if expected_page_count == 0 {
			return result.next_cursor_updated_at == 0 && result.next_cursor_asset_id == 0
		}
		expected_cursor_id := expected_ids[start_index + expected_page_count - 1]
		return result.next_cursor_updated_at == model.assets[int(expected_cursor_id)].updated_at && result.next_cursor_asset_id == expected_cursor_id
	}

	generated_shard_live_entity_count :: proc(model: ^Generated_Shard_Model) -> u64 {
		return generated_shard_live_task_count(model) + generated_shard_live_asset_count(model)
	}

	generated_shard_select_live_entity :: proc(model: ^Generated_Shard_Model, ordinal: u64) -> (pr.TargetType, u64, bool) {
		wanted := ordinal
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			if !model.tasks[id].live do continue
			if wanted == 0 do return .Task, u64(id), true
			wanted -= 1
		}
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			if !model.assets[id].live do continue
			if wanted == 0 do return .Asset, u64(id), true
			wanted -= 1
		}
		return {}, 0, false
	}

	generated_shard_create_edge :: proc(model: ^Generated_Shard_Model, writer: ^Shard_Transaction_Writer, workspace: []byte, selector: u64) -> bool {
		id := model.edge_high + 1
		if id >= GENERATED_SHARD_MAX_ENTITIES do return true
		entity_count := generated_shard_live_entity_count(model)
		if entity_count < 2 do return true
		source_index := selector % entity_count
		target_index := (source_index + 1 + (selector / entity_count) % (entity_count - 1)) % entity_count
		source_type, source_id, source_ok := generated_shard_select_live_entity(model, source_index)
		target_type, target_id, target_ok := generated_shard_select_live_entity(model, target_index)
		if !source_ok || !target_ok do return false
		relation := pr.RelationType(u64(min(pr.RelationType)) + (selector / (entity_count * (entity_count - 1))) % u64(len(pr.RelationType)))
		if relation == .MemberOf {
			for edge in model.edges {
				if !edge.live || edge.relation != .MemberOf do continue
				same := edge.source_type == source_type && edge.source_id == source_id && edge.target_type == target_type && edge.target_id == target_id
				reverse := edge.source_type == target_type && edge.source_id == target_id && edge.target_type == source_type && edge.target_id == source_id
				if same || reverse do relation = .References
			}
		}
		edge := pr.Edge {
			edge_id     = pr.EdgeID(id),
			conv_id     = GENERATED_SHARD_CONV,
			source_type = source_type,
			source_id   = source_id,
			target_type = target_type,
			target_id   = target_id,
			relation    = relation,
			created_by  = transmute([]byte)string("generated"),
		}
		built, ok := build_shard_edge_mutation(workspace, .Create, &edge, writer.floors)
		if !ok do return false
		defer destroy_shard_mutation_transaction(&built)
		if !generated_shard_append_apply(writer, &built) do return false
		model.edge_high = id
		model.edges[id] = {
			live        = true,
			source_type = source_type,
			source_id   = source_id,
			target_type = target_type,
			target_id   = target_id,
			relation    = relation,
		}
		return true
	}

	generated_shard_create_membership :: proc(model: ^Generated_Shard_Model, writer: ^Shard_Transaction_Writer, workspace: []byte, selector: u64) -> bool {
		id := model.edge_high + 1
		if id >= GENERATED_SHARD_MAX_ENTITIES do return true
		slices: [GENERATED_SHARD_MAX_ENTITIES]u64
		members: [GENERATED_SHARD_MAX_ENTITIES * 2]Generated_Shard_Graph_Node
		slice_count, member_count := 0, 0
		for asset_id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			asset := model.assets[asset_id]
			if !asset.live do continue
			if asset.asset_type == .Slice {slices[slice_count] = u64(asset_id); slice_count += 1}
			if asset.asset_type == .Note || asset.asset_type == .File || asset.asset_type == .CustomerCompany {
				members[member_count] = {
					target_type = .Asset,
					target_id   = u64(asset_id),
				}; member_count += 1
			}
		}
		for task_id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.tasks[task_id].live {
			members[member_count] = {
				target_type = .Task,
				target_id   = u64(task_id),
			}; member_count += 1
		}
		if slice_count == 0 || member_count == 0 do return true
		slice_id := slices[selector % u64(slice_count)]
		member := members[(selector / u64(slice_count)) % u64(member_count)]
		// The same relation also expresses customer membership. Generate that
		// shape explicitly; slice folding must discriminate the company target.
		if selector & 128 != 0 {
			for asset_id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.assets[asset_id].live && model.assets[asset_id].asset_type == .CustomerCompany {slice_id = u64(asset_id); break}
			for task_id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.tasks[task_id].live {member = {
					target_type = .Task,
					target_id   = u64(task_id),
				}; break}
			for asset_id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
				if model.assets[asset_id].live && model.assets[asset_id].asset_type == .CustomerContact {
					member = {
						target_type = .Asset,
						target_id   = u64(asset_id),
					}
					break
				}
			}
		}
		if member.target_type == .Asset && member.target_id == slice_id do return true
		// MemberOf identity is an unordered endpoint pair. Skip already accepted
		// memberships so generated WAL operations always preserve set semantics.
		for edge in model.edges {
			if !edge.live || edge.relation != .MemberOf do continue
			same := edge.source_type == member.target_type && edge.source_id == member.target_id && edge.target_type == .Asset && edge.target_id == slice_id
			reversed :=
				edge.target_type == member.target_type && edge.target_id == member.target_id && edge.source_type == .Asset && edge.source_id == slice_id
			if same || reversed do return true
		}
		source_type, source_id := member.target_type, member.target_id
		target_type, target_id := pr.TargetType.Asset, slice_id
		if selector & 1 != 0 {source_type, target_type = target_type, source_type; source_id, target_id = target_id, source_id}
		edge := pr.Edge {
			edge_id     = pr.EdgeID(id),
			conv_id     = GENERATED_SHARD_CONV,
			source_type = source_type,
			source_id   = source_id,
			target_type = target_type,
			target_id   = target_id,
			relation    = .MemberOf,
			created_by  = transmute([]byte)string("generated-member"),
		}
		built, ok := build_shard_edge_mutation(workspace, .Create, &edge, writer.floors)
		if !ok do return false
		defer destroy_shard_mutation_transaction(&built)
		if !generated_shard_append_apply(writer, &built) do return false
		model.edge_high = id
		model.edges[id] = {
			live        = true,
			source_type = source_type,
			source_id   = source_id,
			target_type = target_type,
			target_id   = target_id,
			relation    = .MemberOf,
			created_by  = "generated-member",
		}
		return true
	}

	generated_shard_query_slices :: proc(model: ^Generated_Shard_Model, workspace: []byte, selector: u64) -> (ok: bool) {
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil do return false
		defer virtual.arena_destroy(&arena)
		allocator := virtual.arena_allocator(&arena)
		owners := [?]string{"", "generated-owner", "", "other-owner"}
		names := [?]string{"", "SLICE-0", "-02", "absent"}
		owner_mode := (selector / 2) % 4
		name_mode := (selector / 8) % 4
		query := Slice_Query {
			include_closed     = selector & 1 != 0,
			has_owner          = owner_mode != 0,
			owner              = owners[owner_mode],
			has_name           = name_mode != 0,
			name               = names[name_mode],
			limit              = int((selector / 32) % 3) + 1,
			with_work_counters = owner_mode == 0 && name_mode == 0,
		}
		expected: [GENERATED_SHARD_MAX_ENTITIES]Generated_Shard_Slice_Expected
		assigned_tasks: [GENERATED_SHARD_MAX_ENTITIES]bool
		count := 0
		for slice_id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			state := model.assets[slice_id]
			if !state.live || state.asset_type != .Slice do continue
			closed := state.update_variant == 1
			entry := Generated_Shard_Slice_Expected {
				id      = pr.AssetID(slice_id),
				closed  = closed,
				sort_at = state.created_at != 0 ? state.created_at : 3_000 + i64(slice_id),
			}
			for edge in model.edges {
				if !edge.live || edge.relation != .MemberOf do continue
				member_type: pr.TargetType
				member_id: u64
				if edge.target_type == .Asset && edge.target_id == u64(slice_id) {
					member_type, member_id = edge.source_type, edge.source_id
				} else if edge.source_type == .Asset && edge.source_id == u64(slice_id) {
					member_type, member_id = edge.target_type, edge.target_id
				} else {
					continue
				}
				if member_type == .Task {
					task := model.tasks[member_id]
					if !task.live || task.status == .Note do continue
					assigned_tasks[member_id] = true
					switch task.status {
					case .Backlog:
						entry.backlog += 1
					case .Todo:
						entry.todo += 1
					case .InProgress:
						entry.in_progress += 1
					case .Done:
						entry.done += 1
					case .Note:
					}
					// Model tasks carry their own nonzero ID as blocked_by.
					entry.blocked += 1
					created_at := 1_000 + i64(member_id)
					if task.status != .Done && (entry.oldest_active_at == 0 || created_at < entry.oldest_active_at) do entry.oldest_active_at = created_at
					entry.last_moved_at = max(entry.last_moved_at, task.updated_at)
				} else if member_type == .Asset {
					asset := model.assets[member_id]
					if !asset.live do continue
					if asset.asset_type == .Note do entry.notes += 1
					if asset.asset_type == .File do entry.files += 1
					if asset.asset_type == .Note || asset.asset_type == .File do entry.last_moved_at = max(entry.last_moved_at, asset.updated_at)
				}
			}
			// Fold global assignment before filtering: closed and hidden slices
			// still own their tasks. No production fold or comparator is used.
			if closed && !query.include_closed do continue
			if query.has_owner && generated_shard_slice_owner(state, u64(slice_id)) != query.owner do continue
			if query.has_name && !strings.contains(generated_shard_slice_name(u64(slice_id)), strings.to_lower(query.name, allocator)) do continue
			entry.sort_at = max(entry.sort_at, entry.last_moved_at)
			insert_at := count
			for existing, index in expected[:count] {
				if (entry.closed != existing.closed && !entry.closed) ||
				   (entry.closed == existing.closed && (entry.sort_at > existing.sort_at || (entry.sort_at == existing.sort_at && entry.id < existing.id))) {
					insert_at = index
					break
				}
			}
			for index := count; index > insert_at; index -= 1 do expected[index] = expected[index - 1]
			expected[insert_at] = entry
			count += 1
		}
		expected_assigned, expected_unassigned: u32
		for task, id in model.tasks {
			if !task.live || task.status == .Note do continue
			if assigned_tasks[id] {expected_assigned += 1} else {expected_unassigned += 1}
		}
		ws := get_workspace(string(workspace))
		conv := get_conversation(ws, GENERATED_SHARD_CONV)
		actual := make([dynamic]pr.TaskSlice, 0, query.limit, allocator)
		assigned := make(map[pr.TaskID]struct{}, allocator)
		consumed := 0
		// Walk every page plus one request beyond the last cursor. Bounded by
		// the model, so broken progress cannot hang the property or repeat rows.
		for _ in 0 ..< GENERATED_SHARD_MAX_ENTITIES + 1 {
			clear(&actual)
			clear(&assigned)
			page := collect_task_slices(conv, query, &actual, &assigned, allocator)
			page_size := min(count - consumed, query.limit)
			defer if !ok {
				fmt.eprintf(
					"slice model mismatch: query=%v consumed=%d page=%v rows=%v expected=%v assigned=%d unassigned=%d\n",
					query,
					consumed,
					page,
					actual[:],
					expected[:count],
					expected_assigned,
					expected_unassigned,
				)
			}
			if len(actual) != page_size || page.total_count != u32(count) || page.has_more != (consumed + page_size < count) do return false
			want_assigned, want_unassigned: u32
			if query.with_work_counters {want_assigned, want_unassigned = expected_assigned, expected_unassigned}
			if page.assigned_tasks != want_assigned || page.unassigned_tasks != want_unassigned do return false
			for row, index in actual {
				e := expected[consumed + index]
				if row.slice_id != e.id ||
				   (pr.TaskSliceFlag_CLOSED <= row.flags) != e.closed ||
				   string(row.name) != generated_shard_slice_name(u64(e.id)) ||
				   string(row.owner) != generated_shard_slice_owner(model.assets[e.id], u64(e.id)) ||
				   row.backlog != e.backlog ||
				   row.todo != e.todo ||
				   row.in_progress != e.in_progress ||
				   row.done != e.done ||
				   row.blocked != e.blocked ||
				   row.notes != e.notes ||
				   row.files != e.files ||
				   row.oldest_active_at != e.oldest_active_at ||
				   row.last_moved_at != e.last_moved_at {
					return false
				}
			}
			if page_size == 0 do return page.next_cursor == {}
			consumed += page_size
			last := expected[consumed - 1]
			if page.next_cursor.closed != last.closed || page.next_cursor.sort_at != last.sort_at || page.next_cursor.slice_id != last.id do return false
			query.has_cursor = true
			query.cursor_closed = page.next_cursor.closed
			query.cursor_sort_at = page.next_cursor.sort_at
			query.cursor_slice_id = page.next_cursor.slice_id
			query.with_work_counters = false
			ok = true
		}
		return false
	}

	generated_shard_query_graph :: proc(model: ^Generated_Shard_Model, workspace: []byte, selector: u64) -> bool {
		entity_count := generated_shard_live_entity_count(model)
		if entity_count == 0 do return true
		start_type, start_id, start_ok := generated_shard_select_live_entity(model, selector % entity_count)
		if !start_ok do return false
		max_depth := u8(1 + (selector / entity_count) % 4)
		direction := pr.Direction((selector / (entity_count * 4)) % 3)
		relation_slot := u16((selector / (entity_count * 12)) % (u64(max(pr.RelationType)) + 1))
		relation_mask: u16
		if relation_slot > 0 do relation_mask = u16(1) << (relation_slot - 1)

		visited: [3][GENERATED_SHARD_MAX_ENTITIES]bool
		depths: [3][GENERATED_SHARD_MAX_ENTITIES]u8
		queue: [GENERATED_SHARD_MAX_ENTITIES * 2]Generated_Shard_Graph_Node
		queue_count := 1
		queue[0] = {
			target_type = start_type,
			target_id   = start_id,
		}
		visited[int(start_type)][start_id] = true
		expected_edges: [GENERATED_SHARD_MAX_ENTITIES]bool
		for queue_index := 0; queue_index < queue_count; queue_index += 1 {
			entry := queue[queue_index]
			if entry.depth >= max_depth do continue
			for edge_id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
				edge := model.edges[edge_id]
				if !edge.live do continue
				relation_value := u16(edge.relation)
				if relation_mask != 0 && (relation_value < u16(min(pr.RelationType)) || relation_value > u16(max(pr.RelationType)) || relation_mask & (u16(1) << (relation_value - 1)) == 0) do continue
				neighbor_type: pr.TargetType
				neighbor_id: u64
				resolved := false
				if edge.source_type == entry.target_type && edge.source_id == entry.target_id && direction != .Incoming {
					neighbor_type, neighbor_id, resolved = edge.target_type, edge.target_id, true
				} else if edge.target_type == entry.target_type && edge.target_id == entry.target_id && direction != .Outgoing {
					neighbor_type, neighbor_id, resolved = edge.source_type, edge.source_id, true
				}
				if !resolved do continue
				if !visited[int(neighbor_type)][neighbor_id] {
					visited[int(neighbor_type)][neighbor_id] = true
					depths[int(neighbor_type)][neighbor_id] = entry.depth + 1
					queue[queue_count] = {
						target_type = neighbor_type,
						target_id   = neighbor_id,
						depth       = entry.depth + 1,
					}
					queue_count += 1
				}
				expected_edges[edge_id] = true
			}
		}

		expected_nodes: [GENERATED_SHARD_MAX_ENTITIES * 2]Generated_Shard_Graph_Node
		expected_node_count := 0
		for entity_type in pr.TargetType.Asset ..= pr.TargetType.Task {
			for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
				if !visited[int(entity_type)][id] do continue
				node := Generated_Shard_Graph_Node {
					target_type = entity_type,
					target_id   = u64(id),
					depth       = depths[int(entity_type)][id],
				}
				insert_at := expected_node_count
				for existing, index in expected_nodes[:expected_node_count] {
					if node.depth < existing.depth ||
					   (node.depth == existing.depth &&
							   (node.target_type < existing.target_type ||
									   (node.target_type == existing.target_type && node.target_id < existing.target_id))) {
						insert_at = index
						break
					}
				}
				for index := expected_node_count; index > insert_at; index -= 1 do expected_nodes[index] = expected_nodes[index - 1]
				expected_nodes[insert_at] = node
				expected_node_count += 1
			}
		}

		ws := get_workspace(string(workspace))
		conv := get_conversation(ws, GENERATED_SHARD_CONV)
		if conv == nil do return false
		req := pr.GraphQueryRequest {
			conv_id       = GENERATED_SHARD_CONV,
			start_type    = start_type,
			start_id      = start_id,
			max_depth     = max_depth,
			relation_mask = relation_mask,
			direction     = direction,
		}
		actual_nodes, actual_edges, truncated := collect_graph_query(conv, req)
		defer delete(actual_nodes)
		defer delete(actual_edges)
		if truncated || len(actual_nodes) != expected_node_count do return false
		for node, index in actual_nodes {
			expected := expected_nodes[index]
			if node.target_type != expected.target_type || node.target_id != expected.target_id || node.depth != expected.depth do return false
		}
		expected_edge_count := 0
		for present in expected_edges do if present do expected_edge_count += 1
		if len(actual_edges) != expected_edge_count do return false
		actual_index := 0
		for edge_id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			if !expected_edges[edge_id] do continue
			if actual_edges[actual_index].edge_id != pr.EdgeID(edge_id) do return false
			actual_index += 1
		}
		return true
	}

	generated_shard_delete_edge :: proc(model: ^Generated_Shard_Model, writer: ^Shard_Transaction_Writer, workspace: []byte, selector: u64) -> bool {
		live_count := generated_shard_live_edge_count(model)
		if live_count == 0 do return true
		wanted := selector % live_count
		edge_id: u64
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.edges[id].live {if wanted == 0 {edge_id = u64(id); break}; wanted -= 1}
		built, ok := build_shard_edge_delete_mutation(workspace, GENERATED_SHARD_CONV, pr.EdgeID(edge_id), writer.floors)
		if !ok do return false
		defer destroy_shard_mutation_transaction(&built)
		if !generated_shard_append_apply(writer, &built) do return false
		model.edges[edge_id].live = false
		return true
	}

	generated_shard_delete_asset :: proc(model: ^Generated_Shard_Model, writer: ^Shard_Transaction_Writer, workspace: []byte, selector: u64) -> bool {
		root: u64
		live_count := generated_shard_live_asset_count(model)
		if live_count == 0 do return true
		wanted := selector % live_count
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.assets[id].live {if wanted == 0 {root = u64(id); break}; wanted -= 1}
		expected_edge_storage: [GENERATED_SHARD_MAX_ENTITIES]pr.EdgeID
		expected_edge_count := 0
		selected: [GENERATED_SHARD_MAX_ENTITIES]bool
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.assets[id].live && generated_shard_asset_descends_from(model, u64(id), root) do selected[id] = true
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			edge := model.edges[id]
			if edge.live &&
			   ((edge.source_type == .Asset && selected[edge.source_id]) ||
					   (edge.target_type == .Asset &&
							   selected[edge.target_id])) {expected_edge_storage[expected_edge_count] = pr.EdgeID(id); expected_edge_count += 1}
		}

		ws := get_workspace(string(workspace))
		conv := get_conversation(ws, GENERATED_SHARD_CONV)
		if conv == nil do return false
		children := make([dynamic]pr.AssetID, 0, 16)
		defer delete(children)
		collect_child_asset_delete_ids(conv, pr.AssetID(root), &children)
		production_assets := make([]pr.AssetID, len(children) + 1)
		defer delete(production_assets)
		copy(production_assets, children[:])
		production_assets[len(children)] = pr.AssetID(root)
		child_edges: Edge_Delete_Plan
		edge_delete_plan_init(&child_edges)
		defer edge_delete_plan_destroy(&child_edges)
		for child_id in children do collect_edges_for_entity_delete(conv, &child_edges, .Asset, u64(child_id))
		root_edges: Edge_Delete_Plan
		edge_delete_plan_init(&root_edges)
		defer edge_delete_plan_destroy(&root_edges)
		collect_edges_for_entity_delete_excluding(conv, &root_edges, .Asset, root, &child_edges)
		production_selected: [GENERATED_SHARD_MAX_ENTITIES]bool
		production_edges: [GENERATED_SHARD_MAX_ENTITIES]bool
		for asset_id in production_assets {
			if asset_id == 0 || int(asset_id) >= GENERATED_SHARD_MAX_ENTITIES do return false
			production_selected[asset_id] = true
		}
		for edge_id in child_edges.edge_ids {
			if edge_id == 0 || int(edge_id) >= GENERATED_SHARD_MAX_ENTITIES do return false
			production_edges[edge_id] = true
		}
		for edge_id in root_edges.edge_ids {
			if edge_id == 0 || int(edge_id) >= GENERATED_SHARD_MAX_ENTITIES do return false
			production_edges[edge_id] = true
		}
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			if production_selected[id] != selected[id] do return false
			expected_edge := false
			for edge_id in expected_edge_storage[:expected_edge_count] do if int(edge_id) == id do expected_edge = true
			if production_edges[id] != expected_edge do return false
		}
		cascade, ok := build_shard_asset_delete_transaction(
			workspace,
			GENERATED_SHARD_CONV,
			production_assets,
			child_edges.edge_ids[:],
			root_edges.edge_ids[:],
			writer.floors,
		)
		if !ok do return false
		defer destroy_shard_asset_delete_transaction(&cascade)
		if !persist_and_apply_shard_delete_transaction(writer, &cascade.tx) do return false
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if selected[id] do model.assets[id].live = false
		for edge_id in expected_edge_storage[:expected_edge_count] do model.edges[edge_id].live = false
		return true
	}

	generated_shard_model_delete_task :: proc(model: ^Generated_Shard_Model, task_id: u64) {
		selected_assets: [GENERATED_SHARD_MAX_ENTITIES]bool
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.assets[id].live && generated_shard_asset_owned_by_task(model, u64(id), task_id) do selected_assets[id] = true
		model.tasks[task_id].live = false
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			if selected_assets[id] do model.assets[id].live = false
			edge := model.edges[id]
			if !edge.live do continue
			if (edge.source_type == .Task && edge.source_id == task_id) ||
			   (edge.target_type == .Task && edge.target_id == task_id) ||
			   (edge.source_type == .Asset && selected_assets[edge.source_id]) ||
			   (edge.target_type == .Asset && selected_assets[edge.target_id]) {
				model.edges[id].live = false
			}
		}
	}

	generated_shard_delete_task :: proc(model: ^Generated_Shard_Model, writer: ^Shard_Transaction_Writer, workspace: []byte, selector: u64) -> bool {
		live_count := generated_shard_live_task_count(model)
		if live_count == 0 do return true
		wanted := selector % live_count
		task_id: u64
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.tasks[id].live {if wanted == 0 {task_id = u64(id); break}; wanted -= 1}
		expected_asset_edges: [GENERATED_SHARD_MAX_ENTITIES]pr.EdgeID
		expected_task_edges: [GENERATED_SHARD_MAX_ENTITIES]pr.EdgeID
		expected_asset_edge_count, expected_task_edge_count := 0, 0
		selected: [GENERATED_SHARD_MAX_ENTITIES]bool
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.assets[id].live && generated_shard_asset_owned_by_task(model, u64(id), task_id) do selected[id] = true
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			edge := model.edges[id]
			if !edge.live do continue
			if (edge.source_type == .Asset && selected[edge.source_id]) ||
			   (edge.target_type == .Asset &&
					   selected[edge.target_id]) {expected_asset_edges[expected_asset_edge_count] = pr.EdgeID(id); expected_asset_edge_count += 1} else if (edge.source_type == .Task && edge.source_id == task_id) || (edge.target_type == .Task && edge.target_id == task_id) {expected_task_edges[expected_task_edge_count] = pr.EdgeID(id); expected_task_edge_count += 1}
		}

		ws := get_workspace(string(workspace))
		conv := get_conversation(ws, GENERATED_SHARD_CONV)
		if conv == nil do return false
		production_assets := make([dynamic]pr.AssetID, 0, 16)
		defer delete(production_assets)
		collect_task_asset_delete_ids(conv, pr.TaskID(task_id), &production_assets)
		asset_edges: Edge_Delete_Plan
		edge_delete_plan_init(&asset_edges)
		defer edge_delete_plan_destroy(&asset_edges)
		for asset_id in production_assets do collect_edges_for_entity_delete(conv, &asset_edges, .Asset, u64(asset_id))
		task_edges: Edge_Delete_Plan
		edge_delete_plan_init(&task_edges)
		defer edge_delete_plan_destroy(&task_edges)
		collect_edges_for_entity_delete_excluding(conv, &task_edges, .Task, task_id, &asset_edges)
		production_selected: [GENERATED_SHARD_MAX_ENTITIES]bool
		production_asset_edges: [GENERATED_SHARD_MAX_ENTITIES]bool
		production_task_edges: [GENERATED_SHARD_MAX_ENTITIES]bool
		for asset_id in production_assets {
			if asset_id == 0 || int(asset_id) >= GENERATED_SHARD_MAX_ENTITIES do return false
			production_selected[asset_id] = true
		}
		for edge_id in asset_edges.edge_ids {
			if edge_id == 0 || int(edge_id) >= GENERATED_SHARD_MAX_ENTITIES do return false
			production_asset_edges[edge_id] = true
		}
		for edge_id in task_edges.edge_ids {
			if edge_id == 0 || int(edge_id) >= GENERATED_SHARD_MAX_ENTITIES do return false
			production_task_edges[edge_id] = true
		}
		for id in 1 ..< GENERATED_SHARD_MAX_ENTITIES {
			if production_selected[id] != selected[id] do return false
			expected_asset_edge := false
			for edge_id in expected_asset_edges[:expected_asset_edge_count] do if int(edge_id) == id do expected_asset_edge = true
			expected_task_edge := false
			for edge_id in expected_task_edges[:expected_task_edge_count] do if int(edge_id) == id do expected_task_edge = true
			if production_asset_edges[id] != expected_asset_edge || production_task_edges[id] != expected_task_edge do return false
		}
		cascade, ok := build_shard_task_delete_transaction(
			workspace,
			GENERATED_SHARD_CONV,
			pr.TaskID(task_id),
			production_assets[:],
			asset_edges.edge_ids[:],
			task_edges.edge_ids[:],
			writer.floors,
		)
		if !ok do return false
		defer destroy_shard_task_delete_transaction(&cascade)
		if !persist_and_apply_shard_delete_transaction(writer, &cascade.tx) do return false
		generated_shard_model_delete_task(model, task_id)
		return true
	}

	generated_shard_restore_state :: proc(writer: ^Shard_Transaction_Writer) -> bool {
		shard_replay_state_init()
		floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
		if !replay_ok || floors != writer.floors {
			shard_replay_state_destroy()
			return false
		}
		return true
	}

	generated_shard_crash_restart :: proc(writer: ^Shard_Transaction_Writer, shard_dir: string, shard: int) -> bool {
		storage := writer.storage
		persistence.force_fsync(&writer.wal)
		if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count do return false
		if writer.oversized_write != nil do byte_pool.release(td.spool, writer.oversized_write)
		persistence.simulate_wal_crash_for_test(&writer.wal)
		persistence.cleanup_init_wal_state(&writer.wal)
		discard_shard_deferred_requests(writer)
		delete(writer.durability_waiters)
		destroy_shard_segment_catalog(&writer.catalog)
		if writer.shard_dir != "" do delete(writer.shard_dir)
		writer^ = {}
		shard_replay_state_destroy()
		if !init_managed_shard_transaction_writer(writer, storage, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			shard_replay_state_init()
			return false
		}
		return generated_shard_restore_state(writer)
	}

	generated_shard_compact :: proc(writer: ^Shard_Transaction_Writer) -> bool {
		if !writer.manifest.sealed_present do return true
		shard_replay_state_destroy()
		job_dir, clone_err := strings.clone(writer.shard_dir)
		if clone_err != nil {
			shard_replay_state_init()
			return false
		}
		job := Shard_Compaction_Job {
			owner_worker          = writer.owner_worker,
			shard                 = writer.shard,
			storage               = writer.storage,
			manifest              = writer.manifest,
			checkpoint_generation = writer.manifest.manifest_generation + 1,
			shard_dir             = job_dir,
		}
		writer.compaction = .Building
		result := run_shard_compaction_job(job)
		defer destroy_shard_segment_clean_result(&result.segments)
		if !result.ok || !publish_shard_compaction_result(writer, result) {
			shard_replay_state_init()
			return false
		}
		return generated_shard_restore_state(writer)
	}

	generated_shard_apply_op :: proc(
		model: ^Generated_Shard_Model,
		writer: ^Shard_Transaction_Writer,
		workspace: []byte,
		shard_dir: string,
		op: Generated_Shard_Op,
	) -> bool {
		switch op.kind {
		case .Create_Task:
			return generated_shard_create_task(model, writer, workspace)
		case .Update_Task:
			return generated_shard_mutate_task(model, writer, workspace, .Update, op.selector)
		case .Move_Task:
			return generated_shard_mutate_task(model, writer, workspace, .Move, op.selector)
		case .Query_Tasks_Paged:
			return generated_shard_query_tasks_paged(model, workspace, op.selector)
		case .Create_Asset:
			return generated_shard_create_asset(model, writer, workspace, op.selector & 1 == 1)
		case .Create_Slice:
			return generated_shard_create_asset(model, writer, workspace, false, .Slice)
		case .Create_File:
			return generated_shard_create_asset(model, writer, workspace, false, .File)
		case .Create_Customer:
			return generated_shard_create_asset(model, writer, workspace, false, .CustomerCompany)
		case .Create_Contact:
			return generated_shard_create_asset(model, writer, workspace, false, .CustomerContact)
		case .Update_Asset:
			return generated_shard_update_asset(model, writer, workspace, op.selector)
		case .Query_Assets_Paged:
			return generated_shard_query_assets_paged(model, workspace, op.selector)
		case .Create_Edge:
			return generated_shard_create_edge(model, writer, workspace, op.selector)
		case .Create_Membership:
			return generated_shard_create_membership(model, writer, workspace, op.selector)
		case .Query_Graph:
			return generated_shard_query_graph(model, workspace, op.selector)
		case .Query_Slices:
			return generated_shard_query_slices(model, workspace, op.selector)
		case .Delete_Asset:
			return generated_shard_delete_asset(model, writer, workspace, op.selector)
		case .Delete_Task:
			return generated_shard_delete_task(model, writer, workspace, op.selector)
		case .Delete_Edge:
			return generated_shard_delete_edge(model, writer, workspace, op.selector)
		case .Crash_Restart:
			return generated_shard_crash_restart(writer, shard_dir, writer.shard)
		case .Rotate:
			if writer.manifest.sealed_present do return true
			return rotate_shard_writer_for_compaction(writer)
		case .Compact:
			return generated_shard_compact(writer)
		}
		return false
	}

	generated_shard_log_replay_fixture :: proc(ops: []Generated_Shard_Op, op_index: int, reason: string) {
		fmt.eprintf("generated transactional shard failure: op_index=%d reason=%s\n", op_index, reason)
		fmt.eprintf("Copy this into a regression test and run generated_shard_replay_ops(t, ops[:]):\n")
		fmt.eprintf("ops := [?]Generated_Shard_Op {{\n")
		for op, index in ops {
			fmt.eprintf("\t// %d\n\t{{kind = .%v, selector = %d}},\n", index, op.kind, op.selector)
		}
		fmt.eprintf("}}\n")
	}

	generated_shard_run_ops :: proc(ops: []Generated_Shard_Op, thread_index: int, emit_fixture: bool) -> (reason: string, ok: bool) {
		workspace_id := "generated-transactional-shard"
		workspace := transmute([]byte)workspace_id
		shard := int(shard_for_workspace(workspace))
		shard_dir := storage_layout_test_setup(fmt.tprintf("generated-transactional-shard-%d", thread_index))
		defer os.remove_all(shard_dir)
		active_path := shard_generation_wal_path(shard_dir, 0)
		if os.write_entire_file(active_path, nil) != nil {
			delete(active_path)
			return "create managed shard WAL", false
		}
		delete(active_path)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, thread_index)
		defer simulation_test_end(&ctx)
		writer: Shard_Transaction_Writer
		if !init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
			return "initialize managed production shard writer", false
		}
		defer shutdown_shard_transaction_writer(&writer)

		model: Generated_Shard_Model
		for op, op_index in ops {
			if !generated_shard_apply_op(&model, &writer, workspace, shard_dir, op) {
				reason = "production semantic operation failed"
				if emit_fixture do generated_shard_log_replay_fixture(ops[:op_index + 1], op_index, reason)
				return reason, false
			}
			if compare_reason, equal := generated_shard_compare(&model, workspace_id, writer.floors); !equal {
				if emit_fixture do generated_shard_log_replay_fixture(ops[:op_index + 1], op_index, compare_reason)
				return compare_reason, false
			}
		}
		return "", true
	}

	generated_shard_replay_ops :: proc(t: ^testing.T, ops: []Generated_Shard_Op, thread_index: int = 87) -> bool {
		reason, ok := generated_shard_run_ops(ops, thread_index, true)
		testing.expectf(t, ok, "generated transactional shard replay fixture failed: %s", reason)
		return ok
	}

	prop_generated_transactional_shard_state :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		op_count, draw_err := hgl.draw_i64(tc, 0, GENERATED_SHARD_MAX_OPS)
		if draw_err == .Stop_Test do return hgl.abort()
		if draw_err != nil do return hgl.interesting("operation-count draw failed")

		// The stable semantic prefix guarantees task update/move, CRUD cascades, crash/restart,
		// rotation, writes to the new active WAL, sealed restart, and checkpoint
		// publication even when Hegel shrinks the generated suffix to zero.
		prefix := [?]Generated_Shard_Op {
			{kind = .Create_Task},
			{kind = .Create_Asset},
			{kind = .Create_Slice},
			{kind = .Create_File},
			{kind = .Create_Customer},
			{kind = .Create_Slice},
			{kind = .Create_Contact},
			{kind = .Create_Membership, selector = 0},
			{kind = .Create_Membership, selector = 1},
			{kind = .Create_Membership, selector = 2},
			{kind = .Create_Membership, selector = 6},
			{kind = .Create_Membership, selector = 7},
			{kind = .Create_Membership, selector = 128},
			{kind = .Query_Slices, selector = 1},
			{kind = .Query_Slices, selector = 3},
			{kind = .Query_Slices, selector = 5},
			{kind = .Query_Slices, selector = 9},
			{kind = .Query_Slices, selector = 17},
			{kind = .Query_Slices, selector = 25},
			{kind = .Update_Task, selector = 3},
			{kind = .Query_Slices, selector = 1},
			{kind = .Update_Asset, selector = 1},
			{kind = .Query_Slices, selector = 1},
			{kind = .Update_Asset, selector = 1},
			{kind = .Query_Slices, selector = 7},
			// Remove every membership to exercise non-empty -> empty histories,
			// then repopulate in both directions before the first restart.
			{kind = .Delete_Edge, selector = 0},
			{kind = .Delete_Edge, selector = 0},
			{kind = .Delete_Edge, selector = 0},
			{kind = .Delete_Edge, selector = 0},
			{kind = .Delete_Edge, selector = 0},
			{kind = .Delete_Edge, selector = 0},
			{kind = .Query_Slices, selector = 1},
			{kind = .Create_Membership, selector = 0},
			{kind = .Create_Membership, selector = 1},
			{kind = .Create_Membership, selector = 6},
			{kind = .Create_Membership, selector = 7},
			{kind = .Query_Slices, selector = 1},
			{kind = .Crash_Restart},
			{kind = .Create_Asset, selector = 1},
			{kind = .Create_Edge},
			{kind = .Query_Graph},
			{kind = .Delete_Edge},
			{kind = .Query_Graph},
			{kind = .Create_Edge},
			{kind = .Query_Graph},
			{kind = .Delete_Asset},
			{kind = .Query_Graph},
			{kind = .Create_Asset},
			{kind = .Create_Asset, selector = 1},
			{kind = .Create_Edge},
			{kind = .Delete_Task},
			{kind = .Create_Task},
			{kind = .Update_Task, selector = 3},
			{kind = .Update_Task, selector = 3},
			{kind = .Query_Tasks_Paged, selector = 16},
			{kind = .Move_Task, selector = 2},
			{kind = .Move_Task, selector = 4},
			{kind = .Create_Asset},
			{kind = .Update_Asset},
			{kind = .Crash_Restart},
			{kind = .Rotate},
			{kind = .Create_Task},
			{kind = .Update_Task, selector = 0},
			{kind = .Query_Tasks_Paged, selector = 25},
			{kind = .Create_Asset},
			{kind = .Create_Asset},
			{kind = .Update_Asset},
			{kind = .Query_Assets_Paged, selector = 6},
			{kind = .Create_Edge, selector = 0},
			{kind = .Create_Edge, selector = 1},
			{kind = .Create_Edge, selector = 2},
			{kind = .Create_Edge, selector = 20},
			{kind = .Create_Membership, selector = 0},
			{kind = .Create_Membership, selector = 1},
			{kind = .Create_Membership, selector = 4},
			{kind = .Query_Graph, selector = 35},
			{kind = .Query_Graph, selector = 43},
			{kind = .Query_Graph, selector = 95},
			{kind = .Crash_Restart},
			{kind = .Query_Graph, selector = 35},
			{kind = .Query_Tasks_Paged, selector = 16},
			{kind = .Query_Assets_Paged, selector = 8},
			{kind = .Compact},
			{kind = .Query_Graph, selector = 95},
			{kind = .Query_Tasks_Paged, selector = 16},
			{kind = .Query_Assets_Paged, selector = 1},
		}
		ops := make([dynamic]Generated_Shard_Op, 0, len(prefix) + int(op_count))
		defer delete(ops)
		append(&ops, ..prefix[:])
		for _ in 0 ..< int(op_count) {
			kind, kind_err := hgl.draw_i64(tc, 0, i64(Generated_Shard_Op_Kind.Compact))
			if kind_err == .Stop_Test do return hgl.abort()
			if kind_err != nil do return hgl.interesting("operation-kind draw failed")
			selector, selector_err := hgl.draw_i64(tc, 0, 255)
			if selector_err == .Stop_Test do return hgl.abort()
			if selector_err != nil do return hgl.interesting("operation-selector draw failed")
			append(&ops, Generated_Shard_Op{kind = Generated_Shard_Op_Kind(kind), selector = u64(selector)})
			append(&ops, Generated_Shard_Op{kind = .Query_Slices, selector = u64(selector)})
		}
		reason, ok := generated_shard_run_ops(ops[:], 88, tc.is_final)
		if !ok do return hgl.interesting(reason)
		return hgl.valid()
	}
}

@(test)
test_generated_transactional_shard_semantic_replay_fixture :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ops := [?]Generated_Shard_Op {
			{kind = .Create_Task},
			{kind = .Update_Task, selector = 3},
			{kind = .Update_Task, selector = 3},
			{kind = .Query_Tasks_Paged, selector = 16},
			{kind = .Move_Task, selector = 4},
			{kind = .Create_Asset},
			{kind = .Create_Asset, selector = 1},
			{kind = .Create_Asset},
			{kind = .Query_Assets_Paged, selector = 3},
			{kind = .Update_Asset},
			{kind = .Query_Assets_Paged, selector = 6},
			{kind = .Query_Assets_Paged, selector = 8},
			{kind = .Crash_Restart},
			{kind = .Move_Task, selector = 2},
			{kind = .Create_Edge},
			{kind = .Query_Graph, selector = 3},
			{kind = .Rotate},
			{kind = .Create_Task},
			{kind = .Update_Asset},
			{kind = .Crash_Restart},
			{kind = .Query_Graph, selector = 3},
			{kind = .Query_Tasks_Paged, selector = 25},
			{kind = .Compact},
			{kind = .Query_Assets_Paged, selector = 1},
			{kind = .Delete_Asset, selector = 1},
			{kind = .Crash_Restart},
			{kind = .Rotate},
			{kind = .Compact},
			{kind = .Rotate},
			{kind = .Create_Task},
			{kind = .Create_Task},
			{kind = .Create_Task},
			{kind = .Create_Task},
			{kind = .Create_Task},
			{kind = .Create_Task},
			{kind = .Create_Task},
			{kind = .Update_Task, selector = 5},
			{kind = .Move_Task, selector = 8},
			{kind = .Query_Tasks_Paged, selector = 16},
			{kind = .Query_Tasks_Paged, selector = 25},
			{kind = .Compact},
		}
		generated_shard_replay_ops(t, ops[:])
	}
}

@(test)
test_hegel_generated_transactional_shard_state_matches_replay :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_generated_transactional_shard_state, nil, {test_cases = GENERATED_SHARD_CASES})
		testing.expectf(t, err == nil, "generated transactional shard property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
