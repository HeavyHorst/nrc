package main

import "core:encoding/endian"
import "core:hash/xxhash"

SHARD_WAL_MAGIC :: u32(0x4e524357) // NRCW; shard transaction WAL identity.
SHARD_TRANSACTION_MAX_SIZE :: 16 * 1024 * 1024
SHARD_TRANSACTION_MAX_MUTATIONS :: 65535

Shard_Log_Op :: enum u8 {
	Transaction = 1,
}

Shard_Mutation_Domain :: enum u8 {
	Task  = 1,
	Asset = 2,
	Edge  = 3,
}
Shard_Transaction_Error :: enum {
	None,
	Malformed,
	Unsupported,
	Too_Large,
}

Shard_Mutation :: struct {
	domain:                Shard_Mutation_Domain,
	op:                    u8,
	entity_record_version: u16,
	payload:               []byte, // Existing entity bytes after its workspace prefix; borrowed and preserved exactly.
}

Shard_Transaction :: struct {
	workspace:        []byte,
	task_high_water:  u64,
	asset_high_water: u64,
	edge_high_water:  u64,
	mutations:        []Shard_Mutation,
}

Shard_Transaction_View :: struct {
	workspace:        []byte,
	task_high_water:  u64,
	asset_high_water: u64,
	edge_high_water:  u64,
	mutation_count:   u32,
	mutation_data:    []byte,
}

shard_for_workspace :: proc(workspace: []byte) -> u8 {
	return u8(xxhash.XXH64(workspace) % LOGICAL_SHARD_COUNT)
}

shard_mutation_supported :: proc(domain: Shard_Mutation_Domain, op: u8, version: u16) -> bool {
	switch domain {
	case .Task:
		return version == 1 && op >= 1 && op <= 4
	case .Asset:
		return version >= 1 && version <= 3 && (op == 1 || op == 2 || op == 3)
	case .Edge:
		return version == 1 && (op == 1 || op == 2)
	}
	return false
}

shard_transaction_size :: proc(tx: ^Shard_Transaction) -> (size: int, err: Shard_Transaction_Error) {
	if len(tx.workspace) == 0 do return 0, .Malformed
	if len(tx.workspace) > int(max(u16)) || len(tx.mutations) > SHARD_TRANSACTION_MAX_MUTATIONS do return 0, .Too_Large
	size = 34 + len(tx.workspace)
	for m in tx.mutations {
		if !shard_mutation_supported(m.domain, m.op, m.entity_record_version) do return 0, .Unsupported
		if u64(len(m.payload)) > u64(max(u32)) do return 0, .Too_Large
		if len(m.payload) > SHARD_TRANSACTION_MAX_SIZE || size > SHARD_TRANSACTION_MAX_SIZE - 8 - len(m.payload) do return 0, .Too_Large
		size += 8 + len(m.payload)
	}
	if size > SHARD_TRANSACTION_MAX_SIZE do return 0, .Too_Large
	return size, .None
}

// Validation and exact sizing happen before the first output byte is changed.
encode_shard_transaction :: proc(tx: ^Shard_Transaction, out: []byte) -> Shard_Transaction_Error {
	size, err := shard_transaction_size(tx)
	if err != .None do return err
	if len(out) != size do return .Malformed
	endian.put_u16(out, .Big, u16(len(tx.workspace))); copy(out[2:], tx.workspace)
	o := 2 + len(tx.workspace)
	endian.put_u64(out[o:], .Big, tx.task_high_water); o += 8
	endian.put_u64(out[o:], .Big, tx.asset_high_water); o += 8
	endian.put_u64(out[o:], .Big, tx.edge_high_water); o += 8
	endian.put_u32(out[o:], .Big, u32(len(tx.mutations))); o += 4
	endian.put_u32(out[o:], .Big, 0); o += 4
	for m in tx.mutations {
		out[o] = u8(m.domain); out[o + 1] = m.op
		endian.put_u16(out[o + 2:], .Big, m.entity_record_version)
		endian.put_u32(out[o + 4:], .Big, u32(len(m.payload))); o += 8
		copy(out[o:], m.payload); o += len(m.payload)
	}
	return .None
}

// The returned view borrows data. The envelope and every entry are completely
// validated before success, so callers can perform a separate traversal pass.
decode_shard_transaction :: proc(data: []byte) -> (view: Shard_Transaction_View, err: Shard_Transaction_Error) {
	if len(data) > SHARD_TRANSACTION_MAX_SIZE do return view, .Too_Large
	if len(data) < 34 do return view, .Malformed
	wlen, _ := endian.get_u16(data, .Big); if wlen == 0 do return view, .Malformed
	o := 2 + int(wlen); if o > len(data) || len(data) - o < 32 do return view, .Malformed
	view.workspace = data[2:o]
	view.task_high_water, _ = endian.get_u64(data[o:], .Big); o += 8
	view.asset_high_water, _ = endian.get_u64(data[o:], .Big); o += 8
	view.edge_high_water, _ = endian.get_u64(data[o:], .Big); o += 8
	view.mutation_count, _ = endian.get_u32(data[o:], .Big); o += 4
	reserved, _ := endian.get_u32(data[o:], .Big); o += 4
	if reserved != 0 do return Shard_Transaction_View{}, .Malformed
	if view.mutation_count > SHARD_TRANSACTION_MAX_MUTATIONS do return Shard_Transaction_View{}, .Too_Large
	start := o
	for _ in 0 ..< int(view.mutation_count) {
		if len(data) - o < 8 do return Shard_Transaction_View{}, .Malformed
		domain := Shard_Mutation_Domain(data[o]); op := data[o + 1]; version, _ := endian.get_u16(data[o + 2:], .Big)
		plen, _ := endian.get_u32(data[o + 4:], .Big); o += 8
		if u64(plen) > u64(SHARD_TRANSACTION_MAX_SIZE - o) do return Shard_Transaction_View{}, .Too_Large
		if u64(plen) > u64(len(data) - o) do return Shard_Transaction_View{}, .Malformed
		if !shard_mutation_supported(domain, op, version) do return Shard_Transaction_View{}, .Unsupported
		o += int(plen)
	}
	if o != len(data) do return Shard_Transaction_View{}, .Malformed
	view.mutation_data = data[start:o]
	return view, .None
}

Shard_Mutation_Visitor :: proc(mutation: Shard_Mutation, user_data: rawptr) -> bool

// A rejecting callback may observe earlier mutations; no later callback runs.
visit_shard_transaction_mutations :: proc(view: ^Shard_Transaction_View, visitor: Shard_Mutation_Visitor, user_data: rawptr = nil) -> bool {
	o := 0
	for _ in 0 ..< int(view.mutation_count) {
		domain := Shard_Mutation_Domain(view.mutation_data[o]); op := view.mutation_data[o + 1]
		version, _ := endian.get_u16(view.mutation_data[o + 2:], .Big)
		plen, _ := endian.get_u32(view.mutation_data[o + 4:], .Big); o += 8
		payload := view.mutation_data[o:o + int(plen)]; o += int(plen)
		if !visitor({domain = domain, op = op, entity_record_version = version, payload = payload}, user_data) do return false
	}
	return true
}

// High-waters are shard-wide maxima immediately after this transaction. They
// are nondecreasing along a shard WAL and the next allocated ID must be greater.
// Future replay performs a semantic no-side-effect pass (primary IDs, task
// BlockedBy, asset parent references, typed edge endpoints), then an infallible
// apply pass, then publication. Structural atomicity means one checksummed outer
// WAL record is recoverable all-or-none; it does not promise immediate fsync or
// callback-level atomic apply. There is intentionally no inner checksum.
