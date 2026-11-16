package protocol

import "core:encoding/endian"
import "core:unicode/utf8"

MAX_MONITOR_INSTANCES :: 1024
// monitor_id=0 lists monitors; otherwise lists that monitor's instances.
QueryMonitorStatusRequest :: struct {
	correlation_id:        u32,
	monitor_id, cursor_id: u64,
	cursor_rank:           u8,
	at:                    i64,
	limit:                 u8,
	include_retired:       bool,
}

parseQueryMonitorStatusRequest :: proc(data: []byte) -> (r: QueryMonitorStatusRequest, err: ProtocolParseError) {
	if len(data) >= 4 do r.correlation_id, _ = endian.get_u32(data, .Big)
	if len(data) != 31 do return r, .InvalidValue
	r.monitor_id, _ = endian.get_u64(data[4:], .Big)
	r.cursor_id, _ = endian.get_u64(data[12:], .Big)
	r.cursor_rank = data[20]
	r.at, _ = endian.get_i64(data[21:], .Big)
	r.limit = data[29]
	r.include_retired = data[30] == 1
	if r.limit == 0 ||
	   r.limit > 16 ||
	   data[30] > 1 ||
	   r.cursor_rank > 8 ||
	   r.at < 0 ||
	   (r.cursor_id == 0 && r.cursor_rank != 0) ||
	   (r.cursor_id != 0 && r.at == 0) ||
	   (r.monitor_id == 0 && r.include_retired) {
		return r, .InvalidValue
	}
	return
}

GetMonitorStateRequest :: struct {
	correlation_id: u32,
	monitor_id:     u64,
	// Optional bounded instance page for analytical availability snapshots.
	detailed:       bool,
	cursor:         u64,
	revision:       i64,
	sequence:       u64,
	at:             i64,
}

parseGetMonitorStateRequest :: proc(data: []byte) -> (r: GetMonitorStateRequest, err: ProtocolParseError) {
	if len(data) >= 4 do r.correlation_id, _ = endian.get_u32(data, .Big)
	if len(data) < 12 do return r, .TooShort
	if len(data) != 12 && len(data) != 44 do return r, .InvalidValue
	r.monitor_id, _ = endian.get_u64(data[4:], .Big)
	if r.monitor_id == 0 do return r, .InvalidValue
	if len(data) == 44 {
		r.detailed = true
		r.cursor, _ = endian.get_u64(data[12:], .Big)
		revision, _ := endian.get_u64(data[20:], .Big); r.revision = i64(revision)
		r.sequence, _ = endian.get_u64(data[28:], .Big)
		at, _ := endian.get_u64(data[36:], .Big); r.at = i64(at)
		if r.revision <= 0 || r.at < 0 || (r.cursor != 0 && r.at == 0) do return r, .InvalidValue
	}
	return
}

valid_monitor_route :: proc(route: string) -> bool {
	if len(route) == 0 || len(route) > 64 do return false
	for c in route {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') do return false
	}
	return true
}

MonitorDeliveryRequest :: struct {
	correlation_id: u32,
	monitor_id:     u64,
	stream, action: u8,
	id:             u64,
	generation:     i64,
	route:          string,
}

parseMonitorDeliveryRequest :: proc(data: []byte) -> (r: MonitorDeliveryRequest, err: ProtocolParseError) {
	if len(data) >= 4 do r.correlation_id, _ = endian.get_u32(data, .Big)
	if len(data) < 31 do return r, .TooShort
	r.monitor_id, _ = endian.get_u64(data[4:], .Big)
	r.stream, r.action = data[12], data[13]
	r.id, _ = endian.get_u64(data[14:], .Big)
	g, _ := endian.get_u64(data[22:], .Big); r.generation = i64(g)
	if len(data) != 31 + int(data[30]) do return r, .InvalidValue
	r.route = string(data[31:])
	// Resync page: ID is the exclusive incident cursor; generation is snapshot version.
	if r.action == 7 {
		if r.monitor_id == 0 || r.stream != 1 || r.generation <= 0 || !valid_monitor_route(r.route) do return r, .InvalidValue
		return
	}
	// Discovery uses route as an exclusive cursor, empty for the first page.
	if r.action == 6 {
		if r.monitor_id == 0 || r.stream != 1 || r.id != 0 || r.generation != 0 || (r.route != "" && !valid_monitor_route(r.route)) do return r, .InvalidValue
		return
	}
	if r.monitor_id == 0 || r.stream != 1 || r.action > 5 || r.generation < 0 || !valid_monitor_route(r.route) do return r, .InvalidValue
	if r.action < 2 {if r.id != 0 || r.generation != 0 do return r, .InvalidValue} else if r.id == 0 || r.generation == 0 do return r, .InvalidValue
	return
}

