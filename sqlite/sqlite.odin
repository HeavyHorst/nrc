// Minimal SQLite C ABI. Every handle belongs to one DB executor; these calls
// are synchronous and must never run on a network worker.
package sqlite

import "core:c"
import "core:encoding/endian"

Database :: struct {}
Statement :: struct {}
Destructor :: #type proc "c" (_: rawptr)

OK :: c.int(0)
ERROR :: c.int(1)
BUSY :: c.int(5)
NOMEM :: c.int(7)
IOERR :: c.int(10)
CORRUPT :: c.int(11)
FULL :: c.int(13)
TOOBIG :: c.int(18)
CONSTRAINT :: c.int(19)
MISUSE :: c.int(21)
NOTADB :: c.int(26)
ROW :: c.int(100)
DONE :: c.int(101)

OPEN_READONLY :: c.int(0x00000001)
OPEN_READWRITE :: c.int(0x00000002)
OPEN_CREATE :: c.int(0x00000004)
OPEN_NOMUTEX :: c.int(0x00008000)

foreign import library "system:sqlite3"

@(default_calling_convention = "c", link_prefix = "sqlite3_")
foreign library {
	libversion_number :: proc() -> c.int ---
	open_v2 :: proc(filename: cstring, db: ^^Database, flags: c.int, vfs: cstring) -> c.int ---
	close :: proc(db: ^Database) -> c.int ---
	busy_timeout :: proc(db: ^Database, milliseconds: c.int) -> c.int ---
	db_status :: proc(db: ^Database, operation: c.int, current, high: ^c.int, reset: c.int) -> c.int ---
	errmsg :: proc(db: ^Database) -> cstring ---
	get_autocommit :: proc(db: ^Database) -> c.int ---
	exec :: proc(db: ^Database, sql: cstring, callback: rawptr, arg: rawptr, error_message: ^cstring) -> c.int ---
	prepare_v2 :: proc(db: ^Database, sql: cstring, length: c.int, statement: ^^Statement, tail: ^cstring) -> c.int ---
	step :: proc(statement: ^Statement) -> c.int ---
	finalize :: proc(statement: ^Statement) -> c.int ---
	reset :: proc(statement: ^Statement) -> c.int ---
	clear_bindings :: proc(statement: ^Statement) -> c.int ---
	bind_int64 :: proc(statement: ^Statement, index: c.int, value: i64) -> c.int ---
	bind_blob64 :: proc(statement: ^Statement, index: c.int, data: rawptr, length: u64, destroy: Destructor) -> c.int ---
	column_int64 :: proc(statement: ^Statement, column: c.int) -> i64 ---
	column_bytes :: proc(statement: ^Statement, column: c.int) -> c.int ---
	column_blob :: proc(statement: ^Statement, column: c.int) -> rawptr ---
}

// SQLite copies bindings before returning, including stack-allocated ID bytes.
// A non-null pointer is required to distinguish an empty BLOB from SQL NULL.
bind_bytes :: proc(statement: ^Statement, index: c.int, value: []byte) -> c.int {
	empty: byte
	data := len(value) == 0 ? rawptr(&empty) : rawptr(raw_data(value))
	return bind_blob64(statement, index, data, u64(len(value)), transmute(Destructor)(uintptr(max(uintptr))))
}

// Big-endian BLOB keys preserve all u64 bits and unsigned SQL ordering.
bind_id :: proc(statement: ^Statement, index: c.int, value: u64) -> c.int {
	bytes: [8]byte
	endian.put_u64(bytes[:], .Big, value)
	return bind_bytes(statement, index, bytes[:])
}

// Borrowed until the next step/reset/finalize of this statement.
column_bytes_view :: proc(statement: ^Statement, column: c.int) -> []byte {
	data := column_blob(statement, column)
	length := column_bytes(statement, column)
	return length == 0 ? nil : ([^]byte)(data)[:int(length)]
}

column_id :: proc(statement: ^Statement, column: c.int) -> (value: u64, status: c.int) {
	bytes := column_bytes_view(statement, column)
	if len(bytes) != 8 do return 0, CORRUPT
	value, _ = endian.get_u64(bytes, .Big)
	return value, OK
}
