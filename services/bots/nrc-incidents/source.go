package main

import (
	"context"
	"encoding/binary"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

var errRejected = errors.New("NRC rejected the request")

type nrcSource struct {
	server, workspace, nickname, secret string
	requests                            chan struct{}
}

func newNRCSource(server, workspace, nickname, secret string) nrcSource {
	// Checks, history, webhooks and discovery share admission, including copies
	// of this source. Seven slots leave room in NRC's 10 MiB writer budget for
	// maximum-size command bodies and two overlapping maintenance reservations.
	return nrcSource{server, workspace, nickname, secret, make(chan struct{}, 7)}
}

// One request per connection, sent once. Network errors after a write are not
// rejection; the next cycle reads NRC's committed sequence instead of replaying
// a newly measured result under an old sequence.
func (s nrcSource) request(ctx context.Context, wire []byte, expected uint16, correlation uint32) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case s.requests <- struct{}{}:
	}
	defer func() { <-s.requests }()
	h := http.Header{"X-NRC-User-Type": {"bot"}, "X-NRC-Bot-Secret": {s.secret}, "X-NRC-Bot-Nickname": {s.nickname}}
	u := strings.TrimRight(s.server, "/") + "/" + url.PathEscape(s.workspace)
	c, response, err := websocket.DefaultDialer.DialContext(ctx, u, h)
	if err != nil {
		if response != nil && response.Body != nil {
			response.Body.Close()
		}
		return nil, errors.New("NRC connection failed")
	}
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	deadline, _ := ctx.Deadline()
	c.SetReadDeadline(deadline)
	c.SetWriteDeadline(deadline)
	c.SetReadLimit(1 << 20)
	sent := false
	for {
		kind, b, err := c.ReadMessage()
		if err != nil {
			return nil, errors.New("NRC response unavailable")
		}
		if kind != websocket.BinaryMessage {
			return nil, errors.New("invalid NRC frame")
		}
		m, err := p.ReadMessage(b)
		if err != nil {
			return nil, errors.New("invalid NRC message")
		}
		if m.Opcode == p.S_ServerReady && !sent {
			sent = true
			if err := c.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				return nil, errors.New("NRC write outcome unknown")
			}
			continue
		}
		if sent && m.Opcode == expected {
			return m.Data, nil
		}
		if m.Opcode == p.S_ErrorResponse {
			failure, decodeErr := p.DecodeErrorResponse(m.Data)
			if sent && decodeErr == nil && failure.OriginOpcode == binary.BigEndian.Uint16(wire) && failure.CorrelationID == correlation {
				return nil, errRejected
			}
			return nil, errors.New("unmatched NRC error response")
		}
	}
}

func (s nrcSource) monitor(ctx context.Context, id uint64) (p.Asset, p.MonitorState, error) {
	wire, err := p.EncodeGetMonitorState(id, 1)
	if err != nil {
		return p.Asset{}, p.MonitorState{}, err
	}
	b, err := s.request(ctx, wire, p.S_MonitorState, 1)
	if err != nil {
		return p.Asset{}, p.MonitorState{}, err
	}
	state, err := p.DecodeMonitorState(b)
	if err != nil || state.CorrelationID != 1 || state.MonitorID != id {
		return p.Asset{}, state, errors.New("invalid monitor state response")
	}
	asset, err := s.asset(ctx, id)
	if err != nil || asset.UpdatedAt != state.Revision {
		return p.Asset{}, state, errors.New("monitor changed during read")
	}
	return asset, state, nil
}

func (s nrcSource) asset(ctx context.Context, id uint64) (p.Asset, error) {
	wire, err := (&p.Message{Opcode: p.C_GetAsset, Data: p.EncodeGetAssetWithCorrelation(0, id, 1)}).Write()
	if err != nil {
		return p.Asset{}, err
	}
	b, err := s.request(ctx, wire, p.S_AssetFull, 1)
	if err != nil {
		return p.Asset{}, err
	}
	asset, err := p.DecodeAssetFullResponse(b)
	if err != nil || asset.CorrelationID != 1 || asset.Asset.AssetID != id || asset.Asset.ConvID != 0 {
		return p.Asset{}, errors.New("invalid asset response")
	}
	return asset.Asset, nil
}

