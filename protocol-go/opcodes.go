package protocol

// Client -> Server opcodes
const (
	C_SetNickname      uint16 = 0
	C_SendMessage      uint16 = 1
	C_SubscribeConvs   uint16 = 2
	C_UnsubscribeConvs uint16 = 3
	// 4, 5 reserved (formerly C_SetAgenda, C_GetAgenda)
	// 6, 7 reserved (formerly C_SetDiagram, C_GetDiagram)
	C_Stats        uint16 = 8
	C_Authenticate uint16 = 9

	// Voice chat (Client -> Server)
	C_JoinVoice  uint16 = 10
	C_LeaveVoice uint16 = 11
	C_AudioFrame uint16 = 12

	// Screen share (Client -> Server)
	C_StartScreenshare uint16 = 13
	C_StopScreenshare  uint16 = 14
	C_ScreenFrame      uint16 = 15

	// Direct Messages (Client -> Server)
	C_StartDM uint16 = 16
	C_ListDMs uint16 = 17
	C_LeaveDM uint16 = 18
	C_Ping    uint16 = 19

	// Tasks/Kanban (Client -> Server)
	C_CreateTask        uint16 = 20
	C_UpdateTask        uint16 = 21
	C_DeleteTask        uint16 = 22
	C_MoveTask          uint16 = 23
	C_GetTasks          uint16 = 24
	C_ListTasksPaged    uint16 = 25
	C_GetTask           uint16 = 26
	C_ApplyTransaction  uint16 = 27
	C_QueryTasks        uint16 = 28
	C_ListTaskProjects  uint16 = 29
	C_ListTaskSlices    uint16 = 56
	C_ListTaskAssignees uint16 = 57
	C_QueryCalendar     uint16 = 58

	// Assets (Client -> Server)
	C_CreateAsset              uint16 = 30
	C_UpdateAsset              uint16 = 31
	C_DeleteAsset              uint16 = 32
	C_GetAsset                 uint16 = 33
	C_ListAssets               uint16 = 34
	C_ListAssetsPaged          uint16 = 35
	C_ListAssetsPagedByProject uint16 = 36
	C_ListNoteProjects         uint16 = 37
	C_ListAssetsPagedByTag     uint16 = 38
	C_ListNoteTags             uint16 = 39

	// Edges/Knowledge Graph (Client -> Server)
	C_CreateEdge        uint16 = 40
	C_DeleteEdge        uint16 = 41
	C_ListEdges         uint16 = 42
	C_ListAllEdges      uint16 = 43
	C_ListAllEdgesPaged uint16 = 53
	C_ListEdgesPaged    uint16 = 54
	C_SearchCustomers   uint16 = 55

	// Graph Query (Client -> Server)
	C_GraphQuery           uint16 = 44
	C_GraphShortestPath    uint16 = 45
	C_GraphDegree          uint16 = 46
	C_GraphCommonNeighbors uint16 = 47
	C_SendMessageV2        uint16 = 48
	C_SubscribeConvsV2     uint16 = 49
	C_ListMessagesBefore   uint16 = 50
	C_ReplayMessagesAfter  uint16 = 51
	C_GraphRank            uint16 = 52
)

// Server -> Client opcodes
const (
	S_ServerReady      uint16 = 100
	S_NicknameResponse uint16 = 101
	S_NewMessage       uint16 = 102
	S_AckSendMessage   uint16 = 103
	S_ErrorResponse    uint16 = 104
	// 105, 106 reserved (formerly S_AgendaResponse, S_AgendaUpdated)
	// 107, 108 reserved (formerly S_DiagramResponse, S_DiagramUpdated)
	S_RoomPresenceUpdate uint16 = 109
	S_StatsResponse      uint16 = 110
	S_AuthResponse       uint16 = 111

	// Voice chat (Server -> Client)
	S_VoiceJoined  uint16 = 112
	S_VoiceLeft    uint16 = 113
	S_AudioFrame   uint16 = 114
	S_Speaking     uint16 = 115
	S_VoiceMetrics uint16 = 116

	// Screen share (Server -> Client)
	S_ScreenshareStarted uint16 = 117
	S_ScreenshareEnded   uint16 = 118
	S_ScreenFrame        uint16 = 119
	S_ScreenshareMetrics uint16 = 120

	// Direct Messages (Server -> Client)
	S_DMStarted           uint16 = 121
	S_DMList              uint16 = 122
	S_DMError             uint16 = 123
	S_DMLeft              uint16 = 124
	S_DMPartnerStatus     uint16 = 125
	S_Pong                uint16 = 126
	S_AckUnsubscribeConvs uint16 = 127

	// Tasks/Kanban (Server -> Client)
	S_TaskCreated       uint16 = 130
	S_TaskUpdated       uint16 = 131
	S_TaskDeleted       uint16 = 132
	S_TaskMoved         uint16 = 133
	S_TaskListResponse  uint16 = 134
	S_TaskListPage      uint16 = 135
	S_TaskFull          uint16 = 136
	S_TransactionResult uint16 = 137
	S_TaskQueryPage     uint16 = 138
	S_TaskProjects      uint16 = 139
	S_TaskSliceList     uint16 = 164
	S_TaskAssignees     uint16 = 165
	S_CalendarPage      uint16 = 166

	// Assets (Server -> Client)
	S_AssetCreated    uint16 = 140
	S_AssetUpdated    uint16 = 141
	S_AssetDeleted    uint16 = 142
	S_AssetFull       uint16 = 143
	S_AssetList       uint16 = 144
	S_AssetListPage   uint16 = 145
	S_NoteProjectList uint16 = 146
	S_NoteTagList     uint16 = 147

	// Edges/Knowledge Graph (Server -> Client)
	S_EdgeCreated        uint16 = 150
	S_EdgeDeleted        uint16 = 151
	S_EdgeList           uint16 = 152
	S_AllEdgeList        uint16 = 153
	S_AllEdgeListPage    uint16 = 161
	S_EdgeListPage       uint16 = 162
	S_CustomerSearchPage uint16 = 163

	// Graph Query (Server -> Client)
	S_GraphQueryResult           uint16 = 154
	S_GraphShortestPathResult    uint16 = 155
	S_GraphDegreeResult          uint16 = 156
	S_GraphCommonNeighborsResult uint16 = 157
	S_SubscriptionReady          uint16 = 158
	S_MessagePage                uint16 = 159
	S_GraphRankResult            uint16 = 160
)

