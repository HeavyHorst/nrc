-- Caller owns a write transaction. All staging is rollback-safe and disk-backed.
CREATE TEMP TABLE IF NOT EXISTS nrc_slice_keys(workspace BLOB,slice_id BLOB,edge_id BLOB,PRIMARY KEY(workspace,slice_id,edge_id)) WITHOUT ROWID;
INSERT INTO nrc_slice_keys
 SELECT m.workspace,m.slice_id,m.edge_id FROM slice_pending p
 CROSS JOIN slice_members m INDEXED BY slice_members_record
 ON m.workspace=p.workspace AND m.member_type=p.kind AND m.member_id=p.id
 WHERE p.kind IN (1,2) ON CONFLICT DO NOTHING;
INSERT INTO nrc_slice_keys
 SELECT m.workspace,m.slice_id,m.edge_id FROM slice_pending p
 CROSS JOIN slice_members m INDEXED BY slice_members_edge ON m.workspace=p.workspace AND m.edge_id=p.id
 WHERE p.kind=3 ON CONFLICT DO NOTHING;
INSERT INTO nrc_slice_keys
 SELECT m.workspace,m.slice_id,m.edge_id FROM slice_pending p
 CROSS JOIN slice_members m ON m.workspace=p.workspace AND m.slice_id=p.id
 WHERE p.kind=4 ON CONFLICT DO NOTHING;
INSERT INTO nrc_slice_keys
 SELECT e.workspace,s.asset_id,e.id FROM slice_pending p
 CROSS JOIN edges e ON e.workspace=p.workspace AND e.id=p.id
 CROSS JOIN slice_metadata s ON s.workspace=e.workspace AND s.asset_id=e.source_id
 WHERE p.kind=3 AND e.relation=7 AND e.source_type=1 ON CONFLICT DO NOTHING;
INSERT INTO nrc_slice_keys
 SELECT e.workspace,s.asset_id,e.id FROM slice_pending p
 CROSS JOIN edges e ON e.workspace=p.workspace AND e.id=p.id
 CROSS JOIN slice_metadata s ON s.workspace=e.workspace AND s.asset_id=e.target_id
 WHERE p.kind=3 AND e.relation=7 AND e.target_type=1 ON CONFLICT DO NOTHING;
INSERT INTO nrc_slice_keys
 SELECT e.workspace,p.id,e.id FROM slice_pending p
 CROSS JOIN edges e INDEXED BY edges_source ON e.workspace=p.workspace AND e.source_type=1 AND e.source_id=p.id AND e.relation=7
 WHERE p.kind=4 ON CONFLICT DO NOTHING;
INSERT INTO nrc_slice_keys
 SELECT e.workspace,p.id,e.id FROM slice_pending p
 CROSS JOIN edges e INDEXED BY edges_target ON e.workspace=p.workspace AND e.target_type=1 AND e.target_id=p.id AND e.relation=7
 WHERE p.kind=4 ON CONFLICT DO NOTHING;

CREATE TEMP TABLE IF NOT EXISTS nrc_slice_old AS SELECT * FROM slice_members LIMIT 0;
INSERT INTO nrc_slice_old SELECT m.* FROM nrc_slice_keys k CROSS JOIN slice_members m
 ON m.workspace=k.workspace AND m.slice_id=k.slice_id AND m.edge_id=k.edge_id;
CREATE TEMP TABLE IF NOT EXISTS nrc_slice_new AS SELECT * FROM slice_members LIMIT 0;
INSERT INTO nrc_slice_new WITH endpoints AS (
 SELECT k.workspace,k.slice_id,e.id AS edge_id,
 CASE WHEN e.source_type=1 AND e.source_id=k.slice_id THEN e.target_type ELSE e.source_type END AS member_type,
 CASE WHEN e.source_type=1 AND e.source_id=k.slice_id THEN e.target_id ELSE e.source_id END AS member_id
 FROM nrc_slice_keys k CROSS JOIN edges e ON e.workspace=k.workspace AND e.id=k.edge_id
 CROSS JOIN slice_metadata s ON s.workspace=k.workspace AND s.asset_id=k.slice_id
 WHERE e.relation=7 AND ((e.source_type=1 AND e.source_id=k.slice_id) OR (e.target_type=1 AND e.target_id=k.slice_id))
 AND NOT(e.source_type=1 AND e.target_type=1 AND e.source_id=e.target_id))
 SELECT m.*,
 CASE WHEN t.status BETWEEN 0 AND 3 THEN t.status
 WHEN a.asset_type=5 THEN 5 WHEN a.asset_type=3 THEN 6 WHEN a.asset_type=13 THEN 7 ELSE -1 END AS category,
 coalesce(t.status!=4,0) AS work,coalesce(t.status!=4 AND t.blocked_by!=zeroblob(8),0) AS blocked,
 CASE WHEN t.status NOT IN (3,4) THEN nullif(t.created_at,0) END AS active_at,
 CASE WHEN t.status!=4 THEN max(0,t.updated_at)
 WHEN a.asset_type IN (5,3,13) THEN max(0,coalesce(n.updated_at,a.updated_at)) ELSE 0 END AS moved,
 CASE WHEN t.status!=4 THEN t.project WHEN a.asset_type=5 THEN coalesce(n.project,x'') ELSE x'' END AS project
 FROM endpoints m
 LEFT JOIN tasks t ON t.workspace=m.workspace AND t.id=CASE WHEN m.member_type=2 THEN m.member_id END
 LEFT JOIN assets a ON a.workspace=m.workspace AND a.id=CASE WHEN m.member_type=1 THEN m.member_id END
 LEFT JOIN note_metadata n ON n.workspace=m.workspace AND n.asset_id=CASE WHEN a.asset_type=5 THEN m.member_id END;
