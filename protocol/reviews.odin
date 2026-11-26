package protocol

import "core:encoding/endian"
import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

MAX_REVIEW_POINTS :: 100
MAX_REVIEW_FORM_BYTES :: 48 * 1024

// Point IDs are local to a form, never their array offsets. Reordering preserves
// identity. Decimal strings keep IDs and nanosecond timestamps lossless in JS.
Review_Point :: struct {
	id:          string,
	question:    string,
	instruction: string,
	expected:    string,
	// Optional author-defined label. Old forms omit it and remain valid.
	section:     string `json:"section,omitempty"`,
}
Review_Form :: struct {
	version:     int,
	title:       string,
	build:       string,
	environment: string,
	released_at: string,
	archived:    bool `json:"archived,omitempty"`,
	points:      []Review_Point,
}
Review_Request :: struct {
	op:                                     string,
	form_id:                                string,
	if_revision:                            string,
	if_released_at:                         string,
	form:                                   Review_Form,
	run_id, label, kind, previous_run:      string,
	source, identity, name:                 string,
	can_close:                              bool,
	point_id, result, comment, decision:    string,
	token, guest_id, expires_at, invite_id: string,
	cursor:                                 string,
	portal_proof:                           Portal_Write_Proof `json:"-"`,
}
Review_Participant :: struct {
	id, source, identity, name: string,
	can_close:                  bool,
}
Review_Answer :: struct {
	id, participant_id, point_id, result, comment, name, updated_at: string,
}
Review_Run :: struct {
	id, form_id, label, kind, previous_run, revision:                    string,
	title:                                                               string,
	decision, comment, closed_at, closed_by, closed_name, closed_source: string,
	participants:                                                        []Review_Participant,
	answers:                                                             []Review_Answer,
	answered_points:                                                     int,
}
Review_Account_Choice :: struct {requester, name, login: string}
Review_Invite :: struct {
	id, expires_at, revoked_at: string,
	can_close:                  bool,
	expired:                    bool,
	token:                      string `json:"token,omitempty"`,
}
Review_Response :: struct {
	status:                           string,
	form_id:                          string,
	revision:                         string,
	form:                             Review_Form,
	run:                              Review_Run,
	runs:                             []Review_Run,
	accounts:                         []Review_Account_Choice `json:"accounts,omitempty"`,
	invites:                          []Review_Invite `json:"invites,omitempty"`,
	token, invite_id, participant_id: string,
	cursor:                           string,
	has_more:                         bool,
}

review_text_valid :: proc(text: string, limit: int, required := false) -> bool {
	return len(text) <= limit && utf8.valid_string(text) && strings.index_byte(text, 0) < 0 && (!required || strings.trim_space(text) != "")
}

validate_review_form :: proc(form: Review_Form, released := false) -> bool {
	if form.version != 1 ||
	   !review_text_valid(form.title, MAX_TASK_TITLE_LENGTH, true) ||
	   !review_text_valid(form.build, 512, released) ||
	   !review_text_valid(form.environment, 2048) ||
	   len(form.points) > MAX_REVIEW_POINTS ||
	   (form.archived && form.released_at == "") ||
	   (released && len(form.points) == 0) {return false}
	if form.released_at != "" {
		n, ok := chronicle_decimal(form.released_at)
		if !ok || n == 0 || n > u64(max(i64)) do return false
	}
	for point, i in form.points {
		id, ok := chronicle_decimal(point.id)
		if !ok ||
		   id == 0 ||
		   !review_text_valid(point.question, 1024, true) ||
		   !review_text_valid(point.instruction, 2048) ||
		   !review_text_valid(point.expected, 2048) ||
		   !review_text_valid(point.section, 256) {return false}
		for j in 0 ..< i do if form.points[j].id == point.id do return false
	}
	return true
}

