//
// asset_persistence_test.odin - Tests and Benchmarks for Asset Persistence
//
// Tests:
// - Record serialization/parsing roundtrip
// - CRC validation and corruption detection
// - Hash chain linking
// - Empty payload handling
// - Large payload handling
// - Fixed-order format verification
//
// Benchmarks:
// - Full asset record serialization
//
package main

import "base:intrinsics"
import "base:runtime"
import "core:crypto/hash"
import "core:encoding/endian"
import "core:hash/xxhash"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

import "persistence"
import pr "protocol"

// ============================================================================
// Record Serialization Tests
// ============================================================================

@(test)
test_asset_record_structure :: proc(t: ^testing.T) {
	// Verify the record structure matches expected layout
	// Header: magic(4) + version(2) + op(1) + flags(1) + length(4) + prev_hash(32) + record_hash(4) = 48
	// Payload: workspace_len(2) + workspace + asset_type(2) + asset_id(8) + parent_type(2) + parent_id(8)
	//          + owner_len(2) + owner + created_at(8) + updated_at(8) + conv_id(8)
	//          + payload_encoding(1) + payload_raw_len(4)
	//          + preview_len(2) + preview + payload_len(2) + payload + attachment_count(2)

	workspace_id := "test-workspace"
	owner := "alice"
	preview := "preview content"
	payload := "full payload content"

	payload_size := 2 + len(workspace_id) + 2 + 8 + 2 + 8 + 2 + len(owner) + 8 + 8 + 8 + 1 + 4 + 2 + len(preview) + 2 + len(payload) + 2
	expected_record_size := persistence.LOG_HEADER_SIZE + payload_size

	// Verify current XXH64 header constant
	testing.expect_value(t, persistence.LOG_HEADER_SIZE, 52)

	// Build a record manually and verify structure
	buf := make([]byte, expected_record_size)
	defer delete(buf)

	// Fill header
	endian.put_u32(buf[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, ASSET_LOG_VERSION)
	buf[6] = u8(Asset_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64 // flags
	endian.put_u32(buf[8:], .Big, u32(payload_size))
	// prev_hash at 12-43 (zeros for first record)
	// record_hash at 44-51 (computed later)

	// Fill payload in fixed order
	payload_buf := buf[persistence.LOG_HEADER_SIZE:]
	offset := 0

	// workspace_id
	endian.put_u16(payload_buf[offset:], .Big, u16(len(workspace_id)))
	offset += 2
	copy(payload_buf[offset:], workspace_id)
	offset += len(workspace_id)

	// asset_type
	endian.put_u16(payload_buf[offset:], .Big, u16(pr.AssetType.Comment))
	offset += 2

	// asset_id
	endian.put_u64(payload_buf[offset:], .Big, 42)
	offset += 8

	// parent_type
	endian.put_u16(payload_buf[offset:], .Big, u16(pr.ParentType.Task))
	offset += 2

	// parent_id
	endian.put_u64(payload_buf[offset:], .Big, 100)
	offset += 8

	// owner
	endian.put_u16(payload_buf[offset:], .Big, u16(len(owner)))
	offset += 2
	copy(payload_buf[offset:], owner)
	offset += len(owner)

	// created_at
	endian.put_u64(payload_buf[offset:], .Big, 1234567890)
	offset += 8

	// updated_at
	endian.put_u64(payload_buf[offset:], .Big, 1234567999)
	offset += 8

	// conv_id
	endian.put_u64(payload_buf[offset:], .Big, 12345)
	offset += 8

	// payload_encoding + payload_raw_len
	payload_buf[offset] = u8(pr.PayloadEncoding.Plain)
	offset += 1
	endian.put_u32(payload_buf[offset:], .Big, u32(len(payload)))
	offset += 4

	// preview
	endian.put_u16(payload_buf[offset:], .Big, u16(len(preview)))
	offset += 2
	copy(payload_buf[offset:], preview)
	offset += len(preview)

	// payload
	endian.put_u16(payload_buf[offset:], .Big, u16(len(payload)))
	offset += 2
	copy(payload_buf[offset:], payload)
	offset += len(payload)

	// attachments
	endian.put_u16(payload_buf[offset:], .Big, 0)
	offset += 2

	testing.expect_value(t, offset, payload_size)

	// Verify magic can be read back
	read_magic, _ := endian.get_u32(buf[0:], .Big)
	testing.expect_value(t, read_magic, ASSET_LOG_MAGIC)

	// Verify version can be read back
	read_version, _ := endian.get_u16(buf[4:], .Big)
	testing.expect_value(t, read_version, ASSET_LOG_VERSION)

	// Verify op can be read back
	testing.expect_value(t, buf[6], u8(Asset_Log_Op.Create))
}

@(test)
test_asset_workspace_prefix_roundtrip :: proc(t: ^testing.T) {
	workspace_id := "my-test-workspace-123"

	buf: [256]byte
	written := persistence.write_workspace_prefix(buf[:], workspace_id)

	testing.expect_value(t, written, 2 + len(workspace_id))

	// Parse it back
	parsed_ws, offset, ok := persistence.parse_workspace_prefix(buf[:written])
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, offset, written)
	testing.expect(t, parsed_ws == workspace_id, "workspace should match")
}

@(test)
test_asset_payload_size_calculation :: proc(t: ^testing.T) {
	workspace_id := "workspace"
	asset := pr.Asset {
		asset_type  = .Document,
		asset_id    = 1,
		parent_type = .None,
		parent_id   = 0,
		owner       = transmute([]byte)string("alice"),
		created_at  = 1000,
		updated_at  = 2000,
		conv_id     = 42,
		preview     = transmute([]byte)string("Preview text"),
		payload     = transmute([]byte)string("Full document content here"),
	}

	size := calculate_asset_payload_size(workspace_id, &asset)

	// Expected: ws(2+9) + asset_type(2) + asset_id(8) + parent_type(2) + parent_id(8)
	//           + owner(2+5) + created_at(8) + updated_at(8) + conv_id(8)
	//           + payload_encoding(1) + payload_raw_len(4)
	//           + preview(2+12) + payload(2+26) + attachment_count(2)
	expected := 2 + 9 + 2 + 8 + 2 + 8 + 2 + 5 + 8 + 8 + 8 + 1 + 4 + 2 + 12 + 2 + 26 + 2
	testing.expect_value(t, size, expected)
}

@(test)
test_asset_persistence_roundtrip_with_attachments :: proc(t: ^testing.T) {
	workspace_id := "workspace"
	file_id := "att-note-1"
	filename := "diagram.png"
	mime_type := "image/png"
	attachments := []pr.Attachment {
		{
			file_id = transmute([]byte)file_id,
			filename = transmute([]byte)filename,
			size = 42_000,
			mime_type = transmute([]byte)mime_type,
			uploaded_at = 123456789,
		},
	}
	asset := pr.Asset {
		asset_type       = .Note,
		asset_id         = 7,
		parent_type      = .None,
		owner            = transmute([]byte)string("alice"),
		created_at       = 1000,
		updated_at       = 2000,
		conv_id          = 42,
		payload_encoding = .Plain,
		payload_raw_len  = 7,
		preview          = transmute([]byte)string("note"),
		payload          = transmute([]byte)string("content"),
		attachments      = attachments,
	}

	payload_size := calculate_asset_payload_size(workspace_id, &asset)
	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)
	serialize_asset_to_record(buf, workspace_id, &asset)

	payload := buf[persistence.LOG_HEADER_SIZE:]
	_, offset, prefix_ok := persistence.parse_workspace_prefix(payload)
	testing.expect(t, prefix_ok, "workspace prefix should parse")
	parsed, parse_ok := parse_asset_from_payload(payload, offset, ASSET_LOG_VERSION)
	testing.expect(t, parse_ok, "asset payload should parse")
	if !parse_ok do return

	testing.expect_value(t, parsed.asset_type, pr.AssetType.Note)
	testing.expect_value(t, parsed.asset_id, pr.AssetID(7))
	testing.expect_value(t, parsed.attachment_count, 1)
	testing.expect(t, string(parsed.attachments[0].file_id) == file_id, "attachment file_id should roundtrip")
	testing.expect(t, string(parsed.attachments[0].filename) == filename, "attachment filename should roundtrip")
	testing.expect_value(t, parsed.attachments[0].size, u64(42_000))
	testing.expect(t, string(parsed.attachments[0].mime_type) == mime_type, "attachment mime type should roundtrip")
	testing.expect_value(t, parsed.attachments[0].uploaded_at, i64(123456789))
}

