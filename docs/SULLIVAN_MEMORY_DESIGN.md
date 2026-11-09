# Personal Sullivan memory

Status: private execution, storage/tree core, gated Ask/GPT Live integration,
durable run recovery, approval receipts, forgetting cancellation and backend
retention controls, web/native privacy settings, opt-in store wiring, background
summaries, revision polling, Live context acknowledgments, whole-call admission
and storage maintenance implemented locally. Latest isolated real-provider runs
passed 90/90 long requests, 30/30 long content controls, 21/21 short controls and
3/3 chat-to-GPT-Live recalls at the standard budget. Exact voice quotations passed
2/3: one answer added a period absent from the original transcript. The existing
short-conversation latency regression remains; cache hit rates alone do not prove
lower cost. Real-browser two-tab revision/forget synchronization passed earlier.
Native rendering and Android unit/lint checks passed; physical-device audio and
acoustic playback remain unverified. One unchanged shared diagnostic test expects
protocol 8 from a protocol 9 fixture. Changes are uncommitted and not deployed.
Updated 2026-11-09.

### Sol summary default: repeated real-provider long tests

OpenAI summaries now default to `gpt-6.1-sol`; other providers retain `LLM_MODEL`.
An explicit `NRC_MEMORY_SUMMARY_MODEL` still overrides the default. Foreground
selection, shared output allowance, tool restrictions and memory safety rules
are unchanged. No production configuration was changed.

Three fresh conversations of 27 turns each, plus fresh-session/restart recall and
isolation/deletion controls, passed 90/90 HTTP requests and 30/30 content checks.
This used a real isolated NRC and AI service with real OpenAI requests, the
128,000 admission budget and the shared 8192 output-token default. Captured
request/response metadata confirms 66 Sol summary calls and 131 Terra foreground
calls, all completed successfully with matching model identifiers and 8192 limits.
All Sol requests had zero tools. All three original-source answers cited sequence
0 and preserved the exact emergency phrase/compartment. Fresh and restarted
sessions distinguished the current 9061 code from obsolete 8426 and 7319.

First-call cached-input share was 92.15% on turns 18–21 and 92.35% on turns 22–27.
Post-boundary request latency was 3.966 seconds median, versus 3.534 in the older
Terra-summary run; foreground calls for those 18 requests were 43 versus 39.
These separate live runs use different summary/output configurations and do not
establish a causal speed comparison. Summaries consumed 7577 output tokens,
including reasoning. Standard list-price estimates from raw provider usage,
including 30-minute cache writes, are $0.23753 for summaries and $0.23728 for
foreground calls ($0.47481 total), not measured billing charges.

After worker drain, all 166 nodes were ready (including deletion tombstones),
with zero pending/exhausted nodes; maximum stored summary length was 507 bytes.
No node revision needed more than one build attempt. Deleted segment bodies were
empty. Full serial-package AI/memory race tests, Go vet and real-process NRC
receipt/approval/SIGTERM controls passed. The latter use fixture model/voice
providers; real voice/audio and UI tests were not repeated for this model switch.

Evidence: `.amp/in/artifacts/cache-proof/long-sol-summary/`, plus
`sol-summary-checks.log` in its parent directory. Binary
`.amp/in/cache-proof/sol-summary-bin` SHA-256:
`eab22f2251e31bf4fefc12def410db39b5240dc5203005baf2488fe774c5b1ff`.
The historical measurements below describe earlier builds, not this Sol run.

The subsequent overall review found and fixed two additional cases: rejected
stale-session requests were captured after forgetting, and a valid escape-heavy
original could block later summaries. Session validation now precedes new input
admission; read-only digest-checked replay still works after session loss. Failed
summaries, including deadline failures, yield to other eligible work in the scope.
The final follow-up review found no blockers in these corrections.

Verification after these fixes: the full AI/memory race suite and Go vet pass.
An identical real-process fixture with 32,600 backslashes fails on the retained
pre-fix binary and passes on the final binary. Real local NRC approval/receipt,
SIGTERM and restart tests also pass, using fixture model/voice providers.
The final binary was then retested with real local NRC and OpenAI gpt-6.1-terra,
at the unchanged 128,000 budget: 90/90 HTTP requests and 30/30 content checks pass.
Three conversations each span 27 turns, with fresh-session/restart recall,
corrections, original-source recall, owner/workspace isolation and forgetting.
The first-call cached-input share is 91.7% on turns 18–21 and 92.7% on turns 22–27.
This does not establish a speed improvement: post-boundary request latency is
3.534 seconds median versus 1.594 in the earlier comparison run, with 39 rather
than 26 model calls for those 18 requests. Background summaries use 157 calls
versus 115 previously; three were interrupted during restart/shutdown, and the
final drain leaves zero ready jobs. These are separate live runs, not a controlled
same-time performance experiment. Short/voice provider tests were not repeated.
Raw final provider evidence is under `.amp/in/artifacts/cache-proof/long-review-final/`.
Logs and binary hashes are under `.amp/in/artifacts/cache-proof/review-final/`.
Cleanup removed 547,342,570 bytes of superseded proof executables. `gist-final-bin`
is the retained pre-fix comparison; `review-final-bin` is the final build, both
under `.amp/in/cache-proof/`. Evidence, fixtures, and safety ledgers were retained.

