# NRC Protocol

This is a binary WebSocket protocol for high-performance real-time communication.
It carries ephemeral chat and DMs, and durable workspace entities: tasks, notes,
reminders, files, customer records, work slices, edges and the graph queries over
them.

The tables and payload layouts below are checked against `protocol/types.odin`
and the serializers by `protocol-go/readme_opcodes_test.go`. When an opcode or a
limit changes, that test fails until this file is updated with it.

## Design Philosophy

This protocol is specifically designed to be an optimal match for high-performance WebSocket servers:

**Simple & Readable**: The protocol uses a straightforward binary format with fixed-size headers and length-prefixed variable data. No complex nested structures or schema evolution - just direct byte packing that's easy to understand and debug.

**Efficient**: Minimal wire overhead with big-endian encoding, compact opcodes, and direct memory layout. Perfect for high-throughput scenarios where every byte counts. The server can parse messages with minimal allocations and copying.

**Standalone**: No external dependencies, code generators, or compilation steps required. Unlike gRPC/Protocol Buffers, this protocol is implemented in pure Odin code with full control over serialization and parsing. No need for protoc, schema files, or language bindings.

**Performance-Oriented**: Designed for zero-allocation parsing where possible, with direct byte slice access to content. The binary format allows for efficient parsing without intermediate string conversions or complex unmarshaling steps.

**Systems Programming Friendly**: Aligns perfectly with Odin's systems programming philosophy - direct control over memory layout, explicit error handling, and predictable performance characteristics.

## Message Format

All messages use big-endian byte order and have the following structure:

```
[Opcode: 2 bytes] [Payload: variable length]
```

## Protocol Version

- Current protocol version: `8`
- Server advertises this in `S_ServerReady`
- Clients should reject or warn on mismatches

Version history:

| Version | Wire-breaking change |
|---------|----------------------|
| 2 | Mandatory trailing `CorrelationID` for RPC-style opcodes |
| 3 | Keyset-paginated list opcodes (`C_ListTasksPaged`, `C_ListAssetsPaged`, `C_ListAllEdgesPaged`) |
| 4 | Retained chat: `C_SendMessageV2`, `C_SubscribeConvsV2`, `S_SubscriptionReady`, `S_MessagePage` |
| 5 | Asset-backed notes/reminders with project and tag facets |
| 6 | Durable entities use workspace scope `0`; conversations are chat-only |
| 7 | Move flags on `C_MoveTask`: `Append` asks for the end of the target column |
| 8 | Calendar kind 2 appointment rows append actual start and optional end instants |

For server-side error return policy (generic vs domain-specific channels), see `docs/ERROR_HANDLING.md`.

## Durable Scope

Durable entities are **not** scoped to a chat conversation. Tasks, notes,
reminders, files, customer records, work slices, edges and graph data all live in
one workspace-wide scope:

- `WORKSPACE_DATA_ID = 0` is the only valid `ConversationID` for durable
  requests. The server rejects a nonzero durable scope rather than silently
  publishing private conversation data.
- Chat and DMs keep their own conversation IDs and are unaffected.
- The `conv_id` field is still present on durable messages so the entity codecs
  and the durable record format stay unchanged. It carries the workspace scope.
- Existing clients that pass a room ID to a durable request are rejected; see
  `docs/` and the CLI README for the migration note.

## Correlation Contract (v2)

For request-response RPC-style opcodes (tasks/assets/edges/graph queries/DMs), client requests include a **mandatory trailing** `u32` correlation field:

```
[...request payload...] [CorrelationID: 4 bytes]
```

Request-scoped responses echo that correlation value in a trailing `u32`:

```
[...response payload...] [CorrelationID: 4 bytes]
```

`correlation_id = 0` is valid and used for broadcast/non-request-scoped server events.

A response that spans several frames repeats
the same correlation ID on every frame; the client accumulates until the
continuation flag is clear. Paged listings — the task query, the task page and
the slice register — are answered one page per request instead: each page carries
its own cursor and the client asks for the next one when it needs it.

## Data Types

| Type | Width | Meaning |
|------|-------|---------|
| `ConversationID` | 8 bytes (u64) | Chat room or DM thread. `0` is the durable workspace scope. |
| `MessageSeq` | 8 bytes (u64) | Monotonic sequence number per conversation |
| `TaskID` | 8 bytes (u64) | Task identity |
| `AssetID` | 8 bytes (u64) | Asset identity (notes, files, reminders, customers, slices) |
| `EdgeID` | 8 bytes (u64) | Graph edge identity |
| `MessageContentType` | 1 byte | `PlainText` (0), `Markdown` (1) |
| `PresenceEventType` | 1 byte | `UserJoined` (0), `UserLeft` (1), `UserListSync` (2), `UserRenamed` (3) |
| `User_Type` | 1 byte | `User` (0), `Admin` (1), `Bot` (2), `System` (3) |
| `TaskStatus` | 1 byte | See Enums |
| `TaskColor` | 1 byte | See Enums |
| `AssetType` | 2 bytes (u16) | See Enums |
| `TargetType` | 2 bytes (u16) | `Asset` (1), `Task` (2) |
| `RelationType` | 2 bytes (u16) | See Enums |

## Opcodes

`get_opcode` accepts only these ranges. An opcode outside them is rejected as
invalid before any payload parsing happens, so a new opcode must be added to both
the enum and the range check in `protocol/protocol.odin`.

- Client to server: `1-3`, `8`, `16-58`
- Server to client: `100`, `102-111`, `121-127`, `130-147`, `150-166`

### Client to Server

#### Chat, DMs and subscriptions

| Opcode | Name | Description |
|--------|------|-------------|
| 1 | `C_SendMessage` | Send a message to a conversation |
| 2 | `C_SubscribeConvs` | Subscribe to conversation updates |
| 3 | `C_UnsubscribeConvs` | Unsubscribe from conversation updates |
| 8 | `C_Stats` | Request per-thread server metrics snapshot |
| 16 | `C_StartDM` | Start DM conversation |
| 17 | `C_ListDMs` | List DM conversations |
| 18 | `C_LeaveDM` | Leave DM conversation |
| 19 | `C_Ping` | Lightweight liveness/RTT ping |

#### Retained chat

| Opcode | Name | Description |
|--------|------|-------------|
| 48 | `C_SendMessageV2` | Send a retained message with a client message ID |
| 49 | `C_SubscribeConvsV2` | Subscribe and receive high-water marks per conversation |
| 50 | `C_ListMessagesBefore` | Page retained messages backwards from a cursor |
| 51 | `C_ReplayMessagesAfter` | Page retained messages forwards from a cursor |

#### Tasks and slices

