package protocol

import "core:encoding/endian"
import "core:testing"

@(test)
test_open_incident_wire_contract :: proc(t: ^testing.T) {
	fixture := transmute([]byte)string("\x00\x4c\x12\x34\x56\x78\x80\x00\x00\x00\x00\x00\x00\x07\x10")
	r, err := parseListOpenIncidentsRequest(fixture[2:])
	testing.expect(t, get_opcode(fixture) == .C_ListOpenIncidents && err == nil && r == ListOpenIncidentsRequest{0x12345678, 0x8000000000000007, 16})
	testing.expect_value(t, get_opcode({0, 181}), .S_OpenIncidentPage)
	for cut in 0 ..< 13 {_, e := parseListOpenIncidentsRequest(fixture[2:2 + cut]); testing.expect(t, e != nil)}
	bad: [14]byte
	copy(bad[:], fixture[2:])
	_, e := parseListOpenIncidentsRequest(bad[:]); testing.expect(t, e != nil)
	for limit in ([2]u8{0, 17}) {
		bad[12] = limit
		_, e = parseListOpenIncidentsRequest(bad[:13]); testing.expect(t, e != nil)
	}
}

@(test)
test_monitor_history_wire_contract :: proc(t: ^testing.T) {
	// Same independent continuation fixture as protocol-go/monitoring_test.go.
	fixture := transmute([]byte)string(
		"\x00\x4b\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x64\x00",
	)
	r, err := parseMonitorHistoryRequest(fixture[2:])
	testing.expect(t, get_opcode(fixture) == .C_MonitorHistory && err == nil && r == MonitorHistoryRequest{1, 7, 11, 16, 100, false})
	for cut in 0 ..< 37 {
		_, err = parseMonitorHistoryRequest(fixture[2:2 + cut])
		testing.expect(t, err != nil)
	}
	for invalid in 0 ..< 5 {
		bad: [37]byte
		copy(bad[:], fixture[2:])
		switch invalid {
		case 0:
			endian.put_u64(bad[4:], .Big, 0)
		case 1:
			endian.put_u64(bad[28:], .Big, 0)
		case 2:
			bad[36] = 2
		case 3:
			bad[36] = 1 // An acknowledgment cannot contain a page cursor.
		case 4:
			endian.put_u64(bad[20:], .Big, 0) // Initial reads cannot invent a snapshot.
		}
		_, err = parseMonitorHistoryRequest(bad[:])
		testing.expect(t, err != nil)
	}
	initial: [37]byte
	endian.put_u64(initial[4:], .Big, 7)
	_, err = parseMonitorHistoryRequest(initial[:]); testing.expect(t, err == nil)
	endian.put_u64(initial[28:], .Big, 100); initial[36] = 1
	_, err = parseMonitorHistoryRequest(initial[:]); testing.expect(t, err != nil)
	endian.put_u64(initial[12:], .Big, 1)
	_, err = parseMonitorHistoryRequest(initial[:]); testing.expect(t, err == nil) // Run sequence may be zero; capture ID cannot.
}

@(test)
test_monitor_status_wire_contract :: proc(t: ^testing.T) {
	// Same independent bytes as protocol-go/monitor_status_test.go.
	fixture := transmute([]byte)string(
		"\x00\x49\x12\x34\x56\x78\x00\x00\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x0b\x02\x00\x00\x00\x00\x00\x00\x00\x09\x10\x01",
	)
	r, err := parseQueryMonitorStatusRequest(fixture[2:])
	testing.expect(
		t,
		err == nil &&
		get_opcode(fixture) == .C_QueryMonitorStatus &&
		r.correlation_id == 0x12345678 &&
		r.monitor_id == 7 &&
		r.cursor_id == 11 &&
		r.cursor_rank == 2 &&
		r.at == 9 &&
		r.limit == 16 &&
		r.include_retired,
	)
	testing.expect_value(t, get_opcode({0, 179}), .S_MonitorStatusPage)
	filtered: [35]byte
	filtered[29] = 16; filtered[31] = 2; filtered[32] = '#'; filtered[33] = '1'; filtered[34] = '2'
	f, fe := parseQueryMonitorStatusRequest(filtered[:])
	testing.expect(t, fe == nil && f.state_filter == 2 && f.search == "#12")
	filtered[31] = 4
	_, fe = parseQueryMonitorStatusRequest(filtered[:]); testing.expect(t, fe != nil)
	filtered[31] = 0; filtered[32] = 255
	_, fe = parseQueryMonitorStatusRequest(filtered[:]); testing.expect(t, fe != nil)
	for cut in 0 ..< 31 {_, parse_err := parseQueryMonitorStatusRequest(fixture[2:2 + cut]); testing.expect(t, parse_err != nil)}
	for pair in ([3][2]u8{{20, 9}, {29, 0}, {30, 2}}) {
		bad: [31]byte; copy(bad[:], fixture[2:]); bad[pair[0]] = pair[1]
		_, parse_err := parseQueryMonitorStatusRequest(bad[:]); testing.expect(t, parse_err != nil)
	}
}

