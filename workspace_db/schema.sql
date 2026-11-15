-- Canonical workspace records. Byte fields are lossless BLOBs; every unsigned
-- ID is an eight-byte big-endian BLOB, including IDs above INT64_MAX.
CREATE TABLE sequences (
    domain TEXT PRIMARY KEY,
    high_water BLOB NOT NULL CHECK(length(high_water) = 8)
) STRICT, WITHOUT ROWID;
INSERT INTO sequences VALUES ('task', x'0000000000000000'),
                             ('asset', x'0000000000000000'),
                             ('edge', x'0000000000000000');

CREATE TABLE tasks (
    workspace BLOB NOT NULL CHECK(length(workspace) > 0),
    id BLOB NOT NULL CHECK(length(id) = 8 AND id != x'0000000000000000'),
    title BLOB NOT NULL,
    description BLOB NOT NULL,
    status INTEGER NOT NULL,
    order_index INTEGER NOT NULL,
    assignee BLOB NOT NULL,
    priority INTEGER NOT NULL,
    color INTEGER NOT NULL,
    created_by BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    external_ref BLOB NOT NULL,
    due_at INTEGER NOT NULL,
    blocked_by BLOB NOT NULL CHECK(length(blocked_by) = 8),
    completed_at INTEGER NOT NULL,
    completed_by BLOB NOT NULL,
    project BLOB NOT NULL,
    PRIMARY KEY (workspace, id)
) STRICT, WITHOUT ROWID;