| Opcode | Name | Description |
|--------|------|-------------|
| 20 | `C_CreateTask` | Create kanban task |
| 21 | `C_UpdateTask` | Update task |
| 22 | `C_DeleteTask` | Delete task |
| 23 | `C_MoveTask` | Move task between columns |
| 24 | `C_GetTasks` | Get all tasks for conversation |
| 25 | `C_ListTasksPaged` | List status-filtered tasks with a keyset cursor |
| 26 | `C_GetTask` | Get one task directly |
| 27 | `C_ApplyTransaction` | Apply several task/asset/edge operations atomically |
| 28 | `C_QueryTasks` | Multi-key sorted task query with a keyset cursor |
| 29 | `C_ListTaskProjects` | List the distinct task project labels |
| 56 | `C_ListTaskSlices` | List work slices with per-slice summaries |
| 57 | `C_ListTaskAssignees` | List distinct workspace task assignees |
| 58 | `C_QueryCalendar` | Query dated work in a half-open time range |

#### Assets

| Opcode | Name | Description |
|--------|------|-------------|
| 30 | `C_CreateAsset` | Create generic asset |
| 31 | `C_UpdateAsset` | Update asset preview/payload |
| 32 | `C_DeleteAsset` | Delete asset |
| 33 | `C_GetAsset` | Get full asset (with payload) |
| 34 | `C_ListAssets` | List assets (preview only) |
| 35 | `C_ListAssetsPaged` | List assets with cursor pagination |
| 36 | `C_ListAssetsPagedByProject` | List assets filtered by one project label |
| 37 | `C_ListNoteProjects` | List the distinct note project labels |
| 38 | `C_ListAssetsPagedByTag` | List assets filtered by one tag |
| 39 | `C_ListNoteTags` | List the distinct note tags |

#### Edges, graph and customer reads

| Opcode | Name | Description |
|--------|------|-------------|
| 40 | `C_CreateEdge` | Create knowledge graph edge |
| 41 | `C_DeleteEdge` | Delete edge |
| 42 | `C_ListEdges` | List edges for an entity |
| 43 | `C_ListAllEdges` | List all edges in conversation |
| 44 | `C_GraphQuery` | Graph traversal query |
| 45 | `C_GraphShortestPath` | Graph shortest path query |
| 46 | `C_GraphDegree` | Graph degree/top-n query |
| 47 | `C_GraphCommonNeighbors` | Graph common neighbors query |
| 52 | `C_GraphRank` | Rank a bounded multi-anchor graph neighborhood |
| 53 | `C_ListAllEdgesPaged` | Page all edges in the workspace by edge ID |
| 54 | `C_ListEdgesPaged` | Page the edges incident to one entity |
| 55 | `C_SearchCustomers` | Search customer companies and their contacts |

#### Reserved client opcodes

These numbers are not allocated. The names are historical; the server rejects
them.

| Opcode | Formerly |
|--------|----------|
| 0 | Set-nickname (identity is carried by the authenticated upgrade) |
| 4, 5 | Agenda (now the asset infrastructure) |
| 6, 7 | Diagram |
| 9 | Authenticate (authentication happens during the HTTP upgrade) |
| 10-15 | Voice and screenshare |

### Server to Client

#### Chat, DMs and subscriptions

| Opcode | Name | Description |
|--------|------|-------------|
| 100 | `S_ServerReady` | Server ready with build info, protocol version and CPU model |
| 102 | `S_NewMessage` | Broadcast new message to subscribers |
| 103 | `S_AckSendMessage` | Acknowledgment of sent message with sequence |
| 104 | `S_ErrorResponse` | Error response |
| 109 | `S_RoomPresenceUpdate` | Room presence change notifications |
| 110 | `S_StatsResponse` | Metrics response to `C_Stats` |
| 111 | `S_AuthResponse` | Authentication response |
| 121 | `S_DMStarted` | DM start response/event |
| 122 | `S_DMList` | DM list response |
| 123 | `S_DMError` | DM operation error |
| 124 | `S_DMLeft` | DM leave response |
| 125 | `S_DMPartnerStatus` | DM partner presence update |
| 126 | `S_Pong` | Lightweight pong response |
| 127 | `S_AckUnsubscribeConvs` | Correlated unsubscribe completion acknowledgment |

#### Retained chat

| Opcode | Name | Description |
|--------|------|-------------|
| 158 | `S_SubscriptionReady` | Per-conversation high-water and retention cutoff after `C_SubscribeConvsV2` |
| 159 | `S_MessagePage` | Retained message page |

#### Tasks and slices

| Opcode | Name | Description |
|--------|------|-------------|
| 130 | `S_TaskCreated` | Task created notification |
| 131 | `S_TaskUpdated` | Task updated notification |
| 132 | `S_TaskDeleted` | Task deleted notification |
| 133 | `S_TaskMoved` | Task moved notification |
| 134 | `S_TaskListResponse` | Response to task list request |
| 135 | `S_TaskListPage` | Status-filtered task list page |
| 136 | `S_TaskFull` | Direct task response |
| 137 | `S_TransactionResult` | Per-operation transaction outcome |
| 138 | `S_TaskQueryPage` | Multi-key sorted task query page |
| 139 | `S_TaskProjects` | Distinct task project labels |
| 164 | `S_TaskSliceList` | Work slice list with per-slice summaries |
| 165 | `S_TaskAssignees` | Chunked distinct task assignees, same layout as S_TaskProjects |
| 166 | `S_CalendarPage` | Compact calendar summaries with a time/kind/ID cursor |

#### Assets

| Opcode | Name | Description |
|--------|------|-------------|
| 140 | `S_AssetCreated` | Asset created notification |
| 141 | `S_AssetUpdated` | Asset updated notification |
| 142 | `S_AssetDeleted` | Asset deleted notification |
| 143 | `S_AssetFull` | Full asset response (with payload) |
| 144 | `S_AssetList` | Asset list response (preview only) |
| 145 | `S_AssetListPage` | Asset list page response |
| 146 | `S_NoteProjectList` | Distinct note project labels |
| 147 | `S_NoteTagList` | Distinct note tags |

#### Edges, graph and customer reads

| Opcode | Name | Description |
|--------|------|-------------|
| 150 | `S_EdgeCreated` | Edge created notification |
| 151 | `S_EdgeDeleted` | Edge deleted notification |
| 152 | `S_EdgeList` | Edge list response |
| 153 | `S_AllEdgeList` | Full edge list response |
| 154 | `S_GraphQueryResult` | Graph query result |
| 155 | `S_GraphShortestPathResult` | Graph shortest path result |
| 156 | `S_GraphDegreeResult` | Graph degree result |
| 157 | `S_GraphCommonNeighborsResult` | Graph common neighbors result |
| 160 | `S_GraphRankResult` | Ranked graph entities with evidence paths |
| 161 | `S_AllEdgeListPage` | Paged all-edge list |
| 162 | `S_EdgeListPage` | Paged incident-edge list |
| 163 | `S_CustomerSearchPage` | Paged customer search result |

#### Reserved server opcodes

These numbers are not allocated.

| Opcode | Formerly |
|--------|----------|
| 101 | Nickname response |
| 105, 106 | Agenda (now the asset infrastructure) |
| 107, 108 | Diagram |
| 112-120 | Voice and screenshare |

## Message Payloads

### Chat

#### C_SendMessage (Client → Server)
```
[ConversationID: 8 bytes] [ClientRequestID: 4 bytes] [ContentType: 1 byte] [ContentLength: 2 bytes] [Content: variable]
```

