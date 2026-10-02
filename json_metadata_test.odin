package main

import "core:mem"
import "core:testing"

json_metadata_failing_allocator :: proc(
	_: rawptr,
	_: mem.Allocator_Mode,
	_, _: int,
	_: rawptr,
	_: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	return nil, .Out_Of_Memory
}

@(test)
test_json_metadata_key_allocation_failure :: proc(t: ^testing.T) {
	testing.expect_assert(t, "failed to decode JSON metadata string")
	// A failed escaped-key decode must not hide a duplicate selected key.
	_, _, _ = json_metadata_fields(
		transmute([]byte)string(`{"project":"p","pro\u006aect":"q"}`),
		[?]string{"project", "tags"},
		mem.Allocator{procedure = json_metadata_failing_allocator},
	)
	testing.expect(t, false, "metadata decoding must not return after allocation failure")
}

@(test)
test_json_metadata_tag_allocation_failure :: proc(t: ^testing.T) {
	testing.expect_assert(t, "failed to decode JSON metadata string")
	// Removal must not treat an undecodable stored tag as an empty tag.
	tags: [dynamic]string
	_ = json_note_metadata_fields(
		transmute([]byte)string(`{"project":"p","tags":["\u0074"]}`),
		&tags,
		mem.Allocator{procedure = json_metadata_failing_allocator},
	)
	testing.expect(t, false, "metadata decoding must not return after allocation failure")
}
