package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

SQLITE_PORTAL_ACCOUNT_FIELDS :: `SELECT id,revision,login,requester,name,company_id,contact_id,disabled,`

sqlite_portal_account_row :: proc(s: ^sql.Statement) -> (a: pr.Portal_Account, rc: c.int) {
	id, id_rc := sql.column_id(s, 0)
	company, company_rc := sql.column_id(s, 5)
	contact, contact_rc := sql.column_id(s, 6)
	if id_rc != sql.OK || company_rc != sql.OK || contact_rc != sql.OK do return {}, sql.CORRUPT
	a.id = fmt.aprintf("%d", id)
	a.revision = fmt.aprintf("%d", sql.column_int64(s, 1))
	a.login = strings.clone(string(sql.column_bytes_view(s, 2)))
	a.requester = strings.clone(string(sql.column_bytes_view(s, 3)))
	a.name = strings.clone(string(sql.column_bytes_view(s, 4)))
	if company != 0 do a.company_id = fmt.aprintf("%d", company)
	if contact != 0 do a.contact_id = fmt.aprintf("%d", contact)
	a.disabled = sql.column_int64(s, 7) != 0
	a.password_hash = strings.clone(string(sql.column_bytes_view(s, 8)))
	return a, sql.OK
}

sqlite_portal_account_lookup :: proc(
	store: ^db.Store,
	workspace: string,
	query: cstring,
	values: []SQLite_Projection_Value,
) -> (
	a: pr.Portal_Account,
	found: bool,
	rc: c.int,
) {
	s, status := sqlite_chronicle_statement(store, query, workspace, values)
	if status != sql.OK do return {}, false, status
	defer sql.finalize(s)
	status = sql.step(s)
	if status == sql.DONE do return {}, false, sql.OK
	if status != sql.ROW do return {}, false, status
	a, rc = sqlite_portal_account_row(s)
	return a, rc == sql.OK, rc
}

sqlite_portal_account_binding :: proc(store: ^db.Store, workspace: string, company, contact: u64) -> (bool, c.int) {
	if company == 0 do return contact == 0, sql.OK
	s, rc := sqlite_chronicle_statement(
		store,
		`SELECT EXISTS(SELECT 1 FROM assets WHERE workspace=?1 AND id=?2 AND asset_type=?4)
 AND (?3=x'0000000000000000' OR (
  EXISTS(SELECT 1 FROM assets WHERE workspace=?1 AND id=?3 AND asset_type=?5)
  AND EXISTS(SELECT 1 FROM edges WHERE workspace=?1 AND source_type=?6 AND target_type=?6 AND relation=?7
             AND ((source_id=?3 AND target_id=?2) OR (source_id=?2 AND target_id=?3)))))`,
		workspace,
		{company, contact, i64(pr.AssetType.CustomerCompany), i64(pr.AssetType.CustomerContact), i64(pr.TargetType.Asset), i64(pr.RelationType.MemberOf)},
	)
	if rc != sql.OK do return false, rc
	defer sql.finalize(s)
	if rc = sql.step(s); rc != sql.ROW do return false, rc
	return sql.column_int64(s, 0) != 0, sql.OK
}

sqlite_portal_account_audit :: proc(store: ^db.Store, request: ^db.Request, id: u64, revision: i64, operation: string) -> c.int {
	return sqlite_chronicle_execute(
		store,
		`INSERT INTO portal_account_audit
 (workspace,account_id,revision,operation,actor_subject,occurred_at) VALUES(?1,?2,?3,CAST(?4 AS TEXT),?5,?6)`,
		request.workspace,
		{id, revision, operation, request.subject, request.timestamp},
	)
}

