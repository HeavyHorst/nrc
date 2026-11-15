package sqlite

import "core:testing"

@(test)
test_unsigned_keys_and_copied_blob_bindings :: proc(t: ^testing.T) {
	db: ^Database
	if !testing.expect_value(t, open_v2(":memory:", &db, OPEN_READWRITE | OPEN_CREATE, nil), OK) do return
	defer close(db)
	if !testing.expect_value(t, exec(db, "CREATE TABLE records(id BLOB PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil), OK) do return
	insert: ^Statement
	if !testing.expect_value(t, prepare_v2(db, "INSERT INTO records VALUES (?1, ?2)", -1, &insert, nil), OK) do return
	defer finalize(insert)
	keys := [7]u64{max(u64), 256, 0, u64(1) << 63, 255, 1, (u64(1) << 63) - 1}
	for key in keys {
		testing.expect_value(t, bind_id(insert, 1, key), OK)
		if key == 256 {
			bytes := [3]byte{7, 0, 251}
			testing.expect_value(t, bind_bytes(insert, 2, bytes[:]), OK)
			bytes[0] = 99 // SQLITE_TRANSIENT must already have copied the value.
		} else {
			testing.expect_value(t, bind_bytes(insert, 2, nil), OK)
		}
		testing.expect_value(t, step(insert), DONE)
		testing.expect_value(t, reset(insert), OK)
	}
	read: ^Statement
	if !testing.expect_value(t, prepare_v2(db, "SELECT id, value, typeof(value) FROM records ORDER BY id", -1, &read, nil), OK) do return
	defer finalize(read)
	for expected in ([7]u64{0, 1, 255, 256, (u64(1) << 63) - 1, u64(1) << 63, max(u64)}) {
		if !testing.expect_value(t, step(read), ROW) do return
		id, rc := column_id(read, 0)
		testing.expect_value(t, rc, OK)
		testing.expect_value(t, id, expected)
		testing.expect_value(t, string(column_bytes_view(read, 2)), "blob")
		value := column_bytes_view(read, 1)
		if expected == 256 {
			testing.expect_value(t, string(value), "\x07\x00\xfb")
		} else {
			testing.expect_value(t, len(value), 0)
		}
	}
	testing.expect_value(t, step(read), DONE)
}
