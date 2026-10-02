package protocol

import (
	"encoding/binary"
	"testing"
)

func TestDurableEncodersAcceptWorkspaceScope(t *testing.T) {
	transaction, err := EncodeTransactionDelete(TransactionDelete{ConvID: WorkspaceDataConvID, Entity: Existing(TransactionEntityTask, 19)}, TransactionEntityTask)
	if err != nil {
		t.Fatal(err)
	}
	page, err := EncodeListTasksPaged(WorkspaceDataConvID, 15, 23, nil, 91)
	if err != nil {
		t.Fatal(err)
	}
	for name, payload := range map[string][]byte{
		"task create":      EncodeTaskCreate(WorkspaceDataConvID, "task", "body", 3),
		"task page":        page,
		"asset create":     EncodeCreateAsset(WorkspaceDataConvID, AssetTypeRoomMapping, ParentTypeNone, 0, "room", `{"conv_id":"73"}`),
		"edge create":      EncodeCreateEdge(WorkspaceDataConvID, TargetTypeTask, 19, TargetTypeAsset, 29, RelationReferences),
		"graph query":      EncodeGraphQuery(WorkspaceDataConvID, TargetTypeTask, 19, 2, 0, 0, 0),
		"transaction body": transaction,
	} {
		if len(payload) < 8 || binary.BigEndian.Uint64(payload) != 0 {
			t.Errorf("%s scope = %x, want zero", name, payload)
		}
	}
	for _, scope := range []uint64{7, 1<<63 | 9} {
		if _, err := EncodeGraphRankWithCorrelation(scope, []GraphRankEntity{{Type: TargetTypeTask, ID: 19}}, nil, 2, 0, 0, 5, 91); err == nil {
			t.Errorf("graph rank accepted legacy scope %d", scope)
		}
	}
}