#### S_AckSendMessage (Server → Client)
```
[ClientRequestID: 4 bytes] [AssignedSeq: 8 bytes] [Timestamp: 8 bytes]
```

#### S_NewMessage (Server → Client)
```
[ConversationID: 8 bytes] [Seq: 8 bytes] [UsernameLength: 2 bytes] [Username: variable] [Timestamp: 8 bytes] [ContentType: 1 byte] [ContentLength: 2 bytes] [Content: variable]
```

#### S_ErrorResponse (Server → Client)
```
[OriginOpcode: 2 bytes] [ErrorMsgLength: 2 bytes] [ErrorMsg: variable] [CorrelationID: 4 bytes]
```
If parsing fails before request correlation is readable, server sends `CorrelationID = 0`.

#### C_SubscribeConvs (Client → Server)
```
[Count: 2 bytes] [ConversationID: 8 bytes] × Count
```

#### C_UnsubscribeConvs (Client → Server)
```
[Count: 2 bytes] [ConversationID: 8 bytes] × Count [CorrelationID: 4 bytes, optional]
```
Legacy requests ending after the conversation IDs are accepted and use correlation ID `0`.

#### S_AckUnsubscribeConvs (Server → Client)
```
[CorrelationID: 4 bytes]
```

#### C_Stats (Client → Server)
```
[Timestamp: 8 bytes]
```

#### S_StatsResponse (Server → Client)
```
[ClientTimestamp: 8 bytes] [ServerTimestamp: 8 bytes] [ThreadID: 4 bytes] [TotalThreads: 4 bytes] [Connections: 4 bytes] [MemoryTotalMB: 4 bytes] [BufferPoolPercent: 4 bytes] [IOPending: 4 bytes] [IORingDepth: 4 bytes] [IORingAvailable: 4 bytes] [IOSQOverflow: 4 bytes] [IOTotalCompletions: 8 bytes] [IOTotalLatencyNS: 8 bytes] [IOLatencyCount: 8 bytes] [SendQueueDepth: 4 bytes] [SendQueueLimit: 4 bytes] [SendBackpressure: 1 byte] [SendDropped: 4 bytes] [WALFileSize: 8 bytes] [WALPendingBytes: 8 bytes] [WALRecordCount: 8 bytes] [WALFsyncCount: 8 bytes] [WALTotalFsyncNS: 8 bytes] [WALTotalWriteNS: 8 bytes] [WALWriteCount: 8 bytes]
```

#### C_Ping (Client → Server)
```
[Timestamp: 8 bytes]
```

#### S_Pong (Server → Client)
```
[ClientTimestamp: 8 bytes] [ServerTimestamp: 8 bytes]
```

#### S_ServerReady (Server → Client)
```
[BuildVersionLength: 2 bytes] [BuildVersion: variable] [ProtocolVersion: 4 bytes] [CPUModelLength: 2 bytes] [CPUModel: variable]
```

#### S_RoomPresenceUpdate (Server → Client)
```
[ConversationID: 8 bytes] [EventType: 1 byte] [Sequence: 8 bytes] [UsernameLength: 2 bytes] [Username: variable] [IsAuthenticated: 1 byte] [OldUsernameLength: 2 bytes] [OldUsername: variable] [UserListCount: 2 bytes] [UserList: variable length array of (UsernameLength(2) + Username + AuthFlag(1))]
```

### Retained chat

`C_SendMessageV2` and `S_MessagePage` are the retained path. `C_SendMessage`
remains the ephemeral path.

#### C_SendMessageV2 (Client → Server)
```
[ConversationID: 8 bytes] [ClientMessageID: 16 bytes] [CorrelationID: 4 bytes] [ContentType: 1 byte] [ContentLength: 2 bytes] [Content: variable]
```
`ClientMessageID` is a 16-byte client-generated identifier; the server echoes it
so a resend can be recognised as the same message.

#### C_SubscribeConvsV2 (Client → Server)
```
[Count: 2 bytes] [ConversationID: 8 bytes] × Count [CorrelationID: 4 bytes]
```

#### S_SubscriptionReady (Server → Client)
```
[CorrelationID: 4 bytes] [Count: 2 bytes] [Entry: 24 bytes] × Count
```
Each entry is `[ConversationID: 8 bytes] [HighWaterSeq: 8 bytes] [RetentionCutoffSeq: 8 bytes]`.

#### C_ListMessagesBefore / C_ReplayMessagesAfter (Client → Server)
```
[ConversationID: 8 bytes] [Cursor: 8 bytes] [Limit: 2 bytes] [CorrelationID: 4 bytes]
```
`C_ListMessagesBefore` pages backwards from the cursor, `C_ReplayMessagesAfter`
pages forwards. `Limit` is bounded by `MAX_MESSAGE_PAGE_COUNT`.

#### S_MessagePage (Server → Client)
```
[ConversationID: 8 bytes] [Ascending: 1 byte] [HasMore: 1 byte] [Truncated: 1 byte] [HighWaterSeq: 8 bytes] [RetentionCutoffSeq: 8 bytes] [ContinuationCursor: 8 bytes] [CorrelationID: 4 bytes] [MessageCount: 2 bytes] [Messages: variable]
```
Each message is `[ConversationID: 8 bytes] [Seq: 8 bytes] [ClientMessageID: 16 bytes] [AuthorUsernameLength: 2 bytes] [AuthorUsername: variable] [Timestamp: 8 bytes] [ContentType: 1 byte] [ContentLength: 2 bytes] [Content: variable]`.

### Tasks

#### C_CreateTask (Client → Server)
```
[ConversationID: 8 bytes] [TitleLength: 2 bytes] [Title: variable] [DescriptionLength: 2 bytes] [Description: variable] [Priority: 1 byte] [Color: 1 byte] [ExternalRefLength: 2 bytes] [ExternalRef: variable] [DueAt: 8 bytes] [AttachmentCount: 2 bytes] [Attachments: variable] [Status: 1 byte (optional, default 0)] [ProjectLength: 2 bytes] [Project: variable] [CorrelationID: 4 bytes]
```
Note: Status field is optional for backward compatibility. Default is Backlog (0). Use Status=4 to create notes.

#### C_UpdateTask (Client → Server)
```
[ConversationID: 8 bytes] [TaskID: 8 bytes] [TitleLength: 2 bytes] [Title: variable] [DescriptionLength: 2 bytes] [Description: variable] [Status: 1 byte] [AssigneeLength: 2 bytes] [Assignee: variable] [Priority: 1 byte] [Color: 1 byte] [ExternalRefLength: 2 bytes] [ExternalRef: variable] [DueAt: 8 bytes] [BlockedBy: 8 bytes] [AttachmentCount: 2 bytes] [Attachments: variable] [ProjectLength: 2 bytes] [Project: variable] [CorrelationID: 4 bytes]
```