// ============================================================================
// CRC Validation Tests
// ============================================================================

@(test)
test_asset_crc_computation :: proc(t: ^testing.T) {
	workspace_id := "test-workspace"
	asset := pr.Asset {
		asset_type  = .Comment,
		asset_id    = 1,
		parent_type = .Task,
		parent_id   = 10,
		owner       = transmute([]byte)string("bob"),
		created_at  = 1234567890,
		updated_at  = 1234567999,
		conv_id     = 42,
		preview     = transmute([]byte)string("comment preview"),
		payload     = transmute([]byte)string("full comment text"),
	}

	payload_size := calculate_asset_payload_size(workspace_id, &asset)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	// Build header
	endian.put_u32(buf[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, ASSET_LOG_VERSION)
	buf[6] = u8(Asset_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))

	// Build payload
	serialize_asset_to_record(buf, workspace_id, &asset)

	// Compute CRC
	record_crc := persistence.compute_record_crc64(buf, payload_size)
	endian.put_u64(buf[44:], .Big, record_crc)

	// Verify stored CRC
	stored_crc, _ := endian.get_u64(buf[44:], .Big)
	testing.expect_value(t, stored_crc, record_crc)

	// Recomputing should give same result
	recomputed_crc := persistence.compute_record_crc64(buf, payload_size)
	testing.expect_value(t, recomputed_crc, record_crc)
}

