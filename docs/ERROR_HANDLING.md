# Error Handling Contract

This document defines how request failures are returned to clients.

## Goals

- Eliminate silent request failures for RPC-style operations where clients expect a definitive response.
- Preserve domain-specific error channels where they are part of the protocol contract.
- Keep idempotent/streaming paths lightweight when a no-op is intentional.

## Error Channels

### 1) Generic Error Channel: `S_ErrorResponse` (opcode 104)

Used for generic request failures that are not tied to a domain-specific response opcode.

Wire format:

```
[OriginOpcode: 2B] [ErrorMsgLength: 2B] [ErrorMsg: variable] [CorrelationID: 4B]
```

Rules:

- `origin_opcode` identifies the client request that failed.
- `correlation_id` is echoed when available.
- If parse fails before correlation can be read, server sends `correlation_id = 0`.

#### Retained-send overload

For `C_SendMessageV2` (48), the exact error text `retained_send_overloaded` is
retryable. The wire format is unchanged. It means **this attempt was not newly
staged**, not that the logical message is absent: an earlier attempt with the
same ID may already have committed. Count limits, transient descriptor/lifecycle
pressure, expired deferred sends and a blocked second-generation rotation use
this token. Configured storage quota, corruption and ID/content conflicts do not.

Deferred primaries have a two-second monotonic queue-residence limit, starting
when they enter the ready-to-append queue, not at admission or during asynchronous
dedup lookup. Followers share the primary's outcome; younger independent sends
keep their own deadline. Maintenance checks expiry even during lifecycle work
and before staging. This is not a two-second end-to-end ACK guarantee: scheduling,
lookup, staged writes, fsync and response delivery can take longer. Already-staged
work is never queue-expired. At `rotation_pending && frozen != nil`, known
in-memory duplicates/conflicts are resolved before unknown IDs receive overload.
Stores and their limits are shared by all workspaces hashing to the same shard.

Retry with the same `client_message_id` and identical content within the configured
dedup window (two minutes by default). Retries can change pipelined message order.
The Web client uses separately correlated attempts, bounded jittered backoff and
a 30-second budget from the first write, preserved across reconnect. A valid late
ACK confirms the logical send; a stale attempt's error cannot erase a newer one.
Exhaustion is shown as **unconfirmed**, not proof of storage failure. Operators
must keep the dedup window longer than the retry horizon. The CLI exposes
`retained_send_overloaded` as retryable with a reusable message ID but does not
automatically retry. Updated Web clients also recognize the older admitted-count
error texts; old clients receive a conventional correlated error.

### 2) DM-Specific Error Channel: `S_DMError` (opcode 123)

DM operations use a dedicated error message with DM-specific error codes.

Applies to:

- `C_StartDM` (16)
- `C_ListDMs` (17)
- `C_LeaveDM` (18)

### 3) Task Domain Errors: `S_TaskListResponse(success=false)`

Task handlers currently encode operation-level errors in task response payloads instead of `S_ErrorResponse`.

Applies to task operation failures such as validation/not-found/allocation in:

- `C_CreateTask` (20)
- `C_UpdateTask` (21)
- `C_DeleteTask` (22)
- `C_MoveTask` (23)
- `C_GetTasks` (24)

## Handler Policy Matrix

### Routed Through `S_ErrorResponse`

- Parse failures in dispatcher (`process_protocol_payload`) for all parsed opcodes.
- Invalid/corrupted opcode and unhandled opcode paths in dispatcher.
- Asset failures (not found, allocation failure, missing workspace/conversation) for:
  - `C_CreateAsset` (30)
  - `C_UpdateAsset` (31)
  - `C_DeleteAsset` (32)
  - `C_GetAsset` (33)
- Edge failures (invalid endpoints, self-edge, not found, allocation failure, missing workspace/conversation) for:
  - `C_CreateEdge` (40)
  - `C_DeleteEdge` (41)
- Voice join failures for `C_JoinVoice` (10) when room creation/join fails.
- Screenshare start failures for `C_StartScreenshare` (13) when workspace/conversation/subscription/state/identity checks fail.

### Routed Through Domain-Specific Errors

- DM request failures use `S_DMError`.
- Task request failures use `S_TaskListResponse(success=false, error=...)`.

### Intentional No-Op Returns (Not Treated as Errors)

These are intentionally ignored/idempotent paths and do not emit error responses:

- `C_LeaveVoice` when caller is not in a voice room.
- `C_AudioFrame` when caller is not currently in an active voice room.
- `C_StopScreenshare` when caller is not sharing.
- `C_ScreenFrame` when caller is not the active sharer.

## Implementation Anchors

- Dispatcher + generic error sender: `websocket_handler.odin` (`process_protocol_payload`, `send_error_response`).
- DM custom errors: `dm_handlers.odin` (`send_dm_error`).
- Task custom error responses: `task_handlers.odin` (`send_task_list_error`).
