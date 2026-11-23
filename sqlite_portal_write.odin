package main

import "core:c"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// This check belongs to the mutation's writer transaction, not the HTTP login
// lookup: an account may change while the request is uploading or queued.
sqlite_portal_write_allowed :: proc(store: ^db.Store, request: ^db.Request, proof: pr.Portal_Write_Proof, requester: string) -> (bool, c.int) {
	if store.read_only || sql.get_autocommit(store.db) != 0 do return false, sql.MISUSE
	if !request.portal_account_bot ||
	   !portal_account_key_matches(portal_account_service_key, proof.service_key) ||
	   proof.id == 0 ||
	   proof.revision == 0 ||
	   proof.revision > u64(max(i64)) ||
	   !pr.portal_account_requester_valid(requester) {
		return false, sql.OK
	}
	s, rc := sqlite_chronicle_statement(
		store,
		`SELECT 1 FROM portal_accounts
		WHERE workspace=?1 AND id=?2 AND revision=?3 AND requester=?4 AND disabled=0`,
		request.workspace,
		{proof.id, i64(proof.revision), requester},
	)
	if rc != sql.OK do return false, rc
	defer sql.finalize(s)
	rc = sql.step(s)
	if rc == sql.ROW do return true, sql.OK
	if rc == sql.DONE do return false, sql.OK
	return false, rc
}
