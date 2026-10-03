//
// connection.odin - WebSocket Connection Management
//
// This file handles WebSocket connection lifecycle management including:
// - Connection state definitions and tracking
// - Connection closing logic with proper cleanup
// - Subscription cleanup on disconnection
// - Connection timeout and activity monitoring constants
// - Flow control limits for send operations
//
package main

import "core:container/queue"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:sys/linux"
import "core:time"

import "base:intrinsics"
import "base:runtime"

import "byte_pool"
import hm "core:container/handle_map"
import nbio "nbio/poly"
import pr "protocol"
import "spsc"

// Connection_Handle is a generational handle referencing a specific connection instance.
Connection_Handle :: hm.Handle64

// Connection_Map manages the memory lifecycle of connections, ensuring pointers
// stay stable while properly handling ABA problems during socket reuse.
Connection_Map :: hm.Dynamic_Handle_Map(NRC_Connection, Connection_Handle)

@(thread_local)
connection_storage_initialized: bool

// connection_storage_init initializes the thread-local connection handle map.
connection_storage_init :: proc() {
	if connection_storage_initialized {
		return
	}
	hm.dynamic_init(&td.connections_by_handle, worker_backing_allocator())
	td.retained_connection_count = 0
	connection_storage_initialized = true
}

// connection_storage_destroy cleans up the thread-local connection handle map.
connection_storage_destroy :: proc() {
	if !connection_storage_initialized {
		return
	}
	assert(len(td.inflight_send_handles) == 0, "destroying connection storage with indexed in-flight sends")
	hm.dynamic_destroy(&td.connections_by_handle)
	td.connections_by_handle = {}
	td.connection_handles = {}
	td.retained_connection_count = 0
	connection_storage_initialized = false
}

// connection_alloc allocates a new connection instance and returns its pointer.
connection_alloc :: proc() -> (^NRC_Connection, bool) {
	connection_storage_init()
	handle, err := hm.add(&td.connections_by_handle, NRC_Connection{})
	if err != .None {
		return nil, false
	}
	conn := connection_get_by_handle(handle)
	conn.handle = handle
	td.retained_connection_count += 1
	return conn, true
}

// connection_remove destroys the connection allocation and clears the socket mapping.
connection_remove :: proc(conn: ^NRC_Connection) {
	if conn == nil {
		return
	}
	assert(conn.send_watchdog_slot == 0, "removing connection still indexed by send watchdog")
	if td.connection_handles[conn.sock] == conn.handle {
		connection_clear_socket_handle(conn.sock)
	}
	_, _ = hm.remove(&td.connections_by_handle, conn.handle)
	assert(td.retained_connection_count > 0)
	td.retained_connection_count -= 1
}

// connection_get_by_handle retrieves a connection pointer by its generational handle.
connection_get_by_handle :: #force_inline proc "contextless" (handle: Connection_Handle) -> ^NRC_Connection {
	conn, ok := hm.get(&td.connections_by_handle, handle)
	if !ok {
		return nil
	}
	return conn
}

send_watchdog_track :: proc(c: ^NRC_Connection) {
	if c.send_watchdog_slot != 0 {
		index := int(c.send_watchdog_slot - 1)
		assert(index < len(td.inflight_send_handles) && td.inflight_send_handles[index] == c.handle, "send watchdog slot mismatch")
		return
	}

	append(&td.inflight_send_handles, c.handle)
	c.send_watchdog_slot = u32(len(td.inflight_send_handles))
}

send_watchdog_started :: proc(c: ^NRC_Connection, started_at: time.Time) {
	c.is_sending = true
	c.send_started_at = started_at
	send_watchdog_track(c)

	deadline := time.time_add(started_at, Conn_Send_Timeout)
	if td.next_send_watchdog_at == {} || time.diff(deadline, td.next_send_watchdog_at) > 0 {
		td.next_send_watchdog_at = deadline
	}
}

send_watchdog_untrack :: proc(c: ^NRC_Connection) {
	if c == nil || c.send_watchdog_slot == 0 do return

	index := int(c.send_watchdog_slot - 1)
	last_index := len(td.inflight_send_handles) - 1
	assert(index >= 0 && index <= last_index, "send watchdog slot out of bounds")
	assert(td.inflight_send_handles[index] == c.handle, "send watchdog handle mismatch")

	c.send_watchdog_slot = 0
	if index != last_index {
		moved_handle := td.inflight_send_handles[last_index]
		td.inflight_send_handles[index] = moved_handle
		moved := connection_get_by_handle(moved_handle)
		assert(moved != nil, "send watchdog contains stale handle")
		if moved != nil {
			moved.send_watchdog_slot = u32(index + 1)
		}
	}
	pop(&td.inflight_send_handles)
}

// connection_get retrieves the active connection pointer for a given socket FD.
connection_get :: #force_inline proc "contextless" (sock: net.TCP_Socket) -> ^NRC_Connection {
	return connection_get_by_handle(td.connection_handles[sock])
}

// connection_set_socket_handle associates a socket FD with a connection handle.
connection_set_socket_handle :: #force_inline proc "contextless" (sock: net.TCP_Socket, handle: Connection_Handle) {
	td.connection_handles[sock] = handle
}

// connection_clear_socket_handle removes the handle association for a socket FD.
connection_clear_socket_handle :: #force_inline proc "contextless" (sock: net.TCP_Socket) {
	td.connection_handles[sock] = {}
}

// Detach only this generation; a late close must not remove a replacement FD.
connection_detach_socket :: proc(conn: ^NRC_Connection) {
	if td.connection_handles[conn.sock] != conn.handle do return
	connection_clear_socket_handle(conn.sock)
	if td.connection_count > 0 do td.connection_count -= 1
	delete_key(&td.active_sockets, conn.sock)
}

Connection_IO_Context :: struct {
	sock:   net.TCP_Socket,
	handle: Connection_Handle,
	pinned: bool,
}

