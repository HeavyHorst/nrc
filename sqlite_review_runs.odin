package main

import "core:c"
import "core:crypto"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// The workspace SQL binders already used by Chronicle copy all variable data
// into the handler's scoped arena. No statement/row memory escapes a read.
sqlite_review_read_run :: proc(
	store: ^db.Store,
	workspace: string,
	id: u64,
	details := true,
) -> (
	run: pr.Review_Run,
	form: pr.Review_Form,
	found: bool,
	rc: c.int,
) {
	s: ^sql.Statement
	s, rc = sqlite_chronicle_statement(
		store,
		`SELECT form_id,label,kind,previous_run,revision,decision,comment,closed_at,closed_by,closed_name,closed_source,
 (SELECT count(DISTINCT point_id) FROM review_answers a WHERE a.workspace=r.workspace AND a.run_id=r.id)
 FROM review_runs r WHERE workspace=?1 AND id=?2`,
		workspace,
		{id},
	)
	if rc != sql.OK do return
	defer sql.finalize(s)
	rc = sql.step(s)
	if rc == sql.DONE {rc = sql.OK; return}
	if rc != sql.ROW do return
	form_id, id_rc := sql.column_id(s, 0)
	if id_rc != sql.OK {rc = id_rc; return}
	previous, prev_rc := sql.column_id(s, 3)
	if prev_rc != sql.OK {rc = prev_rc; return}
	run.id = fmt.aprintf("%d", id); run.form_id = fmt.aprintf("%d", form_id)
	run.label = strings.clone(string(sql.column_bytes_view(s, 1)))
	run.kind = strings.clone(string(sql.column_bytes_view(s, 2)))
	run.previous_run = previous == 0 ? "" : fmt.aprintf("%d", previous)
	run.revision = fmt.aprintf("%d", sql.column_int64(s, 4))
	run.decision = strings.clone(string(sql.column_bytes_view(s, 5)))
	run.comment = strings.clone(string(sql.column_bytes_view(s, 6)))
	at := sql.column_int64(s, 7); run.closed_at = at == 0 ? "" : fmt.aprintf("%d", at)
	run.closed_by = strings.clone(string(sql.column_bytes_view(s, 8)))
	run.closed_name = strings.clone(string(sql.column_bytes_view(s, 9)))
	run.closed_source = strings.clone(string(sql.column_bytes_view(s, 10)))
	run.answered_points = int(sql.column_int64(s, 11))
	a, exists, read_rc := sqlite_read_asset(store, workspace, "", form_id, true)
	if read_rc != sql.OK {rc = read_rc; return}
	if !exists ||
	   a.asset_type != .ReviewForm ||
	   a.payload_encoding != .Plain ||
	   json.unmarshal(a.payload, &form, spec = .JSON) != nil ||
	   !pr.validate_review_form(form, true) ||
	   form.released_at == "" {rc = sql.CORRUPT; return}
	run.title = form.title
	run.participants = make([]pr.Review_Participant, 0)
	run.answers = make([]pr.Review_Answer, 0)
	if !details {found = true; rc = sql.OK; return}
	p, p_rc := sqlite_chronicle_statement(
		store,
		`SELECT id,source,identity,name,can_close FROM review_participants WHERE workspace=?1 AND run_id=?2 ORDER BY id LIMIT 65`,
		workspace,
		{id},
	)
	if p_rc != sql.OK {rc = p_rc; return}
	defer sql.finalize(p)
	participants: [dynamic]pr.Review_Participant
	for {
		rc = sql.step(p); if rc == sql.DONE do break
		if rc != sql.ROW do return
		if len(participants) >= 64 {rc = sql.TOOBIG; return}
		pid, pid_rc := sql.column_id(p, 0); if pid_rc != sql.OK {rc = pid_rc; return}
		append(
			&participants,
			pr.Review_Participant {
				fmt.aprintf("%d", pid),
				strings.clone(string(sql.column_bytes_view(p, 1))),
				strings.clone(string(sql.column_bytes_view(p, 2))),
				strings.clone(string(sql.column_bytes_view(p, 3))),
				sql.column_int64(p, 4) != 0,
			},
		)
	}
	run.participants = participants[:]
	answers: [dynamic]pr.Review_Answer
	aq, aq_rc := sqlite_chronicle_statement(
		store,
		`SELECT a.payload FROM review_answers r JOIN assets a ON a.workspace=r.workspace AND a.id=r.asset_id WHERE r.workspace=?1 AND r.run_id=?2 ORDER BY r.asset_id`,
		workspace,
		{id},
	)
	if aq_rc != sql.OK {rc = aq_rc; return}
	defer sql.finalize(aq)
	bytes := 0
	for {
		rc = sql.step(aq); if rc == sql.DONE do break
		if rc != sql.ROW do return
		payload := sql.column_bytes_view(aq, 0); bytes += len(payload)
		if bytes > pr.MAX_PROTOCOL_PAYLOAD_SIZE {rc = sql.TOOBIG; return}
		answer: pr.Review_Answer
		if json.unmarshal(payload, &answer, spec = .JSON) != nil {rc = sql.CORRUPT; return}
		append(&answers, answer)
	}
	run.answers = answers[:]
	found = true; rc = sql.OK
	return
}

