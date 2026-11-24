package main

import "core:c"
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

sqlite_review_test_call :: proc(
	t: ^testing.T,
	store: ^db.Store,
	q: pr.Review_Request,
	workspace := "reviews",
	limit := 131072,
	actor := "alice",
	subject := "staff:alice",
	portal := false,
	at := i64(100),
) -> (
	r: pr.Review_Response,
	rc: c.int,
) {
	wire: [pr.MAX_REVIEW_FORM_BYTES + 6]byte
	n := pr.serializeReviewRequest(q, 73, wire[:])
	if !testing.expect(t, n > 0) do return {}, sql.MISUSE
	request := db.Request {
		operation     = .Command,
		workspace     = workspace,
		actor         = actor,
		subject       = subject,
		review_portal = portal,
		timestamp     = at,
		opcode        = .C_Review,
		body          = wire[2:n],
	}
	output := db.Command_Output {
		limit = limit,
	}
	defer db.destroy_command_output(&output)
	rc = db.begin(store)
	if rc != sql.OK do return
	rc = sqlite_execute_task_command(store, &request, &output)
	if rc == sql.OK do rc = db.commit(store)
	if rc != sql.OK {db.rollback(store); return}
	if !testing.expect(t, output.count >= 1) do return
	frame := output.frames[0].payload
	testing.expect_value(t, pr.get_opcode(frame), pr.Opcode.S_Review)
	correlation, _ := endian.get_u32(frame[2:], .Big)
	testing.expect_value(t, correlation, u32(73))
	testing.expect(t, json.unmarshal(frame[6:], &r) == nil)
	return
}

