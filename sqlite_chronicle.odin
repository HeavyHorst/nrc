package main

import "core:c"
import "core:crypto/sha2"
import "core:encoding/endian"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

CHRONICLE_INPUT_BYTES :: 256 * 1024
CHRONICLE_RAW_TTL :: i64(72 * 60 * 60 * 1_000_000_000)

SQLite_Chronicle_Image :: struct {
	present:             bool,
	version:             i64,
	title, format, body: string,
	body_bytes:          i64,
	hash:                [32]byte,
}

sqlite_chronicle_metadata :: proc(asset: ^pr.Asset) -> (image: SQLite_Chronicle_Image, valid: bool) {
	if asset == nil do return {}, true
	image.present = true
	image.version = asset.updated_at
	image.body_bytes = i64(asset.payload_raw_len)
	image.format = "markdown"
	fields, object, ok := json_metadata_fields(asset.preview, [?]string{"title", "format"}, context.allocator)
	if !ok {
		// Match the client's legacy plain-title fallback without copying tags.
		image.title = string(asset.preview)
		return image, true
	}
	if !object do return image, false
	for field in fields do if field.kind != .Invalid && field.kind != .Null && field.kind != .String do return image, false
	image.title = json_metadata_string(fields[0], context.allocator)
	format := strings.to_lower(strings.trim_space(json_metadata_string(fields[1], context.allocator)))
	if format == "html" do image.format = "html"
	return image, true
}

// Only called after the combined decoded-size bound has passed. Never allocate
// a buffer from an unbounded advertised Zstd length or retain encoded images.
sqlite_chronicle_decode :: proc(asset: ^pr.Asset, image: ^SQLite_Chronicle_Image) -> bool {
	if asset == nil do return true
	switch asset.payload_encoding {
	case .Plain:
		if int(asset.payload_raw_len) != len(asset.payload) do return false
		image.body = string(asset.payload)
	case .Zstd:
		body := make([]byte, max(1, int(asset.payload_raw_len)))
		n := ZSTD_decompress(raw_data(body), uintptr(len(body)), raw_data(asset.payload), uintptr(len(asset.payload)))
		if ZSTD_isError(n) != 0 || n != uintptr(asset.payload_raw_len) do return false
		image.body = string(body[:int(n)])
	case:
		return false
	}
	// Length framing prevents ambiguous concatenation (title="ab", body="c"
	// versus title="a", body="bc"). Absence is represented separately.
	h: sha2.Context_256
	sha2.init_256(&h)
	for text in ([3]string{image.title, image.format, image.body}) {
		length: [8]byte
		endian.put_u64(length[:], .Big, u64(len(text)))
		sha2.update(&h, length[:]); sha2.update(&h, transmute([]byte)text)
	}
	sha2.final(&h, image.hash[:])
	return true
}

// Shared by single writes, atomic batches and cascades. Every error propagates
// to their existing transaction rollback; quota/invalid-input gaps are writes,
// not successful error swallowing. No provider or network work happens here.
sqlite_capture_chronicle :: proc(store: ^db.Store, request: ^db.Request, before, after: ^pr.Asset, source_id: u64, actor: string) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	asset := after != nil ? after : before
	if asset.asset_type != .Note do return sql.OK
	epoch, available, input_slots, enabled, rc := db.chronicle_workspace(store, request.workspace)
	if rc != sql.OK || !enabled do return rc
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	b, b_valid := sqlite_chronicle_metadata(before)
	a, a_valid := sqlite_chronicle_metadata(after)
	reason := ""
	if !b_valid || !a_valid do reason = "invalid_metadata"
	if reason == "" &&
	   before != nil &&
	   after != nil &&
	   b.title == a.title &&
	   b.format == a.format &&
	   before.payload_encoding == after.payload_encoding &&
	   before.payload_raw_len == after.payload_raw_len &&
	   string(before.payload) == string(after.payload) {
		return sql.OK
	}
	b_bytes, a_bytes := b.body_bytes + i64(len(b.title)), a.body_bytes + i64(len(a.title))
	if reason == "" && b_bytes + a_bytes > CHRONICLE_INPUT_BYTES do reason = "input_size"
	if reason == "" {
		if !sqlite_chronicle_decode(before, &b) || !sqlite_chronicle_decode(after, &a) do reason = "decode_error"
		if reason == "" && before != nil && after != nil && b.title == a.title && b.format == a.format && b.body == a.body do return sql.OK
	}
	if reason == "" && b_bytes + a_bytes + i64(len(b.format) + len(a.format)) > available do reason = "workspace_quota"
	if reason == "" && input_slots <= 0 do reason = "input_quota"
	if reason == "" && (len(actor) > 256 || len(request.actor) > 256) do reason = "metadata_size"
	key := pr.Asset {
		asset_id = asset.asset_id,
	}
	before_hash := b.present && reason == "" ? b.hash[:] : nil
	after_hash := a.present && reason == "" ? a.hash[:] : nil
	rc = sqlite_projection_write(
		store,
		`INSERT INTO chronicle_inputs
 (workspace,note_id,source_id,epoch,captured_at,expires_at,actor_id,actor_name,operation,
 before_present,after_present,before_version,after_version,before_bytes,after_bytes,before_hash,after_hash,state,reason)
 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)`,
		request.workspace,
		&key,
		{
			source_id,
			epoch,
			request.timestamp,
			min(request.timestamp, max(i64) - CHRONICLE_RAW_TTL) + CHRONICLE_RAW_TTL,
			actor,
			request.actor,
			i64(before == nil ? 1 : (after == nil ? 3 : 2)),
			i64(b.present),
			i64(a.present),
			b.version,
			a.version,
			b_bytes,
			a_bytes,
			string(before_hash),
			string(after_hash),
			i64(reason == "" ? 0 : 3),
			reason,
		},
	)
	if rc != sql.OK do return rc
	if reason != "" do return db.compact_chronicle_gap(store, request.workspace, source_id)
	key.asset_id = source_id
	return sqlite_projection_write(
		store,
		`INSERT INTO chronicle_raw
 (workspace,source_id,before_title,before_format,before_body,after_title,after_format,after_body)
 VALUES(?1,?2,?3,?4,?5,?6,?7,?8)`,
		request.workspace,
		&key,
		{b.title, b.format, b.body, a.title, a.format, a.body},
	)
}