@(test)
test_asset_crc_detects_corruption :: proc(t: ^testing.T) {
	workspace_id := "workspace"
	asset := pr.Asset {
		asset_type = .Comment,
		asset_id   = 1,
		conv_id    = 1,
		preview    = transmute([]byte)string("test"),
		payload    = transmute([]byte)string("content"),
	}

	payload_size := calculate_asset_payload_size(workspace_id, &asset)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	// Build valid record
	endian.put_u32(buf[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, ASSET_LOG_VERSION)
	buf[6] = u8(Asset_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))
	serialize_asset_to_record(buf, workspace_id, &asset)

	original_crc := persistence.compute_record_crc64(buf, payload_size)

	// Corrupt one byte in payload
	buf[persistence.LOG_HEADER_SIZE + 5] ~= 0xFF

	corrupted_crc := persistence.compute_record_crc64(buf, payload_size)
	testing.expect(t, original_crc != corrupted_crc, "CRC should differ after corruption")
}

@(test)
test_asset_crc_detects_header_corruption :: proc(t: ^testing.T) {
	workspace_id := "ws"
	asset := pr.Asset {
		asset_type = .File,
		asset_id   = 1,
		conv_id    = 1,
		preview    = transmute([]byte)string("file.txt"),
		payload    = nil,
	}

	payload_size := calculate_asset_payload_size(workspace_id, &asset)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	endian.put_u32(buf[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, ASSET_LOG_VERSION)
	buf[6] = u8(Asset_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))
	serialize_asset_to_record(buf, workspace_id, &asset)

	original_crc := persistence.compute_record_crc64(buf, payload_size)

	// Corrupt op byte in header
	buf[6] = u8(Asset_Log_Op.Delete)

	corrupted_crc := persistence.compute_record_crc64(buf, payload_size)
	testing.expect(t, original_crc != corrupted_crc, "CRC should detect header corruption")
}

// ============================================================================
// Hash Chain Tests
// ============================================================================

