package protocol

import (
	"encoding/binary"
	"fmt"
)

const (
	TransactionWireVersion            = 1
	MaxTransactionOperations          = 256
	TransactionOpTaskCreate    uint8  = 1
	TransactionOpTaskPatch     uint8  = 2
	TransactionOpAssetCreate   uint8  = 3
	TransactionOpAssetPatch    uint8  = 4
	TransactionOpEdgeCreate    uint8  = 5
	TransactionOpTaskDelete    uint8  = 6
	TransactionOpAssetDelete   uint8  = 7
	TransactionOpEdgeDelete    uint8  = 8
	TransactionEntityTask      uint8  = 1
	TransactionEntityAsset     uint8  = 2
	TransactionEntityEdge      uint8  = 3
	TransactionRefExisting     uint8  = 0
	TransactionRefCreatedBy    uint8  = 1
	TransactionStatusCommitted uint8  = 0
	TransactionStatusRejected  uint8  = 1
	TransactionFailedNone      uint16 = 0xffff
)
const (
	TransactionTaskPatchTitle uint16 = 1 << iota
	TransactionTaskPatchDescription
	TransactionTaskPatchStatus
	TransactionTaskPatchPriority
	TransactionTaskPatchColor
	TransactionTaskPatchDueAt
	TransactionTaskPatchBlockedBy
	TransactionTaskPatchAssignee
	TransactionTaskPatchExternalRef
	TransactionTaskPatchProject
)
const (
	TransactionAssetPatchPreview uint8 = 1 << iota
	TransactionAssetPatchPayload
)

type TransactionReference struct {
	Kind, EntityType uint8
	Value            uint64
}

func Existing(entityType uint8, id uint64) TransactionReference {
	return TransactionReference{TransactionRefExisting, entityType, id}
}
func CreatedBy(entityType uint8, operationIndex uint64) TransactionReference {
	return TransactionReference{TransactionRefCreatedBy, entityType, operationIndex}
}

type TransactionOperation struct {
	Type uint8
	Body []byte
}
type TransactionTaskCreate struct {
	ConvID                                   uint64
	Status, Priority, Color                  uint8
	DueAt                                    int64
	BlockedBy                                TransactionReference
	Title, Description, ExternalRef, Project string
}
type TransactionTaskPatch struct {
	ConvID                                             uint64
	Task                                               TransactionReference
	IfUpdatedAt                                        int64
	Present                                            uint16
	Status, Priority, Color                            uint8
	DueAt                                              int64
	BlockedBy                                          TransactionReference
	Title, Description, Assignee, ExternalRef, Project string
}
type TransactionAssetCreate struct {
	ConvID                uint64
	AssetType, ParentType uint16
	Parent                TransactionReference
	PayloadEncoding       uint8
	PayloadRawLen         uint32
	Preview, Payload      []byte
}
type TransactionAssetPatch struct {
	ConvID           uint64
	Asset            TransactionReference
	IfUpdatedAt      int64
	Present          uint8
	PayloadEncoding  uint8
	PayloadRawLen    uint32
	Preview, Payload []byte
}
type TransactionEdgeCreate struct {
	ConvID         uint64
	Source, Target TransactionReference
	Relation       uint16
}
type TransactionDelete struct {
	ConvID      uint64
	Entity      TransactionReference
	IfUpdatedAt int64 // Encoded for task/asset deletes; ignored and rejected for EdgeDelete.
}
type TransactionOperationResult struct {
	Type     uint8
	EntityID uint64
}
type TransactionResult struct {
	Status          uint8
	CorrelationID   uint32
	FailedOperation uint16
	Results         []TransactionOperationResult
}