connection_io_context_make :: #force_inline proc "contextless" (conn: ^NRC_Connection) -> Connection_IO_Context {
	return Connection_IO_Context{sock = conn.sock, handle = conn.handle}
}

connection_io_pin :: #force_inline proc "contextless" (conn: ^NRC_Connection) -> bool {
	if conn == nil || conn.state >= .Closing {
		return false
	}
	conn.pending_io += 1
	return true
}

connection_io_unpin :: proc(ctx: Connection_IO_Context) {
	if !ctx.pinned do return
	conn := connection_from_io_context(ctx)
	assert(conn != nil, "pinned I/O context must retain its connection handle")
	if conn == nil do return
	assert(conn.pending_io > 0, "pinned I/O context must own a pending_io reference")
	if conn.pending_io == 0 do return
	conn.pending_io -= 1
	connection_try_submit_close(conn)
	connection_try_reclaim(conn)
}

connection_from_io_context :: proc(ctx: Connection_IO_Context) -> ^NRC_Connection {
	conn := connection_get_by_handle(ctx.handle)
	if conn == nil || conn.sock != ctx.sock {
		return nil
	}
	return conn
}

// =============================================================================
// BATCH SEND SYSTEM
// =============================================================================
//
// Hybrid send strategy with adaptive batching based on queue depth:
//
//   | Condition          | Strategy                      | Syscall  |
//   |--------------------|-------------------------------|----------|
//   | Queue < 2 items    | Single send                   | send()   |
//   | Queue >= 2 items   | Batch up to 256 items (2MB)   | writev() |
//
// Rationale: io_uring's IORING_OP_WRITEV has the same submission cost regardless
// of iovec count, so batching 2+ items saves syscalls with negligible overhead.
// Batch metadata is allocated as one contiguous block and is reused from a
// thread-local classed pool (with heap fallback only when needed).
//
//
//                         SEND FLOW
//                         =========
//
//   websocket_send_all(conn, buf, ctx, callback)
//                 |
//                 v
//         +-------------------+
//         | Queue empty AND   |--Yes--> Direct send_all()
//         | not sending?      |         (bypass queue)
//         +-------------------+
//                 | No
//                 v
//         +-------------------+
//         |  Push to queue    |
//         |  (inline or heap) |
//         +-------------------+
//
//
//               QUEUE PROCESSING
//               ================
//
//   pump_outbox(conn)
//                 |
//                 v
//         +-------------------+
//         | Queue depth >= 2? |
//         +-------------------+
//            |           |
//           Yes          No
//            |           |
//            v           v
//     +-------------+  +-------------+
//     | send_batch  |  | Single send |
//     |  (writev)   |  |  send_all() |
//     +-------------+  +-------------+
//
//
//                 BATCH STATE SOURCE
//                 ==================
//
//   send_batch(count)
//        |
//        v
//   +-----------------------------+
//   | batch_pool_pop(class)       |
//   |   hit  -> reuse cached      |
//   |   miss -> alloc one block   |
//   |           (or heap fallback)|
//   +-----------------------------+
//                |
//                v
//
//                 BATCH BLOCK LAYOUT (single alloc)
//                 ==================================
//
//   +-----------------------------------------------------+
//   | Batch_Send_State | Batch_Item[N] |   iovec[N]       |
//   |     (header)     |   (items)     | (scatter-gather) |
//   |     24 bytes     |   N x 32B     |    N x 16B       |
//   +-----------------------------------------------------+
//                            |
//                            v
//
//                 WRITEV SYSCALL
//                 ==============
//
//   +----------------------------------------------------------+
//   |                     io_uring SQE                         |
//   |  +-----------------------------------------------------+ |
//   |  | opcode: IORING_OP_WRITEV                            | |
//   |  | fd: socket                                          | |
//   |  | iov: ----------------------------------------+      | |
//   |  +---------------------------------------------|-------+ |
//   +-------------------------------------------------|--------+
//                                                     |
//                                                     v
//   +----------------------------------------------------------+
//   |                    iovec array                           |
//   |  +---------+  +---------+  +---------+     +---------+   |
//   |  | iov[0]  |  | iov[1]  |  | iov[2]  | ... | iov[N]  |   |
//   |  | base,len|  | base,len|  | base,len|     | base,len|   |
//   |  +----+----+  +----+----+  +----+----+     +----+----+   |
//   +-------|------------|------------|--------------|--------+
//           |            |            |              |
//           v            v            v              v
//        +------+     +------+     +------+       +------+
//        | Buf0 |     | Buf1 |     | Buf2 |       | BufN |
//        | (WS  |     | (WS  |     | (WS  |       | (WS  |
//        |frame)|     |frame)|     |frame)|       |frame)|
//        +------+     +------+     +------+       +------+
//
//         ------------ Single writev syscall ------------
//                          to kernel
//                             |
//                             v
//                       +-----------+
//                       |  Socket   |
//                       |  (TCP)    |
//                       +-----------+
//
//
//                 COMPLETION CALLBACK
//                 ===================
//
//   on_batch_send_complete(sock, state, sent, err)
//                 |
//                 v
//         +-------------------+
//         | For each item:    |
//         |  - Call callback  |<--- Buffer cleanup
//         |  - Re-check conn  |<--- May close mid-batch
//         +-------------------+
//                 |
//                 v
//         +-------------------+
//         | free_batch_state  |<--- return to pool (or free on overflow/fallback)
//         +-------------------+
//                 |
//                 v
//         +-------------------+
//         | More in queue?    |--Yes--> pump_outbox()
//         +-------------------+
//
//
// Design benefits:
//   1. Amortized syscall overhead - N messages in 1 syscall vs N syscalls
//   2. Reused metadata blocks - avoids repeated heap alloc/free on hot path
//   3. Zero-copy references - iovec points directly to existing buffers
//   4. Inline queue - first 16 items avoid heap entirely (hot path)
//   5. Prefetch hints - hides cache latency when processing queue
//
// =============================================================================

