# Deterministic Simulation Budget Baseline

This report records the first measured budget baseline required by
[`DETERMINISTIC_SIMULATOR_PLAN.md`](DETERMINISTIC_SIMULATOR_PLAN.md). It is a decision aid, not a benchmark:
the measurements are single runs in a constrained `a1.small` Amp orb on 2026-09-05 at commit `7749574`.

## Method

Both runs used one prebuilt optimized root-test executable, one Odin test thread, fixed Odin and Hegel seeds,
required libhegel 0.33.3, and Hegel diagnostics:

```console
HEGEL_SEED=12345 HEGEL_DIAGNOSTICS=1 odin test . -o:speed \
  -out:/tmp/nrc-sim-budget-tests -keep-executable -thread-count:1 \
  -define:NRC_SIMULATION=true \
  -define:HEGEL_REQUIRED=true \
  -define:ODIN_TEST_LOG_LEVEL=error \
  -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_RANDOM_SEED=12345 \
  -- -tests:main.test_simulation_pre_tick_rotation_makes_compaction_eligible_in_same_turn

HEGEL_SEED=12345 HEGEL_DIAGNOSTICS=1 /usr/bin/time -v /tmp/nrc-sim-budget-tests
HEGEL_SEED=12345 HEGEL_DIAGNOSTICS=1 HEGEL_TEST_CASE_MULTIPLIER=4 \
  /usr/bin/time -v /tmp/nrc-sim-budget-tests
```

Odin's runtime `-tests:` filter was also used to run all tests from each `*_simulation_test.odin` file in
one process. Per-property Hegel time comes from `[hegel diag] finish`; it excludes test-runner and native
library process teardown. Source-file group time includes that overhead and is the better estimate for a
separately scheduled CI group. Individual one-test process timings are intentionally not reported: repeated
process setup/teardown made their sum about nine times larger than the full suite and therefore misleading.

## Whole-Suite Result

| Budget | Root tests | Hegel runs | Generated cases | Hegel body time | Suite wall time | Max RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Local (1×) | 486 | 76 (67 test procedures) | 15,208 | 17.577 s | 45.56 s | 1,056,116 KiB |
| Nightly (4×) | 486 | 76 (67 test procedures) | 59,076 | 66.318 s | 94.04 s | 2,334,964 KiB |

The complete per-property data, including invariant owner and source file, is in
[`deterministic-simulation-budget-2026-09-05.csv`](deterministic-simulation-budget-2026-09-05.csv).

The 18-minute PR watchdog and 55-minute nightly watchdog are safety ceilings, not observed runtime needs.
The 4× run has large time headroom. Memory, however, grew by 2.21× and is the practical reason not to raise the
blanket multiplier without another measurement.

Some Hegel runs deliberately ignore the global multiplier because their fixed branch budget owns the useful
state space. Consequently, generated cases are slightly below exactly four times the local count.

## Generated Work by Invariant Owner

Elapsed time is the sum of Hegel body time. It does not include mandatory fixtures in the same test procedure.

| Invariant owner | Properties | Local cases | Local time | 4× cases | 4× time |
| --- | ---: | ---: | ---: | ---: | ---: |
| Global two-worker | 1 | 96 | 5.368 s | 384 | 20.052 s |
| Compaction publication/kernel | 5 | 436 | 3.398 s | 1,696 | 11.808 s |
| Global one-worker semantic | 11 | 376 | 2.341 s | 1,504 | 9.837 s |
| Connection/event ownership | 11 | 2,210 | 2.090 s | 7,802 | 8.357 s |
| Parser/query equivalence | 17 | 6,485 | 1.434 s | 25,913 | 6.131 s |
| Durability/semantic recovery | 5 | 376 | 1.220 s | 1,380 | 3.316 s |
| Retained messages | 2 | 80 | 0.769 s | 320 | 3.043 s |
| Focused models/codecs/fanout | 9 | 4,573 | 0.590 s | 17,773 | 2.398 s |
| DM authorization | 6 | 576 | 0.367 s | 2,304 | 1.376 s |

### Most Expensive Generated Properties