When a task transitions to `Done` through `C_UpdateTask`, `C_MoveTask`, or a
transaction task patch, the server clears `BlockedBy` on its direct dependents
and advances their `UpdatedAt`. The completion and dependent post-images share
one atomic WAL transaction. Every subscribed client, including the requester,
receives the dependent changes through ordinary `S_TaskUpdated` broadcasts
with correlation ID `0`; no new opcode or client-side status inference is needed.

Completion consumes the dependency: reopening the blocker does **not** restore
it, because doing so could silently stop work that has already started. A new
dependency must be set explicitly. Unblocking B does not complete B or unblock
tasks depending on B. In a transaction, the final task post-images determine
dependencies: a dependent patched to another blocker keeps that blocker, while
a created or patched task still pointing at a blocker completed in the same
transaction is unblocked regardless of operation order. Existing records are
not retroactively rewritten on startup; replay applies the stored post-images.

#### C_DeleteTask (Client → Server)
```
[ConversationID: 8 bytes] [TaskID: 8 bytes] [CorrelationID: 4 bytes]
```

#### C_MoveTask (Client → Server)
```
[ConversationID: 8 bytes] [TaskID: 8 bytes] [Status: 1 byte] [Flags: 1 byte] [OrderIndex: 2 bytes] [CorrelationID: 4 bytes]
```
`Flags` bit 0 (`Append`) asks the server to put the task at the end of the target status column and ignores `OrderIndex`: a register draws one page at a time, so a client does not always hold the column, and the column order is the server's to fold. The acknowledgement and the broadcast carry the folded position. Without the flag, `OrderIndex` is the position in the target column, which is what a drag between two drawn rows sends. A column whose positions are exhausted rejects the write (`Status column is full`) rather than folding an index past the `u16` space. A move that carries a flag bit this build does not define is a malformed request and is refused, rather than read as a named position. `C_UpdateTask` never changes a task's position: it keeps the order index it had, and the position of a status change comes from the move that follows it.

#### C_GetTasks (Client → Server)
```
[ConversationID: 8 bytes] [CorrelationID: 4 bytes]
```

#### C_ListTasksPaged (Client → Server)
```
[ConversationID: 8 bytes] [StatusMask: 1 byte] [Limit: 2 bytes] [HasCursor: 1 byte] [CursorSortAt: 8 bytes, when present] [CursorTaskID: 8 bytes, when present] [CorrelationID: 4 bytes]
```

Status bits correspond to task status values. Done pages sort by `CompletedAt` descending; other statuses sort by `UpdatedAt` descending. Task ID descending is the deterministic tie-breaker.

#### C_GetTask (Client → Server)
```
[ConversationID: 8 bytes] [TaskID: 8 bytes] [CorrelationID: 4 bytes]
```

#### C_QueryTasks (Client → Server)
```
[ConversationID: 8 bytes] [StatusMask: 1 byte] [Limit: 2 bytes] [Sort: 1 byte] [Descending: 1 byte] [Color: 1 byte (255 = any)] [Blocked: 1 byte (0 any, 1 blocked, 2 unblocked)] [OverdueBefore: 8 bytes] [HasAssignee: 1 byte] [AssigneeLength: 2 bytes] [Assignee: variable] [HasProject: 1 byte] [ProjectLength: 2 bytes] [Project: variable] [HasCursor: 1 byte] [CursorNumber: 8 bytes] [CursorTextLength: 2 bytes] [CursorText: variable] [CursorTaskID: 8 bytes] [CorrelationID: 4 bytes]
```
`Sort` indexes `TaskQuerySort`. Numeric sorts carry a cursor number, textual
sorts (`Assignee`, `Title`, `Project`) carry cursor text. `HasProject` with an
empty project is meaningful: it selects the tasks that carry no project label.

#### C_ListTaskProjects (Client → Server)
```
[ConversationID: 8 bytes] [CorrelationID: 4 bytes]
```

#### S_TaskCreated / S_TaskUpdated (Server → Client)
```
[Task: variable] [CorrelationID: 4 bytes]
```

#### S_TaskDeleted (Server → Client)
```
[TaskID: 8 bytes] [ConversationID: 8 bytes] [CorrelationID: 4 bytes]
```

#### S_TaskMoved (Server → Client)
```
[TaskID: 8 bytes] [ConversationID: 8 bytes] [Status: 1 byte] [OrderIndex: 2 bytes] [CompletedAt: 8 bytes] [CorrelationID: 4 bytes]
```

#### S_TaskListResponse (Server → Client)
```
[ConversationID: 8 bytes] [Success: 1 byte] [TaskCount: 2 bytes] [Tasks: variable] [ErrorLength: 2 bytes] [Error: variable] [CorrelationID: 4 bytes]
```

#### S_TaskListPage (Server → Client)
```
[ConversationID: 8 bytes] [Success: 1 byte] [TaskCount: 2 bytes] [Tasks: variable] [HasMore: 1 byte] [NextCursorSortAt: 8 bytes] [NextCursorTaskID: 8 bytes] [TotalCount: 4 bytes] [ErrorLength: 2 bytes] [Error: variable] [CorrelationID: 4 bytes]
```

#### S_TaskFull (Server → Client)
```
[ConversationID: 8 bytes] [Success: 1 byte] [HasTask: 1 byte] [Task: variable, when present] [ErrorLength: 2 bytes] [Error: variable] [CorrelationID: 4 bytes]
```

#### S_TaskQueryPage (Server → Client)
```
[ConversationID: 8 bytes] [Success: 1 byte] [TaskCount: 2 bytes] [Tasks: variable] [HasMore: 1 byte] [NextCursorNumber: 8 bytes] [NextCursorTaskID: 8 bytes] [NextCursorTextLength: 2 bytes] [NextCursorText: variable] [TotalCount: 4 bytes] [ErrorLength: 2 bytes] [Error: variable] [CorrelationID: 4 bytes]
```

#### S_TaskProjects (Server → Client)
```
[ConversationID: 8 bytes] [ProjectCount: 2 bytes] [Project: (Length(2) + bytes)] × ProjectCount [HasMore: 1 byte] [CorrelationID: 4 bytes]
```
Labels are sorted and unique. An empty label is not reported. A response that
exceeds one frame's byte budget is split, repeating the correlation ID with
`HasMore` set.

#### Task Structure (used in S_TaskCreated, S_TaskUpdated, S_TaskListResponse)
```
[ID: 8 bytes] [ConversationID: 8 bytes] [TitleLength: 2 bytes] [Title: variable] [DescriptionLength: 2 bytes] [Description: variable] [Status: 1 byte] [OrderIndex: 2 bytes] [AssigneeLength: 2 bytes] [Assignee: variable] [Priority: 1 byte] [Color: 1 byte] [CreatedByLength: 2 bytes] [CreatedBy: variable] [CreatedAt: 8 bytes] [UpdatedAt: 8 bytes] [ExternalRefLength: 2 bytes] [ExternalRef: variable] [DueAt: 8 bytes] [BlockedBy: 8 bytes] [CompletedAt: 8 bytes] [CompletedByLength: 2 bytes] [CompletedBy: variable] [ProjectLength: 2 bytes] [Project: variable] [AttachmentCount: 2 bytes] [Attachments: variable]
```
Each attachment is `[FileIDLength: 2 bytes] [FileID: variable] [FilenameLength: 2 bytes] [Filename: variable] [Size: 8 bytes] [MimeTypeLength: 2 bytes] [MimeType: variable] [UploadedAt: 8 bytes]`.