// Batch send configuration constants
Batch_Queue_Threshold :: 2 // Start batching when queue depth >= this (writev overhead ~= send)
Max_Batch_Size :: 512 // Max items per batch
Max_Batch_Bytes :: 2 * 1024 * 1024 // 2MB max total batch size

Batch_Pool_Class_Count :: 8
Batch_Pool_Small_Class_Max_Free :: 8192

// Track batch state during writev operation
Batch_Item :: struct {
	handle:   Connection_Handle,
	lease:    Frame_Lease,
	action:   Send_Completion_Action,
	observer: Send_Completion_Observer,
}

// Batch send state - single allocation pattern
// Layout: [Batch_Send_State header][items array][iovec array]
Batch_Send_State :: struct {
	items:       []Batch_Item, // Slice into trailing buffer
	iovec:       []nbio.iovec, // Slice into trailing buffer
	items_base:  ^Batch_Item,
	iovec_base:  ^nbio.iovec,
	total_bytes: int, // Total bytes in batch
	count:       int, // Number of items in batch
	capacity:    int,
	pool_class:  int, // -1 = heap fallback, otherwise class index in Batch_Pool_Class_Capacities
	io_pinned:   bool, // This submitted writev owns one connection pending_io reference
}

Batch_State_Pool :: struct {
	free_lists:           [Batch_Pool_Class_Count][dynamic]^Batch_Send_State,
	pooled_allocations:   u64,
	pooled_reuses:        u64,
	pooled_releases:      u64,
	pooled_drops:         u64,
	heap_fallback_allocs: u64,
	heap_fallback_frees:  u64,
}

// Maps a requested batch item count to a pool class index.
// Returns -1 when the request exceeds pooled capacity and must use heap fallback.
batch_pool_class_for_count :: proc(count: int) -> int {
	if count <= 0 {
		return 0
	}
	for i in 0 ..< Batch_Pool_Class_Count {
		if count <= batch_pool_class_capacity(i) {
			return i
		}
	}
	return -1
}

// Capacity for each class index. We use powers of two so nearby request sizes
// share reusable slabs while keeping internal waste bounded.
batch_pool_class_capacity :: proc(class: int) -> int {
	switch class {
	case 0:
		return 2
	case 1:
		return 4
	case 2:
		return 8
	case 3:
		return 16
	case 4:
		return 32
	case 5:
		return 64
	case 6:
		return 128
	case 7:
		return 256
	}
	return 0
}

// Maximum free-list size per class.
// Smaller classes are used for short queue bursts (the common case), so we keep
// a deeper cache there to avoid alloc/free churn under sustained broadcast load;
// after class 1, doubling block capacity halves the number retained.
batch_pool_max_free_for_class :: proc(class: int) -> int {
	if class < 0 || class >= Batch_Pool_Class_Count {
		return 0
	}
	return Batch_Pool_Small_Class_Max_Free >> uint(max(class - 1, 0))
}

// Initializes one free-list per class. Lists are LIFO to improve cache locality
// by reusing the most recently returned batch-state blocks first.
init_batch_state_pool :: proc() {
	context.allocator = worker_backing_allocator()
	for i in 0 ..< Batch_Pool_Class_Count {
		td.batch_state_pool.free_lists[i] = make([dynamic]^Batch_Send_State, 0, 32)
	}
}

// Frees all cached blocks during thread shutdown.
destroy_batch_state_pool :: proc() {
	context.allocator = worker_backing_allocator()
	for i in 0 ..< Batch_Pool_Class_Count {
		free_list := td.batch_state_pool.free_lists[i]
		for state in free_list {
			free(state)
		}
		delete(td.batch_state_pool.free_lists[i])
		td.batch_state_pool.free_lists[i] = nil
	}
}

// Allocates one contiguous block for metadata used by writev batching.
// Layout: [Batch_Send_State][Batch_Item * capacity][iovec * capacity]
// `items_base`/`iovec_base` are stored so reused states can restore full slices.
alloc_batch_state_block :: proc(capacity: int, pool_class: int) -> ^Batch_Send_State {
	context.allocator = worker_backing_allocator()
	total_size := size_of(Batch_Send_State) + capacity * size_of(Batch_Item) + capacity * size_of(nbio.iovec)

	block, _ := mem.alloc_bytes(total_size)
	if len(block) == 0 {
		return nil
	}

	state := (^Batch_Send_State)(raw_data(block))
	offset := size_of(Batch_Send_State)

	items_ptr := (^Batch_Item)(raw_data(block[offset:]))
	state.items_base = items_ptr
	state.items = mem.slice_ptr(items_ptr, capacity)
	offset += capacity * size_of(Batch_Item)

	iovec_ptr := (^nbio.iovec)(raw_data(block[offset:]))
	state.iovec_base = iovec_ptr
	state.iovec = mem.slice_ptr(iovec_ptr, capacity)

	state.capacity = capacity
	state.pool_class = pool_class
	state.count = 0
	state.total_bytes = 0
	state.io_pinned = false
	return state
}

// Fast-path pooled acquire. Restores full slices because previous use truncates
// items/iovec to actual batch count before submit.
batch_pool_pop :: proc(class: int) -> ^Batch_Send_State {
	if class < 0 || class >= Batch_Pool_Class_Count {
		return nil
	}

	free_list := &td.batch_state_pool.free_lists[class]
	if len(free_list^) == 0 {
		return nil
	}

	last := len(free_list^) - 1
	state := free_list^[last]
	resize(free_list, last)

	state.items = mem.slice_ptr(state.items_base, state.capacity)
	state.iovec = mem.slice_ptr(state.iovec_base, state.capacity)
	state.count = 0
	state.total_bytes = 0
	state.io_pinned = false
	td.batch_state_pool.pooled_reuses += 1
	return state
}

