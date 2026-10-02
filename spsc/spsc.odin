// Bounded single-producer/single-consumer ring, based on RingBufferV5:
// https://david.alvarezrosa.com/posts/optimizing-a-lock-free-ring-buffer/
package spsc

import "base:runtime"
import "core:sync"

@(private)
Cursor :: struct #align (64) {
	value: int,
}
#assert(size_of(Cursor) == 64)

// Share a pointer to Queue; never copy the queue itself. Exactly one producer
// owns head/tail_cached, and one consumer owns tail/head_cached. Ownership may
// transfer to another thread only after synchronization (for example a join).
// No blocking, wakeups or close protocol are provided. Payloads are shallow
// copies; their lifetimes and cleanup remain the caller's responsibility.
Queue :: struct($T: typeid) {
	data:        []T,
	allocator:   runtime.Allocator,
	head:        Cursor,
	head_cached: Cursor,
	tail:        Cursor,
	tail_cached: Cursor,
}

// capacity is the usable number of entries; one additional sentinel slot is
// allocated. Capacity need not be a power of two. No allocation occurs in use.
create :: proc($T: typeid, capacity: int, allocator := context.allocator) -> (queue: ^Queue(T), allocator_error: runtime.Allocator_Error) {
	assert(capacity > 0 && capacity < max(int))
	q := new(Queue(T), allocator) or_return
	q.allocator = allocator
	data, err := make([]T, capacity + 1, allocator)
	if err != .None {
		free(q, allocator)
		return nil, err
	}
	q.data = data
	return q, .None
}

// Call only after producer and consumer stop. Does not destroy queued payloads.
destroy :: proc(q: ^Queue($T)) {
	allocator := q.allocator
	delete(q.data, allocator)
	free(q, allocator)
}

// Producer only. A capacity check, not a reservation; it mutates the producer's
// cached tail. A successful check stays valid until the next producer push.
can_push :: proc(q: ^Queue($T)) -> bool {
	head := sync.atomic_load_explicit(&q.head.value, .Relaxed)
	next := head + 1
	if next == len(q.data) do next = 0
	if next == q.tail_cached.value {
		q.tail_cached.value = sync.atomic_load_explicit(&q.tail.value, .Acquire)
		if next == q.tail_cached.value do return false
	}
	return true
}

// Consumer only. Reads the published head rather than the consumer cache, for
// callers rechecking after rearming their own notification mechanism. This
// check alone does not provide a lost-wakeup protocol.
can_pop :: proc(q: ^Queue($T)) -> bool {
	head := sync.atomic_load_explicit(&q.head.value, .Acquire)
	tail := sync.atomic_load_explicit(&q.tail.value, .Relaxed)
	return head != tail
}

// Producer only. A successful push publishes the payload to the consumer.
try_push :: proc(q: ^Queue($T), value: T) -> bool {
	if !can_push(q) do return false
	head := sync.atomic_load_explicit(&q.head.value, .Relaxed)
	next := head + 1
	if next == len(q.data) do next = 0
	q.data[head] = value
	sync.atomic_store_explicit(&q.head.value, next, .Release)
	return true
}

// Consumer only. A successful pop releases the slot for producer reuse.
try_pop :: proc(q: ^Queue($T)) -> (value: T, ok: bool) {
	tail := sync.atomic_load_explicit(&q.tail.value, .Relaxed)
	if tail == q.head_cached.value {
		q.head_cached.value = sync.atomic_load_explicit(&q.head.value, .Acquire)
		if tail == q.head_cached.value do return {}, false
	}
	value = q.data[tail]
	next := tail + 1
	if next == len(q.data) do next = 0
	sync.atomic_store_explicit(&q.tail.value, next, .Release)
	return value, true
}