// JSON allocations are owned by a caller-scoped arena. Preflight bounds nesting
// and tokens before parsing, including malicious arrays and unknown fields.
parseReviewRequest :: proc(data: []byte, allocator := context.allocator) -> (q: Review_Request, correlation: u32, err: ProtocolParseError) {
	if len(data) < 6 do return {}, 0, .TooShort
	correlation, _ = endian.get_u32(data[len(data) - 4:], .Big)
	body := data[:len(data) - 4]
	// A zero byte cannot start the legacy JSON envelope. Older servers reject
	// the request instead of silently accepting an unfenced mutation.
	proof: Portal_Write_Proof
	if body[0] == 0 {
		if len(body) <= 1 + PORTAL_WRITE_PROOF_SIZE do return {}, correlation, .TooShort
		proof = parse_portal_write_proof(body[1:])
		body = body[1 + PORTAL_WRITE_PROOF_SIZE:]
	}
	if len(body) > MAX_REVIEW_FORM_BYTES || !utf8.valid_string(string(body)) do return {}, correlation, .InvalidValue
	tok := json.make_tokenizer(string(body), .JSON, true)
	depth, tokens := 0, 0
	for {
		t, e := json.get_token(&tok)
		if t.kind == .EOF && e == .EOF do break
		if e != nil do return {}, correlation, .InvalidValue
		tokens += 1
		if tokens > 4096 do return {}, correlation, .TooMany
		if t.kind == .Open_Brace || t.kind == .Open_Bracket do depth += 1
		if t.kind == .Close_Brace || t.kind == .Close_Bracket do depth -= 1
		if depth > 4 || depth < 0 do return {}, correlation, .InvalidValue
	}
	if !json.is_valid(body, .JSON, true) do return {}, correlation, .InvalidValue
	if json.unmarshal(body, &q, allocator = allocator, spec = .JSON) != nil do return {}, correlation, .InvalidValue
	q.portal_proof = proof
	if data[0] == 0 && (q.source != "portal" || (q.op != "answer" && q.op != "close")) do return {}, correlation, .InvalidValue
	switch q.op {
	case "create",
	     "update",
	     "release",
	     "unrelease",
	     "archive",
	     "restore",
	     "delete_draft",
	     "copy",
	     "get",
	     "run_create",
	     "run_get",
	     "run_list",
	     "participant_accounts",
	     "participant_add",
	     "answer",
	     "close",
	     "invite",
	     "invite_list",
	     "revoke",
	     "invitation_info",
	     "guest_join":
	case:
		return {}, correlation, .InvalidValue
	}
	for id in ([7]string{q.form_id, q.run_id, q.previous_run, q.point_id, q.invite_id, q.if_revision, q.cursor}) {
		if id != "" {_, ok := chronicle_decimal(id); if !ok do return {}, correlation, .InvalidValue}
	}
	changes_form := q.op == "update" || q.op == "release" || q.op == "unrelease" || q.op == "archive" || q.op == "restore" || q.op == "delete_draft"
	if (changes_form || q.op == "copy" || q.op == "get" || q.op == "run_create") && (q.form_id == "" || q.form_id == "0") do return {}, correlation, .InvalidValue
	if (q.op == "run_get" || q.op == "participant_add" || q.op == "participant_accounts" || q.op == "answer" || q.op == "close" || q.op == "invite" || q.op == "invite_list" || q.op == "revoke") && (q.run_id == "" || q.run_id == "0") do return {}, correlation, .InvalidValue
	for text in ([8]string{q.label, q.identity, q.name, q.token, q.guest_id, q.expires_at, q.kind, q.source}) {
		if !review_text_valid(text, 512) do return {}, correlation, .InvalidValue
	}
	if !review_text_valid(q.comment, 4096) || !review_text_valid(q.result, 16) || !review_text_valid(q.decision, 32) do return {}, correlation, .InvalidValue
	if changes_form {
		n, ok := chronicle_decimal(q.if_revision)
		if !ok || n == 0 || n > u64(max(i64)) do return {}, correlation, .InvalidValue
	}
	if q.if_released_at != "" {
		n, ok := chronicle_decimal(q.if_released_at)
		if q.op != "run_create" || !ok || n == 0 || n > u64(max(i64)) do return {}, correlation, .InvalidValue
	}
	if q.op == "create" || q.op == "update" {
		if !validate_review_form(q.form) || q.form.released_at != "" do return {}, correlation, .InvalidValue
	}
	return
}

serializeReviewRequest :: proc(q: Review_Request, correlation: u32, buf: []byte) -> int {
	payload, err := json.marshal(q)
	if err != nil do return -1
	defer delete(payload)
	offset := 2
	if q.portal_proof != {} do offset += 1 + PORTAL_WRITE_PROOF_SIZE
	if len(payload) > MAX_REVIEW_FORM_BYTES || len(buf) < offset + len(payload) + 4 do return -1
	if offset > 2 {
		if len(q.portal_proof.service_key) != 64 do return -1
		buf[2] = 0
		endian.put_u64(buf[3:], .Big, q.portal_proof.id)
		endian.put_u64(buf[11:], .Big, q.portal_proof.revision)
		copy(buf[19:offset], transmute([]byte)q.portal_proof.service_key)
	}
	endian.put_u16(buf, .Big, u16(Opcode.C_Review))
	copy(buf[offset:], payload)
	endian.put_u32(buf[offset + len(payload):], .Big, correlation)
	return offset + len(payload) + 4
}
