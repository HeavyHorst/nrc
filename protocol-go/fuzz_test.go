package protocol

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

// decodeServerFrame routes one server-to-client frame to the same decoder the
// CLI uses. A decoder error is a normal result for mutated input; a panic, OOM
// or timeout is the finding. Opcodes without a Go decoder (S_TaskAssignees,
// S_HistoryPage and the retired voice/screen-share range) return without work.
func decodeServerFrame(data []byte) {
	if len(data) < 2 {
		return
	}
	opcode := binary.BigEndian.Uint16(data[:2])
	payload := data[2:]
	var err error

	switch opcode {
	case S_ServerReady:
		// This decoder predates the payload-only convention and reads the opcode itself.
		_, err = ParseServerReady(data)
	case S_NicknameResponse:
		_, err = DecodeNicknameResponse(payload)
	case S_NewMessage:
		_, err = DecodeChatMessage(payload)
	case S_AckSendMessage:
		_, err = DecodeAckSendMessage(payload)
	case S_ErrorResponse:
		_, err = DecodeErrorResponse(payload)
	case S_RoomPresenceUpdate:
		_, err = DecodePresenceUpdate(payload)
	case S_StatsResponse:
		_, err = DecodeStatsResponse(payload)
	case S_AuthResponse:
		_, err = DecodeAuthResponse(payload)

	case S_DMStarted:
		_, err = DecodeDMStarted(payload)
	case S_DMList:
		_, err = DecodeDMList(payload)
	case S_DMError:
		_, err = DecodeDMError(payload)
	case S_DMLeft:
		_, err = DecodeDMLeft(payload)
	case S_DMPartnerStatus:
		_, err = DecodeDMPartnerStatus(payload)
	case S_Pong:
		_, err = DecodePongResponse(payload)
	case S_AckUnsubscribeConvs:
		_, err = DecodeAckUnsubscribeConvs(payload)

	case S_TaskCreated:
		_, err = DecodeTaskCreated(payload)
	case S_TaskUpdated:
		_, err = DecodeTaskUpdated(payload)
	case S_TaskDeleted:
		_, err = DecodeTaskDeleted(payload)
	case S_TaskMoved:
		_, err = DecodeTaskMoved(payload)
	case S_TaskListResponse:
		_, err = DecodeTaskListResponse(payload)
	case S_TaskListPage:
		_, err = DecodeTaskListPage(payload)
	case S_TaskFull:
		_, err = DecodeTaskFull(payload)
	case S_TransactionResult:
		_, err = DecodeTransactionResult(payload)
	case S_TaskQueryPage:
		_, err = DecodeTaskQueryPage(payload)
	case S_TaskProjects:
		_, err = DecodeTaskProjects(payload)
	case S_TaskSliceList:
		_, err = DecodeTaskSliceList(payload)
	case S_CalendarPage:
		_, err = DecodeCalendarPage(payload)
	case S_WorkspaceOverview:
		_, err = DecodeWorkspaceOverview(payload)
	case S_TaskDependentsPage:
		_, err = DecodeTaskDependentsPage(payload)
	case S_SliceOwners:
		_, err = DecodeSliceOwners(payload)
	case S_TicketAssignees:
		_, err = DecodeTicketAssignees(payload)
	case S_CalendarPeople:
		_, err = DecodeCalendarPeople(payload)

	case S_AssetCreated:
		_, err = DecodeAssetCreated(payload)
	case S_AssetUpdated:
		_, err = DecodeAssetUpdated(payload)
	case S_AssetDeleted:
		_, err = DecodeAssetDeleted(payload)
	case S_AssetFull:
		_, err = DecodeAssetFullResponse(payload)
	case S_AssetList:
		_, err = DecodeAssetListResponse(payload)
	case S_AssetListPage:
		_, err = DecodeAssetListPage(payload)
	case S_NoteProjectList:
		_, err = DecodeNoteProjectList(payload)
	case S_NoteTagList:
		_, err = DecodeNoteTagList(payload)

	case S_EdgeCreated:
		_, err = DecodeEdgeCreated(payload)
	case S_EdgeDeleted:
		_, err = DecodeEdgeDeleted(payload)
	case S_EdgeList:
		_, err = DecodeEdgeListResponse(payload)
	case S_AllEdgeList:
		_, err = DecodeAllEdgeListResponse(payload)
	case S_AllEdgeListPage:
		_, err = DecodeAllEdgeListPage(payload)
	case S_EdgeListPage:
		_, err = DecodeEdgeListPage(payload)
	case S_CustomerSearchPage:
		_, err = DecodeCustomerSearchPage(payload)
	case S_TicketPage:
		_, err = DecodeTicketPage(payload)

	case S_GraphQueryResult:
		_, err = DecodeGraphQueryResult(payload)
	case S_GraphShortestPathResult:
		_, err = DecodeGraphShortestPathResult(payload)
	case S_GraphDegreeResult:
		_, err = DecodeGraphDegreeResult(payload)
	case S_GraphCommonNeighborsResult:
		_, err = DecodeGraphCommonNeighborsResult(payload)
	case S_SubscriptionReady:
		_, err = DecodeSubscriptionReady(payload)
	case S_MessagePage:
		_, err = DecodeMessagePage(payload)
	case S_GraphRankResult:
		_, err = DecodeGraphRankResult(payload)
	}

	_ = err
}

// FuzzDecodeServerFrame fuzzes every server response decoder with the same
// bytes the Odin fuzzer's response corpus uses. go test runs the seeds as
// ordinary cases; a campaign runs with -fuzz.
func FuzzDecodeServerFrame(f *testing.F) {
	seeds, _ := filepath.Glob(filepath.Join("..", "test", "protocol_fuzz", "corpus", "*.bin"))
	for _, path := range seeds {
		data, err := os.ReadFile(path)
		if err != nil || len(data) < 2 {
			continue
		}
		if binary.BigEndian.Uint16(data[:2]) < 100 {
			continue
		}
		f.Add(data)
	}

	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 128*1024 {
			return
		}
		decodeServerFrame(data)
	})
}