Cost investigation with identical eight-segment fixtures found frequent 512-byte
summary violations. At that point, five model calls bounded one compression attempt,
but the worker retried failed pending nodes indefinitely. On that binary, Terra needed
21 and 36 calls; Sol needed 7, 7 and 9, with the same 450-output-token limit.
All three Sol runs preserved the checked names, codes and correction order, and
completed all 15 tree nodes. This is a summary-worker comparison, not a Sol chat
or voice E2E test. Actual monetary savings require the configured provider rates.
The current correction format also changes the source message itself, reducing
reusable message prefixes; separating the correction is a candidate, not yet a fix.
No model setting was changed outside disposable tests. `gpt-6.1-luna` returned
404/model_not_found; the provider lists `gpt-6-luna`, not a 6.1 Luna variant.
Evidence is under `.amp/in/artifacts/cache-proof/cost-investigation/`.

The subsequent `gpt-6-luna` comparison completed three runs (6, 21 and 8 calls;
26.3, 112.7 and 28.0 seconds), but only one root summary retained all checked
facts. Two runs stored provider-truncated text as ready summaries. Responses
reported `incomplete` / `finish_reason=length` at the 450-token cap, often consumed
mostly by reasoning. The adapter then accepted nonempty text within 512 bytes
without checking the finish reason. This was a correctness defect, not evidence
that Luna completed the task cheaply. Stored originals remained intact.

### Finish validation, retry limits and larger-budget comparison

The adapter now requires `FinishReasonStop` before accepting generated text.
Truncated, filtered and unknown finishes fail closed. Each node revision has three
durable build attempts, reserved before generation; restarting or rebuilding the
derived queue does not reset them. A changed source revision gets a fresh allowance.
Each build retains the five-generation length-correction limit per fragment and
adds a shared 16-generation allowance across recursive splitting. Fantasy's own
provider retry loop is disabled for summaries. Exhaustion leaves a node pending
and its originals readable; it does not clip source text or mark the node ready.
Other eligible nodes continue. There is no automatic reset on a model/config change.

The comparison build exposed a separate summary output cap. At the user's request,
that setting was subsequently removed: summaries now inherit the same
`LLM_MAX_OUTPUT_TOKENS` as chat, including reasoning (8192 by default for OpenAI).
This follows UniiChat's shared-limit approach, not unlimited generation: its
inspected implementation used a shared 128,000 maximum. NRC's existing whole-call
admission and shared model defaults are unchanged. The stored-summary limit remains
512 UTF-8 bytes. The summary model now defaults to `gpt-6.1-sol` for OpenAI and
`LLM_MODEL` for other providers; `NRC_MEMORY_SUMMARY_MODEL` overrides that choice.
No production configuration was changed. The numbers below describe the earlier explicit-cap
comparison, not a new 8192-token model comparison.

Twelve real-provider summary-worker trials used identical eight-segment stores,
the standard 128,000 admission budget, and the same patched binary. Each of four
model/budget combinations ran three times. Calls and tokens below are medians
per entire fixture, including unsuccessful work; output includes reasoning.

| Model / output cap | Complete trees | Roots with all seven checked facts | Calls | Output tokens |
| --- | --- | --- | --- | --- |
| GPT-6.1 Sol / 2048 | 3/3 | 3/3 | 7 | 1094 |
| GPT-6.1 Sol / 4096 | 3/3 | 3/3 | 7 | 1178 |
| GPT-6 Luna / 2048 | 0/3 | 0/3 | 20 | 6593 |
| GPT-6 Luna / 4096 | 2/3 | 1/3 | 19 | 5896 |

Sol finished in 21.6–28.1 seconds at 2048 and 20.9–25.0 seconds at 4096.
Luna's completed 4096 fixtures took 22.3 and 75.6 seconds. The other four Luna
fixtures exhausted attempts and remained unfinished at the harness's 180-second
observation limit; that includes idle time after retries stopped, not 180 seconds
of generation. All 151 provider responses completed normally, with no HTTP errors.
The larger budgets removed observed truncation but did not fix Luna's repeated
512-byte violations: 50 oversized outputs at 2048 and 27 at 4096, versus one
and zero for Sol. No stored summary exceeded 512 bytes and all originals matched
the input fixture exactly. A failed Luna store was restarted for ten seconds:
the process rebuilt the queue but made zero additional provider calls.

Manual root review confirmed Sol preserved the current/obsolete code ordering
and distinguished assistant claims from verified writes. Luna's first completed
root omitted the emergency phrase, compartment and city. Its other completed
root retained those facts but stated that no records were created without keeping
the attribution to the assistant. This is a small summary workload, not a broad
model-quality benchmark or a new full chat/voice long test. Provider caches cannot
be flushed; currency savings require the actual model-specific prices.