func validRef(r TransactionReference, expected uint8) error {
	if r.Kind > 1 || r.EntityType < 1 || r.EntityType > 3 || (expected != 0 && r.EntityType != expected) {
		return fmt.Errorf("invalid transaction reference")
	}
	if r.Kind == TransactionRefCreatedBy && r.Value >= MaxTransactionOperations {
		return fmt.Errorf("created-by operation index exceeds maximum")
	}
	return nil
}
func appendRef(b []byte, r TransactionReference, expected uint8) ([]byte, error) {
	if err := validRef(r, expected); err != nil {
		return nil, err
	}
	p := make([]byte, 12)
	p[0] = r.Kind
	p[1] = r.EntityType
	binary.BigEndian.PutUint64(p[4:], r.Value)
	return append(b, p...), nil
}
func appendString(b []byte, s string, max int) ([]byte, error) {
	if len(s) > max {
		return nil, fmt.Errorf("field length %d exceeds maximum %d", len(s), max)
	}
	p := make([]byte, 2)
	binary.BigEndian.PutUint16(p, uint16(len(s)))
	b = append(b, p...)
	return append(b, s...), nil
}
func validTaskEnums(status, color uint8) error {
	if status > TaskStatusNote {
		return fmt.Errorf("invalid task status")
	}
	if color > TaskColorGold {
		return fmt.Errorf("invalid task color")
	}
	return nil
}