CREATE TABLE task_attachments (
    workspace BLOB NOT NULL,
    task_id BLOB NOT NULL,
    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
    file_id BLOB NOT NULL,
    filename BLOB NOT NULL,
    size BLOB NOT NULL CHECK(length(size) = 8),
    mime_type BLOB NOT NULL,
    uploaded_at INTEGER NOT NULL,
    PRIMARY KEY (workspace, task_id, ordinal),
    FOREIGN KEY (workspace, task_id)
        REFERENCES tasks(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE INDEX tasks_column_order ON tasks(workspace, status, order_index);
CREATE INDEX tasks_updated ON tasks(workspace, updated_at, id);
-- TaskStatus.Done=3 uses completed_at in the public paging cursor.
CREATE INDEX tasks_page ON tasks(workspace, (CASE WHEN status=3 THEN completed_at ELSE updated_at END), id);
CREATE INDEX tasks_assignee ON tasks(workspace, assignee, status, id);
CREATE INDEX tasks_project ON tasks(workspace, project, status, id);
CREATE INDEX tasks_blocker ON tasks(workspace, blocked_by, id);
CREATE INDEX tasks_due ON tasks(workspace, due_at, id) WHERE due_at > 0;

CREATE TABLE assets (
    workspace BLOB NOT NULL CHECK(length(workspace) > 0),
    id BLOB NOT NULL CHECK(length(id) = 8 AND id != x'0000000000000000'),
    asset_type INTEGER NOT NULL,
    parent_type INTEGER NOT NULL,
    parent_id BLOB NOT NULL CHECK(length(parent_id) = 8),
    owner BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    payload_encoding INTEGER NOT NULL,
    payload_raw_len INTEGER NOT NULL,
    preview BLOB NOT NULL,
    payload BLOB NOT NULL,
    PRIMARY KEY (workspace, id)
) STRICT, WITHOUT ROWID;

-- Polymorphic parents and edge endpoints intentionally have no FK: historical
-- records may be dangling. Domain commands validate new links and cascade in
-- the same transaction; import preserves the historical post-images.
CREATE INDEX assets_parent ON assets(workspace, parent_type, parent_id, id);
CREATE INDEX assets_type_updated ON assets(workspace, asset_type, updated_at, id);
CREATE INDEX assets_owner ON assets(workspace, owner, asset_type, id);

CREATE TABLE asset_attachments (
    workspace BLOB NOT NULL,
    asset_id BLOB NOT NULL,
    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
    file_id BLOB NOT NULL,
    filename BLOB NOT NULL,
    size BLOB NOT NULL CHECK(length(size) = 8),
    mime_type BLOB NOT NULL,
    uploaded_at INTEGER NOT NULL,
    PRIMARY KEY (workspace, asset_id, ordinal),
    FOREIGN KEY (workspace, asset_id)
        REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX task_attachment_files ON task_attachments(file_id);
CREATE INDEX asset_attachment_files ON asset_attachments(file_id);

CREATE TABLE edges (
    workspace BLOB NOT NULL CHECK(length(workspace) > 0),
    id BLOB NOT NULL CHECK(length(id) = 8 AND id != x'0000000000000000'),
    source_type INTEGER NOT NULL,
    source_id BLOB NOT NULL CHECK(length(source_id) = 8),
    target_type INTEGER NOT NULL,
    target_id BLOB NOT NULL CHECK(length(target_id) = 8),
    relation INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    created_by BLOB NOT NULL,
    PRIMARY KEY (workspace, id)
) STRICT, WITHOUT ROWID;
CREATE INDEX edges_source ON edges(workspace, source_type, source_id, relation, id);
CREATE INDEX edges_target ON edges(workspace, target_type, target_id, relation, id);
-- Cursor reads span relations; seek directly by ID without sorting a full adjacency list.
CREATE INDEX edges_source_page ON edges(workspace, source_type, source_id, id);
CREATE INDEX edges_target_page ON edges(workspace, target_type, target_id, id);
-- MemberOf is an unordered set; other relations may repeat.
CREATE UNIQUE INDEX edges_membership ON edges (
    workspace,
    CASE WHEN source_type < target_type OR (source_type = target_type AND source_id < target_id) THEN source_type ELSE target_type END,
    CASE WHEN source_type < target_type OR (source_type = target_type AND source_id < target_id) THEN source_id ELSE target_id END,
    CASE WHEN source_type < target_type OR (source_type = target_type AND source_id < target_id) THEN target_type ELSE source_type END,
    CASE WHEN source_type < target_type OR (source_type = target_type AND source_id < target_id) THEN target_id ELSE source_id END
) WHERE relation = 7;

-- A zero membership mask is a durable revocation, not an absent conversation.
-- Message bodies and retained-message file generations are NOT stored here.
CREATE TABLE dm_conversations (
    workspace BLOB NOT NULL CHECK(length(workspace) > 0),
    id BLOB NOT NULL CHECK(length(id) = 8),
    user_a BLOB NOT NULL CHECK(length(user_a) > 0),
    user_b BLOB NOT NULL CHECK(length(user_b) > 0),
    members INTEGER NOT NULL CHECK(members BETWEEN 0 AND 3),
    CHECK(user_a < user_b AND length(user_a) + 1 + length(user_b) <= 512),
    PRIMARY KEY (workspace, id),
    UNIQUE (workspace, user_a, user_b)
) STRICT, WITHOUT ROWID;
CREATE INDEX dm_user_a ON dm_conversations(workspace, user_a, id) WHERE (members & 1) != 0;
CREATE INDEX dm_user_b ON dm_conversations(workspace, user_b, id) WHERE (members & 2) != 0;

-- Derived room-name lookup. Built-ins are constants, never materialized here.
CREATE TABLE room_mappings (
    workspace BLOB NOT NULL,
    name BLOB NOT NULL CHECK(length(name) BETWEEN 1 AND 32),
    conversation_id BLOB NOT NULL CHECK(length(conversation_id) = 8),
    asset_id BLOB NOT NULL,
    PRIMARY KEY (workspace, name),
    FOREIGN KEY (workspace, asset_id)
        REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
-- One canonical mapping asset supplies one name. Also indexes FK cascades
-- and projection cleanup by asset, without relying on planner statistics.
CREATE UNIQUE INDEX room_mapping_asset ON room_mappings(workspace, asset_id);

-- Event IDs are workspace-local and survive record deletion.
CREATE TABLE history_sequences (
    workspace BLOB PRIMARY KEY,
    high_water BLOB NOT NULL CHECK(length(high_water) = 8)
) STRICT, WITHOUT ROWID;
CREATE TABLE history (
    workspace BLOB NOT NULL,
    id BLOB NOT NULL CHECK(length(id) = 8),
    entity_kind INTEGER NOT NULL,
    entity_id BLOB NOT NULL CHECK(length(entity_id) = 8),
    body BLOB NOT NULL,
    private_owner BLOB NOT NULL DEFAULT x'',
    source_kind INTEGER NOT NULL DEFAULT 0,
    source_id BLOB NOT NULL DEFAULT x'0000000000000000' CHECK(length(source_id) = 8),
    target_kind INTEGER NOT NULL DEFAULT 0,
    target_id BLOB NOT NULL DEFAULT x'0000000000000000' CHECK(length(target_id) = 8),
    PRIMARY KEY (workspace, id)
) STRICT, WITHOUT ROWID;

CREATE INDEX history_entity ON history(workspace, entity_kind, entity_id, id);
CREATE INDEX history_source ON history(workspace, source_kind, source_id, id);
CREATE INDEX history_target ON history(workspace, target_kind, target_id, id);

-- Rebuildable query projections, populated by the same Odin parsers as writes.
-- Do not use SQLite JSON extraction: legacy fallback/typing, Zstd and visibility
-- rules differ by asset type. Absence means the type-specific parser rejected
-- the record, not that the canonical asset may be discarded.
CREATE TABLE note_metadata (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    project BLOB NOT NULL, updated_at INTEGER NOT NULL,
    PRIMARY KEY (workspace, asset_id),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX note_project_order ON note_metadata(workspace, project, updated_at, asset_id);
CREATE TABLE note_tags (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    tag BLOB NOT NULL, updated_at INTEGER NOT NULL,
    PRIMARY KEY (workspace, asset_id, tag),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX note_tag_order ON note_tags(workspace, tag, updated_at, asset_id);

CREATE TABLE reminder_metadata (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    personal INTEGER NOT NULL CHECK(personal IN (0,1)),
    deadline INTEGER NOT NULL, title BLOB NOT NULL,
    PRIMARY KEY (workspace, asset_id),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX reminder_deadline ON reminder_metadata(workspace, deadline, asset_id) WHERE deadline > 0;

-- Recurrences stay compact in the canonical preview. The envelope includes
-- exceptions; bounded occurrence expansion happens after the indexed seek.
CREATE TABLE appointment_metadata (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    bucket INTEGER NOT NULL, slot INTEGER NOT NULL,
    start_at INTEGER NOT NULL, end_at INTEGER NOT NULL,
    assignee BLOB NOT NULL, project BLOB NOT NULL,
    PRIMARY KEY (workspace, asset_id),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX appointment_interval ON appointment_metadata(workspace, bucket, slot, start_at, asset_id);
CREATE TABLE appointment_people (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    person BLOB NOT NULL,
    PRIMARY KEY (workspace, asset_id, person),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX appointment_person ON appointment_people(workspace, person, asset_id);

CREATE TABLE slice_metadata (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    name BLOB NOT NULL, owner BLOB NOT NULL, outcome BLOB NOT NULL,
    closed INTEGER NOT NULL CHECK(closed IN (0,1)),
    closed_at INTEGER NOT NULL, closed_by BLOB NOT NULL,
    PRIMARY KEY (workspace, asset_id),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX slice_owner ON slice_metadata(workspace, owner, asset_id);

CREATE TABLE customer_metadata (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    title BLOB NOT NULL, search_text BLOB NOT NULL,
    archived INTEGER NOT NULL CHECK(archived IN (0,1)),
    active_contact INTEGER NOT NULL CHECK(active_contact IN (0,1)),
    email BLOB NOT NULL,
    PRIMARY KEY (workspace, asset_id),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX customer_title ON customer_metadata(workspace, title, asset_id);

CREATE TABLE ticket_metadata (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    title BLOB NOT NULL, status BLOB NOT NULL, assignee BLOB NOT NULL,
    company_id BLOB NOT NULL, contact_id BLOB NOT NULL,
    requester BLOB NOT NULL, requester_name BLOB NOT NULL, priority BLOB NOT NULL,
    follow_up_at INTEGER NOT NULL,
    PRIMARY KEY (workspace, asset_id),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX ticket_assignee ON ticket_metadata(workspace, assignee, asset_id);
CREATE INDEX ticket_status ON ticket_metadata(workspace, status, asset_id);
CREATE INDEX ticket_follow_up ON ticket_metadata(workspace, follow_up_at, asset_id);
CREATE TABLE ticket_entry_metadata (
    workspace BLOB NOT NULL, asset_id BLOB NOT NULL,
    ticket_id BLOB NOT NULL CHECK(length(ticket_id) = 8),
    kind BLOB NOT NULL, created_at INTEGER NOT NULL,
    PRIMARY KEY (workspace, asset_id),
    FOREIGN KEY (workspace, asset_id) REFERENCES assets(workspace, id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX ticket_entry_kind ON ticket_entry_metadata(workspace, ticket_id, kind, asset_id);
CREATE INDEX ticket_entry_time ON ticket_entry_metadata(workspace, ticket_id, created_at, asset_id);

PRAGMA application_id = 0x4e524351;
PRAGMA user_version = 1;