Sol was more reliable in this workload; 4096 did not improve its checked outcomes
over 2048. The subsequent user decision was to remove the separate summary cap.
Isolation, deletion and approval code is unchanged.
Regression tests failed before the fixes and pass afterward. The full AI/memory
race suite passes with serial package execution, Go vet passes, and real local NRC
receipt/approval, SIGTERM and AI-process tests pass with fixture providers. The
first parallel-package race run failed `TestVoiceCoalescesPublicTranscriptEvents`
at its closed-listener assertion; it passed in isolation and the serial full run.
This timing-sensitive failure remains recorded rather than omitted.

Evidence: `.amp/in/artifacts/cache-proof/cost-investigation/token-budgets/`, including
raw calls, roots, per-trial token counts, before/after tests and cleanup metadata.
The tested binary is `.amp/in/cache-proof/retry-final-bin`, SHA-256
`d80b01b7933b516221a16d8a890f2852d63c2d6d7bc2d56b2141d1402b582106`.
That comparison build is retained. The subsequent shared-limit build is
`.amp/in/cache-proof/shared-output-bin`, SHA-256
`45b24c92c75f160076fd81bf18da7b64aa084b08bfe71339d0defa9487c8425b`.
Its real-process fixture sets the global output limit to 16,384 and checks the
actual outgoing summary HTTP requests. The old binary fails with 2048; the new
binary passes. Targeted race tests, AI-process/NRC receipt/SIGTERM tests and Go vet
pass after this change. The real-provider comparison at the shared default follows below.
All proof processes stopped; temporary provider credentials and the seed executable were removed.
Changes remain uncommitted and undeployed.

### Sol, Luna and Terra at the shared 8192-token default

Nine fresh-store runs used the same eight source segments, 128,000 admission
budget and unchanged shared-limit binary (SHA-256 above). Three runs per model
rotated model order. Both output-limit environment overrides were removed, and
all 144 outgoing provider requests were verified to use the actual default 8192.
Provider response model identifiers matched the requested models.

| Model | Complete trees | Roots with all seven facts | Median calls | Median output tokens including reasoning |
| --- | --- | --- | --- | --- |
| GPT-6.1 Sol | 3/3 | 3/3 | 7 | 940 |
| GPT-6.1 Terra | 2/3 | 2/3 | 28 | 4006 |
| GPT-6 Luna | 2/3 | 1/3 | 19 | 6425 |

These medians include failed workloads. Sol completed in 20.9–28.4 seconds,
Terra's completed runs in 32.5 and 84.9 seconds, and Luna's in 22.1 and 92.5
seconds. One Terra run and one Luna run exhausted node attempts and remained
unfinished at the 180-second observation limit, including idle time after retries
stopped. No HTTP failures or incomplete generations occurred. Terra produced 56
oversized candidates and Luna 28; Sol produced none. The stored summaries all
respected 512 bytes and all originals remained byte-for-byte equivalent to the
source fixture. No action tools were sent; no node exceeded three build attempts.

Sol preserved the correction order and qualified assistant claims about workspace
writes in all three roots. Both completed Terra roots retained the checked facts
and attributed the no-write claim to the assistant. One completed Luna root omitted
Velvet Cedar, Q-64 and Berlin. The other retained the facts but stated that no
workspace records had been created without preserving the assistant attribution.

Sol remains the most reliable summarizer in this small workload. More output
headroom did not resolve Terra/Luna's byte-limit failures or Luna's omissions.
This was the real AI summary worker with a real provider, not a new full chat/voice
long test. Currency costs need actual provider rates, and provider cache warmth
could not be controlled. No application code or production model setting changed.

Evidence is under `.amp/in/artifacts/cache-proof/cost-investigation/shared-standard/`.
All processes stopped; temporary credentials and the seed executable were removed.
The rebuilt binary matched the retained shared-output binary exactly, so the
91,287,831-byte duplicate was removed. Logs, raw calls, source stores and analysis
remain available; the evidence scan found no provider-key matches.

Ask and GPT Live use signed human identity, owner/workspace checks and expiring
authorization. The web client requests personal memory by default for Ask and
voice; temporary mode is an explicit page choice. Legacy API requests without
an execution policy still default to temporary. Private/temporary sessions
suppress room progress and automatic conversation-to-workspace retrieval.
Tool lookup queries are bounded to 160
single-line bytes, and process logs use a metadata allowlist. These limits do
not prove that a model-selected short query contains no sensitive information.

The `services/bots/nrc-ai/personal_memory` package implements SQLite WAL/FULL
originals, stable sequence numbers, active/terminal capture states, FTS5, a binary
summary forest, bounded views and revision-checked expansion. Summaries build
outside transactions and publish only against the same source revision.
Views reserve compact root references before summary text, so pending work never
removes the navigation path to older originals. A missing preview is not missing
history. Original reads page up to 32 fragments and 4,096 text bytes; supplemental
literal-keyword search returns newest matches first to favor recent corrections.
Forgetting removes readable originals and FTS entries and invalidates ancestors;
late fragments and in-flight summary jobs cannot restore them. Pending nodes
remain durable. A transactionally maintained ready queue indexes jobs whose
dependencies have completed; startup rebuilds it after recovery. Runtime work
selection does not rescan historical trees. Original fragments can be appended,
not rewritten.

