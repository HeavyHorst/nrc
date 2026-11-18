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

- Current protocol version: `10`
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
| 9 | Slice rows append an independent `Tickets` u16 counter after `Files` |
| 10 | Calendar kind 3 series occurrences append original `occurrence_at:i64` after the kind 2 interval fields |

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

The batch reads `C_GetTasksByIDs` and `C_GetAssetsByIDs` are exceptions to the
request layout: their correlation ID follows the workspace scope, before the
content flag and ID array. Their responses still use a trailing correlation ID.

`S_HistoryPage` puts the correlation ID immediately after the opcode, before
its UTF-8 JSON body. `C_ListHistory` uses the normal trailing correlation ID.

`C_QueryTickets` and `S_TicketPage` also put the correlation ID immediately
after the opcode. Ticket queries always address workspace scope `0` implicitly.

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

- Client to server: `1-3`, `8`, `16-75`
- Server to client: `100`, `102-111`, `121-127`, `130-147`, `150-180`

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
| 59 | `C_GetWorkspaceOverview` | Read one complete, unpaged workspace aggregate snapshot |
| 60 | `C_GetTasksByIDs` | Read tasks by an exact set of IDs |
| 62 | `C_ListHistory` | Page visible workspace or record change history |
| 63 | `C_QueryTickets` | Filtered, sorted ticket pages and ticket-entry pages |
| 64 | `C_ListTaskDependents` | Page tasks directly dependent on one task |
| 65 | `C_ListSliceOwners` | List distinct workspace slice owners, including closed slices |
| 66 | `C_ListTicketAssignees` | List distinct workspace ticket assignees, including closed tickets |
| 67 | `C_ListCalendarPeople` | List task assignees and appointment people independently of date range |
| 68 | `C_ApplyMonitorRun` | Apply one complete monitor result or query failure atomically |
| 69 | `C_ControlMonitorInstance` | Pause, resume or retire an instance with a Monitor revision fence |
| 70 | `C_ActOnIncident` | Acknowledge or assign an Incident at its expected revision |
| 71 | `C_MonitorDelivery` | Discover, lease, settle or resynchronize webhook delivery |
| 72 | `C_GetMonitorState` | Read current revision and committed sequence as the configured evaluator |
| 73 | `C_QueryMonitorStatus` | Workspace monitor summaries or instance status, problem-first live pagination |
| 74 | `C_Chronicle` | Multiplexed JSON chronicle request with trailing correlation |
| 75 | `C_MonitorHistory` | Read immutable pending availability pages or acknowledge a stored snapshot |

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
| 61 | `C_GetAssetsByIDs` | Read visible assets by an exact set of IDs |

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
| 167 | `S_WorkspaceOverview` | Unique task totals and open-slice distributions |
| 168 | `S_HistoryPage` | Correlated JSON change-history page |
| 169 | `S_TicketPage` | Ticket activity metadata and binary asset page |
| 170 | `S_TaskDependentsPage` | ID-ordered direct dependents with an exclusive cursor |
| 171 | `S_SliceOwners` | Chunked distinct slice owners, same layout as S_TaskProjects |
| 172 | `S_TicketAssignees` | Chunked distinct ticket assignees, same layout as S_TaskProjects |
| 173 | `S_CalendarPeople` | Chunked distinct calendar people, same layout as S_TaskProjects |
| 174 | `S_MonitorRunApplied` | Durable monitor-run acknowledgment, including latest-run replay |
| 175 | `S_MonitorInstanceControlled` | Durable instance-action acknowledgment and resulting Monitor revision |
| 176 | `S_IncidentActionApplied` | Durable human-action acknowledgment and resulting Incident revision |
| 177 | `S_MonitorDelivery` | Correlated delivery state and immutable event payload |
| 178 | `S_MonitorState` | Current Monitor revision and last committed run sequence |
| 179 | `S_MonitorStatusPage` | Correlation u32 followed by bounded version-1 status JSON; [wire contract](../services/bots/nrc-incidents/README.md#current-status-reads-nrc-protocol) |
| 180 | `S_Chronicle` | Multiplexed JSON chronicle response with leading correlation |

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

DMs use these same formats whenever `NRC_MESSAGE_RETENTION` enables message
retention. Send and subscription requests require DM membership; history requires
membership plus subscription, rechecked when asynchronous reads finish.
After `S_DMStarted` or `S_DMList`, clients probe DM capability with a correlated
`C_SubscribeConvsV2`: an authorized DM omitted from `S_SubscriptionReady` uses
the ephemeral path. DM start/list auto-subscription alone does not negotiate
retention. `S_MessagePage` with correlation zero is a live retained broadcast;
nonzero correlations identify requested history pages.

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

#### C_GetTasksByIDs / C_GetAssetsByIDs (Client → Server)
```
[ConversationID: 8 bytes, must be 0] [CorrelationID: 4 bytes] [FullContent: 1 byte] [IDCount: 2 bytes] [ID: 8 bytes] × IDCount
```

`IDCount` is 0–64 (`MAX_ID_BATCH_SIZE`). `FullContent` must be 0 or 1;
tasks always return full records, while assets include payloads only when it is 1.
Duplicate IDs are returned once, in request order. Missing or invisible records
are omitted.

Responses reuse `S_TaskListPage` or `S_AssetListPage`, with zero cursor fields
and `TotalCount` equal to the number of returned records across all chunks.
An empty result still returns one empty page. Byte-bounded chunks share the
correlation ID; `HasMore` means another response chunk follows without another
request. These exact-set reads do not make a list or filter cache complete.

#### C_QueryTasks (Client → Server)
```
[ConversationID: 8 bytes] [StatusMask: 1 byte] [Limit: 2 bytes] [Sort: 1 byte] [Descending: 1 byte] [Color: 1 byte (255 = any)] [Blocked: 1 byte (0 any, 1 blocked, 2 unblocked)] [OverdueBefore: 8 bytes] [HasAssignee: 1 byte] [AssigneeLength: 2 bytes] [Assignee: variable] [HasProject: 1 byte] [ProjectLength: 2 bytes] [Project: variable] [HasCursor: 1 byte] [CursorNumber: 8 bytes] [CursorTextLength: 2 bytes] [CursorText: variable] [CursorTaskID: 8 bytes] [CorrelationID: 4 bytes]
```
`Sort` indexes `TaskQuerySort`. Numeric sorts carry a cursor number, textual
sorts (`Assignee`, `Title`, `Project`) carry cursor text. `HasProject` with an
empty project is meaningful: it selects the tasks that carry no project label.

`WorkOrder` (8) requires `Descending=0` and optionally accepts a trailing
`SliceID: 8 bytes` after CorrelationID. A nonzero slice restricts tasks to its
explicit MemberOf edges in this conversation. Other sorts reject the trailer.
Filters and membership are applied before dependency ordering. Ready tasks are
chosen by priority descending, positive due date ascending (missing last), then
ID ascending. Done prerequisites are satisfied even outside the filter. Missing
or out-of-scope unfinished prerequisites, cycles and their descendants are
unresolved and follow the executable sequence in priority/due/ID order; Done
tasks follow last. This does not assert that all unresolved tasks are cyclic.
WorkOrder cursors carry the last task ID and its one-based position, not a
scalar index key. Pages are live, not snapshots: clients refresh on mutations.
The server recomputes the scope's order for each page; clients fetch only the
requested page rather than loading all tasks to sort locally.

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
members are the tasks, notes, files and tickets linked to it with a `MemberOf` edge.
Nothing is derived from project labels, so a slice spans projects freely and one
task can belong to more than one slice. There is no slice-specific opcode: a
slice is created with `C_CreateAsset`, its record is written with
`C_UpdateAsset`, and its members are linked and unlinked with `C_CreateEdge` and
`C_DeleteEdge`. The stable numeric asset ID identifies a slice. Display names
may repeat and may be renamed without changing memberships or links. The CLI
creates with `nrc slice create <name>` and addresses existing slices only by ID,
including `nrc slice update <id> --name <label>`; there is no name fallback.
Use `nrc slice list --fields slice_id,name` to discover IDs. List name queries
remain case-insensitive substring searches, not identity lookups.

#### C_QueryTickets / S_TicketPage

Request: opcode `u16`, correlation ID `u32`, then a UTF-8 JSON object (at most
65532 bytes). Fields:

- `mode`: empty for the register, `attention` for actionable tickets assigned to
  the authenticated user or unassigned, `entries` for a ticket's conversation,
  or `read` to upload browser-owned read cursors.
- `status`, `assignee`, `company`: exact metadata filters; empty means any.
- `sort`: `activity` (default), `id`, `title`, `status`, `assignee`, `company_id`,
  `contact_id`, or `unread`; `descending` selects direction. Text compares
  lowercase UTF-8 values; company/contact sorting resolves linked names.
- `limit`: 0 means 50; otherwise 1–250. Both row count and the protocol byte
  limit bound the page. Filters apply before pagination.
- `cursor`: `{id, number, text}`, with decimal strings for the ID and numeric
  sort key. Equal sort values use descending asset ID as the tie-breaker.
  Pass the returned cursor unchanged, with unchanged filters and ordering.
- `parent`: decimal ticket ID, required for `entries`. Entry pages sort by
  creation time; full entry payloads are returned only in this mode.
- `read_snapshot`: nonzero `u32` identifying an acknowledged connection-local
  read snapshot; omitted/zero means all incoming records are unread.
- In `read` mode, `read` maps decimal ticket IDs to decimal last-read incoming
  asset IDs. Upload bounded chunks with the same `read_snapshot`; `read_start`
  replaces the old snapshot and `read_end` commits the new one. Each chunk gets
  an empty page acknowledgement. Queries reject incomplete/stale snapshots.
  Serialize uploads and dependent queries on the connection. Re-upload after
  reconnect. These cursors are ephemeral, not persisted workflow state; deleted
  ticket IDs are discarded. Historical cursors therefore cannot overflow a
  register query's request limit.
- `search_results` and `ids`: restrict to up to 100 search-service result IDs.
- `search`: case-insensitive substring fallback across title, requester, ID,
  original body and entry bodies. Compressed bodies are decoded server-side.

Response: opcode `u16`, correlation ID `u32`, JSON byte length `u32`, JSON,
asset count `u16`, full-content flag `u8`, then ordinary binary assets. The JSON
contains `has_more`, `total_count` (before the cursor), `cursor`, and an `activity`
array aligned with the assets. Activity contains `unread`, `waiting`, `latest`
(incoming asset ID as a string), and `timestamp` (nanoseconds as a string).
Register and attention responses carry asset headers, never conversation bodies.
An internal note or a read acknowledgement does not answer a customer follow-up.
Attention paging is independent of register filters. Like other live cursors,
these pages are not a frozen snapshot across concurrent mutations.

#### C_ListTaskDependents / S_TaskDependentsPage

Request (30 bytes after opcode):
```
[Scope: u64 = 0] [TaskID: u64] [Limit: u16] [AfterTaskID: u64] [CorrelationID: u32]
```
Limit is 1–1000 (`MAX_TASK_PAGE_SIZE`). `AfterTaskID = 0` starts the first page;
otherwise only dependent IDs strictly greater than the cursor are returned.

Response (36 bytes including opcode, before task records and error text):
```
[Opcode: u16] [Scope: u64] [TaskID: u64] [Success: u8] [Count: u16]
[Tasks: existing Task records] [HasMore: u8] [NextTaskID: u64]
[Error: u16-length UTF-8] [CorrelationID: u32]
```
The server seeks the existing `(blocker ID, dependent ID)` index and stops at
the end of that parent range, the requested limit, or the response byte budget.
There is no total-count scan. `NextTaskID` is the last returned ID, including
on the final page, or zero for an empty page. A missing root returns
`task_not_found`; a single oversized record returns `task_exceeds_page_byte_limit`.
Pages show current relationships, not a historical snapshot. Completing a
prerequisite clears its dependents' `blocked_by` references. Clients refresh
from the first page on task mutations; pagination is not snapshot isolation.

#### C_ListHistory / S_HistoryPage

Request (31 bytes after opcode):
```
[Scope: u64 = 0] [Kind: u8] [EntityID: u64] [Before: u64] [Limit: u16] [CorrelationID: u32]
```

Kind is 0 for workspace, 1 for task, 2 for asset, 3 for edge. EntityID is zero
only for workspace queries. Before is an exclusive event ID, or zero for newest;
Limit is 1–100. Task/asset queries include related edge events. The connection
selects the authorized workspace; personal Reminder history remains creator-only,
including after deletion, with visibility filtering before pagination.

Response after opcode: `[CorrelationID: u32] [UTF-8 JSON: remaining bytes]`.
JSON is `{events:[...],nextBefore:"0"}` with an optional `error` string.
Events are newest first and contain decimal-string `id`, `timestamp` (Unix
nanoseconds), `entityId`; string `actorId`, `actorName`, `entityType`
(`task|asset|edge`), `action` (`created|updated|deleted`); and `fields`, an array
of changed field names, never field values. Edge events also include
`sourceType`, `sourceId`, `targetType`, `targetId`. Optional `entityLabel`,
`sourceLabel`, `targetLabel` retain identifying names (at most 256 UTF-8 bytes),
including after renames and deletions. Optional numeric `assetType`,
`sourceAssetType`, `targetAssetType` identify asset subtypes for navigation.
Read-time `entityAvailable`, `sourceAvailable`, `targetAvailable` are true only
for records that still exist and are visible; omitted flags mean false.
No document contents or before/after values are retained. IDs use strings to avoid
JavaScript precision loss. A nonzero nextBefore is the last returned event ID;
zero means no older visible entries. Reads may return fewer events than Limit
to respect the frame-size budget. Pending durability returns a retryable error.

#### C_GetWorkspaceOverview (Client → Server)
```
[ConversationID: 8 bytes, must be 0] [CorrelationID: 4 bytes]
```

Uses the connection's authorized workspace. No filters, rows, cursors or page limit.

#### S_WorkspaceOverview (Server → Client)
```
[ConversationID: 8 bytes] [Success: 1 byte] [SampledAt: 8 bytes]
[StatusCounts: 4 × u32] [AssignedTasks: u32] [UnassignedTasks: u32] [OpenSlices: u32]
[SizeBuckets: 5 × u32] [BlockedBuckets: 3 × u32] [AgeBuckets: 5 × u32]
[ErrorLength: u16] [Error: variable UTF-8] [CorrelationID: u32]
```

One worker-owned snapshot, 105 bytes including opcode on success, independent of
workspace size. `SampledAt` is Unix nanoseconds and the age boundary. Status order
is Backlog, Todo, InProgress, Done; retired Note tasks are excluded. Coverage counts
each task once across valid slices, including closed slices and either membership
edge direction. Invalid slice previews, dangling members and non-membership links
are ignored. Each distribution counts every **open** slice once, including empty
and done-only slices:

- Size: 0, 1–5, 6–15, 16–30, 31+ task members, including Done.
- Blocked: 0, 1–2, 3+ members with a nonzero blocker (a flag, not a status).
- Age: ≤7, 8–30, 31–90, 91+ completed days since the oldest non-Done task's
  creation; final bucket means no open tasks. Future timestamps count as age 0.

Aggregation does not use the listing's u16 counters or 512-row page bound. Counters
are u32; an unrepresentable workspace returns `Success=0`, never wrapped totals.
On failure ignore all counters and retain the last successful snapshot. This is
an additive protocol-v8 opcode; the Overview client requires a server supporting it.

#### C_ListTaskSlices (Client → Server)
```
[ConversationID: 8 bytes] [IncludeClosed: 1 byte] [HasOwner: 1 byte] [OwnerLength: 2 bytes] [Owner: variable] [HasName: 1 byte] [NameLength: 2 bytes] [Name: variable] [Limit: 2 bytes] [HasCursor: 1 byte] [CursorClosed: 1 byte] [CursorSortAt: 8 bytes] [CursorSliceID: 8 bytes] [CorrelationID: 4 bytes]
```

Requests may append `[ProjectLength: 2 bytes] [Project: variable]` after the correlation ID. The optional project is valid UTF-8, at most `MAX_PROJECT_LENGTH` bytes; absent or empty means no project filter. A nonempty project matches exactly, case-sensitively, when at least one direct `MemberOf` task or note member has that structured project. Retired tasks, files, tickets and indirect links do not supply projects. Cross-project slices match each member project. Filtering happens before pagination and total counts; counters, movement, ordering and member contents still describe the full slice. Project-filtered requests return zero workspace work counters. Older requests without the extension remain valid; project-filtered requests require an updated server.

The register is paged. `Owner` is matched exactly and an empty owner with `HasOwner` is the slices nobody owns; `Name` is matched as a case-insensitive substring of the slice name. `Limit` is the page bound (`MAX_TASK_SLICE_COUNT` at most). The cursor is the last slice of the previous page, carried in the register's own order — closure, then movement, then ID — and is only sent when `HasCursor` is set. `MY SLICES` is resolved by the client into its own nickname, exactly as the task query resolves `MY TASKS` into the assignee.

#### S_TaskSliceList (Server → Client)
```
[ConversationID: 8 bytes] [Success: 1 byte] [SliceCount: 2 bytes] [Slices: variable] [HasMore: 1 byte] [NextCursorClosed: 1 byte] [NextCursorSortAt: 8 bytes] [NextCursorSliceID: 8 bytes] [TotalCount: 4 bytes] [AssignedTasks: 4 bytes] [UnassignedTasks: 4 bytes] [ErrorLength: 2 bytes] [Error: variable] [CorrelationID: 4 bytes]
```

One page is one frame. `HasMore` says whether another page follows, and the next cursor names the last slice of this page. `TotalCount` is every slice the filters match, not only this page's rows. The workspace counters (`AssignedTasks`, `UnassignedTasks`) are folded on the first page of an unfiltered listing and are zero for a filtered listing and for a page that continues one.

Each slice is:

```
[NameLength: 2 bytes] [Name: variable] [SliceID: 8 bytes] [OwnerLength: 2 bytes] [Owner: variable] [Flags: 1 byte] [Backlog: 2 bytes] [Todo: 2 bytes] [InProgress: 2 bytes] [Done: 2 bytes] [Blocked: 2 bytes] [Notes: 2 bytes] [Files: 2 bytes] [Tickets: 2 bytes] [OldestActiveAt: 8 bytes] [LastMovedAt: 8 bytes]
```

| Field | Meaning |
|-------|---------|
| `Name` | From the slice record preview. Never empty. |
| `SliceID` | Stable numeric identity of the slice asset. Never zero. |
| `Owner` | From the slice record preview. |
| `Flags` | Bit 0 `Closed`. Unknown bits are rejected. |
| `Backlog`/`Todo`/`InProgress`/`Done` | Task members by status. |
| `Blocked` | Task members whose `blocked_by` points at another task. |
| `Notes` | Note members. |
| `Files` | File members. |
| `Tickets` | Ticket members, excluding TicketEntry records. Independent u16 overflow limit. Included in member totals and movement, never task-status or assigned/unassigned task counters. |
| `OldestActiveAt` | `created_at` of the oldest non-Done task member, `0` when there is none. |
| `LastMovedAt` | `updated_at` of the most recently changed member. |

Tickets belong to slices through `MemberOf` (either direction). General ticket/task
work links remain `RelatedTo`; legacy `RelatedTo` slice links are not memberships
and are not implicitly migrated. Version 9 rows are wire-incompatible with version 8.

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

`name` is a nonempty display label, not an identity. Duplicate names are allowed,
and updates may rename the same asset. The name is bounded by
`MAX_PROJECT_LENGTH` (128 bytes). `outcome` is also written to the asset payload
and is bounded by `MAX_SLICE_OUTCOME_LENGTH` (2048 bytes).
A preview that does not decode, carries no version, or carries no name is skipped
rather than repaired. Create and update still require a valid preview and version,
a nonempty name and protocol byte-length validation.
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
- `Priority` (0), `Status` (1), `Assignee` (2), `DueAt` (3), `CreatedAt` (4), `Title` (5), `Color` (6), `Project` (7), `WorkOrder` (8)
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

- **Protocol payload**: 131072 bytes max, including the opcode and excluding the WebSocket frame header (`MAX_PROTOCOL_PAYLOAD_SIZE`)
- **Message content**: 51200 bytes max (`MAX_ALLOWED_CONTENT_LENGTH`)
- **Nickname**: 32 bytes max (`MAX_NICKNAME_LENGTH`)
- **Username**: 255 bytes max (`MAX_USERNAME_LENGTH`)
- **User ID**: 64 bytes max (`MAX_USER_ID_LENGTH`)
- **Authentication token**: 4096 bytes max (`MAX_TOKEN_LENGTH`)
- **Customer search query**: 256 bytes max (`MAX_CUSTOMER_SEARCH_QUERY`)
- **Error message**: 65535 bytes max (u16 length prefix)

### Tasks and slices

- **Task title**: 256 bytes max (`MAX_TASK_TITLE_LENGTH`)
- **Task description**: 4096 bytes max (`MAX_TASK_DESCRIPTION_LENGTH`)
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

   The person facets `C_ListSliceOwners` (65), `C_ListTicketAssignees` (66), and
   `C_ListCalendarPeople` (67) use the same request layout. Responses 171–173
   contain `scope:u64, count:u16, names[count]:str16, has_more:u8,
   correlation_id:u32` after the opcode. Names are sorted, unique and nonempty
   across all chunks. Lists cover the complete workspace data scope, independently
   of record paging, search, active filters and calendar dates. Slice owners include
   closed slices; ticket assignees include resolved/closed tickets. Calendar people
   combine task assignees (Backlog through Done, even without a deadline) with
   appointment assignees and, for v2 appointments, organizers, participants and
   non-cancelled occurrence participant overrides. These are filter candidates,
   not user-directory entries or proof of a matching event in the current range.
   Person facets support full username lengths, not the project-name limit.

   Calendar uses `C_QueryCalendar` (58), with big-endian fields after the opcode:
   `scope:u64=0, start:i64, end:i64, limit:u16, has_cursor:u8,
   cursor_at:i64, cursor_kind:u8, cursor_id:u64, assignee:str16,
   project:str16, correlation_id:u32`. Bounds are absolute nanoseconds in
   `[start,end)`, at most 62 days; limit is 1–100. Empty filters mean all.
   `str16` is a byte-length-prefixed UTF-8 string. Cursor fields must be zero
   without a cursor, otherwise identify the previous page's final row.
   The person filter accepts up to 255 bytes (full participant usernames),
   while stored task/appointment assignee fields remain limited to 32 bytes.

   `S_CalendarPage` (166), after the opcode:
   `scope:u64=0, count:u16, has_more:u8, cursor_at:i64, cursor_kind:u8,
   cursor_id:u64, rows[count], correlation_id:u32`. Each row is
   `kind:u8, id:u64, at:i64, blocked:u8, title:str16, assignee:str16, project:str16`.
   Kind 0 is an open dated task; kind 1 is a reminder deadline. Kind 2 is an
   appointment and appends `actual_start_at:i64, end_at:i64` after the three
   strings (`end_at=0` means a point appointment). Kind 3 is a recurring
   appointment occurrence: it appends the same interval fields followed by
   `occurrence_at:i64`, the original start before any rescheduling. Kinds 0 and 1
   retain the original row layout. Cursor kinds allow 0–3. Rows are ordered
   by `(at,kind,id)`, with exclusive continuation. Task filters intersect and
   exclude reminders and match appointment project. For v2 appointments, the
   person filter matches assignee, organizer or effective occurrence participants;
   v1 matches assignee only. Summary rows omit descriptions, attachments and payloads;
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

   Version 2 retains these fields and adds required `timezone` (IANA name),
   `repeat` (`""`, `daily`, `weekly`, `monthly`), `weekdays` (unique ISO 1–7 for
   weekly, otherwise empty), `until` (inclusive YYYY-MM-DD or empty),
   `participants` (unique usernames, at most 64), `conference` (`none`, `external`,
   `nrc`) and `exceptions` (at most 32). Exceptions are objects with original
   `at` (nanosecond string), `cancelled` (boolean), optional `start_at`, `end_at`
   and `participants`. Absent values inherit; empty `end_at` makes a point,
   empty participants removes additional participants. Cancellation cannot carry
   overrides. Unknown v2 keys, invalid timezones/dates and nonexistent exception
   identities are rejected. All fields together must fit the 4096-byte preview.
   Only the creator may mutate/delete v2 or upgrade v1 to v2, including cascades
   and transactions. Read visibility remains workspace-wide.

   Series preserve the start's local wall time and elapsed duration. Monthly
   missing days and DST gaps are skipped; folds choose the first instant.
   Recurring intervals may last at most 24 hours and must not overlap another
   occurrence of that series. Kind 3 keys use effective start, clamped to the
   query start, while `occurrence_at` stays stable. Indexed envelopes cover the
   series and moved exceptions; expansion is bounded by the requested range.
   Update server and web client together for protocol 10.

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

## Monitor run protocol

Monitor (asset type 15), MonitorSource (type 17) configuration and Incident (type 16) reads use the asset
protocol. Incidents are machine-owned: generic create/update/transaction patch and
delete commands reject them. See [the monitoring contract](../monitoring/README.md)
for configuration fields, authorization, limits and remaining integration.

`C_ApplyMonitorRun` has no caller-selected workspace or timestamp. Its body is
big-endian: correlation ID u32, monitor ID u64, expected asset `updated_at` i64,
monotonically increasing sequence u64, failed u8 (0 or 1), row count u16. Each row
is identity length u16, identity bytes (1–4096), condition u8 (0 passing, 1 failing,
2 between trigger and recovery), and IEEE-754 f64 bits as u64. Values must be
finite. No trailing bytes are allowed. Maximum frame size is 131072 bytes,
including the opcode; at most 1024 rows and no duplicate identities are allowed.

A successful request is a complete result: omitted active identities are absent.
A failed or incomplete query sets failed=1 and sends zero rows. It never infers
absence. Do not send a truncated result as successful or split a run into pages.
The server bounds the union of returned and active identities to 1024, so a legal
frame can still exceed the monitor's capacity. Retired and paused identities are
excluded unless returned; retained history does not consume the active budget.
Missing instances still count as active. Any rejection rolls
back the whole run. Retry the same sequence only with identical body bytes after
the correlation field. The latest receipt survives reconnects and server restarts;
older receipts are not retained. Changing the current monitor revision invalidates
old requests, including their retries.

`S_MonitorRunApplied` body: correlation ID u32, monitor ID u64, sequence u64,
replayed u8. It is emitted only after durable commit. New/updated Incident assets
are broadcast to workspace subscribers; replay emits only the ACK. Errors use
`S_ErrorResponse` with origin opcode 68 and the request correlation ID. The Go
codec takes a full request and decodes a response body without its opcode.

`C_ControlMonitorInstance` (69) has a fixed 29-byte body: correlation u32, Monitor
ID u64, expected Monitor `updated_at` i64, instance ID u64, action u8 (0 pause,
1 resume, 2 retire). IDs must be nonzero, revision positive, and trailing bytes
are rejected. Workspace and actor come from the authenticated connection.
This is a workspace-member action, not an evaluator-only command.

Acceptance advances the Monitor revision, fencing previously started runs.
Pause keeps incidents open; resume requires available active capacity; retirement
closes an episode as `removed` and preserves its history. Retired instances cannot
be paused/resumed; a new present regular observation reactivates them. See the
[instance lifecycle contract](../monitoring/README.md#instance-pause-resume-and-retirement).

`S_MonitorInstanceControlled` (175) body: correlation u32, Monitor ID u64, instance
ID u64, resulting Monitor revision i64, replayed u8 (0 or 1). The latest identical
action, excluding correlation, can replay for the same actor/subject while its
resulting Monitor revision remains current. It returns only the ACK, including
after reconnect/reopen. Replayed ACKs describe the original action, not the current
instance state. Conflicting or superseded actions fail without writes. Errors use
`S_ErrorResponse` with origin opcode 69 and preserve the parsed correlation.

`C_ActOnIncident` (70) body: correlation u32, Incident ID u64, expected Incident
`updated_at` i64, action u8 (0 acknowledge, 1 assign), assignee byte length u16,
then UTF-8 assignee bytes. ID must be nonzero and revision positive. Assignment
allows 0–32 bytes; empty clears it. Acknowledgment requires an empty assignee and
uses the authenticated actor. Invalid UTF-8 and trailing bytes are rejected.

`S_IncidentActionApplied` (176) body: correlation u32, Incident ID u64, resulting
Incident revision i64, replayed u8 (0 or 1). Acceptance advances only the Incident
revision; the first acknowledgment's actor/time remain unchanged. Exact retries
by the same actor/subject, excluding correlation, return only the ACK while that
resulting revision remains current. Later human actions or technical recovery
invalidate the receipt. Asset updates and history commit with the action before
publication. Errors use `S_ErrorResponse` with origin opcode 70 and preserve the
parsed correlation. See the [human-action contract](../monitoring/README.md#incident-acknowledgment-and-assignment).

`C_MonitorDelivery` (71) body: correlation u32, Monitor ID u64, stream u8,
action u8, delivery ID u64, lease generation i64, route byte length u8, route
bytes. Only stream 1 is valid; it identifies a webhook route reference
(1–64 ASCII alphanumeric, `-`, `_` or `.` bytes). Actions: 0 peek, 1 claim,
2 delivered, 3 retry, 4 permanent failure, 5 discard dead webhook. Peek/claim
require zero ID/generation; settlements require positive values.
Action 6 discovers queued or dirty webhook routes: stream must be 1,
ID/generation zero, and route is an exclusive cursor (empty for the first page).
Unknown actions, malformed lengths and trailing bytes fail.

Action 7 pages a leased resync token's open-Incident set. `id` is an exclusive
Incident-ID cursor (zero starts); `generation` is the token's positive
`sync_version`, not its lease generation. The active lease must belong to the
caller. State 6 returns at most 32 decimal-string `incident_ids` and `next_id`
(zero ends). State 7 means stale: discard staged pages and settle the obsolete
token without publishing. Settlement still uses the token ID and lease generation.
If the requested snapshot version belongs to an already replaced token, the command
fails; it does not return state 7 with the replacement token's credentials.
Ordinary responses also expose `sync_version`, `lost`, `loss_first_at` and
`loss_last_at` as decimal strings. Only ACK of the matching snapshot clears loss.

`S_MonitorDelivery` (177) body: correlation u32 followed by JSON:
`version:1`, `state`, `id`, `generation`, `created_at`, `available_at`,
`lease_until`, `attempts`, `payload`. IDs, generation and nanosecond timestamps
are decimal strings; attempts is an integer and payload is a JSON-encoded string
containing the event JSON. States: 0 empty, 1 waiting, 2 leased to this caller,
3 dead, 4 settlement accepted. A repeated settlement may return only its ID and
generation with zero timestamps/attempts and empty payload. Peek does not grant
a lease and returns waiting even for a currently leased head.

Discovery returns state 5, `routes` (at most 32 distinct references in byte order)
and `next_route` (last returned reference when another page exists, otherwise
empty). Other fields are zero/empty. Ordinary responses have empty `routes` and
`next_route`. Discovery includes old routes and dead-only lanes, but excludes
settlement-only receipts and clean configured routes with no queued events. Pages are
live, not snapshots: finish a pass with the returned cursor and periodically
restart from empty to find lanes inserted behind it. Removing the cursor's lane
does not invalidate continuation. Clients may find an empty lane when they claim
after another consumer has drained it.

Workspace members can peek (0), discover lanes (6), and discard a dead head (5)
with its exact event ID and generation. All other actions require the Monitor's
current evaluator. Discard receipts remain bound to actor and subject. Errors use
`S_ErrorResponse` with origin opcode 71 and the parsed correlation ID. See
[queue semantics](../monitoring/README.md#direct-measurement-history-and-webhook-outbox).

`C_GetMonitorState` (72) body: correlation u32, Monitor ID u64 (nonzero).
The configured evaluator may read enabled or disabled monitors in its workspace.
`S_MonitorState` (178) body: correlation u32, Monitor ID u64, current asset revision
i64, last committed run sequence u64 (zero before the first run). Both values are
read in one executor snapshot. This request never changes state. A sidecar reads
the asset separately and requires matching revisions before evaluating; apply's
revision and sequence checks still decide acceptance if a concurrent write occurs.

### Durable monitor availability history

`C_MonitorHistory` (75) body: correlation u32, Monitor ID u64, snapshot ID u64,
cursor u64, capture time i64, acknowledge u8 (0 or 1). Only the Monitor's
current evaluator in the authenticated workspace may use it.

An initial read has snapshot ID, cursor and capture time zero. It returns the oldest
pending snapshot. Continue with its exact snapshot ID and capture time and the
returned cursor. Each `S_MonitorState` (178) page contains correlation u32,
Monitor ID u64, captured revision i64, sequence u64, capture time i64, freshness
horizon i64, next cursor u64 and row count u16, followed by at most 16 rows.
Each row contains instance ID u64, identity byte length u16, UTF-8 identity,
state u8 (0 healthy, 1 failing, 2 unknown, 3 paused), and valid-until i64.
A snapshot ID u64 and final capture-kind u8 follow the rows. The kind is 0 for an accepted run or 1 for an on-demand
disabled-monitor pause observation. The next cursor is the last returned
instance ID, or zero on the final page.

The accepted run and every snapshot page commit in one SQLite transaction.
Later runs and wall-clock changes do not invalidate stored continuations.
Delivery never extends the captured evidence's validity. A disabled Monitor
with no pending snapshot captures bounded pause evidence on demand, including
sequence zero before its first run. An enabled Monitor with no pending snapshot
returns the ordinary short `S_MonitorState`, with sequence zero.

Snapshot IDs come from a durable sequence independent of wall time, including
pause captures. They are never reused after acknowledgment or restart.
After the sink commits the complete snapshot, acknowledge with its exact
snapshot ID and capture time, cursor zero and acknowledge 1. This deletes only
that snapshot; repeating the acknowledgment is harmless. The response is the
ordinary short `S_MonitorState`, with the acknowledged snapshot ID in its sequence field. Missing or
mismatched continuation pages fail explicitly rather than returning live state.
Errors use `S_ErrorResponse` with origin opcode 75 and the request correlation.

## Chronicle interface

Chronicle uses one multiplexed request opcode, `C_Chronicle = 74`, and one
response opcode, `S_Chronicle = 180`. This section defines the codec interface;
it does not assert that every server operation is implemented or enabled.

```
request:  opcode:u16 | JSON object | correlation:u32
response: opcode:u16 | correlation:u32 | JSON object
```

Integers in the binary envelope are big-endian. The complete application frame,
including opcode and correlation but excluding the WebSocket header, must not
exceed 131072 bytes. There is no JSON length prefix. The JSON occupies all bytes
between the fixed fields. JSON must be strict UTF-8 JSON, not JSON5.

Request fields (snake_case in both JSON and Odin):

| Fields | Type and codec bounds |
| --- | --- |
| `op` | One of `list`, `claim`, `chunk`, `reserve`, `commit`, `retry`, `status`, `history`, `gaps`, `delete` |
| `note_id`, `cursor`, `epoch`, `generation` | Optional canonical unsigned 64-bit decimal strings |
| `newest_first` | Optional boolean for `history` and `gaps`; defaults to false |
| `consumer`, `model`, `prompt_version`, `schema_version` | UTF-8 strings, at most 128 bytes each |
| `outcome`, `reason` | UTF-8 strings, at most 128 bytes each |
| `summary` | UTF-8 string, at most 4096 bytes |
| `sources` | At most 32 nonzero canonical u64 decimal strings in strictly increasing numeric order |
| `limit`, `length` | u16 JSON integers |
| `field` | u8 JSON integer |
| `offset`, `input_tokens`, `output_tokens` | u32 JSON integers |

An absent ID is represented by an omitted field or an empty string. A present ID
uses only ASCII digits, has no leading zero except `"0"`, and must fit u64.
JSON numbers are never accepted for IDs, cursors, epochs or generations. Zero
is valid at the codec layer; operation handlers decide whether it is allowed.
Null request fields, unknown keys, duplicate keys and nested objects are rejected.
Omitted scalar fields decode to their zero values. The consumer version constant
is `CHRONICLE_CONSUMER_VERSION = "chronicle-v1"`.

Operation handlers own required-field checks, authorization, lease fencing,
budget enforcement and persistence. The interface separates these operations:

| Operation | Interface purpose and relevant fields |
| --- | --- |
| `list` | Page available inputs using `consumer`, `cursor`, `limit` |
| `claim` | Claim at most `limit` inputs for `consumer` / optional `note_id`; return epoch, generation, note, lease and exact source IDs |
| `chunk` | Read one claimed source ID in `cursor`, using `field`, `offset`, `length` and lease identity |
| `reserve` | Reserve model-call budget with `input_tokens`, `output_tokens` and lease identity |
| `commit` | Submit `sources`, `outcome`, `summary`, model/prompt/schema metadata and usage under the claimed lease |
| `retry` | Release or defer claimed work with `reason` and lease identity |
| `status` | Inspect consumer progress and pending/raw-byte/call/token counters |
| `history` | Page committed entries for `note_id` with `cursor`, `limit` |
| `gaps` | Page compact loss receipts with optional `note_id`, exclusive first-source `cursor`, and `limit` |
| `delete` | Request deletion for `note_id`; return a deletion watermark |

Access bits are `CHRONICLE_ACCESS_READ = 1`, `CHRONICLE_ACCESS_SERVICE = 2`
and `CHRONICLE_ACCESS_DELETE = 4`; the authenticated server determines the
authority needed for each operation. A codec-valid request alone grants nothing.

Response objects may contain string fields `status`, `error`, `epoch`,
`generation`, `lease_until`, `note_id`, `cursor`, `summary`, `outcome`,
`deleted_through`; numeric counters `pending`, `raw_bytes`, `calls`,
`input_tokens`, `output_tokens`, `processing`, `failed`, `acknowledged`, `gap_count`,
`expired`; `enabled`, `more`, `can_delete` (bool); `sources` (decimal strings);
`inputs`, `entries`, and `gaps` arrays; and `chunk` (base64 text). Status values include
`claimed`, `empty`, `busy`, `committed`, `acknowledged`, `gap`, `deleted`,
`forbidden`, `expired`, `budget`, `backoff`, `parked` and `exhausted`.

Each input descriptor has string `source_id`, `note_id`, `captured_at`,
`expires_at`, `before_version`, `after_version`, hex `before_hash` / `after_hash`,
`actor_id`, `actor_name`; numeric `operation`, `attempts`; boolean
`before_present`, `after_present`; and `lengths`, six signed 64-bit raw-field
lengths. Each entry has string `generation`, `note_id`, `created_at`, `first_at`,
`last_at`, `note_title`, `summary`, `model`, `prompt_version`, `schema_version`; `sources`
(decimal strings); and boolean `source_available`.
Each gap has exact decimal strings `first_source`, `last_source`, `note_id`,
`first_at`, `last_at`; strings `note_title`, `reason`; numeric `input_count`; and boolean
`source_available`. Gap responses contain no raw source text, actor or hashes.

For both read collections, `note_title` is the current bounded note-title label
(at most 256 UTF-8 bytes), read in the same transaction as the page. Deleted
notes use their last technical-history label and remain unavailable, not linked.
An empty title means no title metadata is available; never substitute note-body
text. IDs remain the stable identity, including when titles repeat or change.

Odin APIs: `parseChronicleEnvelope` checks only framing without allocating;
`parseChronicleRequest` checks the JSON object and codec bounds using the caller's
scoped arena. The caller must destroy that arena on success or failure after
consuming any result. `serializeChronicleRequest` writes the full request frame
and returns zero on failure. Its temporary JSON allocation is explicitly freed.
Go APIs: `EncodeChronicleRequest` writes the full frame;
`DecodeChronicleResponse` accepts a payload with its opcode already removed.
The Go response types preserve IDs as strings and counters as uint64, never
through float64. Unknown response fields are ignored for forward compatibility.

### Implemented operation rules

All service operations require `consumer:"chronicle-v1"`. `list` and `claim`
require `limit` in 1–32. `list` returns pending descriptors after the exclusive
source cursor. A claim takes one note's prefix of global pending source order;
it cannot skip an earlier unresolved note to enlarge its batch. There is one
active claim per workspace. Its epoch, generation, authenticated subject and
ordered sources are immutable. `note_id` may restrict the head, not choose a
later note. The lease is at most five minutes and never exceeds input expiry.

`chunk`, `reserve`, `commit` and `retry` require epoch/generation and the same
consumer/subject. Except for `chunk`, they require the exact ordered `sources`
from the claim. Chunk fields 0–5 mean before title/format/body, then after
title/format/body; `length` is 1–16384 and the response `chunk` is base64.
Raw reads and new terminal commits enforce the 72h TTL and current epoch even
before cleanup. `reserve` requires 1–128000 complete-request input tokens and
exactly 1000 output tokens. Duplicate identical reservation is free; changed
counts conflict. Persisted daily limits are 8000000 input/500000 output tokens.
The daily call count is telemetry, not a separate limit.
Reservations remain spent on timeout or restart.

On `commit` or `retry`, `input_tokens`/`output_tokens` optionally report confirmed
provider usage, including all request/output tokens, not just summary text.
Both must be positive and no greater than their respective reservation; zero/zero
or omitted values mean unknown usage and retain the full reservation. Partial or
over-reservation reports are invalid. The unused portion is credited atomically
with the terminal transition/retry release, only to the reservation's UTC day.
No later day's budget receives the credit. Calls and attempts are not refunded.
Result replay fingerprints include usage; identical replay never credits twice,
and changed usage conflicts. Consumers without usage reporting remain conservative.

`commit` outcomes are `result` (nonblank summary), `ack` (empty summary), and
`gap`. Result/Ack require a reservation plus nonempty model/prompt/schema versions
and an empty reason. An unreserved singleton may commit `gap` with
`reason:"token_limit"` and no model metadata or summary. Successful replay
returns the stored status/summary; changed content returns `conflict`.
`retry` accepts `rebatch` before reservation, or `temporary`, `timeout`,
`invalid_output` or `permanent` after reservation. `permanent` returns `parked`
and persists `retry_at=expires_at`, preventing deterministic provider failures
from spending more attempts across restart. The input stays pending until TTL or
authorized deletion; claims return `parked` at that boundary. Attempts survive rebatching and lease expiry.
After five attempts, claims return `exhausted`. The failed input stays visible
until TTL or authorized deletion; later pending inputs cannot skip it.

`history` requires `limit` in 1–16, pages by exclusive generation cursor, and
optionally filters by note ID; a response is also bounded to about 60 KB of entry
JSON. Only results appear, never no-change Acks. Source deletion leaves a result
with `source_available:false`. `delete` requires a nonzero note ID and separate
human-delete authority. It atomically deletes Chronicle prose and suppresses
all that note's pending inputs through the returned source watermark. Old replay
then returns `deleted` with no summary. Later mutations remain eligible.
`gaps` requires `limit` in 1–16 and returns ascending compact receipts after
the exclusive `first_source` cursor. `cursor` is the last returned first source;
`more` indicates another row. Optional nonzero `note_id` restricts the page.
Source deletion retains receipts with `source_available:false`. Result and Ack
are not gaps. Paging is live, not a snapshot: cleanup can extend compact ranges.
Empty `history` and `gaps` pages retain the request cursor, or return `"0"` when
no cursor was supplied. Public collection fields (`sources`, `inputs`, `entries`,
`gaps`) serialize as JSON arrays, including `[]` when empty, never `null`.

Both reads accept optional `newest_first:true` to reverse the order. In that mode,
an absent or `"0"` cursor starts at the newest row; subsequent pages return IDs
strictly below the cursor. The web client uses this mode so LOAD MORE appends
older entries. Omitted or false preserves the ascending order for existing clients.

`status` returns opt-in, epoch and `can_delete`, derived only from the current
authenticated DELETE capability. Optional nonzero `note_id` scopes `pending`,
`processing`, `failed`, `acknowledged`, `gap_count` and `expired`. `pending` is
the logically live unresolved input total; `processing` and `failed` are
disjoint subsets of it. Processing requires an active, unexpired current-epoch
lease. Failed inputs are unleased, permanently parked or have exhausted five
attempts; a live fifth attempt is still processing. Queued/backoff work is
pending but neither processing nor failed. `expired` counts pending rows already
logically expired by TTL or disabled epoch, before physical cleanup; these are
excluded from pending/processing/failed. `acknowledged` counts successful
no-change inputs. `gap_count` sums lost inputs, not compact receipt rows.
`raw_bytes` and current-day `calls`, `input_tokens`, `output_tokens` remain
workspace-wide even for note-scoped status. Reads do not trigger cleanup.
Pending/raw counters on other operations describe the pre-operation snapshot.

Service-only operations are list/claim/chunk/reserve/commit/retry. Authenticated
workspace readers may use history/status/gaps, without a consumer version. These
read operations never grant claim or raw-chunk authority. The Chronicle service
identity cannot send unrelated canonical commands. See the operator configuration and remaining
worker rollout gate in [DEVELOPMENT.md](../docs/DEVELOPMENT.md#chronicle-service-boundary).
