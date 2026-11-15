package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:testing"

@(test)
test_slice_deltas_batch_savepoint_and_deleted_extrema :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(t, begin(&store), sql.OK)
	task := pr.Task {
		id         = 1,
		status     = .Todo,
		created_at = 20,
		updated_at = 90,
		project    = transmute([]byte)string("P"),
	}
	testing.expect_value(t, put_task(&store, "w", &task), sql.OK)
	task.id = 2; task.created_at = 0; task.updated_at = 100
	testing.expect_value(t, put_task(&store, "w", &task), sql.OK)
	testing.expect_value(
		t,
		execute(
			&store,
			`
 INSERT INTO assets VALUES(x'77',x'0000000000000001',11,0,zeroblob(8),x'',0,0,0,0,x'',x'');
 INSERT INTO slice_metadata(workspace,asset_id,name,owner,outcome,closed,closed_at,closed_by) VALUES(x'77',x'0000000000000001',x'53',x'',x'',0,0,x'');
 INSERT INTO edges VALUES(x'77',x'0000000000000001',2,x'0000000000000001',1,x'0000000000000001',7,0,x'');
 INSERT INTO edges VALUES(x'77',x'0000000000000002',1,x'0000000000000001',2,x'0000000000000002',7,0,x'');`,
		),
		sql.OK,
	)
	testing.expect_value(t, commit(&store), sql.OK)
	value, status := scalar(&store, "SELECT todo=2 AND oldest=20 AND last_moved=100 FROM slice_summaries")
	testing.expect(t, status == sql.OK && value == 1)
	// The same task is patched twice; a savepoint rolls back a third patch and
	// edge removal. Only the final state may enter the committed counters.
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(
		t,
		execute(
			&store,
			`UPDATE tasks SET status=3; UPDATE tasks SET status=2;
 SAVEPOINT patch; DELETE FROM edges; UPDATE tasks SET project=x'51'; ROLLBACK TO patch; RELEASE patch;`,
		),
		sql.OK,
	)
	testing.expect_value(t, commit(&store), sql.OK)
	value, status = scalar(&store, "SELECT todo=0 AND done=0 AND in_progress=2 AND oldest=20 FROM slice_summaries")
	testing.expect(t, status == sql.OK && value == 1)
	value, status = scalar(&store, "SELECT refs=2 AND project=x'50' FROM slice_projects")
	testing.expect(t, status == sql.OK && value == 1)
	// A project-only change retains status/coverage and the other member's
	// project reference. Repeating it must not accumulate derived counters.
	for _ in 0 ..< 2 {
		testing.expect_value(t, begin(&store), sql.OK)
		testing.expect_value(t, execute(&store, "UPDATE tasks SET project=x'51' WHERE id=x'0000000000000001'"), sql.OK)
		testing.expect_value(t, commit(&store), sql.OK)
	}
	value, status = scalar(&store, "SELECT count(*)=2 AND sum(refs)=2 FROM slice_projects WHERE project IN (x'50',x'51')")
	testing.expect(t, status == sql.OK && value == 1)
	value, status = scalar(&store, "SELECT sum(total)=2 AND sum(covered)=2 FROM workspace_task_counts")
	testing.expect(t, status == sql.OK && value == 1)
	// Remove the oldest member, then the movement winner, retaining dangling
	// edges. Unknown timestamps do not win; resurrection restores contributions.
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, remove_task(&store, "w", 0, 1), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	value, status = scalar(&store, "SELECT in_progress=1 AND oldest=0 AND last_moved=100 FROM slice_summaries")
	testing.expect(t, status == sql.OK && value == 1)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, remove_task(&store, "w", 0, 2), sql.OK)
	task.id = 1; task.status = .Backlog; task.created_at = -5; task.updated_at = 17
	testing.expect_value(t, put_task(&store, "w", &task), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	value, status = scalar(&store, "SELECT in_progress=0 AND backlog=1 AND oldest=-5 AND last_moved=17 FROM slice_summaries")
	testing.expect(t, status == sql.OK && value == 1)
	value, status = scalar(&store, "SELECT sum(total)=1 AND sum(covered)=1 FROM workspace_task_counts")
	testing.expect(t, status == sql.OK && value == 1)
	// A commit error after finalization rolls back canonical rows, deltas and
	// the queue together. The next transaction can safely finalize again.
	testing.expect_value(
		t,
		execute(
			&store,
			`CREATE TABLE fault_parent(id INTEGER PRIMARY KEY);
 CREATE TABLE fault_child(id INTEGER REFERENCES fault_parent(id) DEFERRABLE INITIALLY DEFERRED);`,
		),
		sql.OK,
	)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, execute(&store, "UPDATE tasks SET status=3; INSERT INTO fault_child VALUES(1)"), sql.OK)
	testing.expect_value(t, commit(&store), sql.CONSTRAINT)
	testing.expect_value(t, rollback(&store), sql.OK)
	value, status = scalar(&store, "SELECT backlog=1 AND done=0 FROM slice_summaries")
	testing.expect(t, status == sql.OK && value == 1)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, rebuild_slices(&store), sql.OK)
	testing.expect_value(t, commit(&store), sql.OK)
	value, status = scalar(&store, "SELECT backlog=1 AND oldest=-5 AND last_moved=17 FROM slice_summaries")
	testing.expect(t, status == sql.OK && value == 1)
	value, status = scalar(&store, "SELECT NOT EXISTS(SELECT 1 FROM slice_pending)")
	testing.expect(t, status == sql.OK && value == 1)
	value, status = scalar(&store, "SELECT sort_at=17 FROM slice_metadata")
	testing.expect(t, status == sql.OK && value == 1)
	// The slice's own creation time can win without changing any member.
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(t, execute(&store, "UPDATE assets SET created_at=200"), sql.OK)
	value, status = scalar(&store, "SELECT sort_at=200 FROM slice_metadata")
	testing.expect(t, status == sql.OK && value == 1)
	testing.expect_value(t, rollback(&store), sql.OK)
	value, status = scalar(&store, "SELECT sort_at=17 FROM slice_metadata")
	testing.expect(t, status == sql.OK && value == 1)
}