The integration accepts an internal owner/workspace capability, not an HTTP flag
or model-selected identity. Retained Ask uses a persisted chronological tree
partition instead of the rolling 20-turn session window. Ready summaries append
without changing earlier entries. At the byte high-water mark, ready siblings
merge in batches toward half the budget, prioritizing
`(segment count - pair's last sequence) / child width`, with oldest-first ties.
The pending half-budget target survives requests and restarts. Large leaves can
use fitting ready ancestors without first admitting every child. The stored layout contains only
node bounds, revisions, capacity and pending target; source changes and deletion
invalidate it. A smaller request projects the layout without replacing it.

The model adapter derives canonical history capacity from stable normalized
instructions, tool schemas and output reserve, independent of question length.
It checks the whole call again after insertion and on every tool step.
Four-node user-level blocks preserve cacheable
message boundaries; the last full block receives the OpenAI cache breakpoint.
A separately bounded suffix carries recent/pending evidence. One snapshot remains
fixed through a run's tool steps. Read-only expansion, paginated originals and
search remain available when context is incomplete.
Concurrent identical private-prefix requests may wait for the first provider
response headers, for at most one second. Coordination uses an owner/workspace/
epoch-qualified digest and retains no completed entries or prompt text. Provider
cache lifetime and cache hits are not guaranteed.

Ask commits the user original before generation and the answer before returning
success. GPT Live retains its compact 6,000-byte startup preview as untrusted
`session.input` and `store:false`; delegated reasoning uses the same stable tree
as chat. Temporary mode receives neither personal history nor memory tools.

Voice captures exact transcript events with provider session/event IDs and timing,
deduplicates replayed IDs, and retains backend answers separately. Adjacent same-role
fragments share a bounded segment, but each fragment commits durably before acceptance.
Role changes, explicit turn boundaries and size limits seal segments; normal session
closure seals the remainder. Disconnection marks only still-active captures incomplete.
Synthetic delegation prompts are not stored as duplicate user conversations. A model summarizer adapter
and background worker build pending leaves and parents. Inputs of at most 512
UTF-8 bytes retain exact role-labeled text; short child summaries concatenate
without a model call. Larger inputs use a tool-free summarizer with a separate
stable, bounded prior-history view. Context excludes future segments and remains
owner/epoch-bound. Oversized model output receives up to four correction attempts
after the first attempt; oversized text is never silently truncated or published.
Evidence is sent as role-labeled text without nested JSON escaping. Budget-rejected
inputs split at UTF-8 boundaries and their summaries are recompressed, without
changing stored originals. Correction attempts retain one source and the latest
bounded correction. Splitting stops at 1,024 bytes and recompression must shrink;
an insufficient budget fails closed. A chunk may start inside a record, so its
prompt warns that evidence can be fragmentary. Chunking does not guarantee model
attribution or recall. Failed-attempt priority is derived state, rebuilt on restart.

The worker discovers persisted work after restart and pages through enabled
owner/workspace scopes. Up to eight scopes run concurrently, one job per scope,
with a 45-second deadline. Finished slots refill without waiting for slower peers.
Idle sweeps and failed scopes wait one second. Eligible parents build before newer
leaf backlogs. Forget-all marks empty subtrees ready locally without billed
tombstone-summary work.
Failed summaries stay pending. Forgetting cancels model work and fences publication.
Summary usage has a separate numeric timing/token log, including retries. Unlike
UniiChat's shared conversation/summary prompt, the summarizer has no action tools;
its prefix cache is separate from Ask's. Isolation, explicit approvals and deletion
fences take precedence over sharing those prefixes.

Retained Ask requests require a client-generated `run_id` before submission.
Acceptance atomically stores the request digest, original and tree leaf. Repeating
the same request returns saved evidence/status without generating again, even
after the agent session disappears. Reusing the ID with changed input is refused.
GPT Live backend runs use `<voice-session-id>/<revision>`; their records identify
the delegation without duplicating the synthetic prompt. Completed backend answers
remain complete even if subsequent audio delivery fails. On opening the store,
active captures become incomplete and their revisions advance. A process file lock
prevents another instance from marking a live instance's work incomplete.

Memory-enabled Apply consumes each selected action durably before dispatch.
Receipts are scoped by owner, workspace, channel, agent session, plan and action.
They retain a proposal digest and bounded result IDs/status, not private titles or
tool output. A consumed approval never grants another dispatch, including after
known failure. Until a result commits, the receipt says `outcome_unknown`; this
also covers a crash just before dispatch. Recovery cannot distinguish that case
from a committed write whose acknowledgment was lost. Receipt persistence failure
stops remaining actions and returns an error rather than claiming durable success.
Retained dispatch uses a request-owned snapshot of the approved plan. Session
reset cannot discard acknowledged IDs or cancel an already-approved selection.
The public action stays applying until its receipt commits, so concurrent retries
cannot report success during finalization. Compound task receipts include created
reference edges and failed/unknown edge endpoints; an uncertain edge makes the
overall outcome unknown even when task creation succeeded.
Voice keeps its existing revision and explicit-selection checks and separate plan
store. Plans remain ephemeral and are never restored from history.