@(test)
test_asset_hash_chain_links_correctly :: proc(t: ^testing.T) {
	// Simulate two records and verify hash chaining
	workspace_id := "test"

	// Record 1 with zero prev_hash
	record1: [256]byte
	payload1_size := 2 + len(workspace_id) + 2 + 8 + 2 + 8 + 2 + 8 + 8 + 8 + 2 + 2

	endian.put_u32(record1[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(record1[4:], .Big, ASSET_LOG_VERSION)
	record1[6] = u8(Asset_Log_Op.Create)
	record1[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(record1[8:], .Big, u32(payload1_size))
	// prev_hash at 12-43 is zeros for first record

	// Compute CRC for record1
	crc1 := persistence.compute_record_crc64(record1[:], payload1_size)
	endian.put_u64(record1[44:], .Big, crc1)

	record1_size := persistence.LOG_HEADER_SIZE + payload1_size

	// Compute SHA-256 of record1 (this becomes prev_hash for record2)
	hash1: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, record1[:record1_size], hash1[:])

	// Record 2 should use hash1 as prev_hash
	record2: [256]byte
	payload2_size := payload1_size

	endian.put_u32(record2[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(record2[4:], .Big, ASSET_LOG_VERSION)
	record2[6] = u8(Asset_Log_Op.Create)
	record2[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(record2[8:], .Big, u32(payload2_size))
	copy(record2[12:44], hash1[:]) // Copy prev_hash

	// Verify record2's prev_hash matches hash of record1
	for i in 0 ..< 32 {
		testing.expect_value(t, record2[12 + i], hash1[i])
	}
}

@(test)
test_asset_first_record_has_zero_prev_hash :: proc(t: ^testing.T) {
	record: [128]byte

	endian.put_u32(record[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(record[4:], .Big, ASSET_LOG_VERSION)
	record[6] = u8(Asset_Log_Op.Create)
	endian.put_u32(record[8:], .Big, 20)

	// First record should have zero prev_hash
	expected_prev_hash: [32]byte = {}
	prev_hash_in_record: [32]byte
	copy(prev_hash_in_record[:], record[12:44])

	testing.expect(t, prev_hash_in_record == expected_prev_hash, "first record should have zero prev_hash")
}

// ============================================================================
// Payload Handling Tests
// ============================================================================

@(test)
test_asset_empty_payloads :: proc(t: ^testing.T) {
	workspace_id := "ws"
	asset := pr.Asset {
		asset_type  = .Comment,
		asset_id    = 1,
		parent_type = .None,
		parent_id   = 0,
		owner       = nil,
		created_at  = 1000,
		updated_at  = 1000,
		conv_id     = 1,
		preview     = nil,
		payload     = nil,
	}

	payload_size := calculate_asset_payload_size(workspace_id, &asset)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	endian.put_u32(buf[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, ASSET_LOG_VERSION)
	buf[6] = u8(Asset_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))

	serialize_asset_to_record(buf, workspace_id, &asset)

	// Should be valid - CRC computes fine
	crc := persistence.compute_record_crc64(buf, payload_size)
	testing.expect(t, crc != 0, "CRC should be computed for empty payloads")
}

@(test)
test_asset_max_payload_length :: proc(t: ^testing.T) {
	// Verify we can handle max payload lengths
	workspace_id := "ws"

	// Create max-length preview and payload
	max_preview := make([]byte, pr.MAX_PREVIEW_LENGTH)
	defer delete(max_preview)
	max_payload := make([]byte, pr.MAX_PAYLOAD_LENGTH)
	defer delete(max_payload)

	for i in 0 ..< len(max_preview) {
		max_preview[i] = u8(i % 256)
	}
	for i in 0 ..< len(max_payload) {
		max_payload[i] = u8(i % 256)
	}

	asset := pr.Asset {
		asset_type  = .Document,
		asset_id    = 1,
		parent_type = .None,
		parent_id   = 0,
		owner       = transmute([]byte)string("user"),
		created_at  = 1000,
		updated_at  = 1000,
		conv_id     = 1,
		preview     = max_preview,
		payload     = max_payload,
	}

	payload_size := calculate_asset_payload_size(workspace_id, &asset)

	// Should fit in ASSET_MAX_RECORD_SIZE
	testing.expect(t, persistence.LOG_HEADER_SIZE + payload_size <= ASSET_MAX_RECORD_SIZE, "max asset should fit in record buffer")
}

@(test)
test_asset_delete_record_structure :: proc(t: ^testing.T) {
	// Delete records have minimal payload: workspace + conv_id + asset_id
	workspace_id := "test-ws"

	payload_size := 2 + len(workspace_id) + 8 + 8

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	endian.put_u32(buf[0:], .Big, ASSET_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, ASSET_LOG_VERSION)
	buf[6] = u8(Asset_Log_Op.Delete)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))

	payload := buf[persistence.LOG_HEADER_SIZE:]
	offset := persistence.write_workspace_prefix(payload, workspace_id)
	endian.put_u64(payload[offset:], .Big, 999) // conv_id
	offset += 8
	endian.put_u64(payload[offset:], .Big, 42) // asset_id

	// Should compute valid CRC
	crc := persistence.compute_record_crc64(buf, payload_size)
	endian.put_u64(buf[44:], .Big, crc)

	// Verify op is Delete
	testing.expect_value(t, buf[6], u8(Asset_Log_Op.Delete))

	// Verify length matches
	read_len, _ := endian.get_u32(buf[8:], .Big)
	testing.expect_value(t, read_len, u32(payload_size))
}

// ============================================================================
// Magic Number Tests
// ============================================================================

@(test)
test_asset_magic_number :: proc(t: ^testing.T) {
	// ASSET_LOG_MAGIC should be "NRCS" in ASCII
	// N=0x4E, R=0x52, C=0x43, S=0x53
	expected := 0x4E524353
	testing.expect_value(t, ASSET_LOG_MAGIC, expected)

	// Verify it differs from other magic numbers
	testing.expect(t, ASSET_LOG_MAGIC != TASK_LOG_MAGIC, "asset and task magic should differ")
}

// ============================================================================
// Asset Type Tests
// ============================================================================

@(test)
test_asset_all_types_serialize :: proc(t: ^testing.T) {
	workspace_id := "ws"
	asset_types := []pr.AssetType{.Comment, .Document, .File}

	for asset_type in asset_types {
		asset := pr.Asset {
			asset_type = asset_type,
			asset_id   = 1,
			conv_id    = 1,
		}

		payload_size := calculate_asset_payload_size(workspace_id, &asset)
		buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)

		endian.put_u32(buf[0:], .Big, ASSET_LOG_MAGIC)
		endian.put_u16(buf[4:], .Big, ASSET_LOG_VERSION)
		buf[6] = u8(Asset_Log_Op.Create)
		endian.put_u32(buf[8:], .Big, u32(payload_size))

		serialize_asset_to_record(buf, workspace_id, &asset)

		// Verify asset_type is correctly written (after workspace prefix)
		payload := buf[persistence.LOG_HEADER_SIZE:]
		_, ws_offset, _ := persistence.parse_workspace_prefix(payload)
		read_type, _ := endian.get_u16(payload[ws_offset:], .Big)
		testing.expect_value(t, pr.AssetType(read_type), asset_type)

		delete(buf)
	}
}

@(test)
test_asset_all_parent_types_serialize :: proc(t: ^testing.T) {
	workspace_id := "ws"
	parent_types := []pr.ParentType{.None, .Task, .Asset}

	for parent_type in parent_types {
		asset := pr.Asset {
			asset_type  = .Comment,
			asset_id    = 1,
			parent_type = parent_type,
			parent_id   = 100,
			conv_id     = 1,
		}

		payload_size := calculate_asset_payload_size(workspace_id, &asset)
		buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)

		endian.put_u32(buf[0:], .Big, ASSET_LOG_MAGIC)
		endian.put_u16(buf[4:], .Big, ASSET_LOG_VERSION)
		buf[6] = u8(Asset_Log_Op.Create)
		endian.put_u32(buf[8:], .Big, u32(payload_size))

		serialize_asset_to_record(buf, workspace_id, &asset)

		// Verify parent_type is correctly written
		payload := buf[persistence.LOG_HEADER_SIZE:]
		_, ws_offset, _ := persistence.parse_workspace_prefix(payload)
		// Skip asset_type(2) + asset_id(8) to get to parent_type
		read_parent_type, _ := endian.get_u16(payload[ws_offset + 10:], .Big)
		testing.expect_value(t, pr.ParentType(read_parent_type), parent_type)

		delete(buf)
	}
}

asset_cycle_test_store_asset :: proc(conv: ^Conversation_State, asset_id: pr.AssetID, parent_type: pr.ParentType, parent_id: u64) {
	asset := alloc_asset(transmute([]byte)string("tester"), transmute([]byte)string("asset"), transmute([]byte)string("payload"))
	asset.asset_type = .Note
	asset.asset_id = asset_id
	asset.parent_type = parent_type
	asset.parent_id = parent_id
	asset.conv_id = 1
	conv.assets[asset_id] = asset
}

@(test)
test_asset_parent_cycle_validation :: proc(t: ^testing.T) {
	workspace_id := "asset-cycle-validation"
	if !init_room_mapping_test_state("asset_parent_cycle_validation.log", workspace_id) {
		testing.expect(t, false, "room mapping test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	ws := get_or_create_workspace(workspace_id)
	conv := get_or_create_conversation(ws, 1)

	asset_cycle_test_store_asset(conv, 1, .None, 0)
	asset_cycle_test_store_asset(conv, 2, .Asset, 1)
	asset_cycle_test_store_asset(conv, 3, .Asset, 4)
	asset_cycle_test_store_asset(conv, 4, .Asset, 3)

	testing.expect(t, !asset_parent_would_cycle(conv, 5, .Asset, 2), "new asset can point at an acyclic parent chain")
	testing.expect(t, !asset_parent_would_cycle(conv, 5, .Asset, 99), "missing parent does not introduce a cycle")
	testing.expect(t, !asset_parent_would_cycle(conv, 5, .Task, 1), "task parents cannot create asset parent cycles")
	testing.expect(t, asset_parent_would_cycle(conv, 1, .Asset, 1), "self-parenting must be rejected")
	testing.expect(t, asset_parent_would_cycle(conv, 1, .Asset, 2), "parenting under a descendant must be rejected")
	testing.expect(t, asset_parent_would_cycle(conv, 5, .Asset, 3), "parenting into an existing asset cycle must be rejected")
}

@(test)
test_create_asset_rejects_self_parent_cycle :: proc(t: ^testing.T) {
	workspace_id := "asset-self-cycle-create"
	if !init_room_mapping_test_state("asset_self_parent_cycle_create.log", workspace_id) {
		testing.expect(t, false, "room mapping test WAL should initialize")
		return
	}
	defer cleanup_room_mapping_test_state()

	c := make_room_mapping_test_connection(workspace_id)
	defer send_queue_destroy(&c)

	req := pr.CreateAssetRequest {
		conv_id        = 1,
		asset_type     = .Note,
		parent_type    = .Asset,
		parent_id      = 1,
		preview        = transmute([]byte)string("self-cycle"),
		payload        = transmute([]byte)string("payload"),
		correlation_id = 99,
	}
	handle_create_asset(&c, req)

	ws := get_workspace(workspace_id)
	testing.expect(t, ws != nil, "validation uses the target conversation")
	conv := get_conversation(ws, 1)
	testing.expect(t, conv != nil, "validation uses the target conversation")
	if conv != nil {
		testing.expect_value(t, len(conv.assets), 0)
	}
	testing.expect_value(t, td.asset_seq, u64(0))
}

// ============================================================================
// Benchmarks
// ============================================================================

Asset_Benchmark_State :: struct {
	workspace_id: string,
	asset:        ^pr.Asset,
	buf:          []byte,
	payload_size: int,
	checksum:     u64,
}

persistence_micro_benchmark_enabled :: proc() -> bool {
	value, found := os.lookup_env_alloc("BENCH_PERSISTENCE_MICRO", context.allocator)
	defer delete(value)
	return found && value != "0" && value != "false"
}

benchmark_asset_serialize_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Asset_Benchmark_State)options.user_data
	last_hash: [32]byte
	for _ in 0 ..< options.rounds {
		endian.put_u32(state.buf[0:], .Big, ASSET_LOG_MAGIC)
		endian.put_u16(state.buf[4:], .Big, ASSET_LOG_VERSION)
		state.buf[6] = u8(Asset_Log_Op.Create)
		state.buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
		endian.put_u32(state.buf[8:], .Big, u32(state.payload_size))
		copy(state.buf[12:44], last_hash[:])
		serialize_asset_to_record(state.buf, state.workspace_id, state.asset)
		record_crc := persistence.compute_record_crc64(state.buf, state.payload_size)
		endian.put_u64(state.buf[44:], .Big, record_crc)
		hash.hash_bytes_to_buffer(.SHA256, state.buf, last_hash[:])
	}
	state.checksum, _ = endian.get_u64(last_hash[:], .Big)
	options.count = options.rounds
	options.processed = options.rounds * len(state.buf)
	options.hash = u128(state.checksum)
	return .Okay
}

benchmark_asset_size_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Asset_Benchmark_State)options.user_data
	for _ in 0 ..< options.rounds {
		workspace_id := intrinsics.volatile_load(&state.workspace_id)
		asset := intrinsics.volatile_load(&state.asset)
		state.checksum += u64(calculate_asset_payload_size(workspace_id, asset))
	}
	options.count = options.rounds
	options.hash = u128(state.checksum)
	return .Okay
}

benchmark_asset_hash_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Asset_Benchmark_State)options.user_data
	for _ in 0 ..< options.rounds {
		data := intrinsics.volatile_load(&state.buf)
		state.checksum += xxhash.XXH64(data)
	}
	options.count = options.rounds
	options.processed = options.rounds * len(state.buf)
	options.hash = u128(state.checksum)
	return .Okay
}

