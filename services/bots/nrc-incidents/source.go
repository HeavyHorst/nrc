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

type nrcSource struct{ server, workspace, nickname, secret string }

// One request per connection, sent once. Network errors after a write are not
// rejection; the next cycle reads NRC's committed sequence instead of replaying
// a newly measured result under an old sequence.
func (s nrcSource) request(ctx context.Context, wire []byte, expected uint16, correlation uint32) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
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

func (s nrcSource) snapshot(ctx context.Context, state p.MonitorState) (p.MonitorSnapshotPage, error) {
	var result p.MonitorSnapshotPage
	var cursor uint64
	bytes := 0
	identities := map[string]bool{}
	for {
		wire, err := p.EncodeGetMonitorSnapshot(state, cursor, result.At)
		if err != nil {
			return result, err
		}
		b, err := s.request(ctx, wire, p.S_MonitorState, state.CorrelationID)
		if err != nil {
			return result, err
		}
		page, err := p.DecodeMonitorSnapshotPage(b)
		if err != nil || page.MonitorState != state || result.At != 0 && (page.At != result.At || page.Horizon != result.Horizon) {
			return result, errors.New("inconsistent availability snapshot")
		}
		bytes += len(b)
		if bytes > 4<<20 {
			return result, errors.New("availability snapshot exceeds staging budget")
		}
		for _, row := range page.Instances {
			if row.ID <= cursor || identities[row.Identity] {
				return result, errors.New("repeated availability instance")
			}
			identities[row.Identity] = true
			cursor = row.ID
		}
		result.MonitorState, result.At, result.Horizon = state, page.At, page.Horizon
		result.Instances = append(result.Instances, page.Instances...)
		if page.Next == 0 {
			return result, nil
		}
	}
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
