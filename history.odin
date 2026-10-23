package main

import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import pr "protocol"

// Immutable index prefix: event ID, entity kind/ID, source kind/ID, target
// kind/ID, followed by a u16 private-owner length and owner bytes. The owner
// follows existing personal Reminder ACLs and survives deletion. JSON follows.
HISTORY_HEADER_SIZE :: 37

history_private_owner :: proc(payload: []byte) -> string {
	length, _ := endian.get_u16(payload[35:], .Big)
	return string(payload[HISTORY_HEADER_SIZE:][:int(length)])
}

history_json :: proc(payload: []byte) -> []byte {
	return payload[HISTORY_HEADER_SIZE + len(history_private_owner(payload)):]
}

History_Event :: struct {
	id:                string,
	timestamp:         string,
	actor_id:          string `json:"actorId"`,
	actor_name:        string `json:"actorName"`,
	entity_type:       string `json:"entityType"`,
	entity_id:         string `json:"entityId"`,
	entity_label:      string `json:"entityLabel,omitempty"`,
	asset_type:        u16 `json:"assetType,omitempty"`,
	entity_available:  bool `json:"entityAvailable,omitempty"`, // Read-time only.
	action:            string,
	fields:            []string,
	source_type:       string `json:"sourceType,omitempty"`,
	source_id:         string `json:"sourceId,omitempty"`,
	source_label:      string `json:"sourceLabel,omitempty"`,
	source_asset_type: u16 `json:"sourceAssetType,omitempty"`,
	source_available:  bool `json:"sourceAvailable,omitempty"`,
	target_type:       string `json:"targetType,omitempty"`,
	target_id:         string `json:"targetId,omitempty"`,
	target_label:      string `json:"targetLabel,omitempty"`,
	target_asset_type: u16 `json:"targetAssetType,omitempty"`,
	target_available:  bool `json:"targetAvailable,omitempty"`,
}

HISTORY_LABEL_MAX_BYTES :: 256

history_short_label :: proc(value: string, allocator: mem.Allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	defer strings.builder_destroy(&b)
	// Rune iteration replaces malformed legacy bytes with U+FFFD. Bound the
	// encoded result, rather than slicing potentially invalid source bytes.
	for r in strings.trim_space(value) {
		width := r <= 0x7f ? 1 : r <= 0x7ff ? 2 : r <= 0xffff ? 3 : 4
		if strings.builder_len(b) + width > HISTORY_LABEL_MAX_BYTES do break
		strings.write_rune(&b, r)
	}
	return strings.clone(strings.to_string(b), allocator)
}

history_payload_label :: proc(domain: Shard_Mutation_Domain, payload: []byte, version: u16, allocator: mem.Allocator) -> (label: string, asset_type: u16) {
	if domain == .Task {
		task, ok := parse_task_fields(payload, version)
		if ok do label = history_short_label(string(task.title), allocator)
		return
	}
	if domain != .Asset do return
	asset, ok := parse_asset_from_payload(payload, 0, version)
	if !ok do return
	asset_type = u16(asset.asset_type)
	// Never use document bodies, teasers, descriptions or arbitrary JSON as names.
	if asset.asset_type == .Comment do return
	key := asset.asset_type == .Slice ? "name" : "title"
	fields, object, valid := json_metadata_fields(asset.preview, [2]string{key, "filename"}, allocator)
	if valid && object {
		value := json_metadata_string(fields[0], allocator)
		if value == "" && asset.asset_type == .File do value = json_metadata_string(fields[1], allocator)
		return history_short_label(value, allocator), asset_type
	}
	// Metadata extraction also rejects otherwise valid JSON outside its depth or
	// integer bounds. Never mistake JSON-shaped content for a legacy plain title.
	if valid || asset.asset_type != .Note do return
	text := strings.trim_space(string(asset.preview))
	if len(text) == 0 do return
	first := text[0]
	if first == '{' || first == '[' || first == '"' || first == '-' || first >= '0' && first <= '9' do return
	label = history_short_label(text, allocator)
	return
}