// Returns state to class free-list. If the list is full, caller frees the state.
batch_pool_push :: proc(class: int, state: ^Batch_Send_State) -> bool {
	if class < 0 || class >= Batch_Pool_Class_Count {
		return false
	}

	free_list := &td.batch_state_pool.free_lists[class]
	if len(free_list^) >= batch_pool_max_free_for_class(class) {
		td.batch_state_pool.pooled_drops += 1
		return false
	}

	td.batch_state_pool.pooled_releases += 1
	append(free_list, state)
	return true
}

// Allocate a batch state with items and iovec arrays in a single allocation
alloc_batch_state :: proc(count: int) -> ^Batch_Send_State {
	class := batch_pool_class_for_count(count)

	if class >= 0 {
		if state := batch_pool_pop(class); state != nil {
			return state
		}

		state := alloc_batch_state_block(batch_pool_class_capacity(class), class)
		if state != nil {
			td.batch_state_pool.pooled_allocations += 1
			return state
		}
	}

	// Fallback for oversize requests or pool allocation failure.
	fallback_count := count
	if fallback_count <= 0 {
		fallback_count = 1
	}

	state := alloc_batch_state_block(fallback_count, -1)
	if state != nil {
		td.batch_state_pool.heap_fallback_allocs += 1
	}
	return state
}

// Free batch state (single free for entire allocation)
free_batch_state :: proc(state: ^Batch_Send_State) {
	if state == nil do return
	context.allocator = worker_backing_allocator()
	if state.pool_class < 0 || state.pool_class >= Batch_Pool_Class_Count {
		td.batch_state_pool.heap_fallback_frees += 1
		free(state)
		return
	}

	if !batch_pool_push(state.pool_class, state) {
		free(state)
	}
}

// How long to wait before actually closing a connection.
// This is to make sure the client can fully receive the response.
Conn_Close_Delay :: time.Millisecond * #config(NRC_CONN_CLOSE_DELAY_MS, 50)
Conn_Send_Timeout :: time.Second * 10

// Idle connection timeout - close connections with no activity for this duration
Idle_Timeout :: time.Millisecond * #config(NRC_IDLE_TIMEOUT_MS, 90_000)

// Heartbeat check interval - how often to check for idle connections
Heartbeat_Interval_MS :: #config(NRC_HEARTBEAT_INTERVAL_MS, 30_000)
Heartbeat_Interval :: time.Millisecond * Heartbeat_Interval_MS
Worker_Maintenance_Interval_MS :: 100
Worker_Maintenance_Interval :: time.Millisecond * Worker_Maintenance_Interval_MS
Idle_Scan_Slices :: max(1, Heartbeat_Interval_MS / Worker_Maintenance_Interval_MS)
Idle_Scan_Slots_Per_Tick :: (MAX_SOCK_FD + Idle_Scan_Slices - 1) / Idle_Scan_Slices

// Maximum items in the send queue before dropping connection
Max_Queue_Size :: #config(NRC_MAX_QUEUE_SIZE, 512)

// Inline queue optimization: first N items stored inline to avoid heap access
// 16 items = 16 * 32 bytes = 512 bytes (8 cache lines, still L1-friendly)
Inline_Queue_Size :: 16

// =============================================================================
// INLINE QUEUE OPERATIONS
// =============================================================================
// These functions manage the hybrid inline+spill queue for send operations.
// The inline portion avoids heap pointer chasing for the common case (<=16 items).

// Returns total number of queued items using the cached depth counter.
// This avoids touching inline/spill queue structures on broadcast fanout checks.
send_queue_len :: #force_inline proc(c: ^NRC_Connection) -> int {
	return int(c.queued_count)
}

send_queue_normal_len :: #force_inline proc(c: ^NRC_Connection) -> int {
	return int(c.queued_count) - queue.len(c.priority_queue)
}

send_queue_priority_len :: #force_inline proc(c: ^NRC_Connection) -> int {
	return queue.len(c.priority_queue)
}

// Push an item to the send queue (inline first, spill to heap if full)
// IMPORTANT: If spill queue has items, we must push to spill to maintain FIFO order
send_queue_push :: proc(c: ^NRC_Connection, item: Send_Item) {
	if c.inline_len < Inline_Queue_Size && queue.len(c.spill_queue) == 0 {
		// Space in inline queue AND no spill items - safe to push inline
		tail := (c.inline_head + c.inline_len) % Inline_Queue_Size
		c.inline_queue[tail] = item
		c.inline_len += 1
	} else {
		// Either inline full OR spill has items - must push to spill for FIFO
		queue.push_back(&c.spill_queue, item)
	}
	c.queued_count += 1
}

// Push an item to the priority control queue.
// Priority items preserve FIFO order among themselves but are drained before
// normal queued fanout frames once the current in-flight send completes.
send_queue_push_priority :: proc(c: ^NRC_Connection, item: Send_Item) {
	queue.push_back(&c.priority_queue, item)
	c.queued_count += 1
}

// Pop an item from the front of the send queue
// Returns the item. Caller must check send_queue_len() > 0 before calling.
send_queue_pop :: #force_inline proc(c: ^NRC_Connection) -> Send_Item {
	if queue.len(c.priority_queue) > 0 {
		return send_queue_pop_priority(c)
	}

	return send_queue_pop_normal(c)
}

// Pop an item from the normal queue. Caller must ensure normal queue is non-empty.
send_queue_pop_normal :: #force_inline proc(c: ^NRC_Connection) -> Send_Item {
	if c.inline_len > 0 {
		// Pop from inline queue
		item := c.inline_queue[c.inline_head]
		c.inline_head = (c.inline_head + 1) % Inline_Queue_Size
		c.inline_len -= 1
		c.queued_count -= 1

		// If inline is now empty and spill has items, refill inline from spill
		// This keeps hot items in the inline portion
		if c.inline_len == 0 && queue.len(c.spill_queue) > 0 {
			refill_count := min(queue.len(c.spill_queue), int(Inline_Queue_Size))
			c.inline_head = 0
			for i in 0 ..< refill_count {
				c.inline_queue[i] = queue.pop_front(&c.spill_queue)
			}
			c.inline_len = u8(refill_count)
		}

		return item
	}

	// Inline empty, pop from spill queue
	item := queue.pop_front(&c.spill_queue)
	c.queued_count -= 1
	return item
}