### Work slices

A slice is an explicit work stream: an asset of type `AssetType.Slice` whose
members are the tasks, notes and files linked to it with a `MemberOf` edge.
Nothing is derived from project labels, so a slice spans projects freely and one
task can belong to more than one slice. There is no slice-specific opcode: a
slice is created with `C_CreateAsset`, its record is written with
`C_UpdateAsset`, and its members are linked and unlinked with `C_CreateEdge` and
`C_DeleteEdge`. A slice name is unique within the conversation, because the
register, the record and the CLI address a slice by name.

#### C_ListTaskSlices (Client → Server)
```
[ConversationID: 8 bytes] [IncludeClosed: 1 byte] [HasOwner: 1 byte] [OwnerLength: 2 bytes] [Owner: variable] [HasName: 1 byte] [NameLength: 2 bytes] [Name: variable] [Limit: 2 bytes] [HasCursor: 1 byte] [CursorClosed: 1 byte] [CursorSortAt: 8 bytes] [CursorSliceID: 8 bytes] [CorrelationID: 4 bytes]
```

The register is paged. `Owner` is matched exactly and an empty owner with `HasOwner` is the slices nobody owns; `Name` is matched as a case-insensitive substring of the slice name. `Limit` is the page bound (`MAX_TASK_SLICE_COUNT` at most). The cursor is the last slice of the previous page, carried in the register's own order — closure, then movement, then ID — and is only sent when `HasCursor` is set. `MY SLICES` is resolved by the client into its own nickname, exactly as the task query resolves `MY TASKS` into the assignee.

#### S_TaskSliceList (Server → Client)
```
[ConversationID: 8 bytes] [Success: 1 byte] [SliceCount: 2 bytes] [Slices: variable] [HasMore: 1 byte] [NextCursorClosed: 1 byte] [NextCursorSortAt: 8 bytes] [NextCursorSliceID: 8 bytes] [TotalCount: 4 bytes] [AssignedTasks: 4 bytes] [UnassignedTasks: 4 bytes] [ErrorLength: 2 bytes] [Error: variable] [CorrelationID: 4 bytes]
```

One page is one frame. `HasMore` says whether another page follows, and the next cursor names the last slice of this page. `TotalCount` is every slice the filters match, not only this page's rows. The workspace counters (`AssignedTasks`, `UnassignedTasks`) are folded on the first page of an unfiltered listing and are zero for a filtered listing and for a page that continues one.

Each slice is:

```
[NameLength: 2 bytes] [Name: variable] [SliceID: 8 bytes] [OwnerLength: 2 bytes] [Owner: variable] [Flags: 1 byte] [Backlog: 2 bytes] [Todo: 2 bytes] [InProgress: 2 bytes] [Done: 2 bytes] [Blocked: 2 bytes] [Notes: 2 bytes] [Files: 2 bytes] [OldestActiveAt: 8 bytes] [LastMovedAt: 8 bytes]
```

| Field | Meaning |
|-------|---------|
| `Name` | From the slice record preview. Never empty. |
| `SliceID` | The slice asset. Never zero. |
| `Owner` | From the slice record preview. |
| `Flags` | Bit 0 `Closed`. Unknown bits are rejected. |
| `Backlog`/`Todo`/`InProgress`/`Done` | Task members by status. |
| `Blocked` | Task members whose `blocked_by` points at another task. |
| `Notes` | Note members. |
| `Files` | File members. |
| `OldestActiveAt` | `created_at` of the oldest non-Done task member, `0` when there is none. |
| `LastMovedAt` | `updated_at` of the most recently changed member. |

Slices are name sorted. `TotalCount` counts every slice matching the filter, so a
client can tell a truncated list from a short one. `AssignedTasks` counts the
tasks that belong to at least one slice and `UnassignedTasks` those that belong
to none, so work cannot hide behind an empty register. A list that exceeds one
frame is split, repeating the correlation ID with `HasMore` set.

#### Slice asset payload

An asset of type `AssetType.Slice` carries this preview:

```json
{"version":1,"name":"Sharded Persistence","owner":"rene","outcome":"Restart-safe.","closed":true,"closed_at":1789944297304000000,"closed_by":"rene"}
```

`name` is the slice's identity and is unique within the conversation; a second
slice cannot be created under a name that is already taken, and the name is
bounded by `MAX_PROJECT_LENGTH`. `outcome` is also written to the asset payload.
A preview that does not decode, carries no version, or carries no name is skipped
rather than repaired, so a corrupt record cannot invent or rename a slice.
Closure is an act by the owner: `closed_at`/`closed_by` are set deliberately and
are not derived from member statuses. Membership is not stored in the record at
all: it is the set of `MemberOf` edges pointing at the slice, which is what lets
one task belong to several slices.

### Transactions

#### C_ApplyTransaction (Client → Server)
```
[Version: 1 byte] [OperationCount: 2 bytes] [Operation: variable] × OperationCount [CorrelationID: 4 bytes]
```
Each operation is `[Type: 1 byte] [BodyLength: 2 bytes] [Body: variable]`.
`TransactionOperationType` selects the body layout: `TaskCreate`, `TaskPatch`,
`AssetCreate`, `AssetPatch`, `EdgeCreate`, `TaskDelete`, `AssetDelete`,
`EdgeDelete`. A body may reference an entity that another operation in the same
transaction creates, by zero-based operation index
(`TransactionReferenceKind.CreatedBy`), or an existing entity by ID
(`TransactionReferenceKind.Existing`). That is what makes "create a slice and
link its members" a single atomic write.

#### S_TransactionResult (Server → Client)
```
[Version: 1 byte] [Status: 1 byte] [CorrelationID: 4 bytes] [FailedOperation: 2 bytes (0xffff on commit)] [Count: 2 bytes] [Result: 10 bytes] × Count
```
Each result is `[Type: 1 byte] [Reserved: 1 byte (0)] [EntityID: 8 bytes]`.
`EntityID` is the ID the operation created, or `0` for a patch or delete.

### Assets

#### C_CreateAsset (Client → Server)
```
[ConversationID: 8 bytes] [AssetType: 2 bytes] [ParentType: 2 bytes] [ParentID: 8 bytes] [PreviewLength: 2 bytes] [Preview: variable] [PayloadEncoding: 1 byte] [PayloadRawLength: 4 bytes] [PayloadLength: 2 bytes] [Payload: variable] [AttachmentCount: 2 bytes] [Attachments: variable] [CorrelationID: 4 bytes]
```

#### C_UpdateAsset (Client → Server)
```
[ConversationID: 8 bytes] [AssetID: 8 bytes] [PreviewLength: 2 bytes] [Preview: variable] [PayloadEncoding: 1 byte] [PayloadRawLength: 4 bytes] [PayloadLength: 2 bytes] [Payload: variable] [AttachmentCount: 2 bytes] [Attachments: variable] [CorrelationID: 4 bytes]
```