@(test)
test_review_form_release_copy_and_restart :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "nrc-review-form-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	path := strings.clone_to_cstring(fmt.aprintf("%s/workspace.db", dir))
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	// Ordinary records must survive adding and releasing independent forms.
	db.begin(&store)
	task := pr.Task {
		id    = 41,
		title = transmute([]byte)string("Existing task"),
	}
	testing.expect_value(t, db.put_task(&store, "reviews", &task), sql.OK)
	// Persist the old JSON shape, not a serialization of the current DTO.
	legacy_payload := transmute([]byte)string(
		`{"version":1,"title":"Bestandsbogen","build":"v1","released_at":"50","points":[{"id":"7","question":"Export korrekt?","instruction":"","expected":"PDF"}]}`,
	)
	legacy := pr.Asset {
		asset_id         = 42,
		asset_type       = .ReviewForm,
		owner            = transmute([]byte)string("alice"),
		created_at       = 50,
		updated_at       = 50,
		preview          = transmute([]byte)string(`{"title":"Bestandsbogen","build":"v1","released_at":"50"}`),
		payload          = legacy_payload,
		payload_raw_len  = u32(len(legacy_payload)),
		payload_encoding = .Plain,
	}
	testing.expect_value(t, sqlite_put_asset(&store, "reviews", &legacy, true), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	form := pr.Review_Form {
		version     = 1,
		title       = "PDF-Steuer",
		build       = "build-42",
		environment = "Staging",
		points      = {{"9", "Betrag korrekt?", "PDF öffnen", "19,00 €", "Beträge & Steuern"}, {"3", "Name korrekt?", "", "Kunde A", "Zugang"}},
	}
	for invalid_section in ([2]string{strings.repeat("ä", 129), "Abschnitt\x00intern"}) {
		form.points[0].section = invalid_section
		rejected, _ := sqlite_review_test_call(t, &store, {op = "create", form = form})
		testing.expect_value(t, rejected.status, "invalid")
	}
	form.points[0].section = strings.repeat("ä", 128)
	r, status := sqlite_review_test_call(t, &store, {op = "create", form = form})
	if !testing.expect_value(t, status, sql.OK) || !testing.expect_value(t, r.status, "ok") do return
	id, revision := r.form_id, r.revision
	testing.expect_value(t, r.form.points[0].id, "9")
	testing.expect_value(t, r.form.points[0].section, form.points[0].section)
	form.points[0].section = "Beträge & Steuern"
	form.points = {form.points[1], form.points[0]}
	r, _ = sqlite_review_test_call(t, &store, {op = "update", form_id = id, if_revision = revision, form = form})
	if !testing.expect_value(t, r.status, "ok") do return
	testing.expect_value(t, r.form.points[0].id, "3")
	testing.expect_value(t, r.form.points[0].section, "Zugang")
	stale, _ := sqlite_review_test_call(t, &store, {op = "release", form_id = id, if_revision = revision})
	testing.expect_value(t, stale.status, "conflict")
	r, _ = sqlite_review_test_call(t, &store, {op = "release", form_id = id, if_revision = r.revision})
	if !testing.expect_value(t, r.status, "ok") do return
	testing.expect_value(t, r.form.released_at, r.revision)
	released := r
	form.build = "build-43"
	r, _ = sqlite_review_test_call(t, &store, {op = "update", form_id = id, if_revision = released.revision, form = form})
	testing.expect_value(t, r.status, "released")
	r, _ = sqlite_review_test_call(t, &store, {op = "get", form_id = id}, workspace = "another-workspace")
	testing.expect_value(t, r.status, "not_found")
	r, _ = sqlite_review_test_call(t, &store, {op = "copy", form_id = id})
	if !testing.expect_value(t, r.status, "ok") do return
	testing.expect(t, r.form_id != id)
	testing.expect_value(t, r.form.released_at, "")
	testing.expect_value(t, r.form.points[0].id, "3")
	testing.expect_value(t, r.form.points[1].section, "Beträge & Steuern")
	draft_id, draft_revision := r.form_id, r.revision
	form.points[1].section = "Neue Steuerprüfung"
	r, _ = sqlite_review_test_call(t, &store, {op = "update", form_id = r.form_id, if_revision = r.revision, form = form})
	testing.expect_value(t, r.status, "ok")
	testing.expect_value(t, r.form.build, "build-43")
	updated_revision := r.revision
	r, _ = sqlite_review_test_call(t, &store, {op = "delete_draft", form_id = draft_id, if_revision = draft_revision})
	testing.expect_value(t, r.status, "conflict")
	r, _ = sqlite_review_test_call(t, &store, {op = "delete_draft", form_id = id, if_revision = released.revision})
	testing.expect_value(t, r.status, "released")
	r, _ = sqlite_review_test_call(t, &store, {op = "delete_draft", form_id = draft_id, if_revision = updated_revision})
	testing.expect_value(t, r.status, "ok")
	r, _ = sqlite_review_test_call(t, &store, {op = "get", form_id = draft_id})
	testing.expect_value(t, r.status, "not_found")
	// If response preparation fails, neither a form nor its consumed ID commits.
	_, failed_rc := sqlite_review_test_call(t, &store, {op = "create", form = form}, limit = 1)
	testing.expect_value(t, failed_rc, sql.TOOBIG)
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	r, _ = sqlite_review_test_call(t, &store, {op = "get", form_id = id})
	testing.expect_value(t, r.status, "ok")
	testing.expect_value(t, r.revision, released.revision)
	testing.expect_value(t, r.form.build, "build-42")
	testing.expect_value(t, r.form.released_at, released.form.released_at)
	testing.expect_value(t, r.form.points[0].id, "3")
	testing.expect_value(t, r.form.points[1].expected, "19,00 €")
	testing.expect_value(t, r.form.points[1].section, "Beträge & Steuern")
	r, _ = sqlite_review_test_call(t, &store, {op = "get", form_id = "42"})
	testing.expect_value(t, r.status, "ok")
	testing.expect_value(t, r.form.points[0].section, "")
	testing.expect_value(t, r.form.points[0].question, "Export korrekt?")
	// Seed a release exactly at the content limit, as compact wire JSON can
	// expand when default fields are serialized for storage.
	large := pr.Review_Form {version = 1, title = fmt.aprintf("L%s", strings.repeat("\x01", 255)), released_at = "50"}
	meta := Review_Form_Preview {title = large.title, build = strings.repeat("x", 512), released_at = large.released_at}
	initial_preview, _ := json.marshal(meta)
	escaped := (pr.MAX_PREVIEW_LENGTH - len(initial_preview)) / 5
	large.build = fmt.aprintf("%s%s", strings.repeat("\x01", escaped), strings.repeat("x", 512 - escaped))
	meta.build = large.build
	large_preview, _ := json.marshal(meta)
	testing.expect(t, len(large_preview) > pr.MAX_PREVIEW_LENGTH - 5 && len(large_preview) <= pr.MAX_PREVIEW_LENGTH)
	large.points = make([]pr.Review_Point, 24)
	for &point, i in large.points {
		point.id = fmt.aprintf("%d", i + 1)
		point.question = "Check"
	}
	payload, _ := json.marshal(large)
	remaining := pr.MAX_REVIEW_FORM_BYTES - len(payload)
	for &point in large.points {
		n := min(2048, remaining)
		point.instruction = strings.repeat("x", n)
		remaining -= n
	}
	payload, _ = json.marshal(large)
	testing.expect_value(t, len(payload), pr.MAX_REVIEW_FORM_BYTES)
	if !testing.expect(t, pr.validate_review_form(large, true)) do return
	legacy.payload = payload; legacy.payload_raw_len = u32(len(payload))
	legacy.preview = large_preview
	testing.expect_value(t, db.begin(&store), sql.OK)
	// Use a fresh ID: subsequent form allocations already advanced the sequence.
	legacy.asset_id, rc = db.next_id(&store, .Asset)
	testing.expect_value(t, rc, sql.OK)
	testing.expect_value(t, sqlite_put_asset(&store, "reviews", &legacy, true), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	large_id := fmt.aprintf("%d", legacy.asset_id)
	run, _ := sqlite_review_test_call(t, &store, {op = "run_create", form_id = large_id, if_released_at = "50", label = "QA", kind = "qa"})
	testing.expect_value(t, run.status, "ok")
	r, _ = sqlite_review_test_call(t, &store, {op = "archive", form_id = large_id, if_revision = "49"})
	testing.expect_value(t, r.status, "conflict")
	r, _ = sqlite_review_test_call(t, &store, {op = "archive", form_id = large_id, if_revision = "50"})
	testing.expect_value(t, r.status, "ok")
	testing.expect(t, r.form.archived)
	testing.expect_value(t, r.form.build, large.build)
	r, _ = sqlite_review_test_call(t, &store, {op = "run_get", run_id = run.run.id})
	testing.expect_value(t, r.status, "ok")
	testing.expect(t, !r.form.archived)
	stored, stored_found, stored_rc := sqlite_read_asset(&store, "reviews", "alice", legacy.asset_id, true)
	testing.expect_value(t, stored_rc, sql.OK)
	testing.expect(t, stored_found && string(stored.payload) == string(payload))
	existing, found, read_rc := db.get_task(&store, "reviews", 0, 41)
	testing.expect_value(t, read_rc, sql.OK)
	testing.expect(t, found)
	testing.expect_value(t, string(existing.title), "Existing task")
}

@(test)
test_review_teams_guests_revision_fence_and_frozen_report :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "nrc-review-runs-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	path := strings.clone_to_cstring(fmt.aprintf("%s/workspace.db", dir))
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	form := pr.Review_Form {
		version = 1,
		title   = "PDF",
		build   = "v42",
		points  = {{"9", "Steuer korrekt?", "", "19 %", ""}, {"3", "Name korrekt?", "", "A", ""}},
	}
	r, _ := sqlite_review_test_call(t, &store, {op = "create", form = form})
	r, _ = sqlite_review_test_call(t, &store, {op = "release", form_id = r.form_id, if_revision = r.revision})
	if !testing.expect_value(t, r.status, "ok") do return
	form_id := r.form_id
	a, _ := sqlite_review_test_call(t, &store, {op = "run_create", form_id = form_id, label = "Kunde A", kind = "customer"})
	b, _ := sqlite_review_test_call(t, &store, {op = "run_create", form_id = form_id, label = "Kunde B", kind = "customer"})
	if !testing.expect_value(t, a.status, "ok") || !testing.expect_value(t, b.status, "ok") do return
	aid, bid := a.run.id, b.run.id
	for workspace, i in ([3]string{"reviews", "reviews", "other"}) {
		rc = sqlite_chronicle_execute(&store,
			`INSERT INTO portal_accounts(workspace,id,revision,login,requester,name,company_id,contact_id,password_hash,disabled)
			 VALUES(?1,?2,1,?3,?4,?5,?6,?6,?7,?8)`, workspace,
			{u64(i+1), fmt.aprintf("customer%d", i), fmt.aprintf("customer%d@example.test", i), "Customer", u64(0), strings.repeat("x", 60), i64(i == 1 ? 1 : 0)})
		if !testing.expect_value(t, rc, sql.OK) do return
	}
	choices := pr.Review_Request{op = "participant_accounts", run_id = aid}
	r, rc = sqlite_review_test_call(t, &store, choices)
	if !testing.expect_value(t, rc, sql.OK) || !testing.expect_value(t, r.status, "ok") || !testing.expect_value(t, len(r.accounts), 1) do return
	testing.expect_value(t, r.accounts[0].requester, "customer0@example.test")
	testing.expect_value(t, r.accounts[0].name, "Customer")
	testing.expect_value(t, r.accounts[0].login, "customer0")
	r, _ = sqlite_review_test_call(t, &store, choices, workspace = "other")
	testing.expect_value(t, r.status, "not_found")
	choices.source = "portal"
	choices.identity = "customer0@example.test"
	r, _ = sqlite_review_test_call(t, &store, choices, portal = true)
	testing.expect_value(t, r.status, "forbidden")
	testing.expect_value(t, len(r.accounts), 0)
	for run_id in ([2]string{aid, bid}) {
		r, _ = sqlite_review_test_call(
			t,
			&store,
			{
				op = "participant_add",
				run_id = run_id,
				source = "portal",
				identity = run_id == aid ? "a@example.test" : "b@example.test",
				name = "Alex",
				can_close = true,
			},
		)
		testing.expect_value(t, r.status, "ok")
	}
	listed, _ := sqlite_review_test_call(t, &store, {op = "run_list", source = "portal", identity = "a@example.test"}, portal = true)
	testing.expect_value(t, listed.status, "ok"); testing.expect_value(t, len(listed.runs), 1)
	testing.expect_value(t, listed.runs[0].id, aid)
	r, _ = sqlite_review_test_call(t, &store, {op = "run_get", run_id = aid, source = "portal", identity = "b@example.test"}, portal = true)
	testing.expect_value(t, r.status, "forbidden")
	// Two guests named exactly alike still get distinct participants and answers.
	invite, _ := sqlite_review_test_call(t, &store, {op = "invite", run_id = aid, expires_at = "1000"})
	if !testing.expect_value(t, invite.status, "ok") do return
	guest1 := pr.Review_Request {
		op       = "guest_join",
		source   = "guest",
		token    = invite.token,
		guest_id = "11111111111111111111111111111111",
		name     = "Alex",
	}
	guest2 := guest1; guest2.guest_id = "22222222222222222222222222222222"
	g1, _ := sqlite_review_test_call(t, &store, guest1, portal = true)
	g2, _ := sqlite_review_test_call(t, &store, guest2, portal = true)
	if !testing.expect_value(t, g1.status, "ok") || !testing.expect_value(t, g2.status, "ok") do return
	testing.expect(t, g1.participant_id != g2.participant_id)
	guest1.op = "answer"; guest1.run_id = aid; guest1.point_id = "9"; guest1.result = "yes"; guest1.comment = "Desktop korrekt"
	guest2.op = "answer"; guest2.run_id = aid; guest2.point_id = "9"; guest2.result = "no"; guest2.comment = "Steuer fehlt auf Smartphone"
	r, _ = sqlite_review_test_call(t, &store, guest1, portal = true)
	r, _ = sqlite_review_test_call(t, &store, guest2, portal = true)
	if !testing.expect_value(t, r.status, "ok") do return
	testing.expect_value(t, len(r.run.answers), 2)
	testing.expect_value(t, r.run.answered_points, 1)
	testing.expect_value(t, r.run.answers[0].result, "yes")
	testing.expect_value(t, r.run.answers[1].result, "no")
	testing.expect_value(t, r.run.participants[0].identity, "")
	guest1.op = "close"; guest1.if_revision = r.run.revision; guest1.decision = "accepted"
	r, _ = sqlite_review_test_call(t, &store, guest1, portal = true)
	testing.expect_value(t, r.status, "forbidden")
	preview, _ := sqlite_review_test_call(t, &store, {op = "run_get", run_id = aid, source = "portal", identity = "a@example.test"}, portal = true)
	guest2.comment = "Neue Antwort nach Abschlussvorschau"
	r, _ = sqlite_review_test_call(t, &store, guest2, portal = true)
	close := pr.Review_Request {
		op          = "close",
		run_id      = aid,
		source      = "portal",
		identity    = "a@example.test",
		if_revision = preview.run.revision,
		decision    = "conditional",
		comment     = "Vorbehalt trotz offenem Namenspunkt",
	}
	r, _ = sqlite_review_test_call(t, &store, close, portal = true)
	testing.expect_value(t, r.status, "conflict")
	preview, _ = sqlite_review_test_call(t, &store, {op = "run_get", run_id = aid, source = "portal", identity = "a@example.test"}, portal = true)
	close.if_revision = preview.run.revision
	r, _ = sqlite_review_test_call(t, &store, close, portal = true)
	if !testing.expect_value(t, r.status, "ok") do return
	testing.expect_value(t, r.run.decision, "conditional")
	testing.expect_value(t, len(r.run.answers), 2)
	frozen, _ := json.marshal(r.run)
	r, _ = sqlite_review_test_call(t, &store, guest2, portal = true)
	testing.expect_value(t, r.status, "closed")
	r, _ = sqlite_review_test_call(t, &store, {op = "run_get", run_id = bid, source = "portal", identity = "b@example.test"}, portal = true)
	testing.expect_value(t, r.status, "ok"); testing.expect_value(t, r.run.decision, "")
	testing.expect_value(t, len(r.run.answers), 0)
	// Revocation remains possible after closure and ends an existing session.
	r, _ = sqlite_review_test_call(t, &store, {op = "revoke", run_id = aid, invite_id = invite.invite_id})
	testing.expect_value(t, r.status, "ok")
	guest2.op = "run_get"
	r, _ = sqlite_review_test_call(t, &store, guest2, portal = true)
	testing.expect_value(t, r.status, "forbidden")
	// Explicit guest-close invitation, unlike the standard contributor link.
	invite, _ = sqlite_review_test_call(t, &store, {op = "invite", run_id = bid, expires_at = "1000", can_close = true})
	guest1 = pr.Review_Request {
		op       = "guest_join",
		source   = "guest",
		token    = invite.token,
		guest_id = "33333333333333333333333333333333",
		name     = "Alex",
	}
	r, _ = sqlite_review_test_call(t, &store, guest1, portal = true)
	if !testing.expect_value(t, r.status, "ok") do return
	guest1.op = "close"; guest1.run_id = bid; guest1.if_revision = r.run.revision; guest1.decision = "rejected"
	r, _ = sqlite_review_test_call(t, &store, guest1, portal = true)
	testing.expect_value(t, r.status, "ok"); testing.expect_value(t, r.run.closed_source, "guest")
	testing.expect_value(t, r.run.closed_name, "Alex")
	guest1.op = "run_get"
	r, _ = sqlite_review_test_call(t, &store, guest1, portal = true, at = 1000)
	testing.expect_value(t, r.status, "forbidden")
	// A copied new build can be rechecked without touching the original report.
	copy, _ := sqlite_review_test_call(t, &store, {op = "copy", form_id = form_id})
	copy.form.build = "v43"
	copy, _ = sqlite_review_test_call(t, &store, {op = "update", form_id = copy.form_id, if_revision = copy.revision, form = copy.form})
	copy, _ = sqlite_review_test_call(t, &store, {op = "release", form_id = copy.form_id, if_revision = copy.revision})
	r, _ = sqlite_review_test_call(t, &store, {op = "run_create", form_id = copy.form_id, previous_run = aid, label = "Kunde A", kind = "customer"})
	testing.expect_value(t, r.status, "ok"); testing.expect_value(t, r.run.previous_run, aid)
	// QA is assigned to a stable subject and closes without a customer decision.
	qa, _ := sqlite_review_test_call(t, &store, {op = "run_create", form_id = form_id, label = "Interne QA", kind = "qa"})
	qa_id := qa.run.id
	qa, _ = sqlite_review_test_call(
		t,
		&store,
		{op = "participant_add", run_id = qa_id, source = "staff", identity = "staff:qa", name = "Quality", can_close = true},
	)
	denied, _ := sqlite_review_test_call(
		t,
		&store,
		{op = "answer", run_id = qa_id, source = "staff", identity = "staff:qa", point_id = "9", result = "yes"},
		subject = "staff:other",
	)
	testing.expect_value(t, denied.status, "forbidden")
	qa, _ = sqlite_review_test_call(t, &store, {op = "close", run_id = qa_id, if_revision = qa.run.revision, decision = "accepted"}, subject = "staff:qa")
	testing.expect_value(t, qa.status, "invalid")
	qa, _ = sqlite_review_test_call(t, &store, {op = "run_get", run_id = qa_id}, subject = "staff:qa")
	qa, _ = sqlite_review_test_call(
		t,
		&store,
		{op = "close", run_id = qa_id, if_revision = qa.run.revision, decision = "completed", comment = "Prüfung abgeschlossen"},
		subject = "staff:qa",
	)
	testing.expect_value(t, qa.status, "ok"); testing.expect_value(t, qa.run.decision, "completed")
	testing.expect_value(t, qa.run.closed_source, "staff")
	// Generic writes cannot alter machine-owned forms or answers, even in batches.
	wire, patch: [8192]byte
	for id_text in ([2]string{form_id, preview.run.answers[0].id}) {
		id, _ := pr.chronicle_decimal(id_text)
		n := pr.serializeUpdateAssetRequest({asset_id = id, preview = transmute([]byte)string("tampered")}, wire[:])
		testing.expect_value(t, sqlite_chronicle_test_apply(&store, "reviews", 200, wire[:n]), sql.OK)
		n = pr.serializeDeleteAssetRequest(0, id, wire[:])
		testing.expect_value(t, sqlite_chronicle_test_apply(&store, "reviews", 201, wire[:n]), sql.OK)
		pn := pr.serializeTransactionAssetPatch(
			{
				asset = {kind = .Existing, entity_type = .Asset, value = id},
				present = pr.TRANSACTION_ASSET_PATCH_PREVIEW,
				preview = transmute([]byte)string("tampered"),
			},
			patch[:],
		)
		n = pr.serializeApplyTransactionRequest(11, {{.AssetPatch, patch[:pn]}}, wire[:])
		testing.expect_value(t, sqlite_chronicle_test_apply(&store, "reviews", 202, wire[:n]), sql.OK)
	}
	testing.expect_value(t, db.close(&store), sql.OK)
	store, rc = db.open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	r, _ = sqlite_review_test_call(t, &store, {op = "run_get", run_id = aid, source = "portal", identity = "a@example.test"}, portal = true)
	after, _ := json.marshal(r.run)
	testing.expect_value(t, string(after), string(frozen))
}