history_endpoint_label :: proc(tx: ^Shard_Transaction, kind: u8, id: u64, allocator: mem.Allocator) -> (label: string, asset_type: u16) {
	domain := Shard_Mutation_Domain(kind)
	// Use the transaction's final named image, including forward-created endpoints.
	// Ignore tombstones so cascades retain the deleted endpoint's identifying name.
	for i := len(tx.mutations) - 1; i >= 0; i -= 1 {
		m := tx.mutations[i]
		if m.domain != domain || history_mutation_deleted(m) do continue
		mid, ok := shard_mutation_entity_id(m)
		if ok && mid == id do return history_payload_label(domain, m.payload, m.entity_record_version, allocator)
	}
	payload, version, owned := history_previous_payload(string(tx.workspace), nil, 0, domain, id)
	defer if owned do delete(payload)
	return history_payload_label(domain, payload, version, allocator)
}

history_kind_name :: proc(kind: u8) -> string {
	switch kind {case 1:
		return "task"; case 2:
		return "asset"; case 3:
		return "edge"}
	return ""
}

history_decimal_matches :: proc(text: string, expected: u64) -> bool {
	value, ok := strconv.parse_u64(text, 10)
	return ok && value == expected
}

validate_history_payload :: proc(payload: []byte) -> bool {
	if len(payload) <= HISTORY_HEADER_SIZE || len(payload) > 65536 do return false
	owner_length, _ := endian.get_u16(payload[35:], .Big)
	if owner_length > pr.MAX_OWNER_LENGTH || HISTORY_HEADER_SIZE + int(owner_length) >= len(payload) do return false
	if owner_length != 0 && payload[8] != u8(Shard_Mutation_Domain.Asset) do return false
	id, _ := endian.get_u64(payload, .Big)
	entity, _ := endian.get_u64(payload[9:], .Big)
	if id == 0 || entity == 0 || payload[8] < 1 || payload[8] > 3 || payload[17] > 2 || payload[26] > 2 do return false
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return false
	defer virtual.arena_destroy(&arena)
	event: History_Event
	if json.unmarshal(history_json(payload), &event, allocator = virtual.arena_allocator(&arena)) != nil do return false
	if len(event.entity_label) > HISTORY_LABEL_MAX_BYTES || len(event.source_label) > HISTORY_LABEL_MAX_BYTES || len(event.target_label) > HISTORY_LABEL_MAX_BYTES do return false
	timestamp, timestamp_ok := strconv.parse_i64(event.timestamp, 10)
	if !timestamp_ok ||
	   timestamp <= 0 ||
	   event.actor_id == "" ||
	   event.actor_name == "" ||
	   !history_decimal_matches(event.id, id) ||
	   !history_decimal_matches(event.entity_id, entity) ||
	   event.entity_type != history_kind_name(payload[8]) ||
	   (event.action != "created" && event.action != "updated" && event.action != "deleted") {
		return false
	}
	if len(event.fields) > 32 || event.action == "deleted" && len(event.fields) != 0 do return false
	for field, i in event.fields {
		for j in 0 ..< i do if event.fields[j] == field do return false
		switch field {
		case "title",
		     "description",
		     "status",
		     "order_index",
		     "assignee",
		     "priority",
		     "color",
		     "external_ref",
		     "due_at",
		     "blocked_by",
		     "completed_at",
		     "completed_by",
		     "project",
		     "attachments",
		     "asset_type",
		     "parent_type",
		     "parent_id",
		     "owner",
		     "preview",
		     "payload",
		     "source",
		     "target",
		     "relation":
		case:
			return false
		}
	}
	source, _ := endian.get_u64(payload[18:], .Big); target, _ := endian.get_u64(payload[27:], .Big)
	if payload[8] != 3 do return payload[17] == 0 && source == 0 && payload[26] == 0 && target == 0 && event.source_type == "" && event.source_id == "" && event.target_type == "" && event.target_id == ""
	return(
		payload[17] != 0 &&
		payload[26] != 0 &&
		source != 0 &&
		target != 0 &&
		event.source_type == history_kind_name(payload[17]) &&
		event.target_type == history_kind_name(payload[26]) &&
		history_decimal_matches(event.source_id, source) &&
		history_decimal_matches(event.target_id, target) \
	)
}

