# Odin escape-analysis audit

## Reviewed baseline (2026-10-08)

- NRC: [`78a802a`](https://github.com/HeavyHorst/nrc/commit/78a802afd39ed06497048e3469d5b80bf8d8d17b).
- Odin: [`b0c36ab`](https://github.com/odin-lang/Odin/commit/b0c36ab7ca56f8b0ef06b30119d3b32a7f6abb2d), built with LLVM 19.
- Scope: the **202 warnings** emitted by the non-simulation `odin build . -vet`.
- Exact file/line/message inventory: [ODIN_ESCAPE_WARNINGS.txt](ODIN_ESCAPE_WARNINGS.txt).
  Locations refer to the reviewed commit, not necessarily the current checkout.
- Result: **no additional genuine lifetime defect was identified in this inventory**.
  This is a reviewed baseline, not a compiler suppression or a proof of general memory safety.

The baseline already contains the fix for genuine dangling attachment slices in
asset request/response parsers. Those parsers now borrow attachment descriptors
from caller-owned buffers; their unsafe-return warnings are not part of this inventory.

## Reviewed groups and the conditions that make them safe

| Group | Warn sites | Reviewed lifetime argument |
| --- | ---: | --- |
| Connection handler calls | 132 | 89 sites use `.Closed` fixtures; 43 use `.Idle` with `is_sending = true`. Closed fixtures dispose response frames; the Idle fixtures enqueue but do not pump socket I/O. Their queues are drained/destroyed before state and buffer-pool cleanup. Direct handler calls do not establish the protocol dispatch context that could defer a request. |
| Writer append calls | 53 | 51 sites use standalone writers with `batch_writes = false`: transaction bytes are copied and written synchronously. The two sites in `shard_group_commit_test.odin:38,43` enable batching, but append only two small records; no async submission occurs before the explicit synchronous flush/fsync. |
| Replay origins | 6 | Every reviewed `workspace_data_origins_begin` call has deferred `workspace_data_origins_end`. The owning scope clears the TLS pointer; nested scans with `owned = false` leave the outer tracker intact. |
| `td.server` stores | 5 | `message_seal_test.odin:43,191`, `storage_lifecycle_test.odin:38,147`, and `storage_owner_benchmark.odin:112` restore the complete prior `td` via defer. Service threads are joined before their state is destroyed. |
| Allocator/container stores | 4 | `storage_owner_benchmark.odin:111,125,126,134`: containers are deleted and `td` restored before the heap/tracker is destroyed. Optional benchmark bodies were reviewed statically, not separately activated. |
| Shutdown callback context | 1 | `connection_close_barrier_linux_test.odin:197`: deferred drain at lines 109–126 requires connection reclamation and `num_waiting == 0` before normal return. A drain failure calls `fail_now`, which traps without running defers; this is not a normal-return cleanup guarantee. |
| Retained-message store | 1 | `message_store_test.odin:1578` passes `.EIO`; the completion error path returns before the success path can schedule another store flush. |

### Ownership evidence to revisit when behavior changes

- `room_mapping_test.odin:64–74`: the connection fixture starts `.Closed`.
- `websocket_handler.odin:1169–1181`: closing/closed connections dispose the frame lease.
- `websocket_handler.odin:867–889,1035–1041`: `is_sending` prevents the queue pump.
- `connection.odin:721–735`: queue destruction drains and disposes every frame lease.
- `websocket_handler.odin:175–265,328–346`: protocol dispatch establishes the context;
  deferred requests own copied payloads and pinned connection I/O contexts.
- `websocket_handler.odin:1208–1242`: queued sends store handles and leases, not the
  raw fixture connection address. Real I/O uses lifetime pins and generation-aware handles.
- `shard_transaction.odin:81–98`: encoding copies workspace and mutation payload bytes.
- `shard_runtime_writer.odin:549–552,573–578,616` and
  `shard_writer_registry.odin:157–164,190–208`: batch thresholds and actual async
  writer retention. **Shutdown alone does not establish safety**; it requires drained I/O.
- `workspace_data.odin:45–62`: origins acquire/release and nested-scan ownership.
- `retained_message_handlers.odin:327–352`: store enqueue occurs only after successful fsync.

The reviewed queue backlogs remain below the 512-item limit. Changing a fixture
state, enabling its send pump, increasing its backlog, introducing protocol
dispatch, changing writer batching/record size, or changing teardown invalidates
the corresponding argument. Review that path again rather than relying on this table.

## Executed checks and open boundaries

All completed checks below used active escape analysis and the pinned compiler:

| Check | Result | Maximum RSS |
| --- | --- | ---: |
| Server `-vet` build | Exit 0; 202 warnings | 961,940 KiB |
| Normal root suite | 593 tests passed | 1,057,720 KiB |
| Protocol suite | 161 tests passed | 487,972 KiB |

The first root run in the fresh worktree had nine WAL/directory-fixture failures;
the unchanged repeat passed after the tests had created the missing directories.
Do not interpret this as every fresh-worktree run having passed.

**Active simulation analysis remains unverified.** Both the default compiler run
and `-thread-count:1 -no-threaded-checker` were killed by the 30-GiB workload cgroup
limit (exit 137, no swap). Compiler anonymous RSS at termination was 31,374,216
and 31,378,228 KiB respectively. Neither run executed simulation tests or produced
simulation warning diagnostics. The earlier 683-test simulation pass with
`-no-escape-analysis` verifies runtime behavior, not active simulation analysis.

Run root compiles sequentially. To reproduce with a compiler at the pinned revision:

```sh
odin build . -vet -out:/tmp/nrc-audit-server
ODIN_BIN=/path/to/pinned/odin ./test/run_odin_tests.sh . -define:ODIN_TEST_LOG_LEVEL=error
ODIN_BIN=/path/to/pinned/odin ./test/run_odin_tests.sh protocol/ -define:ODIN_TEST_LOG_LEVEL=error
ODIN_BIN=/path/to/pinned/odin ./test/run_odin_tests.sh . -define:NRC_SIMULATION=true -define:ODIN_TEST_LOG_LEVEL=error
```

## Updating the audit

Keep warnings enabled. On a compiler or relevant ownership-path change, regenerate
the inventory, compare diagnostic file/procedure/message rather than just counts
or line numbers, and review new or changed paths. Record the new revision, evidence,
and unresolved cases; do not silently expand this baseline's scope. A successful
test run alone does not prove that a retained stack reference is safe.

The pinned Odin analysis propagates conditional may-retain flows without
specializing them for runtime scalar values such as `batch_writes` or `.EIO`.
It models defers, but does not generally export helper cleanup as a caller-visible
kill effect; a whole-struct restore does not necessarily clear recorded field stores.
These limitations explain why the reviewed ownership contracts still emit warnings.

Investigation and execution evidence:
[larger-orb audit](https://ampcode.com/threads/T-01a11a51-4497-77aa-876b-c8078f9c50ec)
and [fix/oracle review](https://ampcode.com/threads/T-01a11a15-a214-7077-ae14-babd6c4e7a65).