#### C_DeleteAsset / C_GetAsset (Client → Server)
```
[ConversationID: 8 bytes] [AssetID: 8 bytes] [CorrelationID: 4 bytes]
```

#### C_ListAssets (Client → Server)
```
[ConversationID: 8 bytes] [FilterByType: 1 byte] [AssetType: 2 bytes] [FullContent: 1 byte] [CorrelationID: 4 bytes]
```
When `FilterByType` is `0`, `AssetType` is ignored and every asset type is
returned.

#### C_ListAssetsPaged (Client → Server)
```
[ConversationID: 8 bytes] [AssetType: 2 bytes] [FullContent: 1 byte] [Limit: 2 bytes] [HasCursor: 1 byte] [CursorUpdatedAt: 8 bytes, when present] [CursorAssetID: 8 bytes, when present] [CorrelationID: 4 bytes]
```

#### C_ListAssetsPagedByProject (Client → Server)
```
[ConversationID: 8 bytes] [AssetType: 2 bytes] [FullContent: 1 byte] [Limit: 2 bytes] [HasCursor: 1 byte] [CursorUpdatedAt: 8 bytes, when present] [CursorAssetID: 8 bytes, when present] [ProjectLength: 2 bytes] [Project: variable] [CorrelationID: 4 bytes]
```
`C_ListAssetsPagedByTag` has the same layout with `Tag` in place of `Project`.

Note project/tag facets come from the preview's top-level JSON `project` string
and `tags` array of strings. Missing or null fields are empty. Values are JSON
unescaped, trimmed, and empty tags discarded; duplicate decoded tags count once.
The complete preview must be valid JSON (at most 64 nested containers and signed
64-bit integer tokens). Duplicate selected fields, including escaped spellings,
or wrong metadata types produce no project/tag facets, not partial entries.
Nested fields do not supply metadata. The note itself remains stored and appears
in the unfiltered note list. These rules also apply when replay rebuilds indexes;
older malformed previews are not rewritten, but lose their former incidental
facets after restart/reindexing.

#### C_ListNoteProjects / C_ListNoteTags (Client → Server)
```
[ConversationID: 8 bytes] [CorrelationID: 4 bytes]
```

#### S_AssetCreated / S_AssetUpdated / S_AssetFull (Server → Client)
```
[Asset: variable] [CorrelationID: 4 bytes]
```
`S_AssetFull` carries the payload; the notification variants may omit it.

#### S_AssetDeleted (Server → Client)
```
[AssetID: 8 bytes] [ConversationID: 8 bytes] [CorrelationID: 4 bytes]
```

#### S_AssetList (Server → Client)
```
[ConversationID: 8 bytes] [FullContent: 1 byte] [AssetCount: 2 bytes] [Assets: variable] [CorrelationID: 4 bytes]
```

#### S_AssetListPage (Server → Client)
```
[ConversationID: 8 bytes] [FullContent: 1 byte] [HasMore: 1 byte] [NextCursorUpdatedAt: 8 bytes] [NextCursorAssetID: 8 bytes] [TotalCount: 4 bytes] [AssetCount: 2 bytes] [Assets: variable] [CorrelationID: 4 bytes]
```

#### S_NoteProjectList / S_NoteTagList (Server → Client)
```
[ConversationID: 8 bytes] [Count: 2 bytes] [Value: (Length(2) + bytes)] × Count [CorrelationID: 4 bytes]
```

#### Asset Structure
```
[AssetType: 2 bytes] [AssetID: 8 bytes] [ParentType: 2 bytes] [ParentID: 8 bytes] [OwnerLength: 2 bytes] [Owner: variable] [CreatedAt: 8 bytes] [UpdatedAt: 8 bytes] [ConversationID: 8 bytes] [PayloadEncoding: 1 byte] [PayloadRawLength: 4 bytes] [PreviewLength: 2 bytes] [Preview: variable] [PayloadLength: 2 bytes] [Payload: variable] [AttachmentCount: 2 bytes] [Attachments: variable]
```

### Edges, graph and customer reads

#### C_CreateEdge (Client → Server)
```
[ConversationID: 8 bytes] [SourceType: 2 bytes] [SourceID: 8 bytes] [TargetType: 2 bytes] [TargetID: 8 bytes] [Relation: 2 bytes] [CorrelationID: 4 bytes]
```

#### C_DeleteEdge (Client → Server)
```
[ConversationID: 8 bytes] [EdgeID: 8 bytes] [CorrelationID: 4 bytes]
```

#### C_ListEdges / C_ListAllEdges (Client → Server)
```
[ConversationID: 8 bytes] [TargetType: 2 bytes] [TargetID: 8 bytes] [CorrelationID: 4 bytes]
```

#### C_ListAllEdgesPaged (Client → Server)
```
[ConversationID: 8 bytes] [Limit: 2 bytes] [AfterEdgeID: 8 bytes] [CorrelationID: 4 bytes]
```

#### C_ListEdgesPaged (Client → Server)
```
[ConversationID: 8 bytes] [TargetType: 2 bytes] [TargetID: 8 bytes] [Limit: 2 bytes] [AfterEdgeID: 8 bytes] [CorrelationID: 4 bytes]
```

#### S_EdgeCreated (Server → Client)
```
[Edge: variable] [CorrelationID: 4 bytes]
```

#### S_EdgeDeleted (Server → Client)
```
[ConversationID: 8 bytes] [EdgeID: 8 bytes] [CorrelationID: 4 bytes]
```

#### S_EdgeList / S_AllEdgeList (Server → Client)
```
[ConversationID: 8 bytes] [EdgeCount: 2 bytes] [Edges: variable] [CorrelationID: 4 bytes]
```

#### S_EdgeListPage (Server → Client)
```
[ConversationID: 8 bytes] [TargetType: 2 bytes] [TargetID: 8 bytes] [HasMore: 1 byte] [NextEdgeID: 8 bytes] [TotalCount: 4 bytes] [EdgeCount: 2 bytes] [Edges: variable] [CorrelationID: 4 bytes]
```

#### S_AllEdgeListPage (Server → Client)
```
[ConversationID: 8 bytes] [HasMore: 1 byte] [NextEdgeID: 8 bytes] [TotalCount: 4 bytes] [EdgeCount: 2 bytes] [Edges: variable] [CorrelationID: 4 bytes]
```

#### Edge Structure
```
[EdgeID: 8 bytes] [ConversationID: 8 bytes] [SourceType: 2 bytes] [SourceID: 8 bytes] [TargetType: 2 bytes] [TargetID: 8 bytes] [Relation: 2 bytes] [CreatedAt: 8 bytes] [CreatedByLength: 2 bytes] [CreatedBy: variable]
```

#### C_SearchCustomers (Client → Server)
```
[ConversationID: 8 bytes] [Limit: 2 bytes] [AfterCompanyID: 8 bytes] [IncludeArchived: 1 byte] [QueryLength: 2 bytes] [Query: variable] [CorrelationID: 4 bytes]
```

