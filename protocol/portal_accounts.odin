package protocol

import "core:encoding/json"
import "core:strings"

PORTAL_ACCOUNT_IMPORT_LIMIT :: 64
PORTAL_ACCOUNT_PAGE_SIZE :: 50
PORTAL_ACCOUNT_FRAME_MAX :: 131072

Portal_Account :: struct {
	id, revision, login, requester, name, company_id, contact_id: string,
	password_hash:                                                string `json:"password_hash,omitempty"`,
	disabled:                                                     bool,
}

Portal_Account_Request :: struct {
	op, id, cursor, if_revision, login, requester, service_key, password_hash: string,
	accounts:                                                                  []Portal_Account,
	dry_run:                                                                   bool,
}

Portal_Account_Response :: struct {
	status:        string,
	account:       Portal_Account,
	accounts:      []Portal_Account,
	cursor:        string,
	import_row:    int,
	import_reason: string,
}

portal_account_id :: proc(s: string) -> (u64, bool) {
	id, ok := chronicle_decimal(s)
	return id, ok && id > 0
}

@(private)
portal_account_text_valid :: proc(s: string, limit: int) -> bool {
	if !review_text_valid(s, limit, true) || strings.trim_space(s) != s do return false
	for r in s {
		if r < 32 || (r >= 127 && r <= 159) do return false
	}
	return true
}

portal_account_login_valid :: proc(s: string) -> bool {
	return portal_account_text_valid(s, 320) && strings.index_byte(s, ':') < 0
}

portal_account_requester_valid :: proc(s: string) -> bool {
	if !portal_account_text_valid(s, 320) do return false
	lower := strings.to_lower(s)
	defer delete(lower)
	return lower == s
}

portal_account_hash_valid :: proc(s: string) -> bool {
	if len(s) != 60 ||
	   s[0:2] != "$2" ||
	   (s[2] != 'a' && s[2] != 'b' && s[2] != 'y') ||
	   s[3:5] != "$1" ||
	   s[5] < '2' ||
	   s[5] > '6' ||
	   s[6] != '$' {return false}
	for b in s[7:] {
		if b != '.' && b != '/' && !(b >= 'A' && b <= 'Z') && !(b >= 'a' && b <= 'z') && !(b >= '0' && b <= '9') do return false
	}
	return true
}

portal_account_valid :: proc(a: Portal_Account) -> bool {
	_, company_ok := portal_account_id(a.company_id)
	_, contact_ok := portal_account_id(a.contact_id)
	return(
		a.id == "" &&
		a.revision == "" &&
		(a.company_id == "" || company_ok) &&
		(a.contact_id == "" || (company_ok && contact_ok)) &&
		portal_account_login_valid(a.login) &&
		portal_account_requester_valid(a.requester) &&
		portal_account_text_valid(a.name, 256) &&
		portal_account_hash_valid(a.password_hash) \
	)
}

// Call with a scoped allocator; decoded strings and slices live in that scope.
parsePortalAccountRequest :: proc(body: []byte) -> (q: Portal_Account_Request, correlation: u32, err: ProtocolParseError) {
	payload: []byte
	payload, correlation, err = parseChronicleEnvelope(body)
	if err != nil do return
	if len(body) + 2 > PORTAL_ACCOUNT_FRAME_MAX do return {}, correlation, .ContentLengthExceedsMax
	if strings.index_byte(string(payload), 0) >= 0 || json.unmarshal(payload, &q, spec = .JSON) != nil do return {}, correlation, .InvalidValue
	return
}
