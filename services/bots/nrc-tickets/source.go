package main

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

const ticketType = p.AssetTypeTicket
const entryType = p.AssetTypeTicketEntry

type source interface {
	list(context.Context, uint16) ([]p.Asset, error)
	get(context.Context, uint64) (p.Asset, error)
	create(context.Context, p.Asset) (p.Asset, error)
}
type nrcSource struct{ server, workspace, secret string }

// Each connection has exactly one outstanding correlated request. Mutations are
// sent once only; losing an acknowledgement has an explicitly uncertain outcome.
func (s nrcSource) request(ctx context.Context, op uint16, body []byte, expected uint16) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	h := http.Header{"X-NRC-User-Type": {"bot"}, "X-NRC-Bot-Secret": {s.secret}, "X-NRC-Bot-Nickname": {"nrc-tickets"}}
	c, _, err := websocket.DefaultDialer.DialContext(ctx, s.server+"/"+url.PathEscape(s.workspace), h)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	deadline, _ := ctx.Deadline()
	c.SetReadDeadline(deadline)
	c.SetWriteDeadline(deadline)
	c.SetReadLimit(8 << 20)
	sent := false
	for {
		_, b, e := c.ReadMessage()
		if e != nil {
			return nil, e
		}
		m, e := p.ReadMessage(b)
		if e != nil {
			return nil, e
		}
		if m.Opcode == p.S_ServerReady && !sent {
			wire, e := (&p.Message{Opcode: op, Data: body}).Write()
			if e != nil {
				return nil, e
			}
			sent = true
			if e = c.WriteMessage(websocket.BinaryMessage, wire); e != nil {
				return nil, e
			}
		}
		if sent && m.Opcode == expected {
			return m.Data, nil
		}
		if m.Opcode == p.S_ErrorResponse {
			return nil, errors.New("NRC refused request")
		}
	}
}
func (s nrcSource) get(ctx context.Context, id uint64) (p.Asset, error) {
	b, e := s.request(ctx, p.C_GetAsset, p.EncodeGetAssetWithCorrelation(0, id, 1), p.S_AssetFull)
	if e != nil {
		return p.Asset{}, e
	}
	r, e := p.DecodeAssetFullResponse(b)
	if e != nil {
		return p.Asset{}, e
	}
	if r.CorrelationID != 1 || r.Asset.ConvID != 0 || r.Asset.AssetID != id {
		return p.Asset{}, errors.New("invalid asset response")
	}
	return r.Asset, nil
}
func (s nrcSource) list(ctx context.Context, typ uint16) ([]p.Asset, error) {
	var out []p.Asset
	var updated int64
	var id uint64
	cursor := false
	for pages := 0; pages < 1000; pages++ {
		b, e := s.request(ctx, p.C_ListAssetsPaged, p.EncodeListAssetsPagedWithCorrelation(0, typ, false, 50, cursor, updated, id, 1), p.S_AssetListPage)
		if e != nil {
			return nil, e
		}
		r, e := p.DecodeAssetListPage(b)
		if e != nil {
			return nil, e
		}
		if r.ConvID != 0 || r.CorrelationID != 1 {
			return nil, errors.New("invalid page")
		}
		for _, a := range r.Assets {
			if a.ConvID != 0 || a.AssetType != typ {
				return nil, errors.New("invalid page asset")
			}
			out = append(out, a)
		}
		if !r.HasMore {
			return out, nil
		}
		if cursor && updated == r.NextCursorUpdatedAt && id == r.NextCursorAssetID {
			return nil, errors.New("stalled cursor")
		}
		updated, id, cursor = r.NextCursorUpdatedAt, r.NextCursorAssetID, true
	}
	return nil, errors.New("workspace too large")
}
func (s nrcSource) create(ctx context.Context, a p.Asset) (p.Asset, error) {
	body, e := p.EncodeCreateAssetWithAttachmentsAndCorrelation(0, a.AssetType, a.ParentType, a.ParentID, a.Preview, a.Payload, a.Attachments, 1)
	if e != nil {
		return p.Asset{}, e
	}
	b, e := s.request(ctx, p.C_CreateAsset, body, p.S_AssetCreated)
	if e != nil {
		return p.Asset{}, e
	}
	r, e := p.DecodeAssetCreated(b)
	if e != nil {
		return p.Asset{}, e
	}
	v := r.Asset
	if r.CorrelationID != 1 || v.AssetID == 0 || v.ConvID != 0 || v.AssetType != a.AssetType || v.ParentType != a.ParentType || v.ParentID != a.ParentID || v.Preview != a.Preview || v.Payload != a.Payload || !slices.Equal(v.Attachments, a.Attachments) {
		return p.Asset{}, errors.New("invalid create acknowledgement")
	}
	return v, nil
}
