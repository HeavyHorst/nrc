# Request-Response Correlation

## Status

Correlation is now **mandatory** for RPC-style opcodes. The protocol moved from optional/implicit matching to a deterministic trailing `u32 correlation_id` contract.

This is a wire-breaking change and is advertised as protocol version `2`.

## Contract (Protocol v2)

For covered client requests, payload shape is:

```
[Request fields ...] [CorrelationID: 4 bytes]
```

For covered server responses, payload shape is:

```
[Response fields ...] [CorrelationID: 4 bytes]
```

`correlation_id = 0` is valid and reserved for non-request-scoped events (for example broadcasts).

## Covered Opcodes

Mandatory trailing `correlation_id` is required on these client requests and echoed on their request-scoped responses:

- Tasks: `C_CreateTask` (20), `C_UpdateTask` (21), `C_DeleteTask` (22), `C_MoveTask` (23), `C_GetTasks` (24)
- Assets: `C_CreateAsset` (30), `C_UpdateAsset` (31), `C_DeleteAsset` (32), `C_GetAsset` (33), `C_ListAssets` (34), `C_ListAssetsPaged` (35)
- Edges/Graph index: `C_CreateEdge` (40), `C_DeleteEdge` (41), `C_ListEdges` (42), `C_ListAllEdges` (43)
- Graph queries: `C_GraphQuery` (44), `C_GraphShortestPath` (45), `C_GraphDegree` (46), `C_GraphCommonNeighbors` (47)
- DMs: `C_StartDM` (16), `C_ListDMs` (17), `C_LeaveDM` (18)

## Strict Parsing Rule

Parsers for covered requests now treat missing trailing correlation bytes as malformed input:

- Missing trailing `correlation_id` => `ProtocolParseError.TooShort`
- No optional fallback for correlation on covered request types

This guarantees a deterministic wire shape and removes ambiguity during request matching.

## Error Attribution

`S_ErrorResponse` is now sent for parse failures and includes both the failing opcode and correlation context when available.

Wire format:

```
[Opcode: 2B]          S_ErrorResponse (104)
[OriginOpcode: 2B]    Client opcode that failed
[ErrorMsgLength: 2B]  Error text length
[ErrorMsg: variable]  UTF-8 error text
[CorrelationID: 4B]   Correlation from request when readable, else 0
```

If parsing fails before the trailing correlation can be read, the server sends `correlation_id = 0`.

## Unchanged

- `C_SendMessage`/`S_AckSendMessage` continue using `client_req_id`
- `C_Stats`/`S_StatsResponse` continue using timestamp echo
- `C_Ping`/`S_Pong` use lightweight timestamp echo for RTT/liveness
- Streaming and server-initiated event opcodes remain event-driven and are not request-correlated

## See Also

- Error channel policy and domain-specific behavior: `docs/ERROR_HANDLING.md`