@(test)
test_monitor_run_wire_contract :: proc(t: ^testing.T) {
	// Same independently specified fixture as protocol-go/monitoring_test.go.
	fixture := transmute([]byte)string(
		"\x00\x44\x12\x34\x56\x78\x00\x00\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x01\x00\x04disk\x01\x40\x1d\x00\x00\x00\x00\x00\x00",
	)
	rows: [1]Monitor_Observation
	r, err := parseApplyMonitorRunRequest(fixture[2:], rows[:])
	testing.expect(
		t,
		err == nil &&
		get_opcode(fixture) == .C_ApplyMonitorRun &&
		r.monitor_id == 7 &&
		r.revision == 9 &&
		r.sequence == 11 &&
		r.correlation_id == 0x12345678 &&
		!r.failed,
	)
	testing.expect(t, len(r.observations) == 1 && rows[0].identity == "disk" && rows[0].condition == 1 && rows[0].value == 7.25)
	buf: [100]byte
	n := serializeApplyMonitorRunRequest(r, buf[:])
	testing.expect(t, n == len(fixture) && string(buf[:n]) == string(fixture))
	for cut in 0 ..< len(fixture) - 2 {
		parsed, e := parseApplyMonitorRunRequest(fixture[2:2 + cut], rows[:])
		testing.expect(t, e != nil)
		testing.expect_value(t, parsed.correlation_id, cut >= 4 ? u32(0x12345678) : 0)
	}
	bad, extra := parseApplyMonitorRunRequest(buf[2:n + 1], rows[:]); testing.expect(t, extra != nil && bad.correlation_id == 0x12345678)
	buf[30] = 1 // Failed runs must not contain partial observations.
	failed, partial := parseApplyMonitorRunRequest(buf[2:n], rows[:]); testing.expect(t, partial != nil && failed.correlation_id == 0x12345678)
}

@(test)
test_monitor_control_wire_contract :: proc(t: ^testing.T) {
	fixture := transmute([]byte)string(
		"\x00\x45\x12\x34\x56\x78\x00\x00\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x0b\x02",
	)
	r, err := parseControlMonitorInstanceRequest(fixture[2:])
	testing.expect(t, err == nil && get_opcode(fixture) == .C_ControlMonitorInstance && r == ControlMonitorInstanceRequest{0x12345678, 7, 9, 11, 2})
	buf: [32]byte
	n := serializeControlMonitorInstanceRequest(r, buf[:])
	testing.expect(t, n == len(fixture) && string(buf[:n]) == string(fixture))
	for cut in 0 ..< len(fixture) - 2 {
		parsed, e := parseControlMonitorInstanceRequest(fixture[2:2 + cut])
		testing.expect(t, e != nil && parsed.correlation_id == (cut >= 4 ? u32(0x12345678) : 0))
	}
	_, extra := parseControlMonitorInstanceRequest(buf[2:]); testing.expect(t, extra != nil)
	for offset in ([4]int{13, 21, 29, 30}) {
		copy(buf[:], fixture)
		buf[offset] = offset == 30 ? 3 : 0
		bad, e := parseControlMonitorInstanceRequest(buf[2:31])
		testing.expect(t, e != nil && bad.correlation_id == 0x12345678)
	}
}