@(test)
benchmark_asset_record_serialization :: proc(t: ^testing.T) {
	if !persistence_micro_benchmark_enabled() do return
	workspace_id := "production-workspace-123"
	asset := pr.Asset {
		asset_type  = .Document,
		asset_id    = 12345,
		parent_type = .Task,
		parent_id   = 999,
		owner       = transmute([]byte)string("user@example.com"),
		created_at  = 1700000000000,
		updated_at  = 1700001000000,
		conv_id     = 42,
		preview     = transmute([]byte)string(`{"title":"Meeting Notes","summary":"Q4 planning discussion"}`),
		payload     = transmute([]byte)string("# Meeting Notes\n\n## Attendees\n- Alice\n- Bob\n\n## Agenda\n1. Review metrics\n2. Plan roadmap"),
	}

	payload_size := calculate_asset_payload_size(workspace_id, &asset)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	iterations := 2_000_000
	state := Asset_Benchmark_State {
		workspace_id = workspace_id,
		asset        = &asset,
		buf          = buf,
		payload_size = payload_size,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_asset_serialize_callback,
		rounds    = iterations,
		user_data = &state,
	}
	err := time.benchmark(&options)
	testing.expect_value(t, err, time.Benchmark_Error.Okay)
	testing.expect(t, state.checksum != 0 && options.hash == u128(state.checksum), "serialization checksum must be observable")
	ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
	log.infof(
		"benchmark_asset_record_serialization: %.2f ns/op, %.2f ops/s, %.2f MiB/s (%d iterations)",
		ns_per_op,
		options.rounds_per_second,
		options.megabytes_per_second,
		options.count,
	)
}