CREATE UNIQUE INDEX IF NOT EXISTS temp.nrc_slice_new_key ON nrc_slice_new(workspace,slice_id,edge_id);
-- Keep stable membership keys and their reverse indexes on ordinary edits.
DELETE FROM slice_members AS m WHERE (workspace,slice_id,edge_id) IN (SELECT * FROM nrc_slice_keys)
 AND NOT EXISTS(SELECT 1 FROM nrc_slice_new n WHERE n.workspace=m.workspace AND n.slice_id=m.slice_id
 AND n.edge_id=m.edge_id AND n.member_type=m.member_type AND n.member_id=m.member_id);
INSERT INTO slice_members SELECT * FROM nrc_slice_new WHERE true
 ON CONFLICT(workspace,slice_id,edge_id) DO UPDATE SET category=excluded.category,work=excluded.work,
 blocked=excluded.blocked,active_at=excluded.active_at,moved=excluded.moved,project=excluded.project
 WHERE category!=excluded.category OR work!=excluded.work OR blocked!=excluded.blocked
 OR active_at IS NOT excluded.active_at OR moved!=excluded.moved OR project!=excluded.project;

CREATE TEMP TABLE IF NOT EXISTS nrc_slice_delta(workspace BLOB,slice_id BLOB,member_type INTEGER,member_id BLOB,category INTEGER,work INTEGER,blocked INTEGER,project BLOB,sign INTEGER);
INSERT INTO nrc_slice_delta
 SELECT workspace,slice_id,member_type,member_id,category,work,blocked,project,-1 AS sign FROM nrc_slice_old
 UNION ALL SELECT m.workspace,m.slice_id,m.member_type,m.member_id,m.category,m.work,m.blocked,m.project,1
 FROM nrc_slice_keys k CROSS JOIN slice_members m
 ON m.workspace=k.workspace AND m.slice_id=k.slice_id AND m.edge_id=k.edge_id;
INSERT INTO slice_summaries(workspace,slice_id,backlog,todo,in_progress,done,blocked,notes,files,tickets,work)
 SELECT workspace,slice_id,sum(sign*(category=0)),sum(sign*(category=1)),sum(sign*(category=2)),sum(sign*(category=3)),
 sum(sign*blocked),sum(sign*(category=5)),sum(sign*(category=6)),sum(sign*(category=7)),sum(sign*work)
 FROM nrc_slice_delta WHERE true GROUP BY workspace,slice_id
 ON CONFLICT(workspace,slice_id) DO UPDATE SET backlog=backlog+excluded.backlog,todo=todo+excluded.todo,
 in_progress=in_progress+excluded.in_progress,done=done+excluded.done,blocked=blocked+excluded.blocked,
 notes=notes+excluded.notes,files=files+excluded.files,tickets=tickets+excluded.tickets,work=work+excluded.work
 WHERE excluded.backlog!=0 OR excluded.todo!=0 OR excluded.in_progress!=0 OR excluded.done!=0
 OR excluded.blocked!=0 OR excluded.notes!=0 OR excluded.files!=0 OR excluded.tickets!=0 OR excluded.work!=0;
INSERT INTO slice_summaries(workspace,slice_id)
 SELECT p.workspace,p.id FROM slice_pending p JOIN slice_metadata s ON s.workspace=p.workspace AND s.asset_id=p.id
 WHERE p.kind=4 ON CONFLICT DO NOTHING;
