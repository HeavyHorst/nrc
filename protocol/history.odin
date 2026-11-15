package protocol

import "core:encoding/endian"
import "core:mem"
import "core:strings"

// Shared JSON contract for durable history, independent of storage backend.
History_Event :: struct {
	id:                string,
	timestamp:         string,
	actor_id:          string `json:"actorId"`,
	actor_name:        string `json:"actorName"`,
	entity_type:       string `json:"entityType"`,
	entity_id:         string `json:"entityId"`,
	entity_label:      string `json:"entityLabel,omitempty"`,
	asset_type:        u16 `json:"assetType,omitempty"`,
	entity_available:  bool `json:"entityAvailable,omitempty"`,
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

TASK_CREATED_HISTORY_FIELDS :: [14]string {
	"title",
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

// C_ListHistory (62): scope:u64, kind:u8, entity:u64, before:u64, limit:u16,
// correlation_id:u32. Kind 0 selects every entity type and carries no entity
// id; 1, 2 and 3 select a task, an asset or an edge and require one.
ListHistoryRequest :: struct {
	conv_id:        ConversationID,
	kind:           u8,
	entity:         u64,
	before:         u64,
	limit:          u16,
	correlation_id: u32,
}

LIST_HISTORY_REQUEST_SIZE :: 31
MAX_HISTORY_PAGE_SIZE :: 100
MAX_HISTORY_KIND :: 3

parseListHistoryRequest :: proc(data: []byte) -> (result: ListHistoryRequest, err: ProtocolParseError) {
	// Every response echoes the correlation id, including the error response, so
	// it is read before the body is validated.
	if len(data) >= LIST_HISTORY_REQUEST_SIZE {
		result.correlation_id, _ = endian.get_u32(data[27:], .Big)
	}
	if len(data) < LIST_HISTORY_REQUEST_SIZE do return result, .TooShort
	if len(data) > LIST_HISTORY_REQUEST_SIZE do return result, .ContentLengthMismatch
	scope, scope_ok := endian.get_u64(data, .Big)
	if !scope_ok || ConversationID(scope) != WORKSPACE_DATA_ID do return result, .ContentLengthMismatch
	result.conv_id = WORKSPACE_DATA_ID
	result.kind = data[8]
	result.entity, _ = endian.get_u64(data[9:], .Big)
	result.before, _ = endian.get_u64(data[17:], .Big)
	result.limit, _ = endian.get_u16(data[25:], .Big)
	if result.kind > MAX_HISTORY_KIND ||
	   (result.kind == 0 && result.entity != 0) ||
	   (result.kind != 0 && result.entity == 0) ||
	   result.limit < 1 ||
	   result.limit > MAX_HISTORY_PAGE_SIZE {
		return result, .InvalidValue
	}
	return result, nil
}
