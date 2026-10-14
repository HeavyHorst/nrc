package protocol

import (
	"encoding/binary"
	"fmt"
)

const MaxIDBatchSize = 64

// EncodeGetRecordsByIDs encodes the shared body for C_GetTasksByIDs and
// C_GetAssetsByIDs. Tasks always return full records. Assets honor fullContent.
// Read S_TaskListPage/S_AssetListPage until HasMore is false, using the same
// correlation ID. Cursor fields are unused. Missing or invisible IDs are omitted.
func EncodeGetRecordsByIDs(ids []uint64, fullContent bool, correlationID uint32) ([]byte, error) {
	if len(ids) > MaxIDBatchSize {
		return nil, fmt.Errorf("ID batch exceeds %d records", MaxIDBatchSize)
	}
	body := make([]byte, 15+8*len(ids))
	binary.BigEndian.PutUint32(body[8:], correlationID)
	if fullContent {
		body[12] = 1
	}
	binary.BigEndian.PutUint16(body[13:], uint16(len(ids)))
	for i, id := range ids {
		binary.BigEndian.PutUint64(body[15+8*i:], id)
	}
	return body, nil
}
