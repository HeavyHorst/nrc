package protocol

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strconv"
)

// EncodeTicketQuery encodes the JSON query after its correlation prefix.
func EncodeTicketQuery(id uint32, query json.RawMessage) ([]byte, error) {
	if len(query) < 2 || len(query)+4 > 65536 || !json.Valid(query) {
		return nil, fmt.Errorf("invalid ticket query JSON")
	}
	b := make([]byte, 4+len(query))
	binary.BigEndian.PutUint32(b, id)
	copy(b[4:], query)
	return b, nil
}

type TicketPage struct {
	CorrelationID uint32
	Metadata      json.RawMessage
	FullContent   bool
	Assets        []Asset
}

func DecodeTicketPage(data []byte) (*TicketPage, error) {
	if len(data) < 11 {
		return nil, fmt.Errorf("truncated ticket page")
	}
	n := uint64(binary.BigEndian.Uint32(data[4:]))
	if n > uint64(len(data)-11) {
		return nil, fmt.Errorf("invalid ticket metadata length")
	}
	o := 8 + int(n)
	if !json.Valid(data[8:o]) || data[o+2] > 1 {
		return nil, fmt.Errorf("invalid ticket page metadata or full flag")
	}
	// Reuse the strict ordinary asset-list decoder, including payload normalization.
	b := make([]byte, 15+len(data)-o-3)
	b[8] = data[o+2]
	copy(b[9:11], data[o:o+2])
	copy(b[11:15], data[:4])
	copy(b[15:], data[o+3:])
	a, err := DecodeAssetListResponse(b)
	if err != nil {
		return nil, err
	}
	return &TicketPage{a.CorrelationID, append(json.RawMessage(nil), data[8:o]...), a.FullContent, a.Assets}, nil
}

// TicketDueMembership asks the server to evaluate its clock over candidate IDs.
// Candidate order and caller pagination are deliberately left unchanged.
func TicketDueMembership(assets []Asset, query func(json.RawMessage) (*TicketPage, error)) (map[uint64]bool, error) {
	due := make(map[uint64]bool)
	for start := 0; start < len(assets); start += 100 {
		end := min(start+100, len(assets))
		ids := make([]string, 0, end-start)
		for _, a := range assets[start:end] {
			ids = append(ids, strconv.FormatUint(a.AssetID, 10))
		}
		q := struct {
			FollowUp      string          `json:"follow_up"`
			SearchResults bool            `json:"search_results"`
			IDs           []string        `json:"ids"`
			Limit         int             `json:"limit"`
			Cursor        json.RawMessage `json:"cursor,omitempty"`
		}{FollowUp: "due", SearchResults: true, IDs: ids, Limit: 100}
		for pages := 0; ; pages++ {
			if pages >= len(ids) {
				return nil, fmt.Errorf("ticket due pagination did not finish")
			}
			wire, _ := json.Marshal(q)
			page, err := query(wire)
			if err != nil {
				return nil, err
			}
			var meta struct {
				HasMore bool            `json:"has_more"`
				Cursor  json.RawMessage `json:"cursor"`
			}
			if err := json.Unmarshal(page.Metadata, &meta); err != nil {
				return nil, err
			}
			for _, a := range page.Assets {
				due[a.AssetID] = true
			}
			if !meta.HasMore {
				break
			}
			if len(page.Assets) == 0 || len(meta.Cursor) == 0 || string(meta.Cursor) == string(q.Cursor) {
				return nil, fmt.Errorf("ticket due pagination did not advance")
			}
			q.Cursor = meta.Cursor
		}
	}
	return due, nil
}