UPDATE slice_summaries AS s SET
 oldest=coalesce((SELECT active_at FROM slice_members m WHERE m.workspace=s.workspace AND m.slice_id=s.slice_id AND active_at IS NOT NULL ORDER BY active_at LIMIT 1),0),
 last_moved=coalesce((SELECT moved FROM slice_members m WHERE m.workspace=s.workspace AND m.slice_id=s.slice_id ORDER BY moved DESC LIMIT 1),0)
 WHERE (workspace,slice_id) IN (SELECT workspace,slice_id FROM nrc_slice_keys);
INSERT INTO slice_projects
 SELECT workspace,slice_id,project,sum(sign) FROM nrc_slice_delta WHERE length(project)>0 GROUP BY workspace,slice_id,project
 HAVING sum(sign)!=0
 ON CONFLICT(workspace,slice_id,project) DO UPDATE SET refs=refs+excluded.refs;
DELETE FROM slice_projects WHERE (workspace,slice_id,project) IN
 (SELECT workspace,slice_id,project FROM nrc_slice_delta WHERE length(project)>0) AND refs=0;

CREATE TEMP TABLE IF NOT EXISTS nrc_coverage_keys(workspace BLOB,task_id BLOB,PRIMARY KEY(workspace,task_id)) WITHOUT ROWID;
INSERT INTO nrc_coverage_keys SELECT workspace,member_id FROM nrc_slice_delta WHERE member_type=2 ON CONFLICT DO NOTHING;
INSERT INTO nrc_coverage_keys SELECT workspace,id FROM slice_pending WHERE kind=2 ON CONFLICT DO NOTHING;
CREATE TEMP TABLE IF NOT EXISTS nrc_coverage_delta(workspace BLOB,status INTEGER,sign INTEGER);
INSERT INTO nrc_coverage_delta
 SELECT c.workspace,c.status,-1 AS sign FROM nrc_coverage_keys k CROSS JOIN task_slice_coverage c
 ON c.workspace=k.workspace AND c.task_id=k.task_id;
CREATE TEMP TABLE IF NOT EXISTS nrc_coverage_new AS SELECT * FROM task_slice_coverage LIMIT 0;
INSERT INTO nrc_coverage_new
 SELECT k.workspace,k.task_id,t.status,count(*) FROM nrc_coverage_keys k
 CROSS JOIN tasks t ON t.workspace=k.workspace AND t.id=k.task_id
 CROSS JOIN slice_members m INDEXED BY slice_members_record ON m.workspace=k.workspace AND m.member_type=2 AND m.member_id=k.task_id
 WHERE m.work=1 GROUP BY k.workspace,k.task_id;
CREATE UNIQUE INDEX IF NOT EXISTS temp.nrc_coverage_new_key ON nrc_coverage_new(workspace,task_id);
DELETE FROM task_slice_coverage AS c WHERE (workspace,task_id) IN (SELECT * FROM nrc_coverage_keys)
 AND NOT EXISTS(SELECT 1 FROM nrc_coverage_new n WHERE n.workspace=c.workspace AND n.task_id=c.task_id);
INSERT INTO task_slice_coverage SELECT * FROM nrc_coverage_new WHERE true
 ON CONFLICT(workspace,task_id) DO UPDATE SET status=excluded.status,refs=excluded.refs
 WHERE status!=excluded.status OR refs!=excluded.refs;
INSERT INTO nrc_coverage_delta SELECT c.workspace,c.status,1 FROM nrc_coverage_keys k CROSS JOIN task_slice_coverage c
 ON c.workspace=k.workspace AND c.task_id=k.task_id;
INSERT INTO workspace_task_counts(workspace,status,covered)
 SELECT workspace,status,sum(sign) FROM nrc_coverage_delta WHERE true GROUP BY workspace,status
 HAVING sum(sign)!=0
 ON CONFLICT(workspace,status) DO UPDATE SET covered=covered+excluded.covered;
DELETE FROM slice_summaries WHERE (workspace,slice_id) IN
 (SELECT workspace,id FROM slice_pending WHERE kind=4) AND NOT EXISTS
 (SELECT 1 FROM slice_metadata m WHERE m.workspace=slice_summaries.workspace AND m.asset_id=slice_summaries.slice_id);
DELETE FROM slice_pending;
DELETE FROM nrc_slice_keys;
DELETE FROM nrc_slice_old;
DELETE FROM nrc_slice_new;
DELETE FROM nrc_slice_delta;
DELETE FROM nrc_coverage_keys;
DELETE FROM nrc_coverage_delta;
DELETE FROM nrc_coverage_new;