Authenticated `POST /ask/run/status` and `POST /ask/receipt/status` return evidence
without an agent session. Both require the internal memory capability. The body
contains `workspace`, `channel` (`chat` or `voice`), and either `run_id` or
`session_id`, `plan_id`, `action_id`. Run deletion hides its originals but retains
the idempotency tombstone; retrying cannot recreate the deleted conversation.
Receipts currently remain a separate recovery ledger, not tree evidence.

Forgetting and policy changes advance a durable owner/workspace epoch after a
successful transaction and cancel that scope's active executions. Ask cancels
the provider request; GPT Live receives `session.close`. Old sessions and plans
cannot be resumed, read or applied. Fenced scopes reject late capture completion,
transcript fragments, new approvals and summary publication even if a background
callback uses an uncancelled context. Other users' executions continue. Dispatched
receipts can still finalize: forgetting does not roll back NRC writes or remove
the minimal ledger needed to prevent duplicate execution.

Authenticated `POST /ask/memory` requires the internal memory capability and a
`workspace`. Its operations are:

- `inspect`: return enabled state, original usage and the current `epoch`.
- `changes`: return `enabled`, `epoch` and durable owner/workspace `revision`
  without scanning originals. Segment, receipt and policy changes advance it.
- `export`: return original segments using that `epoch`, `after` sequence
  (default -1) and `limit` (default 50, maximum 100). Use the last returned
  sequence for the next page. A policy change or deletion invalidates the epoch.
- `history`: return newest original segments first, using `epoch`, `before`
  (default -1) and `limit` (maximum 100).
- `receipts`: return newest execution receipts first, using `before` position
  and `limit`. These are evidence, never executable plans.
- `configure`: supply `policy` with `epoch` and `enabled`, plus `confirm:true`.
- `forget`: supply a segment's `sequence`, `revision` and `confirm:true`.
- `forget_all`: supply the current `epoch` and `confirm:true`.

The persisted policy is keep-until-deleted, without a total byte or segment quota
and without timed expiry. Individual originals retain their 64 KiB validation
limit. Legacy quota columns are ignored. Disabled retention preserves exportable history
but refuses new executions and original writes. A new capability or restart
cannot silently re-enable it. Operators must provision and monitor disk space;
deletion remains logical, not forensic erasure.

`main` opens the store only when `NRC_PERSONAL_MEMORY_PATH` is configured. Visiting
Sullivan initializes new accounts with personal memory enabled, without a consent
dialog. Signed human identity selects the owner/workspace. Saved disablement
survives reload and restart. The database directory must be 0700 and the file 0600;
Compose supplies a volume owned by the non-root service user. An invalid or locked
configured store fails startup instead of silently losing history.
The summary worker uses `NRC_MEMORY_SUMMARY_MODEL` on the configured LLM provider,
or `LLM_MODEL` when unset. It can incur provider charges while users are offline.
Ordinary temporary sessions keep their existing approval behavior.
GPT Live appends carry event IDs: only matching provider acknowledgments confirm
timeline delivery. Rejection and disconnect remain visible as unconfirmed delivery;
acknowledgment does not prove speech playback. Every Fantasy model call checks the
complete serialized input and tools against a conservative byte-based budget,
reserving maximum output. This is not exact tokenizer accounting. Excess input
returns HTTP 413 without truncation or retries.
Maintenance checkpoints WAL each minute, checks disk pressure and considers daily
compaction. Originals and consumed approval/run guards have no timed expiry.
SQLite deletion is logical exclusion, not erasure from old WAL files, snapshots
or backups. The [storage operations procedure](../services/bots/nrc-ai/personal_memory/STORAGE_OPERATIONS.md)
provides consistent snapshots and offline restore with current deletion and
execution guards. It requires the latest authoritative safety source: an old
backup alone cannot safely recover a lost ledger. Production volume permissions,
encrypted backups and alert routing remain deployment responsibilities.

The web conversation has a direct TEMPORÄR toggle, not a memory menu. Chat and voice
start without a consent prompt. New accounts use personal memory; a saved opt-out
starts temporary conversations instead. Sullivan memory in the existing Settings
command group offers on/off/export/forget, with selectable action suggestions.
Only deletion opens a confirmation. There are no quota fields, segment IDs or
tree-management controls. TEMPORÄR changes only this page's chat/voice mode;
it does not delete history or change saved retention.
Policy changes end local sessions and require fresh plans. A failed or conflicting
write requires inspection before another attempt; the client never retries it.
Personal requests send `require_memory:true`, so absent memory access cannot
silently downgrade to an unretained chat or voice session. Unavailable storage
leaves the explicit temporary action accessible. Retained Ask creates a UUID
before submission. The client restores recent originals and pages older messages;
matching run IDs suppress duplicates of local live cards. Prior approval receipts
are read-only evidence. Restoration never plays audio or recreates approval buttons.
Five-second revision polling refreshes completion, voice and other-device updates.
An epoch change clears cached personal transcripts and cancels personal conversations,
including after switching to temporary mode. Explicitly temporary content and running
temporary requests survive remote invalidation. Explicit local forgetting clears both.
Policy inspection and configuration reconcile old context before admitting new work;
unchanged revisions cause no original-body scan. Foregrounding also checks revisions.
New user evidence advances an owner/workspace input generation shared by chat and voice.
Proposals retain their run's generation, including through internal voice delegation;
approval consumption atomically rejects proposals predating any newer user input.
Assistant output, summaries and receipts do not advance this generation.
Authenticated middleware now connects these controls to persisted policy and the
internal capability. Execution still checks enabled retention and the current epoch.
Native voice checks saved retention before opening audio. Its existing action menu
offers temporary voice; durable memory controls live in Connection settings, without
a nested menu. The voice disclosure no longer contains a memory form. Export collects
epoch-bound pages and uses Android's Save document picker, not an in-app JSON viewer.
Account changes invalidate pending exports. Export buffers are held in memory rather
than private staging files; a cancelled write can leave a partial user-selected file.
Native Sullivan text chat is not part of the existing mobile client.
After audio closes, native voice makes one bounded terminal status request to check
for remote invalidation. Confirmed invalidation clears conversational evidence and
fences late callbacks. Ordinary closure or a failed terminal check preserves evidence;
this is not offline deletion synchronization.

