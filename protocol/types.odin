package protocol

ConversationID :: u64
MessageSeq :: u64

// Reserved scope for workspace-owned tasks, assets and graph data. It is not a
// chat conversation. The existing conv_id wire field carries this scope so the
// entity codecs and durable record format remain unchanged.
WORKSPACE_DATA_ID :: ConversationID(0)

MessageContentType :: enum u8 {
	PlainText,
	Markdown,
}

Opcode :: enum u16 {
	// Client -> Server
	// 0 reserved (formerly C_SetNickname)
	C_SendMessage = 1,
	C_SubscribeConvs,
	C_UnsubscribeConvs,
	// 4, 5 reserved (formerly C_SetAgenda, C_GetAgenda)
	// 6, 7 reserved (formerly C_SetDiagram, C_GetDiagram)
	C_Stats = 8,
	// 9 reserved (formerly C_Authenticate)
	// 10-15 reserved (formerly C_JoinVoice, C_LeaveVoice, C_AudioFrame, C_StartScreenshare, C_StopScreenshare, C_ScreenFrame)

	// Direct Messages (Client -> Server)
	C_StartDM = 16,
	C_ListDMs = 17,
	C_LeaveDM = 18,
	C_Ping = 19,

	// Retained chat (Client -> Server)
	C_SendMessageV2 = 48,
	C_SubscribeConvsV2 = 49,
	C_ListMessagesBefore = 50,
	C_ReplayMessagesAfter = 51,
	C_GraphRank = 52,

	// Server -> Client
	S_ServerReady = 100,
	// 101 reserved (formerly S_NicknameResponse)
	S_NewMessage = 102,
	S_AckSendMessage = 103,
	S_ErrorResponse = 104,
	// 105, 106 reserved (formerly S_AgendaResponse, S_AgendaUpdated)
	// 107, 108 reserved (formerly S_DiagramResponse, S_DiagramUpdated)
	S_RoomPresenceUpdate = 109,
	S_StatsResponse = 110,
	S_AuthResponse = 111,

	// 112-120 reserved (formerly S_VoiceJoined, S_VoiceLeft, S_AudioFrame, S_Speaking, S_VoiceMetrics, S_ScreenshareStarted, S_ScreenshareEnded, S_ScreenFrame, S_ScreenshareMetrics)

	// Direct Messages (Server -> Client)
	S_DMStarted = 121,
	S_DMList = 122,
	S_DMError = 123,
	S_DMLeft = 124,
	S_DMPartnerStatus = 125,
	S_Pong = 126,
	S_AckUnsubscribeConvs = 127,

	// Retained chat (Server -> Client)
	S_SubscriptionReady = 158,
	S_MessagePage = 159,

	// Tasks/Kanban (Client -> Server)
	C_CreateTask = 20,
	C_UpdateTask = 21,
	C_DeleteTask = 22,
	C_MoveTask = 23,
	C_GetTasks = 24,
	C_ListTasksPaged = 25,
	C_GetTask = 26,
	C_ApplyTransaction = 27,
	C_QueryTasks = 28,
	C_ListTaskProjects = 29,
	C_ListTaskSlices = 56,
	C_ListTaskAssignees = 57,
	C_QueryCalendar = 58,

	// Tasks/Kanban (Server -> Client)
	S_TaskCreated = 130,
	S_TaskUpdated = 131,
	S_TaskDeleted = 132,
	S_TaskMoved = 133,
	S_TaskListResponse = 134,
	S_TaskListPage = 135,
	S_TaskFull = 136,
	S_TransactionResult = 137,
	S_TaskQueryPage = 138,
	S_TaskProjects = 139,
	S_TaskSliceList = 164,
	S_TaskAssignees = 165,
	S_CalendarPage = 166,

	// Assets (Client -> Server)
	C_CreateAsset = 30,
	C_UpdateAsset = 31,
	C_DeleteAsset = 32,
	C_GetAsset = 33,
	C_ListAssets = 34,
	C_ListAssetsPaged = 35,
	C_ListAssetsPagedByProject = 36,
	C_ListNoteProjects = 37,
	C_ListAssetsPagedByTag = 38,
	C_ListNoteTags = 39,

	// Assets (Server -> Client)
	S_AssetCreated = 140,
	S_AssetUpdated = 141,
	S_AssetDeleted = 142,
	S_AssetFull = 143,
	S_AssetList = 144,
	S_AssetListPage = 145,
	S_NoteProjectList = 146,
	S_NoteTagList = 147,

	// Edges/Knowledge Graph (Client -> Server)
	C_CreateEdge = 40,
	C_DeleteEdge = 41,
	C_ListEdges = 42,
	C_ListAllEdges = 43,
	C_ListAllEdgesPaged = 53,
	C_ListEdgesPaged = 54,
	C_SearchCustomers = 55,

	// Graph Query (Client -> Server)
	C_GraphQuery = 44,
	C_GraphShortestPath = 45,
	C_GraphDegree = 46,
	C_GraphCommonNeighbors = 47,

	// Edges/Knowledge Graph (Server -> Client)
	S_EdgeCreated = 150,
	S_EdgeDeleted = 151,
	S_EdgeList = 152,
	S_AllEdgeList = 153,
	S_AllEdgeListPage = 161,
	S_EdgeListPage = 162,
	S_CustomerSearchPage = 163,

	// Graph Query (Server -> Client)
	S_GraphQueryResult = 154,
	S_GraphShortestPathResult = 155,
	S_GraphDegreeResult = 156,
	S_GraphCommonNeighborsResult = 157,
	S_GraphRankResult = 160,
}