| Test procedure | Owner | Local cases/time | 4× cases/time |
| --- | --- | ---: | ---: |
| `test_hegel_generated_two_worker_global_event_schedules` | Global two-worker | 96 / 5.368 s | 384 / 20.052 s |
| `test_hegel_shard_compaction_repeated_publication_history` | Compaction publication | 48 / 2.229 s | 192 / 9.642 s |
| `test_hegel_semantic_transport_persistence_interleavings` | Global one-worker | 64 / 1.069 s | 256 / 4.446 s |
| `test_hegel_semantic_transport_persistence_dependent_update_interleavings` | Global one-worker | 64 / 1.059 s | 256 / 4.506 s |
| `test_hegel_shard_compaction_queue_ownership_transfer` | Compaction ownership | 16 / 0.931 s | 16 / 0.966 s |
| `test_hegel_generated_stale_callback_buffer_ownership_is_released_once` | Connection ownership | 500 / 0.891 s | 2,000 / 3.686 s |
| `test_hegel_sealed_retained_history_matches_sequence_model` | Retained messages | 50 / 0.528 s | 200 / 2.193 s |
| `test_hegel_shard_fsync_completion_interleavings` | Durability | 32 / 0.517 s | 32 / 0.627 s |
| `test_hegel_generated_stale_callback_completions_do_not_target_reused_sockets` | Connection ownership | 500 / 0.495 s | 2,000 / 2.460 s |
| `test_hegel_sharded_startup_recovers_exact_durable_prefix_across_write_and_fsync_crashes` | Durability | 160 / 0.345 s | 612 / 1.283 s |
| `test_hegel_simulation_generated_message_fanout_matches_model` | Focused fanout | 200 / 0.340 s | 800 / 1.408 s |
| `test_hegel_generated_transactional_shard_state_matches_replay` | Semantic model | 24 / 0.248 s | 96 / 1.017 s |
| `test_hegel_active_retained_history_matches_sequence_model` | Retained messages | 30 / 0.241 s | 120 / 0.850 s |

The remaining 54 generated test procedures together consumed 3.316 seconds locally. This long tail is not a
meaningful runtime problem and should not be consolidated merely because several properties parse or query
related protocol types.

## Simulation Source-Group Cost

These local runs include mandatory fixtures, generated bodies, and one process's setup/teardown. Groups are
diagnostic only; their sum is not the full-suite duration because each group repeats process overhead and normal
root tests are omitted.

| Source owner | Tests | Time | Max RSS |
| --- | ---: | ---: | ---: |
| `multi_worker_simulation_test.odin` | 10 | 21.23 s | 55,972 KiB |
| `semantic_transport_persistence_simulation_test.odin` | 15 | 4.50 s | 99,688 KiB |
| `shard_compaction_queue_simulation_test.odin` | 5 | 3.59 s | 23,836 KiB |
| `shard_fsync_interleaving_simulation_test.odin` | 3 | 2.68 s | 22,136 KiB |
| `integrated_persistence_fault_simulation_test.odin` | 11 | 2.50 s | 122,344 KiB |
| `integrated_handler_simulation_test.odin` | 2 | 2.30 s | 44,244 KiB |
| `edge_equivalence_simulation_test.odin` | 1 | 2.19 s | 18,240 KiB |
| `lifecycle_malformed_simulation_test.odin` | 1 | 2.13 s | 18,408 KiB |
| `semantic_handler_graph_swarm_simulation_test.odin` | 1 | 2.07 s | 18,936 KiB |
| `dm_authorization_simulation_test.odin` | 13 | 0.39 s | 90,968 KiB |
| Remaining six simulation files | 9 | 0.56 s | ≤109,248 KiB each |

The largest mandatory anchor is
`test_simulation_two_worker_shards_recover_exact_cross_worker_durable_prefix` at 14.85 seconds when run alone.
It exhausts cross-worker receive-chain merges, durability masks, completion outcomes, and continuation order. The
largest compaction anchor is `test_shard_compaction_repeated_publication_fault_coverage` at 7.75 seconds alone.

## Duplication Assessment

No test should be removed or merged from this measurement alone.

- The fixed two-worker matrix exhausts bounded schedule dimensions; the generated two-worker campaign adds
  semantic histories, fsync errors, arbitrary global ranks, and shrinking. They share a subsystem, not an oracle.
- The repeated-publication matrix guarantees every fault pair; its Hegel companion varies history shape and shrinks.
- Focused parser/query properties provide independent expected-byte and nonmutation models that global histories do
  not reproduce.
- Focused connection and retained-message models explore much larger state counts than the bounded global histories.

This is intentional layered coverage under the plan's duplication rule: production path, generated/fault dimension,
and oracle would all need to match before coverage is redundant.

## Budget Decision

1. Keep the bounded full simulation suite in PR/push CI.
2. Keep the nightly full-suite 4× multiplier and one-process execution for now. Splitting it would repeat native and
   production lifecycle setup, complicate artifact provenance, and solve no observed time problem.
3. Do not raise the blanket multiplier above 4× until peak memory is measured on the actual GitHub runner or the
   high-memory properties are isolated. The small-orb run already reached 2.23 GiB RSS.
4. Do not add a campaign-budget registry or new profile abstraction.
5. Re-run this baseline after a material workload/budget change, an Odin/libhegel upgrade, or a 25% suite-time or
   memory regression.

The next testing investment should use the existing kcov artifact and direct source review to identify an untested,
high-impact production decision path. Add or extend a campaign only if that review finds a new causal invariant.