func EncodeTransactionTaskCreate(v TransactionTaskCreate) ([]byte, error) {
	if v.Title == "" {
		return nil, fmt.Errorf("title is required")
	}
	if err := validTaskEnums(v.Status, v.Color); err != nil {
		return nil, err
	}
	b := make([]byte, 20)
	binary.BigEndian.PutUint64(b, v.ConvID)
	b[8] = v.Status
	b[9] = v.Priority
	b[10] = v.Color
	binary.BigEndian.PutUint64(b[12:], uint64(v.DueAt))
	var err error
	b, err = appendRef(b, v.BlockedBy, TransactionEntityTask)
	if err != nil {
		return nil, err
	}
	for _, x := range []struct {
		s string
		m int
	}{{v.Title, MaxTaskTitleLength}, {v.Description, MaxTaskDescriptionLength}, {v.ExternalRef, MaxExternalRefLength}, {v.Project, MaxProjectLength}} {
		b, err = appendString(b, x.s, x.m)
		if err != nil {
			return nil, err
		}
	}
	return b, nil
}
func EncodeTransactionTaskPatch(v TransactionTaskPatch) ([]byte, error) {
	if v.Present == 0 || v.Present&^uint16(0x3ff) != 0 {
		return nil, fmt.Errorf("invalid task patch mask")
	}
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v.ConvID)
	var err error
	b, err = appendRef(b, v.Task, TransactionEntityTask)
	if err != nil {
		return nil, err
	}
	p8 := make([]byte, 8)
	binary.BigEndian.PutUint64(p8, uint64(v.IfUpdatedAt))
	b = append(b, p8...)
	p := make([]byte, 2)
	binary.BigEndian.PutUint16(p, v.Present)
	b = append(b, p...)
	add := func(bit uint16, s string, m int) bool {
		if v.Present&bit == 0 {
			return true
		}
		b, err = appendString(b, s, m)
		return err == nil
	}
	if !add(TransactionTaskPatchTitle, v.Title, MaxTaskTitleLength) || !add(TransactionTaskPatchDescription, v.Description, MaxTaskDescriptionLength) {
		return nil, err
	}
	if v.Present&TransactionTaskPatchStatus != 0 {
		if v.Status > TaskStatusNote {
			return nil, fmt.Errorf("invalid task status")
		}
		b = append(b, v.Status)
	}
	if v.Present&TransactionTaskPatchPriority != 0 {
		b = append(b, v.Priority)
	}
	if v.Present&TransactionTaskPatchColor != 0 {
		if v.Color > TaskColorGold {
			return nil, fmt.Errorf("invalid task color")
		}
		b = append(b, v.Color)
	}
	if v.Present&TransactionTaskPatchDueAt != 0 {
		p := make([]byte, 8)
		binary.BigEndian.PutUint64(p, uint64(v.DueAt))
		b = append(b, p...)
	}
	if v.Present&TransactionTaskPatchBlockedBy != 0 {
		b, err = appendRef(b, v.BlockedBy, TransactionEntityTask)
		if err != nil {
			return nil, err
		}
	}
	for _, x := range []struct {
		bit uint16
		s   string
		m   int
	}{{TransactionTaskPatchAssignee, v.Assignee, MaxAssigneeLength}, {TransactionTaskPatchExternalRef, v.ExternalRef, MaxExternalRefLength}, {TransactionTaskPatchProject, v.Project, MaxProjectLength}} {
		if !add(x.bit, x.s, x.m) {
			return nil, err
		}
	}
	return b, nil
}
func EncodeTransactionAssetCreate(v TransactionAssetCreate) ([]byte, error) {
	// The bound tracks the enum, not a hand-picked maximum, so a new asset type
	// cannot be transaction-creatable on the server but unencodable here.
	if v.AssetType < AssetTypeComment || v.AssetType > AssetTypeAppointment || v.AssetType == AssetTypeAgenda || v.AssetType == AssetTypeRoomMapping {
		return nil, fmt.Errorf("asset type is not transaction-creatable")
	}
	if v.ParentType > ParentTypeAsset {
		return nil, fmt.Errorf("invalid parent type")
	}
	if v.PayloadEncoding > 1 {
		return nil, fmt.Errorf("invalid payload encoding")
	}
	if v.PayloadEncoding == 0 && v.PayloadRawLen != uint32(len(v.Payload)) {
		return nil, fmt.Errorf("plain payload_raw_len mismatch")
	}
	b := make([]byte, 12)
	binary.BigEndian.PutUint64(b, v.ConvID)
	binary.BigEndian.PutUint16(b[8:], v.AssetType)
	binary.BigEndian.PutUint16(b[10:], v.ParentType)
	var err error
	if v.ParentType != 0 {
		e := TransactionEntityTask
		if v.ParentType == ParentTypeAsset {
			e = TransactionEntityAsset
		}
		b, err = appendRef(b, v.Parent, e)
		if err != nil {
			return nil, err
		}
	}
	b = append(b, v.PayloadEncoding)
	p := make([]byte, 4)
	binary.BigEndian.PutUint32(p, v.PayloadRawLen)
	b = append(b, p...)
	b, err = appendString(b, string(v.Preview), MaxPreviewLength)
	if err != nil {
		return nil, err
	}
	return appendString(b, string(v.Payload), MaxPayloadLength)
}
func EncodeTransactionAssetPatch(v TransactionAssetPatch) ([]byte, error) {
	if v.Present == 0 || v.Present&^uint8(3) != 0 {
		return nil, fmt.Errorf("invalid asset patch mask")
	}
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v.ConvID)
	var err error
	b, err = appendRef(b, v.Asset, TransactionEntityAsset)
	if err != nil {
		return nil, err
	}
	p8 := make([]byte, 8)
	binary.BigEndian.PutUint64(p8, uint64(v.IfUpdatedAt))
	b = append(b, p8...)
	b = append(b, v.Present)
	if v.Present&1 != 0 {
		b, err = appendString(b, string(v.Preview), MaxPreviewLength)
		if err != nil {
			return nil, err
		}
	}
	if v.Present&2 != 0 {
		if v.PayloadEncoding > 1 {
			return nil, fmt.Errorf("invalid payload encoding")
		}
		if v.PayloadEncoding == 0 && v.PayloadRawLen != uint32(len(v.Payload)) {
			return nil, fmt.Errorf("plain payload_raw_len mismatch")
		}
		b = append(b, v.PayloadEncoding)
		p := make([]byte, 4)
		binary.BigEndian.PutUint32(p, v.PayloadRawLen)
		b = append(b, p...)
		b, err = appendString(b, string(v.Payload), MaxPayloadLength)
	}
	return b, err
}
func EncodeTransactionEdgeCreate(v TransactionEdgeCreate) ([]byte, error) {
	if v.Relation < RelationReferences || v.Relation > RelationMemberOf {
		return nil, fmt.Errorf("invalid relation")
	}
	if (v.Source.EntityType != TransactionEntityTask && v.Source.EntityType != TransactionEntityAsset) ||
		(v.Target.EntityType != TransactionEntityTask && v.Target.EntityType != TransactionEntityAsset) {
		return nil, fmt.Errorf("edge endpoints must be tasks or assets")
	}
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v.ConvID)
	var err error
	b, err = appendRef(b, v.Source, 0)
	if err != nil {
		return nil, err
	}
	b, err = appendRef(b, v.Target, 0)
	if err != nil {
		return nil, err
	}
	p := make([]byte, 2)
	binary.BigEndian.PutUint16(p, v.Relation)
	return append(b, p...), nil
}
func EncodeTransactionDelete(v TransactionDelete, entityType uint8) ([]byte, error) {
	if v.Entity.Kind != TransactionRefExisting {
		return nil, fmt.Errorf("transaction deletes require an existing ID")
	}
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v.ConvID)
	b, err := appendRef(b, v.Entity, entityType)
	if err != nil {
		return nil, err
	}
	// Edge entities have no updated_at; preserve the original exact EdgeDelete schema.
	if entityType == TransactionEntityEdge {
		if v.IfUpdatedAt != 0 {
			return nil, fmt.Errorf("edge deletes do not support if_updated_at")
		}
		return b, nil
	}
	p := make([]byte, 8)
	binary.BigEndian.PutUint64(p, uint64(v.IfUpdatedAt))
	return append(b, p...), nil
}
func EncodeApplyTransaction(correlationID uint32, ops []TransactionOperation) ([]byte, error) {
	if len(ops) == 0 || len(ops) > MaxTransactionOperations {
		return nil, fmt.Errorf("operation count must be between 1 and %d", MaxTransactionOperations)
	}
	b := make([]byte, 8)
	b[0] = 1
	binary.BigEndian.PutUint16(b[2:], uint16(len(ops)))
	binary.BigEndian.PutUint32(b[4:], correlationID)
	for _, o := range ops {
		if o.Type < 1 || o.Type > 8 {
			return nil, fmt.Errorf("invalid operation type")
		}
		p := make([]byte, 6)
		p[0] = o.Type
		binary.BigEndian.PutUint32(p[2:], uint32(len(o.Body)))
		b = append(b, p...)
		b = append(b, o.Body...)
	}
	return b, nil
}
func DecodeTransactionResult(data []byte) (*TransactionResult, error) {
	if len(data) < 10 {
		return nil, fmt.Errorf("transaction result too short")
	}
	if data[0] != 1 || data[1] > 1 {
		return nil, fmt.Errorf("invalid transaction result header")
	}
	r := &TransactionResult{Status: data[1], CorrelationID: binary.BigEndian.Uint32(data[2:]), FailedOperation: binary.BigEndian.Uint16(data[6:])}
	n := int(binary.BigEndian.Uint16(data[8:]))
	if n > MaxTransactionOperations || len(data) != 10+n*10 {
		return nil, fmt.Errorf("invalid transaction result length")
	}
	r.Results = make([]TransactionOperationResult, n)
	for i := range r.Results {
		o := 10 + i*10
		if data[o] < 1 || data[o] > 8 || data[o+1] != 0 {
			return nil, fmt.Errorf("invalid transaction result entry")
		}
		r.Results[i] = TransactionOperationResult{data[o], binary.BigEndian.Uint64(data[o+2:])}
	}
	if r.Status == TransactionStatusCommitted && (r.FailedOperation != TransactionFailedNone || n == 0) {
		return nil, fmt.Errorf("invalid committed transaction result")
	}
	if r.Status == TransactionStatusRejected && n != 0 {
		return nil, fmt.Errorf("invalid rejected transaction result")
	}
	return r, nil
}