apply_history_payload :: proc(workspace: string, payload: []byte) -> bool {
	if !validate_history_payload(payload) do return false
	ws := get_or_create_workspace(workspace)
	id, _ := endian.get_u64(payload, .Big)
	if len(ws.history) > 0 {
		last, _ := endian.get_u64(ws.history[len(ws.history) - 1], .Big)
		if id <= last {
			// Recovery can reapply a verified durable prefix to existing state.
			// Identical immutable events are idempotent, conflicting IDs are not.
			lo, hi := 0, len(ws.history)
			for lo < hi {
				mid := lo + (hi - lo) / 2
				candidate, _ := endian.get_u64(ws.history[mid], .Big)
				if candidate < id {lo = mid + 1} else {hi = mid}
			}
			return lo < len(ws.history) && string(ws.history[lo]) == string(payload)
		}
	}
	owned := make([]byte, len(payload)); copy(owned, payload)
	append(&ws.history, owned)
	return true
}

history_attachment_equal :: proc(a, b: []pr.Attachment) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		y := b[i]
		if string(x.file_id) != string(y.file_id) || string(x.filename) != string(y.filename) || x.size != y.size || string(x.mime_type) != string(y.mime_type) || x.uploaded_at != y.uploaded_at do return false
	}
	return true
}

history_task_fields :: proc(a, b: Parsed_Task_Data, created: bool, fields: ^[dynamic]string) {
	a, b := a, b
	if created || string(a.title) != string(b.title) do append(fields, "title")
	if created || string(a.description) != string(b.description) do append(fields, "description")
	if created || a.status != b.status do append(fields, "status")
	if created || a.order_index != b.order_index do append(fields, "order_index")
	if created || string(a.assignee) != string(b.assignee) do append(fields, "assignee")
	if created || a.priority != b.priority do append(fields, "priority")
	if created || a.color != b.color do append(fields, "color")
	if created || string(a.external_ref) != string(b.external_ref) do append(fields, "external_ref")
	if created || a.due_at != b.due_at do append(fields, "due_at")
	if created || a.blocked_by != b.blocked_by do append(fields, "blocked_by")
	if created || a.completed_at != b.completed_at do append(fields, "completed_at")
	if created || string(a.completed_by) != string(b.completed_by) do append(fields, "completed_by")
	if created || string(a.project) != string(b.project) do append(fields, "project")
	if created || !history_attachment_equal(a.attachments[:a.attachment_count], b.attachments[:b.attachment_count]) do append(fields, "attachments")
}

history_asset_fields :: proc(a, b: Parsed_Asset_Data, created: bool, fields: ^[dynamic]string) {
	a, b := a, b
	if created || a.asset_type != b.asset_type do append(fields, "asset_type")
	if created || a.parent_type != b.parent_type do append(fields, "parent_type")
	if created || a.parent_id != b.parent_id do append(fields, "parent_id")
	if created || string(a.owner) != string(b.owner) do append(fields, "owner")
	if created || string(a.preview) != string(b.preview) do append(fields, "preview")
	if created || string(a.payload) != string(b.payload) || a.payload_encoding != b.payload_encoding || a.payload_raw_len != b.payload_raw_len do append(fields, "payload")
	if created || !history_attachment_equal(a.attachments[:a.attachment_count], b.attachments[:b.attachment_count]) do append(fields, "attachments")
}

history_mutation_deleted :: proc(m: Shard_Mutation) -> bool {
	return(
		m.domain == .Task && m.op == u8(Task_Log_Op.Delete) ||
		m.domain == .Asset && m.op == u8(Asset_Log_Op.Delete) ||
		m.domain == .Edge && m.op == u8(Edge_Log_Op.Delete) \
	)
}

// The previous post-image in a transaction takes precedence over worker state.
// Owned serialized live images last only for the augmentation, never the WAL.
history_previous_payload :: proc(
	workspace: string,
	mutations: []Shard_Mutation,
	index: int,
	domain: Shard_Mutation_Domain,
	id: u64,
) -> (
	payload: []byte,
	version: u16,
	owned: bool,
) {
	for i := index - 1; i >= 0; i -= 1 {
		m := mutations[i]
		if m.domain != domain do continue
		mid, ok := shard_mutation_entity_id(m)
		if ok && mid == id {
			if history_mutation_deleted(m) do return nil, 1, false
			return m.payload, m.entity_record_version, false
		}
	}
	ws := get_workspace(workspace)
	if ws == nil do return
	conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
	if conv == nil do return
	switch domain {
	case .Task:
		if task := conv.tasks[pr.TaskID(id)]; task != nil do return shard_checkpoint_task_payload(task), 1, true
	case .Asset:
		if asset := conv.assets[pr.AssetID(id)]; asset != nil do return shard_checkpoint_asset_payload(workspace, asset), ASSET_LOG_VERSION, true
	case .Edge:
		if edge := conv.edges[pr.EdgeID(id)]; edge != nil do return shard_checkpoint_edge_payload(workspace, edge), 1, true
	case .DM, .History:
	}
	return
}

