package protocol_fuzz

import pr "../../protocol"
import "core:reflect"
import "core:strings"
import "core:testing"

// Every client-to-server opcode has to be dispatched. Adding one to Opcode
// without extending the target fails here instead of silently shrinking what
// the campaign can reach.
@(test)
test_every_client_opcode_is_dispatched :: proc(t: ^testing.T) {
	checked := 0
	for field in reflect.enum_fields_zipped(pr.Opcode) {
		if !strings.has_prefix(field.name, "C_") do continue
		op := u16(field.value)
		// A bare opcode is enough: every dispatched parser rejects the empty body
		// with a length error, while an undispatched one falls through to
		// InvalidOpcode.
		probe := [2]byte{u8(op >> 8), u8(op & 0xff)}
		if err := exercise(probe[:]); err == .InvalidOpcode {
			testing.expectf(t, false, "opcode %s is not dispatched by the fuzz target", field.name)
		}
		checked += 1
	}
	testing.expectf(t, checked > 0, "found no client opcodes to check")
}