send_queue_pop_priority :: #force_inline proc(c: ^NRC_Connection) -> Send_Item {
	c.queued_count -= 1
	return queue.pop_front(&c.priority_queue)
}

// Peek at the front item without removing it (for prefetching)
// Returns nil if queue is empty
send_queue_peek :: #force_inline proc(c: ^NRC_Connection) -> ^Send_Item {
	if queue.len(c.priority_queue) > 0 {
		return queue.front_ptr(&c.priority_queue)
	}

	return send_queue_peek_normal(c)
}

send_queue_peek_normal :: #force_inline proc(c: ^NRC_Connection) -> ^Send_Item {
	if c.inline_len > 0 {
		return &c.inline_queue[c.inline_head]
	}
	if queue.len(c.spill_queue) > 0 {
		return queue.front_ptr(&c.spill_queue)
	}
	return nil
}

// Initialize the spill queue (call during connection setup)
send_queue_init :: proc(c: ^NRC_Connection) {
	c.inline_head = 0
	c.inline_len = 0
	c.queued_count = 0
	queue.init(&c.priority_queue)
	queue.init(&c.spill_queue)
}

// Drain queued send items and invoke callbacks so pooled buffers and shared
// ref-counts are released even when the connection closes mid-queue.
send_queue_drain :: proc(c: ^NRC_Connection) {
	for send_queue_len(c) > 0 {
		item := send_queue_pop(c)
		frame_lease_dispose(&item.lease)
	}
}

// Destroy the spill queue (call during connection cleanup)
send_queue_destroy :: proc(c: ^NRC_Connection) {
	send_queue_drain(c)
	queue.destroy(&c.priority_queue)
	queue.destroy(&c.spill_queue)
}

// Prefetch a connection pointer from the connections array.
// Call this early in hot path callbacks, then do other work before accessing the connection.
// The CPU will fetch the cache line in parallel with other operations.
// Locality 3 = keep in all cache levels (T0), high temporal locality.
prefetch_connection :: #force_inline proc "contextless" (sock: net.TCP_Socket) {
	intrinsics.prefetch_read_data(&td.connection_handles[sock], 3)
	if conn := connection_get(sock); conn != nil {
		intrinsics.prefetch_read_data(conn, 3)
	}
}

Connection_State :: enum {
	Pending, // Pending a client to attach.
	New, // Got client, waiting to service first request.
	Active, // Servicing request.
	Idle, // Waiting for next request.
	Will_Close, // Closing after the current response is sent.
	Closing, // Going to close, cleaning up.
	Closed, // Fully closed.
}

// Main-to-worker ownership transfer for an HTTP upgrade. The target worker
// validates authentication and sends HTTP 101 before creating NRC_Connection.
Pending_Connection :: struct {
	upgrade: ^HTTP_Upgrade_Connection,
}

// Main is the sole producer; the owning worker is the sole consumer. Shutdown
// transfers consumer ownership to Main after the wait group synchronizes with
// the worker's completion, when it can no longer access the queue.
Pending_Connection_Queue :: struct {
	ring:           ^spsc.Queue(Pending_Connection),
	wake_fd:        linux.Fd, // Wakes an idle worker's nbio tick after a cross-thread commit.
	wake_pending:   ^bool, // Shared across queue handle copies; true while one wake covers queued work.
	wake_allocator: runtime.Allocator,
	wake_ready:     bool,
}

pending_queue_create :: proc(capacity: int) -> (queue: Pending_Connection_Queue, allocator_error: runtime.Allocator_Error) {
	wake_allocator := context.allocator
	wake_pending := new(bool, wake_allocator) or_return
	ring, err := spsc.create(Pending_Connection, capacity, wake_allocator)
	if err != .None {
		free(wake_pending, wake_allocator)
		return {}, err
	}

	wake_fd, wake_err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if wake_err != .NONE {
		free(wake_pending, wake_allocator)
		spsc.destroy(ring)
		return {}, .Out_Of_Memory
	}
	return Pending_Connection_Queue{ring = ring, wake_fd = wake_fd, wake_pending = wake_pending, wake_allocator = wake_allocator, wake_ready = true}, .None
}

pending_queue_destroy :: proc(q: Pending_Connection_Queue) {
	spsc.destroy(q.ring)
	if q.wake_ready do linux.close(q.wake_fd)
	free(q.wake_pending, q.wake_allocator)
}

// Main is the sole producer and prepares each handoff synchronously. After this
// check, only the consumer can change capacity until Main publishes the item.
// This is not a reservation and must not span asynchronous work.
pending_queue_can_send :: proc(q: Pending_Connection_Queue) -> bool {
	return spsc.can_push(q.ring)
}

pending_queue_signal :: proc(q: Pending_Connection_Queue) {
	if !q.wake_ready || q.wake_pending == nil do return
	if sync.atomic_exchange(q.wake_pending, true) do return
	value := u64(1)
	for {
		_, err := linux.write(q.wake_fd, ([^]byte)(&value)[:size_of(value)])
		if err == .EINTR do continue
		// EAGAIN means the eventfd counter is saturated and therefore already
		// readable; the worker cannot miss this wakeup.
		if err != .NONE && err != .EAGAIN {
			log.warnf("Failed to wake pending-connection worker (errno: %v)", err)
		}
		return
	}
}