// Content types
const (
	ContentTypePlainText uint8 = 0
	ContentTypeMarkdown  uint8 = 1
)

// Task status - matches server TaskStatus enum (u8)
const (
	TaskStatusBacklog    uint8 = 0
	TaskStatusTodo       uint8 = 1
	TaskStatusInProgress uint8 = 2
	TaskStatusDone       uint8 = 3
	TaskStatusNote       uint8 = 4
)

// Task color - matches server TaskColor enum (u8)
const (
	TaskColorNone  uint8 = 0
	TaskColorCyan  uint8 = 1
	TaskColorRed   uint8 = 2
	TaskColorGreen uint8 = 3
	TaskColorGray  uint8 = 4
	TaskColorGold  uint8 = 5
)

// Asset types - matches server AssetType enum (u16)
const (
	AssetTypeComment          uint16 = 1
	AssetTypeDocument         uint16 = 2
	AssetTypeFile             uint16 = 3
	AssetTypeAgenda           uint16 = 4
	AssetTypeNote             uint16 = 5
	AssetTypeReminder         uint16 = 6
	AssetTypeRoomMapping      uint16 = 7
	AssetTypeCustomerCompany  uint16 = 8
	AssetTypeCustomerContact  uint16 = 9
	AssetTypeCustomerActivity uint16 = 10
	// AssetTypeSlice is a bound work slice: the asset records a derived slice's
	// owner, outcome and closure. Membership stays the project label.
	AssetTypeSlice       uint16 = 11
	AssetTypeAppointment uint16 = 12
)

// WorkspaceDataConvID is the reserved scope for all durable tasks, assets,
// edges, graph queries and transactions. Subscribe to it for durable events;
// it never carries chat or presence. Encoders retain explicit scope arguments
// for wire compatibility; callers must pass this value for durable operations.
const WorkspaceDataConvID = 0

// Built-in chat room IDs preserved for existing NRC data.
const (
	DefaultRoomID     int64 = 2
	EngineeringRoomID int64 = 2
	OperationsRoomID  int64 = 3
	SystemRoomID      int64 = 7
)

// Asset payload encoding - matches server PayloadEncoding enum (u8)
const (
	AssetPayloadEncodingPlain uint8 = 0
	AssetPayloadEncodingZstd  uint8 = 1
)

// Parent types - matches server ParentType enum (u16)
const (
	ParentTypeNone  uint16 = 0
	ParentTypeTask  uint16 = 1
	ParentTypeAsset uint16 = 2
)

// Edge relation types - matches server RelationType enum (u16)
const (
	RelationReferences  uint16 = 1
	RelationRelatedTo   uint16 = 2
	RelationDependsOn   uint16 = 3
	RelationBlocks      uint16 = 4
	RelationDerivedFrom uint16 = 5
	RelationSupersedes  uint16 = 6
	RelationMemberOf    uint16 = 7
)

// Edge target types - matches server TargetType enum (u16)
const (
	TargetTypeAsset uint16 = 1
	TargetTypeTask  uint16 = 2
)

// Protocol limits - matches server protocol/types.odin
const (
	MaxAllowedContentLength         = 1024 * 50 // 50KB
	MaxTokenLength                  = 4096
	MaxUserIDLength                 = 64
	MaxNicknameLength               = 32
	MaxUsernameLength               = 255
	MaxSubscribeConvs               = 64
	MaxOpusPacketSize               = 1275
	MaxScreenFrameSize              = 131072
	MaxTaskTitleLength              = 256
	MaxTaskDescriptionLength        = 2048
	MaxAppointmentDescriptionLength = MaxTaskDescriptionLength
	MaxAppointmentURLLength         = 2048
	MaxAssigneeLength               = 32
	MaxExternalRefLength            = 512
	MaxProjectLength                = 128
	MaxTaskPageSize                 = 1000
	// One listing frame carries at most this many slices. A slice is an explicit
	// work stream, so the ceiling is a frame bound, not a count of labels.
	MaxTaskSliceCount     = 512
	MaxSliceOutcomeLength = 2048
	MaxFileIDLength       = 36
	MaxFilenameLength     = 256
	MaxMimeTypeLength     = 128
	MaxAttachmentsPerTask = 10
)

// Asset limits - matches server protocol/assets.odin
const (
	MaxOwnerLength   = 64
	MaxPreviewLength = 4096
	MaxPayloadLength = 65535 // Payload length is encoded as uint16 on the wire.
)