The summary tree is the core memory architecture. The first complete feature must
give Sullivan a bounded overview of retained conversation history and let it
expand summaries back to original evidence. Search supplements tree navigation;
it does not replace it.

This design adapts [Uniichat's memory tree](https://github.com/VictorTaelin/uniichat/blob/main/Memory.ts)
to NRC's existing typed Ask and GPT Live integration. It incorporates the privacy
and durability prerequisites found during design review. It does not introduce
a new speech-to-text/text-to-speech pipeline or replace GPT Live.

## Scope and existing implementation

One authenticated user within one workspace owns one durable personal history.
Chat and voice use the same memory, including across devices. Workspace records
remain authoritative for current facts; memory records what was discussed.

The implementation baseline inspected for this design is commit
[`2c0eb5c`](https://github.com/HeavyHorst/nrc/commit/2c0eb5c96d926ff5254994334253a99937fb1f10):

- [voice.go](../services/bots/nrc-ai/voice.go) creates `gpt-live-1` sessions,
  attaches a server-side WebSocket, handles transcripts and delegates work to Ask.
- [agent_session.go](../services/bots/nrc-ai/agent_session.go) stores ephemeral
  Ask sessions. These have workspace scope but no user-owner field.
- [ask_fantasy_handler.go](../services/bots/nrc-ai/ask_fantasy_handler.go) owns
  Ask context, retrieval, tools and model execution.
- [ask_apply.go](../services/bots/nrc-ai/ask_apply.go) owns approval execution
  and session access endpoints.
- [client/voice.js](../client/voice.js) and the mobile
  [VoiceClient](../mobile/shared/src/commonMain/kotlin/dev/nrc/chat/VoiceClient.kt)
  already use native WebRTC audio and explicit action approval.

Keep GPT Live's native speech-to-speech path, voice/personality settings and
backend delegation. Keep voice plans separate from text plans: shared memory
must not make voice proposals executable through ordinary `/ask/apply`.

Personal memory is private from other NRC users, not from the server operator
or configured model providers. Cross-workspace recall, meeting recording,
provider-recording-based memory and multi-replica storage are outside the first
version. No Odin asset or protocol changes are proposed for personal history.

## Identity and private execution are prerequisites

Use an issuer-qualified stable human principal, mapped to an internal owner ID.
Nicknames and mutable login display strings are not permanent memory keys.
Define account-renaming/migration behavior before rollout. Reject machine-tag
identities for personal mode unless a separate human identity is authenticated.

The proxy strips caller-supplied identity assertions and issues an AI-specific
signed assertion with issuer, audience, expiry, principal and authorized
workspace. The AI service validates it. Every history, session, search, run,
plan, approval, receipt, reset and deletion operation checks owner and workspace.
New routes must remain covered by the proxy's workspace authorization policy.

Internal voice delegation passes the already validated principal through an
explicit internal context. The synthetic `voiceCall` HTTP adapter must not
become an authentication bypass when Ask gains owner checks. Do not import
ownerless legacy sessions automatically.

Define an enforceable authorization lease or invalidation mechanism, including
its maximum revocation delay. Revocation stops further tool access/publication
and closes affected Live sessions; checking only session creation is insufficient.

Personal and temporary modes are server-enforced execution policies:

- Personal "remember this" requests must not implicitly create shared notes.
- Do not automatically forward accumulated private transcripts to workspace
  retrieval. Use a minimal scoped query when workspace evidence is needed.
- Keep personal content out of room progress messages and shared search indexes.
- Use allowlisted metadata-only logs; existing tool argument/outcome logging
  needs review, including error paths.
- Temporary conversations neither read nor write personal memory, including
  through delegated calls, tools, caches and background jobs.
- Publishing personal content into shared NRC records requires explicit approval.

## Durable originals and a binary summary tree

Each owner/workspace has durable originals, a tree over closed conversation
segments, an active unsummarized tail and explicit preferences with provenance.

A closed segment receives a stable sequence number and a bounded leaf summary
linked to its originals. Adjacent sibling summaries merge into bounded parent
summaries recursively. Keep stable leaf positions: deletion leaves a tombstone
rather than renumbering later history. The append-only structure can have several
top-level roots until enough siblings exist to merge.

Each node records:

| Field | Contract |
| --- | --- |
| Owner and workspace | Server-enforced privacy scope |
| Covered leaf range | History represented by the node |
| Child references | Navigation toward more detail |
| Summary text | Bounded historical overview |
| Source revisions | Detect corrections and stale builds |
| Model/prompt version | Controlled rebuilding and provenance |
| Build state | Pending, ready or invalidated |

A cheaper model builds summaries through durable background jobs. A job commits
only if its source revisions still match. No audio response waits for a parent
summary to finish. Summary text is derived, untrusted evidence. Retain originals
until the user's retention or deletion policy removes them.

Corrections version affected segments and invalidate ancestors. A new message
correcting a past factual statement remains new evidence; preserve the earlier
statement's historical status and record that it was superseded where applicable.
Do not rewrite the original conversation as though the correction came first.

## A bounded view covers retained history

The context builder selects non-overlapping nodes covering retained history.
Recent segments appear in more detail; older segments use broader summaries.
Active conversation is explicit context outside the stable tree. Node references
and time ranges let the assistant locate the underlying evidence.

Expose owner-scoped, read-only tools:

- `expand_memory(node_id)` returns children or leaf source references.
- `read_memory(segment_id, ...)` reads paginated originals.
- `search_memory(query, ...)` finds details whose clues disappeared in summaries.

The tree provides historical context before Sullivan knows what to search for.
Search is a second route into the same evidence. Start with full-text/date lookup;
add semantic retrieval only if measured recall failures warrant it.

Budget the entire model request, including instructions, current input, memory,
workspace evidence, tool results and output. Prefer stable node selection and
prompt ordering to avoid unnecessary cache invalidation; measure provider cache
savings rather than assuming them.

Missing summaries and rebuilds can prevent full historical coverage within the
budget. Use valid summaries or bounded originals and expose the coverage gap.
Never serve invalidated summaries or label a partial view as complete. Original
retention does not guarantee perfect model recall.

## Voice fragments form a revisable active tail

GPT Live has no completed-turn event. Speakers can overlap, and fragments can
arrive late. The current concatenated transcript is working context, not the
durable source of truth.

Persist original fragments incrementally with the NRC conversation ID, provider
session ID, event ID, speaker, exact delta text, `start_ms`, `end_ms` and receive
sequence. Deduplicate within the provider session by event ID. Preserve spaces
and repeated words. Use timeline information for display grouping without
discarding arrival order or original fragments.

For the initial implementation:

1. Keep the current voice session outside the stable tree as the active tail.
2. After closure and event drain, partition captured history into bounded
   segments and build leaves. One session may produce several leaves.
3. On unexpected disconnect, seal the captured segments with an incomplete
   capture marker. Do not claim complete transcription of audio that bypassed
   the server or of events lost before local commit.
4. Late fragments revise affected segments and invalidate their ancestors.

Completed text exchanges are eligible for leaves. Failed and cancelled runs
retain their actual states rather than disappearing. Application-defined segment
closure is not a claim that the provider confirmed a complete conversational turn.

## GPT Live consumes the same tree through the existing bridge

At session creation, build a compact tree overview plus recent conversation.
Supply historical evidence through `session.input`, preserving original message
roles where appropriate and labeling summaries as historical evidence. Never
promote retrieved memory into trusted application instructions.

Initially target roughly 4,000 startup history tokens, within the documented
128-message/8,192-token limit. This is a tuning target, not a recall guarantee.
Keep the existing voice/personality instructions and configured custom voice.

During a session, GPT Live delegates deeper recall to Ask. Ask expands the same
tree and reads originals. Use `session.thinking.append` for concise background
facts and `session.commentary.append` for results to communicate. Reserve
`session.instructions.append` for trusted application behavior. Each append has
a documented 500-token limit; track event IDs, acknowledgements, timeouts and
errors. An acknowledgement proves neither model use nor user playback.

Do not continuously stream rebuilt trees into Live. Send targeted updates;
the next session gets a fresh tree view. Explicitly set `store: false` and do
not use provider recordings/forking as the memory backend. Provider processing
and broader retention policies still apply.

Keep the existing ten-minute, 64-delegation and 24,000-transcript-byte limits.
Long-term memory continues across sessions; it does not require a permanently
running voice session or an automatic billed restart. Cross-device history does
not imply transfer of an existing WebRTC connection.

## Preserve evidence and approval boundaries

Store and link user speech, Live output, full Ask answers/proposals and action
receipts as distinct evidence. Link them by delegation and revision where known.
Do not persist unrestricted tool dumps. Define permitted stored fields explicitly.

Summaries should cover a linked interaction once while preserving disagreements
and distinguishing proposed, confirmed and unknown outcomes. A backend answer and
its spoken paraphrase are not independent confirmations. Output transcript text
does not prove playback; delivery remains unknown without meaningful client
evidence, and even playback evidence does not prove the person heard it.

Durable history, model runs and approval receipts are separate from disposable
agent sessions and executable plans:

- Accept runs durably with idempotency keys; persist completion before returning
  success. Failed HTTP delivery changes delivery state, not conversation history.
- Each run reads a named memory snapshot. Use a server sequence for durable
  ordering; provider-relative timestamps are provenance, not cross-device order.
- Keep proposals immutable per run and retain channel-specific approval checks.
- Cross-channel corrections invalidate affected proposals through backend
  revision checks. A silent context append cannot make an old proposal safe.
- Persist approval consumption before dispatch. A crash between an NRC write
  and its receipt leaves an unknown outcome, never an automatic redispatch.
- Coordinate mutations per owner/workspace. Do not serialize the audio stream
  behind text generation or pretend that SQLite and an NRC write are atomic.
- Preserve existing voice safeguards: new speech invalidates proposals, late
  fragments can rerun delegation, spoken agreement is not approval, and stopping
  playback does not cancel an already-confirmed write.

Expose durable receipt recovery across restarts and devices without reviving
consumed approvals. Active clients must distinguish pending/failed context
updates from context known to have been delivered to the model timeline.

## Retention and forgetting ship with persistence

Personal retention is enabled by default for new accounts. The mode is keep until
deleted, without a per-user storage quota. Do not
silently discard history or claim an unsaved message was remembered when storage
is unavailable or full. Personal retention is separate from room/DM retention.

Provide inspect, export, correction and forget controls. A new topic resets
working context while permitting historical recall; a temporary conversation
does not use personal memory. Create persistent preferences only on an explicit
request, with an editable confirmation.

For forgetting or retention expiry, immediately exclude affected originals and
derived nodes, invalidate ancestors and rebuild from surviving evidence. Remove
derived preferences, search entries and caches too. Revision fences prevent
late model runs, summary jobs and receipts from recreating deleted content.

Close affected Live sessions and cancel affected Ask runs: removing local records
cannot erase information already supplied to an active model. Handle dispatched
mutations separately from conversational deletion. Define what minimum operation
metadata must survive to avoid retrying an ambiguous write, without retaining
deleted conversation content.

Document backup expiry and deletion replay after restoration. Data already sent
to a provider cannot be recalled through a local deletion. Restrict the data
volume and encrypt storage/backups operationally; this is not end-to-end
encryption from the server operator.

## Storage and implementation ownership

SQLite with WAL and FTS5 is the proposed store, owned by one `nrc-ai` instance
on a local persistent volume. It is an additional dependency despite other NRC
sidecars using bbolt; ordered evidence, transactions and full-text lookup justify
evaluating it. Verify driver/FTS5 support with the current CGO-disabled image and
non-root volume ownership before adopting a driver.

Store conversations, original records, runs, approvals/receipts, tree nodes,
explicit preferences and durable jobs. Keep transactions short and never hold
one during a model call. Use supported database backups rather than copying a
live database file without its WAL state.

Implementation stays mainly in `services/bots/nrc-ai`, the auth proxy,
`client/ai.js`, the existing web/mobile voice clients and Compose storage wiring.
No provider audio transport replacement is needed.

## Delivery order and acceptance

1. Establish human identity and private/temporary execution boundaries.
2. Add durable originals, deletion and crash-safe run/outcome records.
3. Implement tree construction, bounded views, expansion and original-source reads.
4. Integrate Ask/GPT Live context, voice segment sealing and cross-device history.
5. Validate recall, safety, German voice behavior, latency and cost.

The first two stages are foundations, not a replacement feature sold as completed
memory. The first complete release includes the tree. Safety tests accompany
each stage rather than waiting for final performance tuning.

Acceptance scenarios must include:

- An old discussion amid substantial intervening history, resumed through the
  other channel, with exact details recovered through tree expansion. Disable
  search in this scenario so it cannot mask broken tree navigation.
- A broad summary that omits a clue, exercising search as a secondary route.
- Corrections, deletion and late fragments while summary jobs or Ask runs are
  active; invalidated material must not reappear through ancestors or caches.
- Web chat and Android voice continuity without duplicate history or repeated
  action execution. Spoken and backend answers retain separate provenance.
- Two users in the same workspace, forged scope, tagged identities, ownerless
  legacy sessions and workspace revocation during active audio.
- Temporary mode through nested delegation, with no personal reads, writes or
  content leakage through logs, room progress or shared search indexing.
- Concurrent devices, stale proposals, duplicate requests, lost HTTP responses,
  uncertain writes, process crashes, disk-full behavior and backup restoration.
- Unanswered historical questions where Sullivan admits missing evidence.

Measure tree recall and expansion depth, prompt/compactor cost, summary backlog,
latency and context coverage. These are acceptance criteria, not results already
demonstrated by this design.

## References

- [Uniichat](https://github.com/VictorTaelin/uniichat) and its
  [memory implementation](https://github.com/VictorTaelin/uniichat/blob/main/Memory.ts).
- [GPT Live session management](https://developers.openai.com/api/docs/guides/live-conversations),
  including startup history, transcript semantics and context appends. Recheck
  limits and event contracts during implementation.
- [SQLite WAL](https://sqlite.org/wal.html).
- [Design discussion and oracle review](https://ampcode.com/threads/T-01a1b773-cc8c-7477-8346-3ef973c00bc1).