build_history_mutations :: proc(tx: ^Shard_Transaction) -> (mutations: [dynamic]Shard_Mutation, ok: bool) {
	// Standalone WAL tooling has no authoritative worker state or request. It
	// writes supplied mutations verbatim rather than fabricating historical events.
	if td.workspaces == nil || td.shard_writers.mode != .Active do return mutations, true
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return mutations, false
	defer virtual.arena_destroy(&arena)
	labels := virtual.arena_allocator(&arena)
	ws := get_workspace(string(tx.workspace))
	next: u64
	if ws != nil && len(ws.history) > 0 do next, _ = endian.get_u64(ws.history[len(ws.history) - 1], .Big)
	actor_id, actor_name := "system", "System"
	service_actor := ""
	defer delete(service_actor)
	if c := shard_protocol_dispatch_context.connection; c != nil {
		actor_id, actor_name = c.verified_subject, c.verified_username
		if actor_id == "" {service_actor = fmt.aprintf("service:%s", actor_name); actor_id = service_actor}
	}
	timestamp := fmt.aprintf("%d", nrc_time_unix_nanos()); defer delete(timestamp)
	for m, i in tx.mutations {
		if m.domain == .DM || m.domain == .History do continue
		scope, valid := shard_segment_mutation_conversation_id(m)
		if !valid do return mutations, false
		if scope != 0 do continue // Never include private DM/chat data.
		id, id_ok := shard_mutation_entity_id(m)
		if !id_ok || next == max(u64) do return mutations, false
		previous, version, owned := history_previous_payload(string(tx.workspace), tx.mutations, i, m.domain, id)
		defer if owned do delete(previous)
		deleted := history_mutation_deleted(m)
		if deleted && len(previous) == 0 do continue // Unknown tombstone, not a live record deletion.
		created := len(previous) == 0 && !deleted
		fields: [dynamic]string; defer delete(fields)
		source_kind, target_kind: u8
		source_id, target_id: u64
		private_owner := ""
		switch m.domain {
		case .Task:
			if !deleted {
				a, _ := parse_task_fields(previous, version); b, _ := parse_task_fields(m.payload, m.entity_record_version)
				history_task_fields(a, b, created, &fields)
			}
		case .Asset:
			// Personal visibility is immutable, and deletion must use the pre-image.
			visibility_body := deleted ? previous : m.payload
			visibility_version := deleted ? version : m.entity_record_version
			asset, asset_ok := parse_asset_from_payload(visibility_body, 0, visibility_version)
			if !asset_ok do return mutations, false
			if asset.asset_type == .Reminder {
				personal, _ := reminder_visibility(asset.preview)
				if personal do private_owner = string(asset.owner)
			}
			if !deleted {
				a, _ := parse_asset_from_payload(previous, 0, version); b, _ := parse_asset_from_payload(m.payload, 0, m.entity_record_version)
				history_asset_fields(a, b, created, &fields)
			}
		case .Edge:
			body := deleted ? previous : m.payload
			edge, edge_ok := parse_edge_from_payload(body, 0)
			if !edge_ok do return mutations, false
			source_kind = edge.source_type == .Task ? 1 : 2; target_kind = edge.target_type == .Task ? 1 : 2
			source_id, target_id = edge.source_id, edge.target_id
			if !deleted do append(&fields, "source", "target", "relation")
		case .DM, .History:
		}
		split_unblock := false
		if m.system_unblock && !m.system_actor && !deleted {
			for field, j in fields {
				if field == "blocked_by" {
					split_unblock = true
					for k in j ..< len(fields) - 1 do fields[k] = fields[k + 1]
					resize(&fields, len(fields) - 1)
					break
				}
			}
		}
		// Timestamp-only/no-op updates are not changes to user-visible fields.
		if !created && !deleted && len(fields) == 0 && !split_unblock do continue
		next += 1
		id_text := fmt.aprintf("%d", next); defer delete(id_text)
		entity_text := fmt.aprintf("%d", id); defer delete(entity_text)
		event := History_Event {
			id          = id_text,
			timestamp   = timestamp,
			actor_id    = actor_id,
			actor_name  = actor_name,
			entity_type = history_kind_name(u8(m.domain)),
			entity_id   = entity_text,
			action      = deleted ? "deleted" : (created ? "created" : "updated"),
			fields      = fields[:],
		}
		label_payload := deleted ? previous : m.payload
		label_version := deleted ? version : m.entity_record_version
		event.entity_label, event.asset_type = history_payload_label(m.domain, label_payload, label_version, labels)
		if m.system_actor {event.actor_id = "system"; event.actor_name = "System"}
		if split_unblock && len(fields) == 0 {
			event.actor_id = "system"; event.actor_name = "System"; event.fields = []string{"blocked_by"}
			split_unblock = false
		}
		if source_kind != 0 {
			event.source_type = history_kind_name(source_kind); event.target_type = history_kind_name(target_kind)
			event.source_id = fmt.aprintf("%d", source_id); event.target_id = fmt.aprintf("%d", target_id)
			event.source_label, event.source_asset_type = history_endpoint_label(tx, source_kind, source_id, labels)
			event.target_label, event.target_asset_type = history_endpoint_label(tx, target_kind, target_id, labels)
		}
		defer delete(event.source_id); defer delete(event.target_id)
		encoded, err := json.marshal(event); defer delete(encoded)
		if err != nil || len(private_owner) > pr.MAX_OWNER_LENGTH || len(encoded) > 65536 - HISTORY_HEADER_SIZE - len(private_owner) do return mutations, false
		payload := make([]byte, HISTORY_HEADER_SIZE + len(private_owner) + len(encoded))
		endian.put_u64(payload, .Big, next); payload[8] = u8(m.domain); endian.put_u64(payload[9:], .Big, id)
		payload[17] = source_kind; endian.put_u64(payload[18:], .Big, source_id)
		payload[26] = target_kind; endian.put_u64(payload[27:], .Big, target_id)
		endian.put_u16(payload[35:], .Big, u16(len(private_owner)))
		copy(payload[HISTORY_HEADER_SIZE:], private_owner)
		copy(payload[HISTORY_HEADER_SIZE + len(private_owner):], encoded)
		append(&mutations, Shard_Mutation{domain = .History, op = 1, entity_record_version = 1, payload = payload})
		if split_unblock {
			if next == max(u64) do return mutations, false
			next += 1
			event.id = fmt.aprintf("%d", next); defer delete(event.id)
			event.actor_id = "system"; event.actor_name = "System"; event.fields = []string{"blocked_by"}
			event.action = "updated"
			body, split_err := json.marshal(event); defer delete(body)
			if split_err != nil || len(body) > 65536 - HISTORY_HEADER_SIZE do return mutations, false
			p := make([]byte, HISTORY_HEADER_SIZE + len(body)); copy(p, payload[:HISTORY_HEADER_SIZE])
			endian.put_u64(p, .Big, next); copy(p[HISTORY_HEADER_SIZE:], body)
			append(&mutations, Shard_Mutation{domain = .History, op = 1, entity_record_version = 1, payload = p})
		}
	}
	return mutations, true
}

