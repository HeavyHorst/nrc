package main

import "byte_pool"
import "core:container/queue"
import "core:log"

// Bound application work, not completion retirement. Send/fsync/close callbacks
// still run after this budget is spent. A frame/handler is never interrupted.
INPUT_FRAME_BUDGET :: #config(NRC_INPUT_FRAME_BUDGET, 64)
#assert(INPUT_FRAME_BUDGET > 0)

begin_input_turn :: proc() {
	td.input_budget_active = true
	td.input_frames_remaining = INPUT_FRAME_BUDGET
	// Carry server-side durability pressure across turns. Transport backlog is
	// subscriber-local: an active send or a durable queue head must not throttle
	// other clients. Its queue cap/watchdog will disconnect a stalled receiver.
	if c := connection_get_by_handle(td.input_pressure_handle);
	   c != nil && c.state < .Will_Close && !c.is_sending && send_queue_len(c) >= max(1, Max_Queue_Size / 2) && !outbox_item_is_durable(send_queue_peek(c)) {
		td.input_frames_remaining = 1
	} else {
		td.input_pressure_handle = {}
	}
}

input_budget_exhausted :: #force_inline proc() -> bool {
	return td.input_budget_active && td.input_frames_remaining == 0
}

reset_deferred_input :: proc(c: ^NRC_Connection) {
	if c.deferred_input != nil {
		when NRC_SIMULATION {
			if nrc_sim_runtime != nil do delete_key(&nrc_sim_runtime.world.blocked_input, Sim_Input_Key{td.thread_index, c.handle})
		}
		td.deferred_input_bytes -= uint(len(c.deferred_input))
		byte_pool.release(td.spool, c.deferred_input)
	}
	c.deferred_input = nil
	c.deferred_input_offset = 0
	c.input_queued = false
}

queue_deferred_input :: proc(c: ^NRC_Connection) {
	assert(!c.input_queued && c.deferred_input != nil)
	if queue.len(td.deferred_input_handles) == queue.cap(td.deferred_input_handles) {
		// Closed/reused generations must not consume capacity indefinitely.
		n := queue.len(td.deferred_input_handles)
		for _ in 0 ..< n {
			h := queue.pop_front(&td.deferred_input_handles)
			if live := connection_get_by_handle(h); live != nil && live.input_queued && live.state < .Will_Close {
				ok, _ := queue.push_back(&td.deferred_input_handles, h)
				assert(ok)
			} else if live != nil {
				reset_deferred_input(live)
			}
		}
	}
	ok, _ := queue.push_back(&td.deferred_input_handles, c.handle)
	assert(ok, "deferred input exceeded per-worker connection bound")
	c.input_queued = true
}

defer_received_input :: proc(c: ^NRC_Connection, data: []byte) {
	assert(c.deferred_input == nil && len(data) > 0)
	owned, err := byte_pool.alloc(td.spool, uint(len(data)))
	if err != .None {
		log.errorf("[T%d] Failed to retain deferred receive suffix for %v", td.thread_index, c.sock)
		connection_close(c, false)
		return
	}
	copy(owned, data)
	c.deferred_input = owned
	td.deferred_input_bytes += uint(len(owned))
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil do nrc_sim_runtime.world.blocked_input[{td.thread_index, c.handle}] = true
	}
	queue_deferred_input(c)
}

// Caller pins c while parsing: handlers may close it. Returned bytes have either
// been dispatched or copied into the incomplete-frame accumulator. On yield the
// remaining bytes are untouched (in particular, not yet unmasked).
consume_websocket_input :: proc(c: ^NRC_Connection, data: []byte) -> (consumed: int, closed, yielded: bool) {
	if input_budget_exhausted() do return 0, false, true
	fresh := data
	if acc := &c.receive_accumulator; acc.buf != nil {
		if acc.target == 0 {
			for acc.target == 0 && len(fresh) > 0 {
				acc.buf[acc.used] = fresh[0]
				acc.used += 1
				fresh = fresh[1:]
				target, header_complete, success := validate_websocket_frame_target(c, acc.buf[:acc.used])
				if !success {
					reset_receive_accumulator(c)
					return len(data), true, false
				}
				if header_complete {
					if target > len(acc.buf) {
						grown, grow_err := byte_pool.alloc(td.spool, uint(target))
						if grow_err != .None {
							log.errorf("[T%d] Failed to grow receive accumulator for %v", td.thread_index, c.sock)
							connection_close(c, false)
							return len(data), true, false
						}
						copy(grown[:acc.used], acc.buf[:acc.used])
						byte_pool.release(td.spool, acc.buf)
						acc.buf = grown
					}
					acc.target = target
				}
			}
		}
		if acc.target > 0 {
			n := min(len(fresh), acc.target - acc.used)
			copy(acc.buf[acc.used:], fresh[:n])
			acc.used += n
			fresh = fresh[n:]
			if acc.used == acc.target {
				_, closed = process_websocket_frames(c, acc.buf[:acc.target], &yielded)
				assert(!yielded, "accumulator's single frame must fit remaining budget")
				reset_receive_accumulator(c)
				if closed do return len(data), true, false
			}
		}
		if c.receive_accumulator.buf != nil do return len(data), false, false
	}
	processed: int
	processed, closed = process_websocket_frames(c, fresh, &yielded)
	if closed do return len(data), true, false
	if yielded do return len(data) - len(fresh) + processed, false, true
	if processed < len(fresh) {
		if !start_receive_accumulator(c, fresh[processed:]) do return len(data), true, false
	}
	return len(data), false, false
}

receive_websocket_input :: proc(c: ^NRC_Connection, data: []byte) {
	assert(c.deferred_input == nil, "receive rearmed before deferred input was consumed")
	if input_budget_exhausted() || queue.len(td.deferred_input_handles) > 0 {
		defer_received_input(c, data)
		return
	}
	consumed, closed, yielded := consume_websocket_input(c, data)
	if closed do return
	if yielded {
		defer_received_input(c, data[consumed:])
	} else {
		schedule_next_recv(c)
	}
}

drain_deferred_input :: proc() -> bool {
	visits := min(queue.len(td.deferred_input_handles), INPUT_FRAME_BUDGET)
	did_work := false
	for _ in 0 ..< visits {
		if input_budget_exhausted() do break
		h := queue.pop_front(&td.deferred_input_handles)
		did_work = true
		c := connection_get_by_handle(h)
		if c == nil do continue
		c.input_queued = false
		if c.state >= .Will_Close {
			reset_deferred_input(c)
			continue
		}
		assert(c.deferred_input != nil)
		if !connection_io_pin(c) do continue
		ctx := connection_io_context_make(c)
		ctx.pinned = true
		consumed, closed, yielded := consume_websocket_input(c, c.deferred_input[c.deferred_input_offset:])
		if closed {
			reset_deferred_input(c)
		} else if yielded {
			c.deferred_input_offset += consumed
			queue_deferred_input(c)
		} else {
			reset_deferred_input(c)
			schedule_next_recv(c)
		}
		connection_io_unpin(ctx) // May reclaim c; no accesses afterwards.
	}
	return did_work
}

discard_deferred_input :: proc() {
	for queue.len(td.deferred_input_handles) > 0 {
		h := queue.pop_front(&td.deferred_input_handles)
		if c := connection_get_by_handle(h); c != nil do reset_deferred_input(c)
	}
	td.input_budget_active = false
}