// Allow the next producer to wake the worker after a drain. Checking the queue
// after clearing closes the race with a producer that published while the old
// wake was still marked pending and therefore did not write to the eventfd.
pending_queue_rearm_wake :: proc(q: Pending_Connection_Queue) {
	if !q.wake_ready || q.wake_pending == nil do return
	// Acquire the producer's preceding wake exchange, including its publication.
	// A plain store no longer suffices without the old channel mutex. If the
	// producer exchanges after this reset, it observes false and wakes us itself.
	_ = sync.atomic_exchange(q.wake_pending, false)
	// Always refresh head: the consumer cache may still describe an empty ring.
	if spsc.can_pop(q.ring) do pending_queue_signal(q)
}

pending_queue_try_send :: proc(q: Pending_Connection_Queue, pending: Pending_Connection) -> bool {
	if !spsc.try_push(q.ring, pending) do return false
	pending_queue_signal(q)
	return true
}

pending_queue_try_recv :: proc(q: Pending_Connection_Queue) -> (Pending_Connection, bool) {
	return spsc.try_pop(q.ring)
}

// Shared buffer for broadcast operations
Broadcast_Buffer :: struct {
	data:      []byte, // The actual frame data
	ref_count: int, // How many sends are using this (thread-local, no atomics needed)
	pool:      ^byte_pool.BufferPool, // Pool to release to when done
}

shared_frame_retain :: #force_inline proc(buffer: ^Broadcast_Buffer) {
	assert(buffer != nil, "cannot retain nil shared frame")
	assert(buffer.ref_count > 0, "cannot retain released shared frame")
	buffer.ref_count += 1
}

shared_frame_release :: proc(buffer: ^Broadcast_Buffer) {
	if buffer == nil do return
	assert(buffer.ref_count > 0, "shared frame reference underflow")
	buffer.ref_count -= 1
	if buffer.ref_count == 0 {
		byte_pool.release(buffer.pool, buffer.data)
		free(buffer, byte_pool.allocator(buffer.pool))
	}
}

Pooled_Frame_Lease :: struct {
	data: []byte,
	pool: ^byte_pool.BufferPool,
}
Shared_Frame_Lease :: struct {
	buffer: ^Broadcast_Buffer,
}
Connection_Stable_Frame_Lease :: struct {
	data:  []byte,
	owner: Connection_Handle,
}

Frame_Lease :: union {
	Pooled_Frame_Lease,
	Shared_Frame_Lease,
	Connection_Stable_Frame_Lease,
}

Send_Completion_Action :: enum {
	None,
	Close_After_Send,
	Peer_Close_After_Send,
}

frame_lease_data :: proc(lease: Frame_Lease) -> []byte {
	switch v in lease {
	case Pooled_Frame_Lease:
		return v.data
	case Shared_Frame_Lease:
		if v.buffer != nil do return v.buffer.data
	case Connection_Stable_Frame_Lease:
		return v.data
	}
	return nil
}

frame_lease_validate_owner :: proc(lease: Frame_Lease, handle: Connection_Handle) {
	#partial switch v in lease {
	case Connection_Stable_Frame_Lease:
		assert(v.owner != {} && v.owner == handle, "connection-stable frame lease owner/handle mismatch")
	}
}

frame_lease_dispose :: proc(lease: ^Frame_Lease) {
	if lease == nil do return
	switch v in lease^ {
	case Pooled_Frame_Lease:
		if v.data != nil do byte_pool.release(v.pool, v.data)
	case Shared_Frame_Lease:
		shared_frame_release(v.buffer)
	case Connection_Stable_Frame_Lease:
		if owner := connection_get_by_handle(v.owner); owner != nil {
			owner.close_frame_reserved = false
		}
	}
	lease^ = {}
}

Send_Completion_Observer_Callback :: proc(c: ^NRC_Connection, ctx: rawptr, sent: int, err: net.Network_Error)
Send_Completion_Observer :: struct {
	callback: Send_Completion_Observer_Callback,
	ctx:      rawptr,
}

// Queue item for pending sends
Send_Item :: struct {
	lease:                 Frame_Lease,
	handle:                Connection_Handle,
	action:                Send_Completion_Action,
	observer:              Send_Completion_Observer,
	io_pinned:             bool, // This submitted send owns one connection pending_io reference
	durability_writer:     ^Shard_Transaction_Writer,
	durability_generation: u64,
	durability_record:     u64,
	message_store:         ^Message_Store,
	message_generation:    u64,
	message_record:        u64,
}

// Connection-owned transport storage for exactly one incomplete WebSocket wire
// frame. target is zero until enough header bytes have arrived to determine the
// complete envelope length. Message fragmentation is tracked independently.
Receive_Accumulator :: struct {
	buf:    []u8,
	used:   int,
	target: int,
}