// ProtocolParseError uses .None as the zero/success value so parser callers can
// use the established Odin-style `err == nil` / `err != nil` checks safely.
// New strict request parsers should return a non-.None value for payloads that
// are invalid under every supported wire shape. Production-dispatched request
// parsers should reject unexpected trailing bytes as .ContentLengthMismatch;
// legacy wire-compatibility exceptions must be documented where they are tested
// or parsed. Reserved legacy parsers, such as auth opcode 9, are not the model
// for new production-dispatched request parsers.
ProtocolParseError :: enum {
	None,
	TooShort,
	InvalidOpcode,
	InvalidContentType,
	ContentLengthExceedsMax,
	ContentLengthMismatch,
	TooMany,
	InvalidValue,
}

User_Type :: enum u8 {
	User,
	Admin,
	Bot,
	System,
}

PresenceEventType :: enum u8 {
	UserJoined,
	UserLeft,
	UserListSync,
	UserRenamed,
}

// Content limits
MAX_ALLOWED_CONTENT_LENGTH :: 1024 * 50 // 50KB - allows 48KB image chunks + JSON overhead
MAX_TOKEN_LENGTH :: 4096
MAX_USER_ID_LENGTH :: 64
MAX_NICKNAME_LENGTH :: 32
MAX_USERNAME_LENGTH :: 255

// Protocol limits
MAX_SUBSCRIBE_CONVS :: 64
MAX_MESSAGE_PAGE_COUNT :: 100

// Task limits
MAX_TASK_TITLE_LENGTH :: 256
MAX_TASK_DESCRIPTION_LENGTH :: 2048
MAX_ASSIGNEE_LENGTH :: 32
MAX_EXTERNAL_REF_LENGTH :: 512
MAX_PROJECT_LENGTH :: 128
MAX_ACTIVE_TASKS_PER_CONVERSATION :: 1000
MAX_TASKS_PER_CONVERSATION :: 1000 // Legacy name retained for source compatibility.
MAX_TOTAL_TASKS_PER_CONVERSATION :: 10000
MAX_TASK_PAGE_SIZE :: 1000
// One listing frame carries at most this many slices. A slice is an explicit
// work stream, so the ceiling is a frame bound, not a count of labels.
MAX_TASK_SLICE_COUNT :: 512
MAX_SLICE_OUTCOME_LENGTH :: 2048
MAX_FILE_ID_LENGTH :: 36 // "att_" + 32 hex chars (SHA256)
MAX_FILENAME_LENGTH :: 256
MAX_MIME_TYPE_LENGTH :: 128
MAX_ATTACHMENTS_PER_TASK :: 10
