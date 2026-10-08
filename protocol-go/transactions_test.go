package protocol

import (
	"encoding/hex"
	"strings"
	"testing"
)

func TestTransactionTaskDescriptionByteLimit(t *testing.T) {
	for _, size := range []int{2049, 4096, 4097} {
		// Non-ASCII text distinguishes UTF-8 bytes from character count.
		description := strings.Repeat("ä", size/2) + strings.Repeat("x", size%2)
		_, createErr := EncodeTransactionTaskCreate(TransactionTaskCreate{
			Title: "Images", Description: description,
			BlockedBy: Existing(TransactionEntityTask, 0),
		})
		body, patchErr := EncodeTransactionTaskPatch(TransactionTaskPatch{
			Task:    Existing(TransactionEntityTask, 469),
			Present: TransactionTaskPatchDescription, Description: description,
		})
		if size <= 4096 {
			if createErr != nil || patchErr != nil {
				t.Fatalf("%d bytes rejected: create=%v patch=%v", size, createErr, patchErr)
			}
			if string(body[32:]) != description {
				t.Fatalf("%d-byte patch description changed", size)
			}
		} else if createErr == nil || patchErr == nil {
			t.Fatalf("%d bytes accepted: create=%v patch=%v", size, createErr, patchErr)
		}
	}
}

func TestEncodeApplyTransactionByteExact(t *testing.T) {
	body, err := EncodeTransactionDelete(TransactionDelete{ConvID: 2, Entity: Existing(TransactionEntityTask, 9)}, TransactionEntityTask)
	if err != nil {
		t.Fatal(err)
	}
	got, err := EncodeApplyTransaction(7, []TransactionOperation{{Type: TransactionOpTaskDelete, Body: body}})
	if err != nil {
		t.Fatal(err)
	}
	want := "010000010000000706000000001c00000000000000020001000000000000000000090000000000000000"
	if hex.EncodeToString(got) != want {
		t.Fatalf("got %x\nwant %s", got, want)
	}
}

func TestTransactionOptimisticConcurrencyEncoding(t *testing.T) {
	patch, err := EncodeTransactionTaskPatch(TransactionTaskPatch{ConvID: 2, Task: Existing(TransactionEntityTask, 9), IfUpdatedAt: 123, Present: TransactionTaskPatchTitle, Title: "x"})
	if err != nil {
		t.Fatal(err)
	}
	if len(patch) != 33 || hex.EncodeToString(patch[20:28]) != "000000000000007b" || hex.EncodeToString(patch[28:]) != "0001000178" {
		t.Fatalf("task patch schema = %x", patch)
	}
	del, err := EncodeTransactionDelete(TransactionDelete{ConvID: 2, Entity: Existing(TransactionEntityAsset, 9), IfUpdatedAt: 123}, TransactionEntityAsset)
	if err != nil || len(del) != 28 || hex.EncodeToString(del[20:]) != "000000000000007b" {
		t.Fatalf("asset delete schema = %x, err = %v", del, err)
	}
	if _, err = EncodeTransactionDelete(TransactionDelete{Entity: Existing(TransactionEntityEdge, 9), IfUpdatedAt: 123}, TransactionEntityEdge); err == nil {
		t.Fatal("edge delete accepted if_updated_at")
	}
}

func TestTransactionCreatedByAndResultDecode(t *testing.T) {
	body, err := EncodeTransactionEdgeCreate(TransactionEdgeCreate{ConvID: 3, Source: CreatedBy(TransactionEntityTask, 5), Target: Existing(TransactionEntityAsset, 8), Relation: RelationReferences})
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(body[8:20]); got != "010100000000000000000005" {
		t.Fatalf("created-by ref = %s", got)
	}
	r, err := DecodeTransactionResult([]byte{1, 0, 0, 0, 0, 7, 0xff, 0xff, 0, 1, TransactionOpTaskCreate, 0, 0, 0, 0, 0, 0, 0, 0, 42})
	if err != nil {
		t.Fatal(err)
	}
	if r.CorrelationID != 7 || r.Results[0].EntityID != 42 {
		t.Fatalf("decoded %#v", r)
	}
}

func TestTransactionStrictBounds(t *testing.T) {
	_, err := EncodeTransactionTaskCreate(TransactionTaskCreate{BlockedBy: Existing(TransactionEntityTask, 0), Title: string(make([]byte, MaxTaskTitleLength+1))})
	if err == nil {
		t.Fatal("oversized title accepted")
	}
	if _, err = DecodeTransactionResult([]byte{1, 0, 0, 0, 0, 1, 0xff, 0xff, 0, 0}); err == nil {
		t.Fatal("committed result without entries accepted")
	}
}

func TestTransactionAssetCreateCustomerTypeBounds(t *testing.T) {
	for _, assetType := range []uint16{
		AssetTypeCustomerCompany,
		AssetTypeCustomerContact,
		AssetTypeCustomerActivity,
		AssetTypeSlice,
		AssetTypeAppointment,
	} {
		_, err := EncodeTransactionAssetCreate(TransactionAssetCreate{
			AssetType:     assetType,
			ParentType:    ParentTypeNone,
			PayloadRawLen: 0,
		})
		if err != nil {
			t.Errorf("customer asset type %d rejected: %v", assetType, err)
		}
	}

	for _, assetType := range []uint16{0, AssetTypeAgenda, AssetTypeRoomMapping, AssetTypeAppointment + 1} {
		_, err := EncodeTransactionAssetCreate(TransactionAssetCreate{
			AssetType:     assetType,
			ParentType:    ParentTypeNone,
			PayloadRawLen: 0,
		})
		if err == nil {
			t.Errorf("non-transaction-creatable asset type %d accepted", assetType)
		}
	}
}

func TestTransactionEdgeRelationBounds(t *testing.T) {
	for _, relation := range []uint16{RelationReferences, RelationMemberOf} {
		if _, err := EncodeTransactionEdgeCreate(TransactionEdgeCreate{
			Source:   Existing(TransactionEntityAsset, 1),
			Target:   Existing(TransactionEntityAsset, 2),
			Relation: relation,
		}); err != nil {
			t.Errorf("relation %d rejected: %v", relation, err)
		}
	}

	for _, relation := range []uint16{RelationReferences - 1, RelationMemberOf + 1} {
		if _, err := EncodeTransactionEdgeCreate(TransactionEdgeCreate{
			Source:   Existing(TransactionEntityAsset, 1),
			Target:   Existing(TransactionEntityAsset, 2),
			Relation: relation,
		}); err == nil {
			t.Errorf("out-of-range relation %d accepted", relation)
		}
	}
}