// Cache line aligned connection struct with hot fields first.
// Layout: Cache line 1 holds core receive/send state plus workspace routing.
// The following warm bytes hold activity tracking and send queue metadata before inline queue storage.
// This minimizes cache misses during the critical message receive/send path.
NRC_Connection :: struct #align (64) {
	// ============ HOT PATH - Cache Line 1 (64 bytes) ============
	// Fields touched on nearly every receive/send completion and message dispatch.
	sock:                      net.TCP_Socket, // 8 bytes - accessed every I/O op
	state:                     Connection_State, // 8 bytes - checked on every operation
	queued_count:              u32, // 4 bytes - cached queue depth for fast fanout checks
	is_sending:                bool, // 1 byte - checked on every send
	authenticated:             bool, // 1 byte - checked on message handlers
	logical_cleanup_done:      bool, // 1 byte - subscriptions/presence/DM cleanup ran
	close_submitted:           bool,
	close_completed:           bool,
	close_shutdown:            bool, // Preserve cleanup policy while waiting for I/O.
	close_frame_reserved:      bool,
	user_type:                 pr.User_Type, // 1 byte - user classification (user/bot/system)
	pending_io:                u32,
	retained_io:               u8, // bounded retained-history/dedup operations
	deferred_shard_requests:   u16, // application payloads awaiting ordered shard replay
	// The sole outstanding provided-buffer receive. Close cancels this handle so
	// a transient ENOBUFS completion cannot resubmit work against a closing FD.
	recv_completion:           ^nbio.Completion,
	workspace_id:              string, // Interned routing key for workspace dispatch

	// ============ WARM PATH - Cache Line 2 (64 bytes) ============
	// Per-connection timestamps let bounded/indexed maintenance decide whether
	// this connection is idle or has a stalled transport send. send_started_at is
	// monotonic and meaningful only while is_sending is true.
	last_activity:             time.Time,
	send_started_at:           time.Time,

	// Reverse index into td.inflight_send_handles. It is 1-based so zero means
	// "not tracked" and permits O(1) swap-removal when a send completes or the
	// connection closes, avoiding a worker-wide connection scan.
	send_watchdog_slot:        u32,

	// Marks the connection as already listed in td.deferred_outbox_handles. This
	// deduplicates fanout recipients and prevents normal sends from being pumped
	// until the current callback wave has submitted its priority ACKs.
	outbox_pump_deferred:      bool,
	outbox_waiting_durability: bool,
	inline_head:               u8, // Read position in inline queue
	inline_len:                u8, // Number of items in inline queue
	_pad1:                     [1]u8, // Padding to align spill_queue
	spill_queue:               queue.Queue(Send_Item), // Overflow sends once inline queue is full
	priority_queue:            queue.Queue(Send_Item), // Control/ACK fast lane drained before normal sends

	// ============ WARM PATH - Queue Storage ============
	// Inline queue for first N items (avoids heap pointer chase for common case)
	// 16 items * 32 bytes = 512 bytes inline, then spills to heap queue
	inline_queue:              [Inline_Queue_Size]Send_Item, // 512 bytes - inline storage

	// ============ WARM PATH - Message/Frame State ============
	verified_username:         string, // Effective authenticated identity (JWT username or validated service nickname)
	rooms:                     map[pr.ConversationID]bool, // 16 bytes - subscription checks
	receive_accumulator:       Receive_Accumulator,
	deferred_input:            []byte, // Owned raw suffix; never aliases an nbio provided buffer
	deferred_input_offset:     int,
	input_queued:              bool, // Weak generational entry in the worker FIFO
	fragment_buf:              []u8, // Geometrically grown message accumulator (nil when not active)
	fragment_len:              int, // Bytes accumulated in fragment_buf

	// ============ FEATURE STATE ============
	workspace:                 ^Workspace_State, // Cached workspace state for connection-scoped handlers

	// ============ COLD PATH ============
	handle:                    Connection_Handle,
	server:                    ^NRC_Server,
	thread_index:              int, // Ownership validation on close/handoff
	close_frame_buf:           [127]byte, // Maximum 2-byte control header plus 125-byte close payload
}

#assert(align_of(NRC_Connection) == 64)

connection_close :: proc(c: ^NRC_Connection, shutdown: bool, loc := #caller_location) {
	// Ensure we are on the correct thread to close this connection
	// Only worker connections (thread_index >= 0) go through connection_close;
	// pre-handoff connections use http_upgrade_close instead.
	if c.thread_index >= 0 && td.thread_index != c.thread_index {
		log.errorf("Attempting to close connection %v on thread %d, but it belongs to thread %d. Loc: %v", c.sock, td.thread_index, c.thread_index, loc)
		return
	}

	if c.state >= .Closing {
		return
	}

	when ODIN_DEBUG do debug_log("closing connection: %i", c.sock)

	// Reserve a close pin and a setup pin: cancellation may synchronously retire
	// I/O, but must not submit close before shutdown and logical cleanup finish.
	if !connection_io_pin(c) do return
	c.pending_io += 1
	setup_ctx := connection_io_context_make(c)
	setup_ctx.pinned = true
	defer connection_io_unpin(setup_ctx)
	c.close_shutdown = shutdown
	c.state = .Closing
	if c.recv_completion != nil {
		nbio.cancel_recv_provided(&td.io, c.recv_completion)
		c.recv_completion = nil
	}
	send_watchdog_untrack(c)
	connection_run_logical_cleanup(c, shutdown)
	// Detach now; retain the FD itself until all earlier operations are terminal.
	// Otherwise nbio retries/backlogged SQEs could access a replacement FD before
	// NRC's generation-checked callback gets a chance to reject stale work.
	connection_detach_socket(c)
	net.shutdown(c.sock, net.Shutdown_Manner.Both)
}

connection_try_submit_close :: proc(c: ^NRC_Connection) {
	// The remaining reference is reserved for close. Conservatively also wait
	// for application/storage pins, not just socket I/O.
	if c.state != .Closing || c.close_submitted || c.pending_io != 1 do return
	c.close_submitted = true
	close_ctx := connection_io_context_make(c)
	close_ctx.pinned = true
	nrc_io_close(c, close_ctx, c.close_shutdown, on_connection_close_complete)
}

on_connection_close_complete :: proc(ctx: Connection_IO_Context, shutdown: bool, ok: bool) {
	when ODIN_DEBUG do debug_log("closed connection: %i", ctx.sock)

	// SINGLE OWNER PATTERN: connections_by_handle owns all worker connections
	// Step 1: Check if we still own this connection
	conn := connection_from_io_context(ctx)
	if conn == nil {
		when ODIN_DEBUG do debug_log("[T%d] Connection %v already freed by another path", td.thread_index, ctx.sock)
		connection_io_unpin(ctx)
		return
	}

	// Normally already detached by connection_close; generation-check direct
	// completion callers too, without decrementing a replacement's active count.
	connection_detach_socket(conn)

	// Step 3: Mark as closed
	conn.state = .Closed
	conn.close_completed = true
	connection_run_logical_cleanup(conn, shutdown)
	if ctx.pinned {
		connection_io_unpin(ctx) // Final action: this may reclaim conn.
	} else {
		connection_try_reclaim(conn)
	}
}

