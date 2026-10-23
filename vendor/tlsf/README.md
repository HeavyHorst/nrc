# Odin TLSF dependency

Copied from `odin-lang/Odin` `core/mem/tlsf` at nightly revision `a2fb372`
(`dev-2026-09-nightly`), including the upstream BSD-3-Clause license and
copyright notices. NRC imports this copy rather than mutating the installed
compiler's standard library, so builds on other machines receive the same fix.

Local change: if allocating a growth pool's tracking node fails, remove the
fresh pool from the free lists, free its backing buffer and return the original
allocation error. Existing pools and allocations remain usable. The regression
test injects this exact failure twice, then verifies a successful resize and
complete destruction.

ASan builds (`-sanitize:address`, 64-bit only) additionally poison pool storage
and expose only each allocation's requested bytes. Free, shrink and Free_All
revoke access; resize preserves live prefixes and growth rollback/destroy restore
backing storage before releasing it. ASan allocations return the requested length
rather than rounded capacity. Without quarantine, block placement, metadata
layout and reuse policy are unchanged. The existing `no_sanitize_address`
metadata helpers intentionally access poisoned headers/free-list links: this
checks application access, not all allocator-internal access. Poisoning is under
compile-time `when .Address in ODIN_SANITIZER_FLAGS` conditions.

The optional `-define:TLSF_ASAN_QUARANTINE=true` requires ASan and delays reuse
with a per-heap FIFO, bounded by 128 entries and 1 MiB of block storage (including
block overhead). Quarantined blocks remain physically used and poisoned, so
adjacent frees cannot absorb them. The oldest entries become reusable when a
limit is reached, or when an allocation cannot otherwise be satisfied, before
growing the heap or reporting OOM. Oversized blocks bypass quarantine. Free_All
clears the FIFO and poisons the rebuilt pools; destroy releases the pools without
needing to drain individual entries. The FIFO has no separate heap allocations.
With quarantine disabled its state is an empty type: the allocator size and
existing field offsets are unchanged, and all quarantine code is compiled out.

Quarantine is off by default. Retain both ASan variants: immediate reuse and
delayed reuse expose different failures. This is an allocation-count/byte window,
not a time guarantee; under pressure, after eviction, or for oversized blocks,
stale references can again alias live allocations. Shrink tails are poisoned but
not quarantined. LeakSanitizer sees backing allocations, not leaked suballocations;
retain ownership accounting and allocator tracking tests.

`-define:TLSF_CHECK_INVARIANTS=true` enables expensive structure checks after
every allocator API operation (including failed operations and queries). It
walks each physical pool, checking block extents/alignment, sentinel, previous
block flags/pointers and coalescing; then validates free-list membership,
uniqueness, reciprocal links, size classes and both bitmap levels. Quarantine
membership and byte accounting are checked when enabled. Free-list pointers are
looked up in the physical-block inventory before being dereferenced. Scratch
maps use the runtime heap, never the TLSF under test, and are destroyed after
each check. This mode checks metadata while bypassing ASan's intentional poison;
it does not unpoison application storage. It works with or without ASan.

Both optional modes default to false and require assertions enabled. Normal
builds contain neither quarantine state nor checker calls/scratch allocations.
Use the checker on targeted allocator/lifecycle tests; full heap walks after
every operation can be costly on large workloads. The smoke runner injects
corrupt sizes, neighbor flags, cyclic lists, wrong size classes, bitmap bits,
unknown list pointers and broken predecessor links. It requires the specific
invariant assertion, not a generic crash.

Keep the upstream implementation otherwise unchanged when updating this copy.
Run `./test/run_odin_tests.sh vendor/tlsf/` and `./test/run_asan_checks.sh`
after changes. The latter requires intentional invalid accesses to fail in ASan,
then exercises allocator contracts and real io_uring lifecycle tests.