func (s nrcSource) pendingSnapshot(ctx context.Context, id uint64) (p.MonitorSnapshotPage, bool, error) {
	var result p.MonitorSnapshotPage
	var cursor uint64
	bytes := 0
	identities := map[string]bool{}
	for {
		wire, err := p.EncodeMonitorHistory(id, result.SnapshotID, cursor, result.At, false)
		if err != nil {
			return result, false, err
		}
		body, err := s.request(ctx, wire, p.S_MonitorState, 1)
		if err != nil {
			return result, false, err
		}
		if cursor == 0 && len(body) == 28 {
			state, err := p.DecodeMonitorState(body)
			if err != nil || state.CorrelationID != 1 || state.MonitorID != id || state.Sequence != 0 {
				return result, false, errors.New("invalid empty history response")
			}
			return result, false, nil
		}
		page, err := p.DecodeMonitorHistoryPage(body)
		if err != nil || page.CorrelationID != 1 || page.MonitorID != id || result.At != 0 && (page.MonitorState != result.MonitorState || page.SnapshotID != result.SnapshotID || page.At != result.At || page.Horizon != result.Horizon || page.PauseObservation != result.PauseObservation) {
			return result, false, errors.New("inconsistent stored availability snapshot")
		}
		bytes += len(body)
		if bytes > 4<<20 {
			return result, false, errors.New("availability snapshot exceeds staging budget")
		}
		for _, row := range page.Instances {
			if row.ID <= cursor || identities[row.Identity] {
				return result, false, errors.New("repeated availability instance")
			}
			identities[row.Identity] = true
			cursor = row.ID
		}
		result.MonitorState, result.At, result.Horizon = page.MonitorState, page.At, page.Horizon
		result.PauseObservation = page.PauseObservation
		result.SnapshotID = page.SnapshotID
		result.Instances = append(result.Instances, page.Instances...)
		if page.Next == 0 {
			return result, true, nil
		}
	}
}

func (s nrcSource) acknowledgeSnapshot(ctx context.Context, page p.MonitorSnapshotPage) error {
	wire, err := p.EncodeMonitorHistory(page.MonitorID, page.SnapshotID, 0, page.At, true)
	if err != nil {
		return err
	}
	body, err := s.request(ctx, wire, p.S_MonitorState, 1)
	if err != nil {
		return err
	}
	state, err := p.DecodeMonitorState(body)
	if err != nil || state.CorrelationID != 1 || state.MonitorID != page.MonitorID || state.Sequence != page.SnapshotID {
		return errors.New("invalid history acknowledgment")
	}
	return nil
}

func (s nrcSource) apply(ctx context.Context, run p.ApplyMonitorRun) (string, error) {
	wire, err := p.EncodeApplyMonitorRun(run)
	if err != nil {
		return "rejected", err
	}
	b, err := s.request(ctx, wire, p.S_MonitorRunApplied, run.CorrelationID)
	if errors.Is(err, errRejected) {
		return "rejected", err
	}
	if err != nil {
		return "unknown", err
	}
	ack, err := p.DecodeMonitorRunApplied(b)
	if err != nil || ack.CorrelationID != run.CorrelationID || ack.MonitorID != run.MonitorID || ack.Sequence != run.Sequence {
		return "unknown", errors.New("invalid run acknowledgement")
	}
	// Each call submits a fresh measurement, never a retry of the previous
	// attempt. A replay therefore confirms an older measurement, not this one.
	if ack.Replayed {
		return "rejected", errors.New("run sequence collision: older measurement replayed")
	}
	return "confirmed", nil
}