connection_try_reclaim :: proc(conn: ^NRC_Connection) {
	if conn == nil || !conn.close_completed || conn.pending_io != 0 do return
	assert(conn.send_watchdog_slot == 0, "reclaiming connection still indexed by send watchdog")
	reset_deferred_input(conn)
	if conn.receive_accumulator.buf != nil {
		byte_pool.release(td.spool, conn.receive_accumulator.buf)
	}
	conn.receive_accumulator = {}
	if conn.fragment_buf != nil {
		byte_pool.release(td.spool, conn.fragment_buf)
		conn.fragment_buf = nil
		conn.fragment_len = 0
	}
	send_queue_destroy(conn)
	// Shutdown skips logical presence/subscription cleanup, but the room map
	// is connection-owned and must still be freed at final reclamation.
	remove_all_rooms(conn)
	connection_remove(conn)
}

connection_run_logical_cleanup :: proc(c: ^NRC_Connection, shutdown: bool) {
	if shutdown || c.logical_cleanup_done {
		return
	}
	c.logical_cleanup_done = true

	// Note: Order matters for race condition prevention. Run this before the
	// connection handle is removed so presence cleanup can still resolve the
	// closing socket's identity.
	cleanup_connection_subscriptions(c)
	cleanup_connection_presence_notifications(c)
	cleanup_dm_on_disconnect(c)
	remove_all_rooms(c)
}

connection_begin_graceful_logical_close :: proc(c: ^NRC_Connection, shutdown: bool, loc := #caller_location) -> bool {
	if c == nil {
		return false
	}

	if c.thread_index >= 0 && td.thread_index != c.thread_index {
		log.errorf(
			"Attempting to begin graceful logical close for connection %v on thread %d, but it belongs to thread %d. Loc: %v",
			c.sock,
			td.thread_index,
			c.thread_index,
			loc,
		)
		return false
	}

	if c.state >= .Will_Close {
		return false
	}

	c.state = .Will_Close
	// Only an already submitted send may finish after logical close. Drop
	// unsent application frames, including priority ACKs waiting on storage,
	// so the terminal close frame cannot be stranded behind a durability gate.
	send_queue_drain(c)
	connection_run_logical_cleanup(c, shutdown)
	return true
}

// Check only connections that currently own an incomplete transport send.
// Scan backwards because closing a stalled connection swap-removes its dense
// watchdog slot and may move an already-visited handle into the current index.
check_stalled_sends :: proc(now: time.Time) {
	stalled_count := 0
	next_deadline := time.Time{}
	for i := len(td.inflight_send_handles) - 1; i >= 0; i -= 1 {
		handle := td.inflight_send_handles[i]
		conn := connection_get_by_handle(handle)
		assert(conn != nil, "send watchdog contains stale connection handle")
		if conn == nil do continue
		assert(conn.send_watchdog_slot == u32(i + 1), "send watchdog reverse index mismatch")

		if !conn.is_sending || conn.state >= .Closing {
			send_watchdog_untrack(conn)
			continue
		}
		assert(conn.send_started_at != {}, "indexed send missing start timestamp")
		deadline := time.time_add(conn.send_started_at, Conn_Send_Timeout)
		if time.diff(deadline, now) >= 0 {
			stalled_count += 1
			connection_close(conn, false)
			continue
		}
		if next_deadline == {} || time.diff(deadline, next_deadline) > 0 {
			next_deadline = deadline
		}
	}
	td.next_send_watchdog_at = next_deadline
	if stalled_count > 0 {
		log.warnf("[T%d] Closed %d connections with stalled sends", td.thread_index, stalled_count)
	}
}

// Inspect one bounded slice of the direct socket-handle table. A full sweep
// takes approximately Heartbeat_Interval without touching the receive hot path.
check_idle_connections :: proc(now: time.Time) {
	idle_count := 0
	index := td.idle_scan_cursor

	for _ in 0 ..< Idle_Scan_Slots_Per_Tick {
		handle := td.connection_handles[index]
		if handle != {} {
			conn := connection_get_by_handle(handle)
			if conn != nil && int(conn.sock) == index && (conn.state == .New || conn.state == .Active || conn.state == .Idle) {
				idle_duration := time.diff(conn.last_activity, now)
				if idle_duration > Idle_Timeout {
					idle_count += 1
					when ODIN_DEBUG do debug_log("[T%d] Connection %v idle for %v, closing", td.thread_index, conn.sock, idle_duration)
					// Unlike the old active-socket map iteration, advancing through the
					// direct table remains valid when close completion clears this slot.
					send_websocket_close_frame_and_close(conn, 1000, "Idle timeout")
				}
			}
		}

		index += 1
		if index == MAX_SOCK_FD do index = 0
	}
	td.idle_scan_cursor = index

	if idle_count > 0 {
		log.infof("[T%d] Closed %d idle connections", td.thread_index, idle_count)
	}
}

// Helper procedures for connection cleanup

cleanup_connection_presence_notifications :: proc(c: ^NRC_Connection) {
	// Send presence notifications for all rooms this user was in
	username := get_socket_username(c.workspace_id, c.sock)
	if username != "" {
		ws := get_connection_workspace(c)
		for conv_id in c.rooms {
			send_or_defer_user_left(ws, c.workspace_id, conv_id, username, c.authenticated, c.user_type)
		}
	}
}

cleanup_connection_subscriptions :: proc(c: ^NRC_Connection) {
	// SINGLE OWNER PATTERN: Clean up subscriptions using connection's room membership
	ws := get_connection_workspace(c)
	if ws == nil {
		return
	}

	for conv_id in c.rooms {
		conv := get_conversation(ws, conv_id)
		if conv == nil {
			continue
		}

		conversation_remove_subscriber(conv, c.sock)
	}
}
