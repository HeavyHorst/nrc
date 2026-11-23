package main

import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

PORTAL_TEST_HASH :: "$2a$12$....................................................."
PORTAL_TEST_NEW_HASH :: "$2a$13$....................................................."
PORTAL_TEST_KEY :: "5678567856785678567856785678567856785678567856785678567856785678"

sqlite_portal_test_call :: proc(
	t: ^testing.T,
	store: ^db.Store,
	q: pr.Portal_Account_Request,
	status: string,
	workspace := "portal",
	admin := true,
	bot := false,
) -> (
	r: pr.Portal_Account_Response,
) {
	payload, err := json.marshal(q)
	if !testing.expect(t, err == nil) do return
	wire := make([]byte, len(payload) + 4)
	copy(wire, payload)
	endian.put_u32(wire[len(payload):], .Big, 615)
	request := db.Request {
		opcode               = .C_PortalAccount,
		operation            = .Command,
		workspace            = workspace,
		subject              = "verified-admin",
		portal_account_admin = admin,
		portal_account_bot   = bot,
		body                 = wire,
		timestamp            = 500,
	}
	output := db.Command_Output {
		limit = pr.PORTAL_ACCOUNT_FRAME_MAX,
	}
	defer db.destroy_command_output(&output)
	if !testing.expect_value(t, db.begin(store), sql.OK) do return
	rc := sqlite_execute_task_command(store, &request, &output)
	if rc == sql.OK do rc = db.commit(store)
	if !testing.expect(t, rc == sql.OK, fmt.aprintf("%s storage code %d: %s", q.op, rc, sql.errmsg(store.db))) {db.rollback(store); return}
	if !testing.expect_value(t, output.count, 1) do return
	testing.expect_value(t, output.frames[0].audience, db.Command_Audience.Requester)
	frame := output.frames[0].payload
	testing.expect_value(t, pr.get_opcode(frame), pr.Opcode.S_PortalAccount)
	correlation, _ := endian.get_u32(frame[2:], .Big)
	testing.expect_value(t, correlation, u32(615))
	testing.expect(t, json.unmarshal(frame[6:], &r) == nil)
	testing.expect_value(t, r.status, status)
	if q.op != "login" || status != "ok" do testing.expect(t, strings.index(string(frame[6:]), "password_hash") < 0)
	return
}

@(test)
test_sqlite_portal_accounts :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "nrc-portal-accounts-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	store, rc := db.open(strings.clone_to_cstring(fmt.aprintf("%s/workspace.db", dir)), true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	portal_account_service_key = PORTAL_TEST_KEY
	defer portal_account_service_key = ""
	call :: sqlite_portal_test_call
	account := pr.Portal_Account {
		login         = "anna",
		requester     = "anna@example.test",
		name          = "Anna",
		password_hash = PORTAL_TEST_HASH,
	}
	rows := []pr.Portal_Account{account}
	call(t, &store, {op = "create", accounts = rows}, "forbidden", admin = false)
	call(t, &store, {op = "import", accounts = rows, dry_run = true}, "ok")
	list := call(t, &store, {op = "list"}, "ok")
	testing.expect_value(t, len(list.accounts), 0)
	created := call(t, &store, {op = "create", accounts = rows}, "ok")
	testing.expect_value(t, created.account.id, "1")
	testing.expect_value(t, created.account.revision, "1")
	call(t, &store, {op = "create", accounts = rows}, "conflict")
	call(t, &store, {op = "import", accounts = rows}, "ok")
	call(t, &store, {op = "get", id = "01"}, "invalid")
	call(t, &store, {op = "get", id = "1"}, "not_found", workspace = "other")
	q := pr.Portal_Account_Request {
		op    = "login",
		login = account.login,
	}
	call(t, &store, q, "forbidden", admin = false, bot = true)
	q.service_key = PORTAL_TEST_KEY
	call(t, &store, q, "forbidden")
	got := call(t, &store, q, "ok", admin = false, bot = true)
	testing.expect_value(t, got.account.password_hash, PORTAL_TEST_HASH)
	call(t, &store, {op = "disable", id = "1", if_revision = "2"}, "conflict")
	call(t, &store, {op = "disable", id = "1", if_revision = "1"}, "ok")
	call(t, &store, q, "not_found", admin = false, bot = true)
	mapped := call(t, &store, {op = "mapping", requester = account.requester, service_key = PORTAL_TEST_KEY}, "ok", admin = false, bot = true)
	testing.expect(t, mapped.account.disabled)
	call(t, &store, {op = "reset_password", id = "1", if_revision = "2", password_hash = "plaintext"}, "invalid")
	call(t, &store, {op = "reset_password", id = "1", if_revision = "2", password_hash = PORTAL_TEST_NEW_HASH}, "ok")
	call(t, &store, {op = "enable", id = "1", if_revision = "3"}, "ok")
	got = call(t, &store, q, "ok", admin = false, bot = true)
	testing.expect_value(t, got.account.password_hash, PORTAL_TEST_NEW_HASH)

	batch: [50]pr.Portal_Account
	for &a, i in batch {
		a = {
			login         = fmt.aprintf("login%d", i),
			requester     = fmt.aprintf("person%d@example.test", i),
			name          = "Customer",
			password_hash = PORTAL_TEST_HASH,
		}
	}
	call(t, &store, {op = "import", accounts = {batch[0], account}}, "conflict")
	bad := batch[1]
	bad.company_id = "7"
	call(t, &store, {op = "import", accounts = {batch[0], bad}}, "invalid")
	list = call(t, &store, {op = "list"}, "ok")
	testing.expect_value(t, len(list.accounts), 1)
	testing.expect_value(t, list.cursor, "")
	{
		s, audit_rc := sqlite_chronicle_statement(
			&store,
			"SELECT count(*) FROM portal_account_audit WHERE workspace=?1 AND actor_subject=?2",
			"portal",
			{"verified-admin"},
		)
		if !testing.expect_value(t, audit_rc, sql.OK) do return
		defer sql.finalize(s)
		if !testing.expect_value(t, sql.step(s), sql.ROW) do return
		testing.expect_value(t, sql.column_int64(s, 0), i64(4))
	}
	call(t, &store, {op = "import", accounts = batch[:]}, "ok")
	list = call(t, &store, {op = "list"}, "ok")
	testing.expect_value(t, len(list.accounts), 50)
	testing.expect_value(t, list.cursor, "50")
	list = call(t, &store, {op = "list", cursor = list.cursor}, "ok")
	testing.expect_value(t, len(list.accounts), 1)
	testing.expect_value(t, list.cursor, "")
}
