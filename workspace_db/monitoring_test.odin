package workspace_db

import mon "../monitoring"
import sql "../sqlite"
import "core:testing"

@(test)
test_monitor_batch_reopen_replay_and_workspace_isolation :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	inputs := [2]Monitor_Evaluation {
		{max(u64), "host=a;mount=/data", {2, 2, 3, 190}, {1, 100, .Failing, 7.25}},
		{max(u64), "host=b;mount=/", {2, 2, 3, 190}, {1, 100, .Passing, 81.5}},
	}
	outputs: [2]Monitor_Application
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:], outputs[:]), sql.MISUSE)
	for seq in u64(1) ..= 2 {
		for &input in inputs {input.evaluation.sequence = seq; input.evaluation.at = 100 + i64(seq)}
		testing.expect_value(t, begin(&store), sql.OK)
		testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:], outputs[:]), sql.OK)
		testing.expect_value(t, commit(&store), sql.OK)
	}
	id := outputs[0].instance_id
	testing.expect(t, id != outputs[1].instance_id && .Opened in outputs[0].changes && outputs[1].changes == {})
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	saved, found, read_rc := get_monitor_instance(&store, "w", max(u64), inputs[0].identity)
	testing.expect(t, read_rc == sql.OK && found && saved.id == id && saved.state.incident_open && saved.state.episode == 1 && saved.state.last_value == 7.25)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:], outputs[:]), sql.OK)
	testing.expect(t, outputs[0].replayed && outputs[1].replayed && .Opened in outputs[0].changes)
	testing.expect_value(t, commit(&store), sql.OK)
	count, count_rc := scalar(&store, "SELECT count(*) FROM monitor_episodes")
	testing.expect(t, count_rc == sql.OK && count == 1)
	_, found, read_rc = get_monitor_instance(&store, "other", max(u64), inputs[0].identity)
	testing.expect(t, read_rc == sql.OK && !found)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "other", inputs[:], outputs[:]), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect(t, outputs[0].instance_id != id && !outputs[0].replayed)
	// A conflict late in a batch must undo the earlier update too.
	inputs[0].evaluation = {3, 103, .Passing, 25}
	inputs[1].evaluation.value = 99 // same sequence, conflicting payload
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:], outputs[:]), sql.CONSTRAINT)
	testing.expect(t, outputs[0] == {} && outputs[1] == {})
	testing.expect_value(t, commit(&store), sql.OK)
	after, _, _ := get_monitor_instance(&store, "w", max(u64), inputs[0].identity)
	testing.expect(t, after == saved)
	// Recover and create a separate later episode.
	for seq in u64(3) ..= 6 {
		inputs[0].evaluation = {seq, 100 + i64(seq), seq < 5 ? .Passing : .Failing, 25}
		testing.expect_value(t, begin(&store), sql.OK)
		testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:1], outputs[:1]), sql.OK)
		testing.expect_value(t, commit(&store), sql.OK)
	}
	count, count_rc = scalar(&store, "SELECT count(*) FROM monitor_episodes WHERE workspace=x'77'")
	testing.expect(t, count_rc == sql.OK && count == 2)
	count, count_rc = scalar(&store, "SELECT count(*) FROM monitor_episodes WHERE close_reason=1 AND opened_at=102 AND closed_at=104")
	testing.expect(t, count_rc == sql.OK && count == 1)
}

@(test)
test_monitor_storage_failure_rolls_back_ids_state_and_receipts :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	input := [1]Monitor_Evaluation{{9, "disk", {1, 2, 3, 190}, {1, 1, .Failing, 3}}}
	output: [1]Monitor_Application
	testing.expect_value(
		t,
		execute(&store, "CREATE TEMP TRIGGER fail_episode BEFORE INSERT ON monitor_episodes BEGIN SELECT RAISE(ABORT,'injected'); END"),
		sql.OK,
	)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", input[:], output[:]), sql.CONSTRAINT)
	testing.expect_value(t, commit(&store), sql.OK)
	count, count_rc := scalar(&store, "SELECT count(*) FROM monitor_instances")
	testing.expect(t, count_rc == sql.OK && count == 0 && output[0] == {})
	testing.expect_value(t, execute(&store, "DROP TRIGGER fail_episode"), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", input[:], output[:]), sql.OK)
	testing.expect_value(t, rollback(&store), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", input[:], output[:]), sql.OK)
	testing.expect(t, output[0].instance_id == 1 && !output[0].replayed)
	testing.expect_value(t, commit(&store), sql.OK)
	input[0].evaluation = {2, 2, .Absent, 0}
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", input[:], output[:]), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	saved, found, read_rc := get_monitor_instance(&store, "w", 9, "disk")
	testing.expect(t, read_rc == sql.OK && found && saved.state.incident_open && saved.state.freshness == mon.Freshness.Missing && saved.state.last_value == 3)
	// The bounded receipt must not accept conflicting policies or older runs.
	input[0].policy.failures = 2
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", input[:], output[:]), sql.CONSTRAINT)
	input[0].evaluation = {1, 1, .Failing, 3}
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", input[:], output[:]), sql.CONSTRAINT)
	input[0].identity = "never-seen"
	input[0].evaluation = {3, 3, .Absent, 0}
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", input[:], output[:]), sql.CONSTRAINT)
	testing.expect_value(t, commit(&store), sql.OK)
	after, _, _ := get_monitor_instance(&store, "w", 9, "disk")
	testing.expect(t, saved == after)
	_, found, read_rc = get_monitor_instance(&store, "w", 9, "never-seen")
	testing.expect(t, read_rc == sql.OK && !found)
}

@(test)
test_monitor_batch_requires_unique_instances :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	inputs := [2]Monitor_Evaluation{{7, "disk", {1, 2, 3, 190}, {1, 100, .Failing, 7}}, {7, "disk", {1, 2, 3, 190}, {2, 101, .Passing, 20}}}
	outputs: [2]Monitor_Application
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:], outputs[:]), sql.CONSTRAINT)
	inputs[1] = inputs[0]
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:], outputs[:]), sql.CONSTRAINT)
	testing.expect(t, outputs[0] == {} && outputs[1] == {})
	testing.expect_value(t, commit(&store), sql.OK)
	_, found, read_rc := get_monitor_instance(&store, "w", 7, "disk")
	testing.expect(t, read_rc == sql.OK && !found)
	// The same labels on different monitors are independent and replayable.
	inputs[1].monitor_id = 8
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:], outputs[:]), sql.OK)
	testing.expect(t, outputs[0].instance_id == 1 && outputs[1].instance_id == 2)
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, apply_monitor_evaluations(&store, "w", inputs[:], outputs[:]), sql.OK)
	testing.expect(t, outputs[0].replayed && outputs[1].replayed)
	testing.expect_value(t, commit(&store), sql.OK)
}