@(test)
test_review_invitation_info_token_only_private_and_read_only :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	dir, err := os.make_directory_temp("", "nrc-review-invitation-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	path := strings.clone_to_cstring(fmt.aprintf("%s/workspace.db", dir))
	store, rc := db.open(path, true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	form := pr.Review_Form {
		version     = 1,
		title       = "Tatsächlicher Bogentitel ä",
		build       = "private-build",
		environment = "private-environment",
		points      = {{"9", "Private question", "Private instructions", "Private expected", "Private section"}},
	}
	r, _ := sqlite_review_test_call(t, &store, {op = "create", form = form})
	r, _ = sqlite_review_test_call(t, &store, {op = "release", form_id = r.form_id, if_revision = r.revision})
	r, _ = sqlite_review_test_call(t, &store, {op = "run_create", form_id = r.form_id, label = "Private customer label", kind = "customer"})
	if !testing.expect_value(t, r.status, "ok") do return
	run_id := r.run.id
	r, _ = sqlite_review_test_call(t, &store, {op = "participant_add", run_id = run_id, source = "staff", name = "Private staff", can_close = true})
	r, _ = sqlite_review_test_call(t, &store, {op = "answer", run_id = run_id, point_id = "9", result = "no", comment = "Private answer"})
	if !testing.expect_value(t, r.status, "ok") do return
	invite, _ := sqlite_review_test_call(t, &store, {op = "invite", run_id = run_id, expires_at = "1000"})
	revoked, _ := sqlite_review_test_call(t, &store, {op = "invite", run_id = run_id, expires_at = "1000", can_close = true})
	r, _ = sqlite_review_test_call(t, &store, {op = "revoke", run_id = run_id, invite_id = revoked.invite_id})
	if !testing.expect_value(t, r.status, "ok") do return
	// SQLite's connection-wide counter catches ANY SQL write, including floors,
	// history, membership, invitation updates and otherwise invisible revisions.
	changes := proc(store: ^db.Store) -> i64 {
		s, rc := sqlite_chronicle_statement(store, `SELECT total_changes() WHERE ?1 IS NOT NULL`, "reviews", {})
		if rc != sql.OK do return -1
		defer sql.finalize(s)
		if sql.step(s) != sql.ROW do return -1
		return sql.column_int64(s, 0)
	}
	before := changes(&store)
	testing.expect(t, before > 0)
	for variant in 0 ..< 15 {
		q := pr.Review_Request {
			op     = "invitation_info",
			source = "guest",
			token  = invite.token,
		}
		at := i64(100)
		portal := true
		workspace := "reviews"
		expected_status := "forbidden"
		switch variant {
		case 0:
			expected_status = "ok" // No name, guest ID, or participant.
		case 1:
			expected_status = "ok"; q.guest_id = strings.repeat("g", 32)
		case 2:
			expected_status = "ok"; q.run_id = run_id; q.name = "Ignored name"; q.form.title = "Forged title"
		case 3:
			q.token = strings.repeat("x", 64)
		case 4:
			q.token = "short"
		case 5:
			q.token = ""
		case 6:
			q.token = revoked.token
		case 7:
			at = 1000 // Expiry is exclusive, including its exact boundary.
		case 8:
			at = 1001
		case 9:
			q.source = "portal"; q.identity = "private@example.test"
		case 10:
			portal = false // Staff cannot forge guest source.
		case 11:
			workspace = "other-workspace"
		case 12:
			q.run_id = "18446744073709551615"
		case 13:
			q.op = "guest_join"; q.guest_id = strings.repeat("g", 32)
		case 14:
			q.op = "run_get"; q.run_id = run_id; q.guest_id = strings.repeat("g", 32); q.name = "Not joined"
		}
		got, call_rc := sqlite_review_test_call(t, &store, q, portal = portal, workspace = workspace, at = at)
		testing.expect_value(t, call_rc, sql.OK)
		expected := pr.Review_Response {
			status = expected_status,
			runs   = make([]pr.Review_Run, 0),
		}
		if expected_status == "ok" do expected.form.title = form.title
		actual_json, _ := json.marshal(got)
		expected_json, _ := json.marshal(expected)
		// Full DTO comparison: no form/run IDs, revision, answers, names,
		// permissions, tokens, build, environment, points or closing metadata.
		testing.expect_value(t, string(actual_json), string(expected_json))
		testing.expect_value(t, changes(&store), before)
	}
	// A valid invitation stays inspectable after closure, without reopening or
	// altering the report. Existing close rights and revision checks still apply.
	r, _ = sqlite_review_test_call(t, &store, {op = "run_get", run_id = run_id})
	r, _ = sqlite_review_test_call(
		t,
		&store,
		{op = "close", run_id = run_id, if_revision = r.run.revision, decision = "accepted", comment = "Private closure"},
	)
	if !testing.expect_value(t, r.status, "ok") do return
	before = changes(&store)
	r, rc = sqlite_review_test_call(t, &store, {op = "invitation_info", source = "guest", token = invite.token}, portal = true)
	testing.expect_value(t, rc, sql.OK)
	expected := pr.Review_Response {
		status = "ok",
		form = {title = form.title},
		runs = make([]pr.Review_Run, 0),
	}
	actual_json, _ := json.marshal(r)
	expected_json, _ := json.marshal(expected)
	testing.expect_value(t, string(actual_json), string(expected_json))
	testing.expect_value(t, changes(&store), before)
}