destroy_history_mutations :: proc(mutations: [dynamic]Shard_Mutation) {
	for m in mutations do delete(m.payload)
	delete(mutations)
}

history_payload_matches :: proc(payload: []byte, kind: u8, id: u64) -> bool {
	if kind == 0 do return true
	entity, _ := endian.get_u64(payload[9:], .Big)
	if payload[8] == kind && entity == id do return true
	if payload[8] != 3 || kind == 3 do return false
	source, _ := endian.get_u64(payload[18:], .Big); target, _ := endian.get_u64(payload[27:], .Big)
	return payload[17] == kind && source == id || payload[26] == kind && target == id
}

history_record_available :: proc(ws: ^Workspace_State, kind: u8, id: u64, username: string, asset_type: ^u16) -> bool {
	if ws == nil do return false
	conv := get_conversation(ws, pr.WORKSPACE_DATA_ID)
	if conv == nil do return false
	if kind == 1 do return conv.tasks[pr.TaskID(id)] != nil
	if kind == 2 {
		asset := conv.assets[pr.AssetID(id)]
		if !asset_visible_to(asset, username) do return false
		if asset_type^ == 0 do asset_type^ = u16(asset.asset_type)
		return true
	}
	return false
}

history_page_json :: proc(ws: ^Workspace_State, kind: u8, entity, before: u64, limit: int, username: string = "") -> []byte {
	b: strings.Builder; strings.builder_init(&b); defer strings.builder_destroy(&b)
	arena: virtual.Arena; if virtual.arena_init_growing(&arena) != nil do return nil
	defer virtual.arena_destroy(&arena)
	strings.write_string(&b, `{"events":[`)
	count := 0; last: u64; more := false
	if ws != nil {
		for i := len(ws.history) - 1; i >= 0; i -= 1 {
			p := ws.history[i]; id, _ := endian.get_u64(p, .Big)
			owner := history_private_owner(p)
			if owner != "" && owner != username do continue
			if before != 0 && id >= before || !history_payload_matches(p, kind, entity) do continue
			virtual.arena_free_all(&arena)
			allocator := virtual.arena_allocator(&arena)
			event: History_Event
			if json.unmarshal(history_json(p), &event, allocator = allocator) != nil do panic("invalid stored history")
			eid, _ := endian.get_u64(p[9:], .Big)
			source, _ := endian.get_u64(p[18:], .Big); target, _ := endian.get_u64(p[27:], .Big)
			event.entity_available = history_record_available(ws, p[8], eid, username, &event.asset_type)
			event.source_available = history_record_available(ws, p[17], source, username, &event.source_asset_type)
			event.target_available = history_record_available(ws, p[26], target, username, &event.target_asset_type)
			body, err := json.marshal(event, allocator = allocator)
			if err != nil do panic("failed to encode history page")
			if count == limit || strings.builder_len(b) + len(body) + 64 > MAX_PROTOCOL_PAYLOAD_SIZE - 6 {more = true; break}
			if count > 0 do strings.write_string(&b, ",")
			strings.write_string(&b, string(body)); count += 1; last = id
		}
	}
	if !more do last = 0
	fmt.sbprintf(&b, `],"nextBefore":"%d"}`, last)
	return transmute([]byte)strings.clone(strings.to_string(b))
}

