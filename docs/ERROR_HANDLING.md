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
- Asset failures (limit reached, not found, allocation failure, missing workspace/conversation) for:
  - `C_CreateAsset` (30)
  - `C_UpdateAsset` (31)
  - `C_DeleteAsset` (32)
  - `C_GetAsset` (33)
- Edge failures (invalid endpoints, self-edge, limit reached, not found, allocation failure, missing workspace/conversation) for:
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