// The public nonce prevents ID reuse after restoring a snapshot from recreating
// a bearer. The indexed lookup key fits the existing 32-byte column: nonce +
// truncated SHA-256. Legacy rows still use the full SHA-256 of a random token.
sqlite_review_invite_token :: proc(workspace: string, run_id, id: u64, nonce: []byte) -> string {
	if jwt_auth_secret == "" || jwt_auth_secret == "dev-insecure-nrc-jwt-secret" do return ""
	key, token: [32]byte
	domain: string : "nrc/review-invite/v1"
	hmac.sum(.SHA256, key[:], transmute([]byte)domain, transmute([]byte)jwt_auth_secret)
	input := fmt.aprintf("%s:%d:%d:%s", sqlite_chronicle_hex(nonce), run_id, id, workspace)
	hmac.sum(.SHA256, token[:], transmute([]byte)input, key[:])
	copy(token[16:], token[:16]); copy(token[:16], nonce)
	return sqlite_chronicle_hex(token[:])
}

sqlite_review_invite_lookup :: proc(token: string, nonce: []byte) -> [32]byte {
	lookup := sqlite_chronicle_hash(transmute([]byte)token)
	copy(lookup[16:], lookup[:16]); copy(lookup[:16], nonce)
	return lookup
}

// A gateway acts for a canonical portal requester or a cryptographically bound
// guest session. A normal staff connection cannot forge either origin.
sqlite_review_run_command :: proc(
	store: ^db.Store,
	request: ^db.Request,
	input: pr.Review_Request,
	correlation: u32,
	output: ^db.Command_Output,
	backing: mem.Allocator,
) -> c.int {
	q := input
	r := pr.Review_Response {
		status = "invalid",
		runs   = make([]pr.Review_Run, 0),
	}
	staff := !request.review_portal
	source, identity := "staff", request.subject
	if identity == "" do identity = request.actor
	if q.op == "invitation_info" && (staff || q.source != "guest") {
		r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)
	}
	if !staff {
		if q.source != "portal" && q.source != "guest" {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		source = q.source; identity = q.identity
		if q.op != "run_list" &&
		   q.op != "run_get" &&
		   q.op != "answer" &&
		   q.op != "close" &&
		   q.op != "invitation_info" &&
		   q.op != "guest_join" {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		if source == "portal" && identity == "" {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
	}
	run_id, _ := pr.chronicle_decimal(q.run_id)
	if q.op == "invite_list" {
		_, _, found, rc := sqlite_review_read_run(store, request.workspace, run_id, false)
		if rc != sql.OK do return rc
		if !found {r.status = "not_found"; return sqlite_review_reply(output, correlation, r, backing)}
		cursor, _ := pr.chronicle_decimal(q.cursor)
		base :: `SELECT id,expires_at,revoked_at,can_close,token_hash FROM review_invites WHERE workspace=?1 AND run_id=?2`
		order :: ` ORDER BY id DESC LIMIT 26`
		s: ^sql.Statement
		query_rc: c.int
		if cursor == 0 {
			s, query_rc = sqlite_chronicle_statement(store, base + order, request.workspace, {run_id})
		} else {
			s, query_rc = sqlite_chronicle_statement(store, base + ` AND id<?3` + order, request.workspace, {run_id, cursor})
		}
		if query_rc != sql.OK do return query_rc
		defer sql.finalize(s)
		invites: [dynamic]pr.Review_Invite
		for {
			query_rc = sql.step(s)
			if query_rc == sql.DONE do break
			if query_rc != sql.ROW do return query_rc
			if len(invites) == 25 {r.has_more = true; break}
			id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
			expires, revoked := sql.column_int64(s, 1), sql.column_int64(s, 2)
			entry := pr.Review_Invite {
				id         = fmt.aprintf("%d", id),
				expires_at = fmt.aprintf("%d", expires),
				can_close  = sql.column_int64(s, 3) != 0,
			}
			entry.expired = expires <= request.timestamp
			if revoked != 0 do entry.revoked_at = fmt.aprintf("%d", revoked)
			if revoked == 0 && !entry.expired {
				stored := sql.column_bytes_view(s, 4)
				token := sqlite_review_invite_token(request.workspace, run_id, id, stored[:16])
				if token != "" {
					digest := sqlite_review_invite_lookup(token, stored[:16])
					if string(digest[:]) == string(stored) do entry.token = token
				}
			}
			append(&invites, entry); r.cursor = entry.id
		}
		r.status = "ok"; r.invites = invites[:]
		return sqlite_review_reply(output, correlation, r, backing)
	}
	if q.op == "participant_accounts" {
		if request.portal_account_bot {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		run, _, found, rc := sqlite_review_read_run(store, request.workspace, run_id, false)
		if rc != sql.OK do return rc
		if !found {r.status = "not_found"; return sqlite_review_reply(output, correlation, r, backing)}
		if run.decision != "" {r.status = "closed"; return sqlite_review_reply(output, correlation, r, backing)}
		cursor, _ := pr.chronicle_decimal(q.cursor)
		s, query_rc := sqlite_chronicle_statement(store,
			`SELECT id,requester,name,login FROM portal_accounts WHERE workspace=?1 AND id>?2 AND disabled=0 ORDER BY id LIMIT ?3`,
			request.workspace, {cursor, i64(pr.PORTAL_ACCOUNT_PAGE_SIZE + 1)})
		if query_rc != sql.OK do return query_rc
		defer sql.finalize(s)
		accounts := make([]pr.Review_Account_Choice, pr.PORTAL_ACCOUNT_PAGE_SIZE)
		count := 0
		for {
			query_rc = sql.step(s)
			if query_rc == sql.DONE do break
			if query_rc != sql.ROW do return query_rc
			if count == len(accounts) {r.has_more = true; break}
			id, id_rc := sql.column_id(s, 0)
			if id_rc != sql.OK do return id_rc
			accounts[count] = {strings.clone(string(sql.column_bytes_view(s, 1))), strings.clone(string(sql.column_bytes_view(s, 2))), strings.clone(string(sql.column_bytes_view(s, 3)))}
			count += 1; r.cursor = fmt.aprintf("%d", id)
		}
		r.status = "ok"; r.accounts = accounts[:count]
		return sqlite_review_reply(output, correlation, r, backing)
	}
	invite_id: u64
	invite_close := false
	if !staff && source == "guest" {
		if len(q.token) != 64 ||
		   (q.op != "invitation_info" &&
				   (len(q.guest_id) < 32 ||
						   len(q.guest_id) > 128 ||
						   !pr.review_text_valid(q.name, 256, true))) {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		hash := sqlite_chronicle_hash(transmute([]byte)q.token)
		nonce: [16]byte
		_, hex_ok := hex.decode_into_buffer(transmute([]byte)q.token[:32], nonce[:])
		if !hex_ok {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		lookup := sqlite_review_invite_lookup(q.token, nonce[:])
		s, rc := sqlite_chronicle_statement(
			store,
			`SELECT run_id,id,can_close FROM review_invites WHERE workspace=?1 AND token_hash IN (?2,?4) AND revoked_at=0 AND expires_at>?3`,
			request.workspace,
			{string(hash[:]), request.timestamp, string(lookup[:])},
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		rc = sql.step(s)
		if rc == sql.DONE {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		if rc != sql.ROW do return rc
		bound_run, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		invite_id, id_rc = sql.column_id(s, 1); if id_rc != sql.OK do return id_rc
		if run_id != 0 && run_id != bound_run {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		run_id = bound_run; invite_close = sql.column_int64(s, 2) != 0; identity = q.guest_id
	}
	if q.op == "invitation_info" {
		// Token-only pre-join projection: never load participants/answers, create
		// a participant, or expose the run/form identity or any other form data.
		_, form, found, rc := sqlite_review_read_run(store, request.workspace, run_id, false)
		if rc != sql.OK do return rc
		if !found {r.status = "not_found"; return sqlite_review_reply(output, correlation, r, backing)}
		r.status = "ok"; r.form.title = form.title
		return sqlite_review_reply(output, correlation, r, backing)
	}
	if q.op == "run_list" {
		if source == "guest" {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		cursor, _ := pr.chronicle_decimal(q.cursor)
		form_filter, _ := pr.chronicle_decimal(q.form_id)
		query: cstring = `SELECT id FROM review_runs WHERE workspace=?1 AND id>?2 AND (?3=zeroblob(8) OR form_id=?3) ORDER BY id LIMIT 51`
		if !staff do query = `SELECT r.id FROM review_participants p JOIN review_runs r ON r.workspace=p.workspace AND r.id=p.run_id WHERE p.workspace=?1 AND r.id>?2 AND (?3=zeroblob(8) OR r.form_id=?3) AND p.source='portal' AND p.identity=?4 ORDER BY r.id LIMIT 51`
		s, rc := sqlite_chronicle_statement(
			store,
			query,
			request.workspace,
			staff ? []SQLite_Projection_Value{cursor, form_filter} : []SQLite_Projection_Value{cursor, form_filter, identity},
		)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		runs: [dynamic]pr.Review_Run
		listing_bytes := 0
		for {
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			if len(runs) == 50 {r.has_more = true; break}
			id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
			run, _, found, read_rc := sqlite_review_read_run(store, request.workspace, id, false)
			if read_rc != sql.OK do return read_rc
			if !found do return sql.CORRUPT
			// Long closing comments must not make the register's next page unreadable.
			encoded, encode_err := json.marshal(run)
			if encode_err != nil do return sql.ERROR
			if listing_bytes + len(encoded) > 64 * 1024 {r.has_more = true; break}
			listing_bytes += len(encoded)
			append(&runs, run); r.cursor = run.id
		}
		r.status = "ok"; r.runs = runs[:]
		return sqlite_review_reply(output, correlation, r, backing)
	}
	if q.op == "run_create" {
		if !staff || !pr.review_text_valid(q.label, 256, true) || (q.kind != "qa" && q.kind != "customer") do return sqlite_review_reply(output, correlation, r, backing)
		form_id, _ := pr.chronicle_decimal(q.form_id)
		a, found, rc := sqlite_read_asset(store, request.workspace, request.actor, form_id, true)
		if rc != sql.OK do return rc
		form: pr.Review_Form
		if !found || a.asset_type != .ReviewForm || json.unmarshal(a.payload, &form, spec = .JSON) != nil || !pr.validate_review_form(form, true) || form.released_at == "" do return sqlite_review_reply(output, correlation, r, backing)
		metadata: Review_Form_Preview
		if json.unmarshal(a.preview, &metadata, spec = .JSON) != nil do return sql.CORRUPT
		if metadata.archived {
			r.status = q.if_released_at == "" ? "conflict" : "archived"
			return sqlite_review_reply(output, correlation, r, backing)
		}
		// Before withdrawal, legacy callers can only have seen this one release.
		if (q.if_released_at != "" || metadata.requires_release_token) && q.if_released_at != form.released_at {
			r.status = "conflict"; return sqlite_review_reply(output, correlation, r, backing)
		}
		previous, _ := pr.chronicle_decimal(q.previous_run)
		if previous != 0 {
			old, _, exists, old_rc := sqlite_review_read_run(store, request.workspace, previous, false)
			if old_rc != sql.OK do return old_rc
			if !exists || old.decision == "" || old.label != q.label || old.kind != q.kind do return sqlite_review_reply(output, correlation, r, backing)
		}
		if request.timestamp <= 0 do return sql.FULL
		run_id, rc = db.next_id(store, .Asset); if rc != sql.OK do return rc
		rc = sqlite_chronicle_execute(
			store,
			`INSERT INTO review_runs(workspace,id,form_id,label,kind,previous_run,revision) VALUES(?1,?2,?3,?4,CAST(?5 AS TEXT),?6,?7)`,
			request.workspace,
			{run_id, form_id, q.label, q.kind, previous, request.timestamp},
		)
		if rc != sql.OK do return rc
	}
	run, form, found, rc := sqlite_review_read_run(store, request.workspace, run_id)
	if rc != sql.OK do return rc
	if !found {r.status = "not_found"; return sqlite_review_reply(output, correlation, r, backing)}
	participant: pr.Review_Participant
	for p in run.participants {
		if p.source == source && p.identity == identity do participant = p
	}
	r.participant_id = participant.id
	if !staff && participant.id == "" && q.op != "guest_join" {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
	if !staff && source == "guest" && participant.id != "" {
		pid, _ := pr.chronicle_decimal(participant.id)
		s, check_rc := sqlite_chronicle_statement(
			store,
			`SELECT 1 FROM review_participants WHERE workspace=?1 AND run_id=?2 AND id=?3 AND invite_id=?4`,
			request.workspace,
			{run_id, pid, invite_id},
		)
		if check_rc != sql.OK do return check_rc
		defer sql.finalize(s)
		check_rc = sql.step(s)
		if check_rc == sql.DONE {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		if check_rc != sql.ROW do return check_rc
	}
	mutating := q.op != "run_get" && q.op != "run_create" && q.op != "revoke" && !(q.op == "guest_join" && participant.id != "")
	if mutating && run.decision != "" {r.status = "closed"; return sqlite_review_reply(output, correlation, r, backing)}
	revision, _ := pr.chronicle_decimal(run.revision)
	if mutating && (revision >= u64(max(i64)) || request.timestamp <= 0) do return sql.FULL
	next_revision := i64(revision)
	if mutating do next_revision = max(i64(revision) + 1, request.timestamp)
	switch q.op {
	case "participant_add", "guest_join":
		if q.op == "participant_add" {
			if !staff || (q.source != "staff" && q.source != "portal") || !pr.review_text_valid(q.name, 256, true) do return sqlite_review_reply(output, correlation, r, backing)
			source = q.source; identity = q.identity
			if source == "staff" && identity == "" do identity = request.subject == "" ? request.actor : request.subject
			if identity == "" do return sqlite_review_reply(output, correlation, r, backing)
			participant = {}
			for p in run.participants do if p.source == source && p.identity == identity do participant = p
		} else if staff || source != "guest" {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		if participant.id == "" {
			if len(run.participants) >= 64 do return sql.TOOBIG
			pid, pid_rc := db.next_id(store, .Asset); if pid_rc != sql.OK do return pid_rc
			close_right := staff ? q.can_close : invite_close
			rc = sqlite_chronicle_execute(
				store,
				`INSERT INTO review_participants VALUES(?1,?2,?3,CAST(?4 AS TEXT),?5,?6,?7,?8)`,
				request.workspace,
				{run_id, pid, source, identity, q.name, i64(close_right), invite_id},
			)
			if rc != sql.OK do return rc
			r.participant_id = fmt.aprintf("%d", pid)
		} else {
			r.participant_id = participant.id
			if q.op == "participant_add" {
				pid, _ := pr.chronicle_decimal(participant.id)
				rc = sqlite_chronicle_execute(
					store,
					`UPDATE review_participants SET name=?4,can_close=?5 WHERE workspace=?1 AND run_id=?2 AND id=?3`,
					request.workspace,
					{run_id, pid, q.name, i64(q.can_close)},
				)
				if rc != sql.OK do return rc
			}
		}
	case "answer":
		valid_point := false
		for p in form.points do if p.id == q.point_id do valid_point = true
		if !valid_point || (q.result != "yes" && q.result != "no" && q.result != "unable") do return sqlite_review_reply(output, correlation, r, backing)
		if participant.id == "" {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		pid, _ := pr.chronicle_decimal(participant.id)
		old: pr.Asset
		for answer in run.answers {
			if answer.participant_id == participant.id && answer.point_id == q.point_id {
				id, _ := pr.chronicle_decimal(answer.id)
				old, _, rc = sqlite_read_asset(store, request.workspace, request.actor, id, true)
				if rc != sql.OK do return rc
			}
		}
		a := old
		if a.asset_id == 0 {
			id, id_rc := db.next_id(store, .Asset); if id_rc != sql.OK do return id_rc
			a = {
				asset_id   = id,
				asset_type = .ReviewAnswer,
				owner      = transmute([]byte)request.actor,
				created_at = next_revision,
			}
		}
		answer := pr.Review_Answer {
			fmt.aprintf("%d", a.asset_id),
			participant.id,
			q.point_id,
			q.result,
			q.comment,
			participant.name,
			fmt.aprintf("%d", next_revision),
		}
		payload, e := json.marshal(answer); if e != nil do return sql.ERROR
		preview, pe := json.marshal(struct {
			title:  string,
			run_id: string,
		}{form.title, run.id}); if pe != nil do return sql.ERROR
		a.updated_at = next_revision; a.payload = payload; a.payload_raw_len = u32(len(payload)); a.preview = preview
		if rc = sqlite_put_asset(store, request.workspace, &a, insert_only = old.asset_id == 0); rc != sql.OK do return rc
		if old.asset_id == 0 {
			rc = sqlite_chronicle_execute(
				store,
				`INSERT INTO review_answers VALUES(?1,?2,?3,?4,?5)`,
				request.workspace,
				{run_id, pid, q.point_id, u64(a.asset_id)},
			)
			if rc != sql.OK do return rc
		}
		if rc = sqlite_asset_history(store, request, &old, &a, old.asset_id == 0); rc != sql.OK do return rc
	case "close":
		if participant.id == "" ||
		   !participant.can_close ||
		   (source == "guest" && !invite_close) {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		if q.if_revision != run.revision {r.status = "conflict"; return sqlite_review_reply(output, correlation, r, backing)}
		if (run.kind == "qa" && q.decision != "completed") || (run.kind == "customer" && q.decision != "accepted" && q.decision != "conditional" && q.decision != "rejected") do return sqlite_review_reply(output, correlation, r, backing)
		rc = sqlite_chronicle_execute(
			store,
			`UPDATE review_runs SET decision=CAST(?3 AS TEXT),comment=?4,closed_at=?5,closed_by=?6,closed_name=?7,closed_source=CAST(?8 AS TEXT) WHERE workspace=?1 AND id=?2`,
			request.workspace,
			{run_id, q.decision, q.comment, next_revision, participant.id, participant.name, source},
		)
		if rc != sql.OK do return rc
	case "invite":
		if !staff {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		expires, valid := pr.chronicle_decimal(q.expires_at)
		if !valid || expires > u64(max(i64)) || i64(expires) <= request.timestamp do return sqlite_review_reply(output, correlation, r, backing)
		id, id_rc := db.next_id(store, .Asset); if id_rc != sql.OK do return id_rc
		random: [32]byte; crypto.rand_bytes(random[:])
		r.token = sqlite_review_invite_token(request.workspace, run_id, id, random[:16])
		digest: [32]byte
		if r.token == "" {
			r.token = sqlite_chronicle_hex(random[:])
			digest = sqlite_chronicle_hash(transmute([]byte)r.token)
		} else {
			digest = sqlite_review_invite_lookup(r.token, random[:16])
		}
		r.invite_id = fmt.aprintf("%d", id)
		rc = sqlite_chronicle_execute(
			store,
			`INSERT INTO review_invites(workspace,run_id,id,token_hash,expires_at,can_close) VALUES(?1,?2,?3,?4,?5,?6)`,
			request.workspace,
			{run_id, id, string(digest[:]), i64(expires), i64(q.can_close)},
		)
		if rc != sql.OK do return rc
	case "revoke":
		if !staff {r.status = "forbidden"; return sqlite_review_reply(output, correlation, r, backing)}
		id, valid := pr.chronicle_decimal(q.invite_id)
		if !valid || id == 0 do return sqlite_review_reply(output, correlation, r, backing)
		rc = sqlite_chronicle_execute(
			store,
			`UPDATE review_invites SET revoked_at=?4 WHERE workspace=?1 AND run_id=?2 AND id=?3 AND revoked_at=0`,
			request.workspace,
			{run_id, id, request.timestamp},
		)
		if rc != sql.OK do return rc
	case "run_create", "run_get":
	case:
		return sqlite_review_reply(output, correlation, r, backing)
	}
	if mutating {
		rc = sqlite_chronicle_execute(store, `UPDATE review_runs SET revision=?3 WHERE workspace=?1 AND id=?2`, request.workspace, {run_id, next_revision})
		if rc != sql.OK do return rc
	}
	r.run, r.form, found, rc = sqlite_review_read_run(store, request.workspace, run_id)
	if rc != sql.OK do return rc
	if !found do return sql.CORRUPT
	r.status = "ok"; r.form_id = r.run.form_id; r.revision = r.run.revision
	// Account references stay private even inside a team's public projection.
	if !staff {for &p in r.run.participants do p.identity = ""}
	if rc = sqlite_review_reply(output, correlation, r, backing); rc != sql.OK do return rc
	return sql.OK
}