process_list_history :: proc(c: ^NRC_Connection, body: []byte) {
	request, parse_err := pr.parseListHistoryRequest(body)
	correlation := request.correlation_id
	// A structurally invalid body reports the request error, a valid one still
	// answers "Authentication required" before the filter is judged.
	authorized := c.authenticated
	error := ""
	switch {
	case parse_err != nil && parse_err != .InvalidValue:
		error = "Invalid history request"
	case !authorized:
		error = "Authentication required"
	case parse_err == .InvalidValue:
		error = "Invalid history filter or limit"
	}
	// The durability gate has always run after the filter check and overrides its
	// message, so a rejected filter still reports pending durability. Only an
	// unauthenticated or structurally invalid request skips it.
	if authorized && (parse_err == nil || parse_err == .InvalidValue) {
		writer := shard_writer_for_workspace(&td.shard_writers, transmute([]byte)c.workspace_id)
		if writer != nil &&
		   (writer.poisoned ||
				   !writer.wal.enabled ||
				   writer.commit_pending ||
				   writer.fsync_in_flight ||
				   writer.wal.buffered_record_count != 0 ||
				   writer.wal.durable_record_count != writer.wal.record_count) {
			error = "History durability pending; retry"
		}
	}
	payload: []byte
	if error != "" {
		payload, _ = json.marshal(struct {
			events:      [0]int,
			next_before: string `json:"nextBefore"`,
			error:       string,
		}{{}, "0", error})
	} else {
		payload = history_page_json(
			get_workspace(c.workspace_id),
			request.kind,
			request.entity,
			request.before,
			int(request.limit),
			get_connection_nickname(c),
		)
	}
	defer delete(payload)
	buf, header := allocate_websocket_frame_buffer(6 + len(payload), "history page")
	if buf == nil do return
	endian.put_u16(buf[header:], .Big, u16(pr.Opcode.S_HistoryPage)); endian.put_u32(buf[header + 2:], .Big, correlation)
	copy(buf[header + 6:], payload)
	send_pooled_buffer(c, buf)
}
