package protocol

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
)

// MonitorID zero lists monitors; a nonzero ID lists that monitor's instances.
// CursorID/Rank and At come from the previous page. This is live pagination.
type MonitorStatusQuery struct {
	CorrelationID       uint32
	MonitorID, CursorID uint64
	CursorRank          uint8
	At                  int64
	Limit               uint8
	IncludeRetired      bool
}

func EncodeQueryMonitorStatus(q MonitorStatusQuery) ([]byte, error) {
	if q.Limit == 0 || q.Limit > 16 || q.CursorRank > 8 || q.At < 0 || q.CursorID == 0 && q.CursorRank != 0 || q.CursorID != 0 && q.At == 0 || q.MonitorID == 0 && q.IncludeRetired {
		return nil, fmt.Errorf("invalid monitor status query")
	}
	b := make([]byte, 33)
	binary.BigEndian.PutUint16(b, C_QueryMonitorStatus)
	binary.BigEndian.PutUint32(b[2:], q.CorrelationID)
	binary.BigEndian.PutUint64(b[6:], q.MonitorID)
	binary.BigEndian.PutUint64(b[14:], q.CursorID)
	b[22] = q.CursorRank
	binary.BigEndian.PutUint64(b[23:], uint64(q.At))
	b[31] = q.Limit
	if q.IncludeRetired {
		b[32] = 1
	}
	return b, nil
}

type MonitorStatusRow struct {
	ID             string    `json:"id"`
	MonitorID      string    `json:"monitor_id"`
	Name           string    `json:"name"`
	Identity       string    `json:"identity"`
	Status         string    `json:"status"`
	Revision       string    `json:"revision"`
	Sequence       string    `json:"sequence"`
	EvaluatedAt    string    `json:"evaluated_at"`
	SeenAt         string    `json:"seen_at"`
	Value          *float64  `json:"value"`
	Paused         bool      `json:"paused"`
	Retired        bool      `json:"retired"`
	IncidentOpen   bool      `json:"incident_open"`
	Observation    uint8     `json:"observation"`
	Freshness      uint8     `json:"freshness"`
	Failures       uint32    `json:"failures"`
	Recoveries     uint32    `json:"recoveries"`
	Missing        uint32    `json:"missing"`
	IncidentID     string    `json:"incident_id"`
	AcknowledgedBy string    `json:"acknowledged_by"`
	AcknowledgedAt string    `json:"acknowledged_at"`
	AssignedTo     string    `json:"assigned_to"`
	Counts         [9]uint64 `json:"counts"`
}

type MonitorStatusPage struct {
	CorrelationID uint32             `json:"-"`
	Version       int                `json:"version"`
	MonitorID     string             `json:"monitor_id"`
	At            string             `json:"at"`
	CursorID      string             `json:"cursor_id"`
	CursorRank    uint8              `json:"cursor_rank"`
	HasMore       bool               `json:"has_more"`
	Rows          []MonitorStatusRow `json:"rows"`
}

func DecodeMonitorStatusPage(body []byte) (MonitorStatusPage, error) {
	var page MonitorStatusPage
	if len(body) < 6 || len(body) > 128*1024 {
		return page, fmt.Errorf("invalid monitor status page length")
	}
	if err := json.Unmarshal(body[4:], &page); err != nil {
		return page, err
	}
	page.CorrelationID = binary.BigEndian.Uint32(body)
	if page.Version != 1 || page.CursorRank > 8 || len(page.Rows) > 16 || page.HasMore && len(page.Rows) == 0 {
		return MonitorStatusPage{}, fmt.Errorf("invalid monitor status page")
	}
	return page, nil
}
