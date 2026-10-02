package main

import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

Pending_Queue_Thread_Test :: struct {
	queue:  Pending_Connection_Queue,
	items:  []HTTP_Upgrade_Connection,
	failed: bool,
}

pending_queue_test_producer :: proc(state: ^Pending_Queue_Thread_Test) {
	start := time.tick_now()
	for &item, i in state.items {
		// Consumer must observe these writes through the release/acquire handoff.
		item.http_received = i * 7 + 3
		for !pending_queue_try_send(state.queue, {upgrade = &item}) {
			if sync.atomic_load(&state.failed) do return
			if time.tick_since(start) > 10 * time.Second {
				sync.atomic_store(&state.failed, true)
				return
			}
			sync.cpu_relax()
		}
	}
}

pending_queue_test_consumer :: proc(state: ^Pending_Queue_Thread_Test) {
	start := time.tick_now()
	expected := 0
	for expected < len(state.items) {
		// Do not inspect the ring until an actual eventfd wake arrives. A missing
		// wake must fail this test rather than being hidden by queue polling.
		wake: u64
		_, err := linux.read(state.queue.wake_fd, ([^]byte)(&wake)[:size_of(wake)])
		if err != .NONE {
			if sync.atomic_load(&state.failed) do return
			if (err != .EAGAIN && err != .EINTR) || time.tick_since(start) > 10 * time.Second {
				sync.atomic_store(&state.failed, true)
				return
			}
			sync.cpu_relax()
			continue
		}
		// A partial drain exercises the worker time-budget rearm as well as the
		// empty-ring rearm. Capacity is three, so bursts repeatedly wrap.
		for _ in 0 ..< 2 {
			item, ok := pending_queue_try_recv(state.queue)
			if !ok do break
			if expected >= len(state.items) || item.upgrade != &state.items[expected] || item.upgrade.http_received != expected * 7 + 3 {
				sync.atomic_store(&state.failed, true)
				return
			}
			expected += 1
		}
		pending_queue_rearm_wake(state.queue)
	}
}

@(test)
test_pending_queue_threaded_fifo_publication_and_wakes :: proc(t: ^testing.T) {
	q, err := pending_queue_create(3)
	if !testing.expect(t, err == .None) do return
	defer pending_queue_destroy(q)
	state := Pending_Queue_Thread_Test {
		queue = q,
		items = make([]HTTP_Upgrade_Connection, 20_003),
	}
	defer delete(state.items)
	producer := thread.create_and_start_with_poly_data(&state, pending_queue_test_producer)
	consumer := thread.create_and_start_with_poly_data(&state, pending_queue_test_consumer)
	thread.join(producer)
	thread.join(consumer)
	thread.destroy(producer)
	thread.destroy(consumer)
	testing.expect(t, !state.failed, "handoffs must preserve FIFO, payload visibility and eventfd wakeups without stalling")
	_, extra := pending_queue_try_recv(q)
	testing.expect(t, !extra, "joined worker transfers an empty queue back to main")
}
