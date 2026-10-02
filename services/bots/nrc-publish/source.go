package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// Fetch on demand, rather than retaining a copy of every private workspace note.
type noteSource interface {
	get(context.Context, uint64) (protocol.Asset, error)
	list(context.Context, int64, uint64, bool) (*protocol.AssetListPageResponse, error)
}

type nrcSource struct{ server, workspace, secret string }

func (s nrcSource) request(ctx context.Context, opcode uint16, payload []byte, response uint16) ([]byte, error) {
	headers := http.Header{}
	if s.secret != "" {
		headers.Set("X-NRC-User-Type", "bot")
		headers.Set("X-NRC-Bot-Secret", s.secret)
		headers.Set("X-NRC-Bot-Nickname", "nrc-publish")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	conn, _, err := websocket.DefaultDialer.DialContext(ctx, s.server+"/"+url.PathEscape(s.workspace), headers)
	if err != nil {
		return nil, fmt.Errorf("NRC connection: %w", err)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	conn.SetReadLimit(8 << 20)
	deadline, _ := ctx.Deadline()
	conn.SetReadDeadline(deadline)
	conn.SetWriteDeadline(deadline)
	sent := false
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return nil, fmt.Errorf("NRC response: %w", err)
		}
		msg, err := protocol.ReadMessage(data)
		if err != nil {
			return nil, err
		}
		if msg.Opcode == protocol.S_ServerReady && !sent {
			wire, err := (&protocol.Message{Opcode: opcode, Data: payload}).Write()
			if err != nil {
				return nil, err
			}
			if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				return nil, err
			}
			sent = true
		}
		if sent && msg.Opcode == response {
			return msg.Data, nil
		}
		if msg.Opcode == protocol.S_ErrorResponse {
			return nil, errors.New("NRC refused this read (check note ID and workspace access)")
		}
	}
}

func (s nrcSource) get(ctx context.Context, id uint64) (protocol.Asset, error) {
	data, err := s.request(ctx, protocol.C_GetAsset, protocol.EncodeGetAssetWithCorrelation(0, id, 1), protocol.S_AssetFull)
	if err != nil {
		return protocol.Asset{}, err
	}
	resp, err := protocol.DecodeAssetFullResponse(data)
	if err != nil {
		return protocol.Asset{}, err
	}
	if resp.CorrelationID != 1 || resp.Asset.AssetID != id || resp.Asset.ConvID != 0 || resp.Asset.AssetType != protocol.AssetTypeNote {
		return protocol.Asset{}, errors.New("response is not the requested workspace note")
	}
	return resp.Asset, nil
}

func (s nrcSource) list(ctx context.Context, updated int64, id uint64, cursor bool) (*protocol.AssetListPageResponse, error) {
	data, err := s.request(ctx, protocol.C_ListAssetsPaged, protocol.EncodeListAssetsPagedWithCorrelation(0, protocol.AssetTypeNote, false, 50, cursor, updated, id, 1), protocol.S_AssetListPage)
	if err != nil {
		return nil, err
	}
	resp, err := protocol.DecodeAssetListPage(data)
	if err == nil && (resp.ConvID != 0 || resp.CorrelationID != 1) {
		return nil, errors.New("invalid NRC note page")
	}
	return resp, err
}