serializeMonitorDeliveryRequest :: proc(r: MonitorDeliveryRequest, buf: []byte) -> int {
	n := 33 + len(r.route)
	if len(r.route) > 64 || len(buf) < n do return -1
	endian.put_u16(buf, .Big, u16(Opcode.C_MonitorDelivery))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.monitor_id)
	buf[14], buf[15] = r.stream, r.action
	endian.put_u64(buf[16:], .Big, r.id)
	endian.put_u64(buf[24:], .Big, u64(r.generation))
	buf[32] = u8(len(r.route)); copy(buf[33:], r.route)
	if _, err := parseMonitorDeliveryRequest(buf[2:n]); err != nil do return -1
	return n
}
Monitor_Observation :: struct {
	identity:  string,
	condition: u8, // 0 passing, 1 failing, 2 hysteresis band.
	value:     f64,
}
ApplyMonitorRunRequest :: struct {
	correlation_id: u32,
	monitor_id:     u64,
	revision:       i64,
	sequence:       u64,
	failed:         bool, // A failed/incomplete query has no rows and never implies absence.
	observations:   []Monitor_Observation,
}

// Body only; rows and identities borrow caller storage/input.
parseApplyMonitorRunRequest :: proc(data: []byte, rows: []Monitor_Observation) -> (r: ApplyMonitorRunRequest, err: ProtocolParseError) {
	if len(data) >= 4 do r.correlation_id, _ = endian.get_u32(data, .Big)
	if len(data) < 31 do return r, .TooShort
	if len(data) > MAX_PROTOCOL_PAYLOAD_SIZE - 2 do return r, .InvalidValue
	r.monitor_id, _ = endian.get_u64(data[4:], .Big)
	revision, _ := endian.get_u64(data[12:], .Big); r.revision = i64(revision)
	r.sequence, _ = endian.get_u64(data[20:], .Big)
	count, _ := endian.get_u16(data[29:], .Big)
	if r.monitor_id == 0 || r.revision <= 0 || r.sequence == 0 || data[28] > 1 || count > MAX_MONITOR_INSTANCES || int(count) > len(rows) do return r, .InvalidValue
	r.failed = data[28] == 1
	if r.failed && count != 0 do return r, .InvalidValue
	offset := 31
	for i in 0 ..< int(count) {
		if len(data) - offset < 2 do return r, .TooShort
		n, _ := endian.get_u16(data[offset:], .Big); offset += 2
		if n == 0 || n > 4096 do return r, .InvalidValue
		if len(data) - offset < int(n) + 9 do return r, .TooShort
		rows[i].identity = string(data[offset:offset + int(n)]); offset += int(n)
		rows[i].condition = data[offset]; offset += 1
		bits, _ := endian.get_u64(data[offset:], .Big); offset += 8
		rows[i].value = transmute(f64)bits
		v := rows[i].value
		if rows[i].condition > 2 || v != v || v > max(f64) || v < -max(f64) do return r, .InvalidValue
	}
	if offset != len(data) do return r, .InvalidValue
	r.observations = rows[:int(count)]
	return
}

