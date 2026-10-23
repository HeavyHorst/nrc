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

// These server responses have a serializer in the protocol package but no Odin
// parser: only the Go CLI and the JS client decode them. This is a manual
// inventory; adding an Odin parser requires removing the opcode here and adding
// a dispatch case. The test below verifies the target's dispatch, not whether a
// parser exists in the protocol package.
RESPONSE_OPCODES_WITHOUT_ODIN_PARSER := [?]pr.Opcode {
	.S_TransactionResult,
	.S_TaskQueryPage,
	.S_TaskProjects,
	.S_TaskAssignees,
	.S_CalendarPage,
	.S_WorkspaceOverview,
	.S_HistoryPage,
	.S_TaskDependentsPage,
	.S_SliceOwners,
	.S_TicketAssignees,
	.S_CalendarPeople,
	.S_EdgeListPage,
	.S_CustomerSearchPage,
	.S_TicketPage,
	.S_GraphRankResult,
}

@(test)
test_every_response_opcode_is_dispatched :: proc(t: ^testing.T) {
	checked := 0
	for field in reflect.enum_fields_zipped(pr.Opcode) {
		if !strings.has_prefix(field.name, "S_") do continue
		op := pr.Opcode(field.value)
		probe := [2]byte{u8(u16(op) >> 8), u8(u16(op) & 0xff)}
		err := exercise_response(probe[:])
		skipped := false
		for candidate in RESPONSE_OPCODES_WITHOUT_ODIN_PARSER {
			if candidate == op {
				skipped = true
				break
			}
		}
		if skipped {
			testing.expectf(t, err == .InvalidOpcode, "opcode %s is listed as unparsed but the target dispatches it; remove it from the skip list", field.name)
		} else {
			testing.expectf(t, err != .InvalidOpcode, "response opcode %s is not dispatched by the fuzz target", field.name)
		}
		checked += 1
	}
	testing.expectf(t, checked > 0, "found no response opcodes to check")
}