@(test)
test_incident_action_wire_contract :: proc(t: ^testing.T) {
	fixture := transmute([]byte)string("\x00\x46\x12\x34\x56\x78\x00\x00\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x09\x01\x00\x03bob")
	r, err := parseActOnIncidentRequest(fixture[2:])
	testing.expect(t, err == nil && get_opcode(fixture) == .C_ActOnIncident && r == ActOnIncidentRequest{0x12345678, 7, 9, 1, "bob"})
	buf: [64]byte
	n := serializeActOnIncidentRequest(r, buf[:])
	testing.expect(t, n == len(fixture) && string(buf[:n]) == string(fixture))
	for cut in 0 ..< len(fixture) - 2 {
		parsed, e := parseActOnIncidentRequest(fixture[2:2 + cut])
		testing.expect(t, e != nil && parsed.correlation_id == (cut >= 4 ? u32(0x12345678) : 0))
	}
	_, extra := parseActOnIncidentRequest(buf[2:n + 1]); testing.expect(t, extra != nil)
	for offset in ([4]int{13, 21, 22, 25}) {
		copy(buf[:], fixture)
		buf[offset] = offset == 22 ? 2 : (offset == 25 ? 255 : 0)
		bad, e := parseActOnIncidentRequest(buf[2:n])
		testing.expect(t, e != nil && bad.correlation_id == 0x12345678)
	}
	copy(buf[:], fixture); buf[22] = 0
	_, forged_ack := parseActOnIncidentRequest(buf[2:n]); testing.expect(t, forged_ack != nil)
	r.assignee = ""; r.action = 0
	testing.expect_value(t, serializeActOnIncidentRequest(r, buf[:]), 25)
	r.action = 1
	testing.expect_value(t, serializeActOnIncidentRequest(r, buf[:]), 25) // Clear assignment.
	r.assignee = "012345678901234567890123456789é" // 30 ASCII bytes + 2 UTF-8 bytes.
	testing.expect_value(t, serializeActOnIncidentRequest(r, buf[:]), 57)
	endian.put_u16(buf[23:], .Big, 33); buf[57] = 'x'
	_, too_long := parseActOnIncidentRequest(buf[2:58]); testing.expect(t, too_long != nil)
}

@(test)
test_monitor_delivery_wire_contract :: proc(t: ^testing.T) {
	fixture := transmute([]byte)string(
		"\x00\x47\x12\x34\x56\x78\x00\x00\x00\x00\x00\x00\x00\x07\x01\x02\x00\x00\x00\x00\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x0b\x06ops-v1",
	)
	r, err := parseMonitorDeliveryRequest(fixture[2:])
	testing.expect(t, err == nil && get_opcode(fixture) == .C_MonitorDelivery && r == MonitorDeliveryRequest{0x12345678, 7, 1, 2, 9, 11, "ops-v1"})
	buf: [128]byte
	n := serializeMonitorDeliveryRequest(r, buf[:])
	testing.expect(t, n == len(fixture) && string(buf[:n]) == string(fixture))
	for cut in 0 ..< len(fixture) - 2 {
		_, e := parseMonitorDeliveryRequest(fixture[2:2 + cut]); testing.expect(t, e != nil)
	}
	_, extra := parseMonitorDeliveryRequest(buf[2:n + 1]); testing.expect(t, extra != nil)
	r.stream = 0
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), -1)
	r.route = ""; r.action = 4
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), -1)
	r.action = 1
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), -1)
	r.id = 0; r.generation = 0
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), -1)
	r.action = 6
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), -1)
	r.stream = 1
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), 33)
	r.route = "ops-v1"
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), 39)
	r.id = 1
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), -1)
	r.id = 0; r.generation = 1
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), -1)
	r.generation = 0; r.route = "bad/route"
	testing.expect_value(t, serializeMonitorDeliveryRequest(r, buf[:]), -1)
}
@(test)
test_monitor_state_request :: proc(t: ^testing.T) {
	fixture := transmute([]byte)string("\x00\x48\x12\x34\x56\x78\x00\x00\x00\x00\x00\x00\x00\x07")
	r, err := parseGetMonitorStateRequest(fixture[2:])
	testing.expect(t, get_opcode(fixture) == .C_GetMonitorState && err == nil && r == GetMonitorStateRequest{correlation_id = 0x12345678, monitor_id = 7})
	for cut in 0 ..< len(fixture) - 2 {_, e := parseGetMonitorStateRequest(fixture[2:2 + cut]); testing.expect(t, e != nil)}
	zero: [13]byte
	_, e := parseGetMonitorStateRequest(zero[:12]); testing.expect(t, e != nil)
	_, e = parseGetMonitorStateRequest(zero[:]); testing.expect(t, e != nil)
	page: [44]byte
	copy(page[:], fixture[2:])
	endian.put_u64(page[20:], .Big, 9)
	endian.put_u64(page[28:], .Big, 11)
	snapshot, se := parseGetMonitorStateRequest(page[:])
	testing.expect(t, se == nil && snapshot.detailed && snapshot.revision == 9 && snapshot.sequence == 11)
	endian.put_u64(page[12:], .Big, 3)
	_, se = parseGetMonitorStateRequest(page[:]); testing.expect(t, se != nil)
	endian.put_u64(page[36:], .Big, 100)
	snapshot, se = parseGetMonitorStateRequest(page[:]); testing.expect(t, se == nil && snapshot.cursor == 3 && snapshot.at == 100)
}