serializeApplyMonitorRunRequest :: proc(r: ApplyMonitorRunRequest, buf: []byte) -> int {
	size := 33
	for row in r.observations do size += 11 + len(row.identity)
	if size > len(buf) || size > MAX_PROTOCOL_PAYLOAD_SIZE || len(r.observations) > MAX_MONITOR_INSTANCES do return -1
	endian.put_u16(buf, .Big, u16(Opcode.C_ApplyMonitorRun))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.monitor_id)
	endian.put_u64(buf[14:], .Big, u64(r.revision))
	endian.put_u64(buf[22:], .Big, r.sequence)
	buf[30] = r.failed ? 1 : 0
	endian.put_u16(buf[31:], .Big, u16(len(r.observations)))
	offset := 33
	for row in r.observations {
		if len(row.identity) == 0 || len(row.identity) > 4096 do return -1
		endian.put_u16(buf[offset:], .Big, u16(len(row.identity))); offset += 2
		copy(buf[offset:], row.identity); offset += len(row.identity)
		buf[offset] = row.condition; offset += 1
		endian.put_u64(buf[offset:], .Big, transmute(u64)row.value); offset += 8
	}
	rows: [MAX_MONITOR_INSTANCES]Monitor_Observation
	if _, err := parseApplyMonitorRunRequest(buf[2:size], rows[:]); err != nil do return -1
	return size
}

ControlMonitorInstanceRequest :: struct {
	correlation_id: u32,
	monitor_id:     u64,
	revision:       i64, // Expected Monitor asset revision; acceptance advances it.
	instance_id:    u64,
	action:         u8, // 0 pause, 1 resume, 2 retire.
}

parseControlMonitorInstanceRequest :: proc(data: []byte) -> (r: ControlMonitorInstanceRequest, err: ProtocolParseError) {
	if len(data) >= 4 do r.correlation_id, _ = endian.get_u32(data, .Big)
	if len(data) < 29 do return r, .TooShort
	if len(data) != 29 do return r, .InvalidValue
	r.monitor_id, _ = endian.get_u64(data[4:], .Big)
	revision, _ := endian.get_u64(data[12:], .Big); r.revision = i64(revision)
	r.instance_id, _ = endian.get_u64(data[20:], .Big)
	r.action = data[28]
	if r.monitor_id == 0 || r.revision <= 0 || r.instance_id == 0 || r.action > 2 do return r, .InvalidValue
	return
}

serializeControlMonitorInstanceRequest :: proc(r: ControlMonitorInstanceRequest, buf: []byte) -> int {
	if len(buf) < 31 do return -1
	endian.put_u16(buf, .Big, u16(Opcode.C_ControlMonitorInstance))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.monitor_id)
	endian.put_u64(buf[14:], .Big, u64(r.revision))
	endian.put_u64(buf[22:], .Big, r.instance_id)
	buf[30] = r.action
	if _, err := parseControlMonitorInstanceRequest(buf[2:31]); err != nil do return -1
	return 31
}

ActOnIncidentRequest :: struct {
	correlation_id: u32,
	incident_id:    u64,
	revision:       i64,
	action:         u8, // 0 acknowledge as the authenticated actor; 1 assign (empty clears).
	assignee:       string,
}

parseActOnIncidentRequest :: proc(data: []byte) -> (r: ActOnIncidentRequest, err: ProtocolParseError) {
	if len(data) >= 4 do r.correlation_id, _ = endian.get_u32(data, .Big)
	if len(data) < 23 do return r, .TooShort
	r.incident_id, _ = endian.get_u64(data[4:], .Big)
	revision, _ := endian.get_u64(data[12:], .Big); r.revision = i64(revision)
	r.action = data[20]
	n, _ := endian.get_u16(data[21:], .Big)
	if r.incident_id == 0 || r.revision <= 0 || r.action > 1 || n > MAX_ASSIGNEE_LENGTH || len(data) != 23 + int(n) || (r.action == 0 && n != 0) do return r, .InvalidValue
	r.assignee = string(data[23:])
	if !utf8.valid_string(r.assignee) do return r, .InvalidValue
	return
}

serializeActOnIncidentRequest :: proc(r: ActOnIncidentRequest, buf: []byte) -> int {
	size := 25 + len(r.assignee)
	if len(r.assignee) > MAX_ASSIGNEE_LENGTH || len(buf) < size do return -1
	endian.put_u16(buf, .Big, u16(Opcode.C_ActOnIncident))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.incident_id)
	endian.put_u64(buf[14:], .Big, u64(r.revision))
	buf[22] = r.action
	endian.put_u16(buf[23:], .Big, u16(len(r.assignee)))
	copy(buf[25:], r.assignee)
	if _, err := parseActOnIncidentRequest(buf[2:size]); err != nil do return -1
	return size
}