#### S_CustomerSearchPage (Server → Client)
```
[ConversationID: 8 bytes] [HasMore: 1 byte] [NextCompanyID: 8 bytes] [TotalCount: 4 bytes] [AssetCount: 2 bytes] [Assets: variable] [CorrelationID: 4 bytes]
```
Companies are returned as asset headers; a matching contact promotes its company
into the result.

#### C_GraphRank / S_GraphRankResult

`C_GraphRank` carries a room ID, 1-5 ordered personalization anchors
(`MAX_GRAPH_RANK_ANCHORS` = 5), up to 50 search candidates
(`MAX_GRAPH_RANK_CANDIDATES` = 50), a depth bounded by `MAX_GRAPH_RANK_DEPTH` =
4, relation/direction filters, a graph-only result limit, and a correlation ID. `S_GraphRankResult` returns every requested search
candidate plus the strongest graph-only entities. Each entry contains its
max-normalized `f64` personalized PageRank score and up to one bounded evidence
path per anchor. Only edges referenced by those paths are serialized.

## Enums

### TaskStatus
- `Backlog` (0)
- `Todo` (1)
- `InProgress` (2)
- `Done` (3)
- `Note` (4) - Notes (displayed in notes view, not kanban)

### TaskColor
- `None` (0)
- `Cyan` (1) - Active/Focus (#00aeef)
- `Red` (2) - Blocked/Critical (#ed1c24)
- `Green` (3) - Ready/Approved (#00a651)
- `Gray` (4) - Deferred/Low (#939598)
- `Gold` (5) - Test (#ffb700)

### TaskQuerySort
- `Priority` (0), `Status` (1), `Assignee` (2), `DueAt` (3), `CreatedAt` (4), `Title` (5), `Color` (6), `Project` (7)
- `Assignee`, `Title` and `Project` are textual sorts; the rest are numeric.

### AssetType
- `Comment` (1), `Document` (2), `File` (3), `Agenda` (4), `Note` (5), `Reminder` (6), `RoomMapping` (7)
- `CustomerCompany` (8), `CustomerContact` (9), `CustomerActivity` (10)
- `Slice` (11) - a work slice
- `Appointment` (12) - a validated calendar appointment

### ParentType
- `None` (0), `Task` (1), `Asset` (2)

### PayloadEncoding
- `Plain` (0), `Zstd` (1)

### TargetType
- `Asset` (1), `Task` (2)

### RelationType
- `References` (1) - generic reference
- `RelatedTo` (2) - bidirectional relation
- `DependsOn` (3) - source depends on target
- `Blocks` (4) - source blocks target
- `DerivedFrom` (5) - source is derived from target
- `Supersedes` (6) - source supersedes or replaces target
- `MemberOf` (7) - source belongs to the target container (work slice or customer company)

### TransactionEntityType
- `Task` (1), `Asset` (2), `Edge` (3)

### TransactionOperationType
- `TaskCreate` (1), `TaskPatch` (2), `AssetCreate` (3), `AssetPatch` (4), `EdgeCreate` (5), `TaskDelete` (6), `AssetDelete` (7), `EdgeDelete` (8)

### TransactionReferenceKind
- `Existing` (0) - `value` is an entity ID
- `CreatedBy` (1) - `value` is a zero-based operation index in the same transaction

### TransactionResultStatus
- `Committed` (0) - every operation applied
- `Rejected` (1) - no operation applied; `FailedOperation` names the first one that failed

A transport failure after the request was sent leaves the outcome unknown rather
than rejected. The client reports that separately and must not retry blindly.

## Protocol Limits

Each limit names the constant that enforces it in `protocol/`.

### Content and identity

- **Message content**: 51200 bytes max (`MAX_ALLOWED_CONTENT_LENGTH`)
- **Nickname**: 32 bytes max (`MAX_NICKNAME_LENGTH`)
- **Username**: 255 bytes max (`MAX_USERNAME_LENGTH`)
- **User ID**: 64 bytes max (`MAX_USER_ID_LENGTH`)
- **Authentication token**: 4096 bytes max (`MAX_TOKEN_LENGTH`)
- **Customer search query**: 256 bytes max (`MAX_CUSTOMER_SEARCH_QUERY`)
- **Error message**: 65535 bytes max (u16 length prefix)

### Tasks and slices

- **Task title**: 256 bytes max (`MAX_TASK_TITLE_LENGTH`)
- **Task description**: 2048 bytes max (`MAX_TASK_DESCRIPTION_LENGTH`)
- **Task assignee**: 32 bytes max (`MAX_ASSIGNEE_LENGTH`)
- **External reference**: 512 bytes max (`MAX_EXTERNAL_REF_LENGTH`)
- **Task project label**: 128 bytes max (`MAX_PROJECT_LENGTH`)
- **Workspace task counts**: no fixed active-task or total-task quota; available resources and wire-format bounds still apply.
- **Task page size**: 1000 max (`MAX_TASK_PAGE_SIZE`)
- **Work slices per page**: 512 max (`MAX_TASK_SLICE_COUNT`), which is also the frame bound
- **Slice name**: 128 bytes max (`MAX_PROJECT_LENGTH`)
- **Slice outcome**: 2048 bytes max (`MAX_SLICE_OUTCOME_LENGTH`)
- **Slice member counters**: each status, blocked, note and file counter is a u16 (65535 max). A listing that cannot represent a category returns an error rather than wrapped counts; totals across categories may exceed 65535.

### Assets, edges and attachments

- **Asset owner**: 64 bytes max (`MAX_OWNER_LENGTH`)
- **Asset preview**: 4096 bytes max (`MAX_PREVIEW_LENGTH`)
- **Asset payload**: 65535 bytes max (`MAX_PAYLOAD_LENGTH`)
- **Appointment description**: 2048 bytes max (`MAX_APPOINTMENT_DESCRIPTION_LENGTH`)
- **Appointment URL**: 2048 bytes max (`MAX_APPOINTMENT_URL_LENGTH`)
- **Workspace asset and edge counts**: no fixed count quotas; available resources and wire-format bounds still apply.
- **Transaction operations**: 256 max (`MAX_TRANSACTION_OPERATIONS`)
- **Expanded atomic persistence operations**: 65535 mutations and 16 MiB per WAL transaction. Oversized cascade deletes or task completions are rejected without changing records or shutting down the server.
- **Attachment file ID**: 36 bytes max (`MAX_FILE_ID_LENGTH`, `att_` + 32 hex chars)
- **Attachment filename**: 256 bytes max (`MAX_FILENAME_LENGTH`)
- **Attachment MIME type**: 128 bytes max (`MAX_MIME_TYPE_LENGTH`)
- **Attachments per task**: 10 max (`MAX_ATTACHMENTS_PER_TASK`)

### Chat and transport

- **Agenda content**: 8180 bytes max
- **Retained message page count**: 100 max (`MAX_MESSAGE_PAGE_COUNT`)
- **Subscribe conversations**: 64 max per request (`MAX_SUBSCRIBE_CONVS`)
- **Opus packet**: 1275 bytes max
- **Screen frame**: 131072 bytes max

### Graph rank

- **Personalization anchors**: 5 max (`MAX_GRAPH_RANK_ANCHORS`)
- **Search candidates**: 50 max (`MAX_GRAPH_RANK_CANDIDATES`)
- **Traversal depth**: 4 max (`MAX_GRAPH_RANK_DEPTH`)

## Error Handling

The protocol includes comprehensive error checking with specific error codes:

- `TooShort` - Input data shorter than required
- `InvalidOpcode` - Opcode does not match the message being parsed
- `InvalidContentType` - Invalid content type enum value
- `ContentLengthExceedsMax` - Content exceeds maximum allowed length
- `ContentLengthMismatch` - Declared length doesn't match available data
- `TooMany` - Too many items (e.g., conversation subscriptions)
- `InvalidValue` - A field is outside its permitted set (unknown flag bit, out-of-range enum, inconsistent cursor)

Production-dispatched request parsers reject unexpected trailing bytes as
`ContentLengthMismatch`; a legacy wire-compatibility exception must be documented
where it is tested or parsed.

For v2 correlation-enabled RPC requests, missing trailing `CorrelationID` is treated as `TooShort`.

## Usage Flow

1. **Connection**: Client connects via WebSocket. Authentication happens during
   the HTTP upgrade (`X-NRC-Auth` JWT or `X-NRC-Bot-Secret` with
   `X-NRC-User-Type`), not with an opcode.
2. **Server Ready**: Server sends `S_ServerReady` with build, protocol version and CPU info.
3. **Subscribe**: Client subscribes with `C_SubscribeConvs` (ephemeral) or
   `C_SubscribeConvsV2` and waits for `S_SubscriptionReady` (retained).
4. **Messaging**: Client sends with `C_SendMessage` or `C_SendMessageV2`, receives
   `S_AckSendMessage` and broadcasts, and pages history with
   `C_ListMessagesBefore` / `C_ReplayMessagesAfter`.
5. **Presence**: Server broadcasts room presence updates via `S_RoomPresenceUpdate`.
6. **Tasks**: Client manages tasks with the task opcodes, reads them with
   `C_ListTasksPaged` or the multi-key `C_QueryTasks`, and groups them with
   `C_ListTaskProjects` and `C_ListTaskSlices`. `C_ListTaskAssignees` (57) returns
   every distinct nonempty assignee in workspace scope 0, including Done tasks,
   independently of task filters, paging and chat presence. Request layout is
   `scope:u64, correlation_id:u32`; `S_TaskAssignees` (165) uses the same chunked
   string-list layout as `S_TaskProjects` (139). Wait for `has_more=false` before
   replacing the previous list; no tasks means a single empty final chunk.
   Calendar uses `C_QueryCalendar` (58), with big-endian fields after the opcode:
   `scope:u64=0, start:i64, end:i64, limit:u16, has_cursor:u8,
   cursor_at:i64, cursor_kind:u8, cursor_id:u64, assignee:str16,
   project:str16, correlation_id:u32`. Bounds are absolute nanoseconds in
   `[start,end)`, at most 62 days; limit is 1–100. Empty filters mean all.
   `str16` is a byte-length-prefixed UTF-8 string. Cursor fields must be zero
   without a cursor, otherwise identify the previous page's final row.

   `S_CalendarPage` (166), after the opcode:
   `scope:u64=0, count:u16, has_more:u8, cursor_at:i64, cursor_kind:u8,
   cursor_id:u64, rows[count], correlation_id:u32`. Each row is
   `kind:u8, id:u64, at:i64, blocked:u8, title:str16, assignee:str16, project:str16`.
   Kind 0 is an open dated task; kind 1 is a reminder deadline. Kind 2 is an
   appointment and appends `actual_start_at:i64, end_at:i64` after the three
   strings (`end_at=0` means a point appointment); kinds 0 and 1 retain the
   original row layout. Rows are ordered
   by `(at,kind,id)`, with exclusive continuation. Task filters intersect and
   exclude reminders and match appointment assignee/project. Summary rows omit descriptions, attachments and payloads;
   use existing direct entity reads for details. Ordinary entity broadcasts
   invalidate the view; pages are live reads, not an isolated snapshot.
   Reminder JSON is validated by a nonrecursive token reader with a fixed
   64-level stack (including compressed payloads and preview fallback). Only
   top-level deadline/title aliases are retained; no JSON object tree is built.
   Duplicate selected fields are rejected; duplicate keys in ignored extra
   data have no effect. The entire document must be valid, including its tail.
   Integer tokens and decimal
   deadline strings must fit signed 64-bit values; invalid deadlines are not
   indexed. Strings require complete conversion, not a numeric prefix.

   Appointment membership uses interval overlap: a ranged appointment matches
   when `start_at < request.end && end_at > request.start`; a point appointment
   matches when `start_at` is in the request range. Its query key is
   `(max(start_at, request.start),2,asset_id)`, keeping keys in range and cursor
   continuation stable for that request.

   `Appointment` assets use `Plain` encoding, an empty payload and an
   authoritative JSON preview: `{"version":1,"title":string,"start_at":string,
   "end_at":string,"description":string,"assignee":string,"project":string,
   "url":string}`. `version`, nonempty `title`, and decimal absolute-nanosecond
   `start_at` are required. Other strings may be omitted; empty `end_at` means a
   point. Start must be positive and a present end greater than start. Existing
   task bounds apply to title, assignee and project; description and URL are at
   most 2048 bytes each. Owner remains the creator, distinct from `assignee`.

   The time index is built lazily once per workspace, then maintained on entity
   mutations. Warm queries seek into the requested range and scan its entries,
   not the whole workspace. The client uses local month boundaries for Agenda
   and the full Monday-first grid for Month, accounting for DST. Task
   project/assignee metadata remain workspace-wide; appointment filter
   choices also include values from the loaded range. Appointment intervals
   occupy one smallest enclosing power-of-two time bucket. Range reads seek
   intersecting buckets at each level and check exact endpoints before decoding
   previews, avoiding a scan through all future or historical appointments.
7. **Assets**: Notes, reminders, files, customers and work slices all use the
   asset infrastructure (`C_CreateAsset`, `C_UpdateAsset`, ...). Project and tag
   facets are read with the by-project and by-tag list opcodes.
8. **Relations**: Client links entities with `C_CreateEdge` and traverses them
   with the graph opcodes, or pages raw adjacency with the paged edge opcodes.
9. **Atomic changes**: Client applies several task/asset/edge operations in one
   write with `C_ApplyTransaction` and reads the per-operation outcome from
   `S_TransactionResult`.
10. **Health Check**: Client can request metrics with `C_Stats`/`S_StatsResponse`
    and use `C_Ping`/`S_Pong` for lightweight RTT checks.
11. **Unsubscribe**: Client can unsubscribe from conversations with `C_UnsubscribeConvs`.

The server maintains message sequences per conversation and broadcasts new messages to all subscribed clients. Room presence is tracked and broadcast to subscribers when users join/leave conversations. Durable entities live in workspace scope `0` and are shared across every chat room in the workspace.
