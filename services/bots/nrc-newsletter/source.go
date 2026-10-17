package main

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

type contact struct {
	ID    string `json:"contact_id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}
type source interface {
	contacts(context.Context) ([]contact, error)
}
type nrcSource struct{ server, workspace, secret string }

func (s nrcSource) page(ctx context.Context, updated int64, id uint64, cursor bool) (*p.AssetListPageResponse, error) {
	return s.assetPage(ctx, p.AssetTypeCustomerContact, updated, id, cursor)
}

func (s nrcSource) assetPage(ctx context.Context, kind uint16, updated int64, id uint64, cursor bool) (*p.AssetListPageResponse, error) {
	m, err := s.exchange(ctx, p.C_ListAssetsPaged, p.EncodeListAssetsPagedWithCorrelation(0, kind, true, 50, cursor, updated, id, 1), p.S_AssetListPage)
	if err != nil {
		return nil, err
	}
	r, err := p.DecodeAssetListPage(m.Data)
	if err != nil {
		return nil, err
	}
	if r.ConvID != 0 || r.CorrelationID != 1 || !r.FullContent {
		return nil, errors.New("invalid asset page")
	}
	return r, nil
}

func (s nrcSource) exchange(ctx context.Context, opcode uint16, data []byte, response uint16) (*p.Message, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	h := http.Header{}
	h.Set("X-NRC-User-Type", "bot")
	h.Set("X-NRC-Bot-Secret", s.secret)
	h.Set("X-NRC-Bot-Nickname", "nrc-newsletter")
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
			b, e := (&p.Message{Opcode: opcode, Data: data}).Write()
			if e != nil {
				return nil, e
			}
			if e = c.WriteMessage(websocket.BinaryMessage, b); e != nil {
				return nil, e
			}
			sent = true
		}
		if sent && m.Opcode == response {
			return m, nil
		}
		if m.Opcode == p.S_ErrorResponse {
			return nil, errors.New("NRC contact read refused")
		}
	}
}
func (s nrcSource) contacts(ctx context.Context) ([]contact, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out := []contact{}
	seen := map[uint64]bool{}
	var updated int64
	var id uint64
	cursor := false
	for pages := 0; pages < 10000; pages++ {
		r, e := s.page(ctx, updated, id, cursor)
		if e != nil {
			return nil, e
		}
		for _, a := range r.Assets {
			if a.ConvID != 0 || a.AssetType != p.AssetTypeCustomerContact || seen[a.AssetID] {
				return nil, errors.New("inconsistent contact register; retry")
			}
			seen[a.AssetID] = true
			var v struct {
				Title, Email string
				Version      int
				Archived     bool
			}
			if json.Unmarshal([]byte(a.Preview), &v) != nil || v.Version != 1 || v.Title == "" {
				return nil, errors.New("invalid contact metadata")
			}
			if v.Archived {
				continue
			}
			out = append(out, contact{strconv.FormatUint(a.AssetID, 10), v.Title, normalize(v.Email)})
		}
		if !r.HasMore {
			return out, nil
		}
		if cursor && updated == r.NextCursorUpdatedAt && id == r.NextCursorAssetID {
			return nil, errors.New("stalled contact cursor")
		}
		updated, id, cursor = r.NextCursorUpdatedAt, r.NextCursorAssetID, true
	}
	return nil, errors.New("contact register exceeds limit")
}