// Validate the whole batch against one writer snapshot before applying any row.
// A replay must match the current record exactly, and never resets credentials
// or reenables a record that's been changed since import.
sqlite_portal_account_import :: proc(store: ^db.Store, request: ^db.Request, q: ^pr.Portal_Account_Request, r: ^pr.Portal_Account_Response) -> c.int {
	if len(q.accounts) == 0 || len(q.accounts) > pr.PORTAL_ACCOUNT_IMPORT_LIMIT || (q.op == "create" && (len(q.accounts) != 1 || q.dry_run)) {return sql.OK}
	new_account: [pr.PORTAL_ACCOUNT_IMPORT_LIMIT]bool
	new_count: u64
	for a, i in q.accounts {
		if !pr.portal_account_valid(a) do return sql.OK
		for previous in q.accounts[:i] {
			if previous.login == a.login || previous.requester == a.requester || (a.contact_id != "" && previous.contact_id == a.contact_id) {
				r.status = "conflict"
				return sql.OK
			}
		}
		company, _ := pr.portal_account_id(a.company_id)
		contact, _ := pr.portal_account_id(a.contact_id)
		bound, bind_rc := sqlite_portal_account_binding(store, request.workspace, company, contact)
		if bind_rc != sql.OK do return bind_rc
		if !bound {
			if q.op == "import" {
				r.import_row = i + 1
				r.import_reason = "invalid_company_contact_binding"
			}
			return sql.OK
		}
		old, found, rc := sqlite_portal_account_lookup(
			store,
			request.workspace,
			SQLITE_PORTAL_ACCOUNT_FIELDS +
			`password_hash FROM portal_accounts WHERE workspace=?1 AND
 (login=?2 OR requester=?3 OR (?4!=x'0000000000000000' AND contact_id=?4))`,
			{a.login, a.requester, contact},
		)
		if rc != sql.OK do return rc
		if found {
			old.id = ""
			old.revision = ""
			if q.op != "import" || old != a {
				r.status = "conflict"
				return sql.OK
			}
		} else {
			new_account[i] = true
			new_count += 1
		}
	}
	r.status = "ok"
	if new_count == 0 do return sql.OK
	last: u64
	{
		s, rc := sqlite_chronicle_statement(store, `SELECT id FROM portal_accounts WHERE workspace=?1 ORDER BY id DESC LIMIT 1`, request.workspace, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		rc = sql.step(s)
		if rc == sql.ROW {
			last, rc = sql.column_id(s, 0)
			if rc != sql.OK do return rc
		} else if rc != sql.DONE {
			return rc
		}
	}
	if last > max(u64) - new_count do return sql.FULL
	if q.dry_run do return sql.OK
	for a, i in q.accounts {
		if !new_account[i] do continue
		last += 1
		id := last
		company, _ := pr.portal_account_id(a.company_id)
		contact, _ := pr.portal_account_id(a.contact_id)
		rc := sqlite_chronicle_execute(
			store,
			`INSERT INTO portal_accounts
 (workspace,id,revision,login,requester,name,company_id,contact_id,password_hash,disabled)
 VALUES(?1,?2,1,?3,?4,?5,?6,?7,?8,?9)`,
			request.workspace,
			{id, a.login, a.requester, a.name, company, contact, a.password_hash, i64(a.disabled ? 1 : 0)},
		)
		if rc != sql.OK do return rc
		if rc = sqlite_portal_account_audit(store, request, id, 1, q.op); rc != sql.OK do return rc
		if q.op == "create" {
			r.account = a
			r.account.id = fmt.aprintf("%d", id)
			r.account.revision = "1"
			r.account.password_hash = ""
		}
	}
	return sql.OK
}

sqlite_portal_account_dispatch :: proc(store: ^db.Store, request: ^db.Request, q: ^pr.Portal_Account_Request, r: ^pr.Portal_Account_Response) -> c.int {
	workspace := request.workspace
	switch q.op {
	case "login", "mapping":
		if !request.portal_account_bot || !portal_account_key_matches(portal_account_service_key, q.service_key) {
			r.status = "forbidden"
			return sql.OK
		}
	case "list", "get", "create", "disable", "enable", "reset_password", "import":
		if !request.portal_account_admin || request.subject == "" {
			r.status = "forbidden"
			return sql.OK
		}
	case:
		return sql.OK
	}
	if (q.id != "" && q.op != "get" && q.op != "disable" && q.op != "enable" && q.op != "reset_password") ||
	   (q.cursor != "" && q.op != "list") ||
	   (q.login != "" && q.op != "login") ||
	   (q.requester != "" && q.op != "mapping") ||
	   (q.service_key != "" && q.op != "login" && q.op != "mapping") ||
	   (q.password_hash != "" && q.op != "reset_password") ||
	   (q.if_revision != "" && q.op != "disable" && q.op != "enable" && q.op != "reset_password") ||
	   (len(q.accounts) != 0 && q.op != "create" && q.op != "import") ||
	   (q.dry_run && q.op != "import") {return sql.OK}

	switch q.op {
	case "create", "import":
		return sqlite_portal_account_import(store, request, q, r)
	case "list":
		cursor, ok := pr.portal_account_id(q.cursor)
		if q.cursor != "" && !ok do return sql.OK
		s, rc := sqlite_chronicle_statement(
			store,
			SQLITE_PORTAL_ACCOUNT_FIELDS + `'' FROM portal_accounts WHERE workspace=?1 AND id>?2 ORDER BY id LIMIT ?3`,
			workspace,
			{cursor, i64(pr.PORTAL_ACCOUNT_PAGE_SIZE + 1)},
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		accounts := make([]pr.Portal_Account, pr.PORTAL_ACCOUNT_PAGE_SIZE)
		count := 0
		for {
			rc = sql.step(s)
			if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			if count == len(accounts) {
				r.cursor = accounts[count - 1].id
				break
			}
			accounts[count], rc = sqlite_portal_account_row(s)
			if rc != sql.OK do return rc
			count += 1
		}
		r.accounts = accounts[:count]
		r.status = "ok"
		return sql.OK
	case "login", "mapping":
		a: pr.Portal_Account
		found: bool
		rc: c.int
		if q.op == "login" {
			if !pr.portal_account_login_valid(q.login) do return sql.OK
			a, found, rc = sqlite_portal_account_lookup(
				store,
				workspace,
				SQLITE_PORTAL_ACCOUNT_FIELDS + `password_hash FROM portal_accounts WHERE workspace=?1 AND login=?2 AND disabled=0`,
				{q.login},
			)
		} else {
			if !pr.portal_account_requester_valid(q.requester) do return sql.OK
			a, found, rc = sqlite_portal_account_lookup(
				store,
				workspace,
				SQLITE_PORTAL_ACCOUNT_FIELDS + `'' FROM portal_accounts WHERE workspace=?1 AND requester=?2`,
				{q.requester},
			)
		}
		if rc != sql.OK do return rc
		if !found {r.status = "not_found"; return sql.OK}
		r.account = a
		r.status = "ok"
		return sql.OK
	case "get", "disable", "enable", "reset_password":
		id, valid_id := pr.portal_account_id(q.id)
		if !valid_id do return sql.OK
		if q.op != "get" {
			expected, valid_revision := pr.portal_account_id(q.if_revision)
			if !valid_revision || expected > u64(max(i64)) do return sql.OK
			if q.op == "reset_password" && !pr.portal_account_hash_valid(q.password_hash) do return sql.OK
		}
		a, found, rc := sqlite_portal_account_lookup(
			store,
			workspace,
			SQLITE_PORTAL_ACCOUNT_FIELDS + `'' FROM portal_accounts WHERE workspace=?1 AND id=?2`,
			{id},
		)
		if rc != sql.OK do return rc
		if !found {r.status = "not_found"; return sql.OK}
		if q.op != "get" {
			if a.revision != q.if_revision {r.status = "conflict"; return sql.OK}
			old, _ := pr.portal_account_id(a.revision)
			if old >= u64(max(i64)) do return sql.FULL
			revision := i64(old) + 1
			if q.op == "reset_password" {
				rc = sqlite_chronicle_execute(
					store,
					`UPDATE portal_accounts SET revision=?3,password_hash=?4 WHERE workspace=?1 AND id=?2`,
					workspace,
					{id, revision, q.password_hash},
				)
			} else {
				a.disabled = q.op == "disable"
				rc = sqlite_chronicle_execute(
					store,
					`UPDATE portal_accounts SET revision=?3,disabled=?4 WHERE workspace=?1 AND id=?2`,
					workspace,
					{id, revision, i64(a.disabled ? 1 : 0)},
				)
			}
			if rc != sql.OK do return rc
			if rc = sqlite_portal_account_audit(store, request, id, revision, q.op); rc != sql.OK do return rc
			a.revision = fmt.aprintf("%d", revision)
		}
		r.account = a
		r.status = "ok"
	}
	return sql.OK
}

sqlite_execute_portal_account :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	q, correlation, err := pr.parsePortalAccountRequest(request.body)
	r := pr.Portal_Account_Response {
		status = "invalid",
	}
	if err == nil {
		if rc := sqlite_portal_account_dispatch(store, request, &q, &r); rc != sql.OK do return rc
	}
	payload: []byte
	marshal_err: json.Marshal_Error
	if r.account.id != "" {
		payload, marshal_err = json.marshal(struct {
			status:  string,
			account: pr.Portal_Account,
		}{r.status, r.account})
	} else if q.op == "list" && r.status == "ok" {
		payload, marshal_err = json.marshal(struct {
			status:   string,
			accounts: []pr.Portal_Account,
			cursor:   string `json:"cursor,omitempty"`,
		}{r.status, r.accounts, r.cursor})
	} else if r.import_row != 0 {
		payload, marshal_err = json.marshal(struct {
			status:        string,
			import_row:    int,
			import_reason: string,
		}{r.status, r.import_row, r.import_reason})
	} else {
		payload, marshal_err = json.marshal(struct {
			status: string,
		}{r.status})
	}
	if marshal_err != nil do return sql.ERROR
	context.allocator = backing
	buf, rc := db.command_frame(output, len(payload) + 6, .Requester)
	if rc != sql.OK do return rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_PortalAccount))
	endian.put_u32(buf[2:], .Big, correlation)
	copy(buf[6:], payload)
	return sql.OK
}