@(test)
benchmark_asset_payload_size_calculation :: proc(t: ^testing.T) {
	if !persistence_micro_benchmark_enabled() do return
	workspace_id := "workspace"
	asset := pr.Asset {
		asset_type  = .Document,
		asset_id    = 1,
		parent_type = .Task,
		parent_id   = 100,
		owner       = transmute([]byte)string("user@example.com"),
		created_at  = 1000,
		updated_at  = 2000,
		conv_id     = 42,
		preview     = transmute([]byte)string("Preview metadata"),
		payload     = transmute([]byte)string("Full document content with some text"),
	}

	iterations := 300_000_000
	state := Asset_Benchmark_State {
		workspace_id = workspace_id,
		asset        = &asset,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_asset_size_callback,
		rounds    = iterations,
		user_data = &state,
	}
	err := time.benchmark(&options)
	expected := u64(calculate_asset_payload_size(workspace_id, &asset)) * u64(iterations)
	testing.expect_value(t, err, time.Benchmark_Error.Okay)
	testing.expect_value(t, state.checksum, expected)
	ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
	log.infof("benchmark_asset_payload_size_calculation: %.2f ns/op, %.2f ops/s (%d iterations)", ns_per_op, options.rounds_per_second, options.count)
}

@(test)
benchmark_asset_xxhash_crc :: proc(t: ^testing.T) {
	if !persistence_micro_benchmark_enabled() do return
	// Typical asset record size
	data := make([]byte, 512)
	defer delete(data)
	for i in 0 ..< len(data) {
		data[i] = u8(i)
	}

	iterations := 15_000_000
	state := Asset_Benchmark_State {
		buf = data,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_asset_hash_callback,
		rounds    = iterations,
		user_data = &state,
	}
	err := time.benchmark(&options)
	expected := xxhash.XXH64(data) * u64(iterations)
	testing.expect_value(t, err, time.Benchmark_Error.Okay)
	testing.expect_value(t, state.checksum, expected)
	ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
	log.infof(
		"benchmark_asset_xxhash_crc (512 bytes): %.2f ns/op, %.2f ops/s, %.2f MiB/s (%d iterations)",
		ns_per_op,
		options.rounds_per_second,
		options.megabytes_per_second,
		options.count,
	)
}
