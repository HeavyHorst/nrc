package main

import (
	"encoding/binary"
	"hash/fnv"
	"testing"

	"github.com/heavyhorst/nrc/protocol-go"
)

// buildFullAsset encodes a protocol.Asset into the full binary wire format.
func buildFullAsset(a protocol.Asset) []byte {
	attachments := protocol.EncodeAttachments(a.Attachments)
	// asset_type(2) + asset_id(8) + parent_type(2) + parent_id(8) +
	// owner_len(2) + owner(N) + created_at(8) + updated_at(8) + conv_id(8) +
	// payload_encoding(1) + payload_raw_len(4) +
	// preview_len(2) + preview(N) + payload_len(2) + payload(N) + attachments
	size := 2 + 8 + 2 + 8 + 2 + len(a.Owner) + 8 + 8 + 8 + 1 + 4 + 2 + len(a.Preview) + 2 + len(a.Payload) + len(attachments)
	buf := make([]byte, size)
	off := 0

	binary.BigEndian.PutUint16(buf[off:], a.AssetType)
	off += 2
	binary.BigEndian.PutUint64(buf[off:], a.AssetID)
	off += 8
	binary.BigEndian.PutUint16(buf[off:], a.ParentType)
	off += 2
	binary.BigEndian.PutUint64(buf[off:], a.ParentID)
	off += 8
	binary.BigEndian.PutUint16(buf[off:], uint16(len(a.Owner)))
	off += 2
	copy(buf[off:], a.Owner)
	off += len(a.Owner)
	binary.BigEndian.PutUint64(buf[off:], uint64(a.CreatedAt))
	off += 8
	binary.BigEndian.PutUint64(buf[off:], uint64(a.UpdatedAt))
	off += 8
	binary.BigEndian.PutUint64(buf[off:], a.ConvID)
	off += 8
	buf[off] = a.PayloadEncoding
	off += 1
	binary.BigEndian.PutUint32(buf[off:], a.PayloadRawLen)
	off += 4
	binary.BigEndian.PutUint16(buf[off:], uint16(len(a.Preview)))
	off += 2
	copy(buf[off:], a.Preview)
	off += len(a.Preview)
	binary.BigEndian.PutUint16(buf[off:], uint16(len(a.Payload)))
	off += 2
	copy(buf[off:], a.Payload)
	off += len(a.Payload)
	copy(buf[off:], attachments)

	return buf
}

// buildAssetHeader encodes a protocol.Asset into the header-only binary wire format (no payload).
func buildAssetHeader(a protocol.Asset) []byte {
	attachments := protocol.EncodeAttachments(a.Attachments)
	size := 2 + 8 + 2 + 8 + 2 + len(a.Owner) + 8 + 8 + 8 + 1 + 4 + 2 + len(a.Preview) + len(attachments)
	buf := make([]byte, size)
	off := 0

	binary.BigEndian.PutUint16(buf[off:], a.AssetType)
	off += 2
	binary.BigEndian.PutUint64(buf[off:], a.AssetID)
	off += 8
	binary.BigEndian.PutUint16(buf[off:], a.ParentType)
	off += 2
	binary.BigEndian.PutUint64(buf[off:], a.ParentID)
	off += 8
	binary.BigEndian.PutUint16(buf[off:], uint16(len(a.Owner)))
	off += 2
	copy(buf[off:], a.Owner)
	off += len(a.Owner)
	binary.BigEndian.PutUint64(buf[off:], uint64(a.CreatedAt))
	off += 8
	binary.BigEndian.PutUint64(buf[off:], uint64(a.UpdatedAt))
	off += 8
	binary.BigEndian.PutUint64(buf[off:], a.ConvID)
	off += 8
	buf[off] = a.PayloadEncoding
	off += 1
	binary.BigEndian.PutUint32(buf[off:], a.PayloadRawLen)
	off += 4
	binary.BigEndian.PutUint16(buf[off:], uint16(len(a.Preview)))
	off += 2
	copy(buf[off:], a.Preview)
	off += len(a.Preview)
	copy(buf[off:], attachments)

	return buf
}

func TestParseAssetFull(t *testing.T) {
	tests := []struct {
		name      string
		buildData func() ([]byte, int)
		want      protocol.Asset
		wantOff   int // expected final offset relative to start of asset data
	}{
		{
			name: "valid full asset",
			buildData: func() ([]byte, int) {
				a := protocol.Asset{
					AssetType:  protocol.AssetTypeComment,
					AssetID:    1001,
					ParentType: 3,
					ParentID:   500,
					Owner:      "alice",
					CreatedAt:  1700000000,
					UpdatedAt:  1700001000,
					ConvID:     42,
					Preview:    "hello world",
					Payload:    "full message body",
				}
				return buildFullAsset(a), 0
			},
			want: protocol.Asset{
				AssetType:  protocol.AssetTypeComment,
				AssetID:    1001,
				ParentType: 3,
				ParentID:   500,
				Owner:      "alice",
				CreatedAt:  1700000000,
				UpdatedAt:  1700001000,
				ConvID:     42,
				Preview:    "hello world",
				Payload:    "full message body",
			},
		},
		{
			name: "empty strings",
			buildData: func() ([]byte, int) {
				a := protocol.Asset{
					AssetType:  protocol.AssetTypeDocument,
					AssetID:    99,
					ParentType: 0,
					ParentID:   0,
					Owner:      "",
					CreatedAt:  0,
					UpdatedAt:  0,
					ConvID:     7,
					Preview:    "",
					Payload:    "",
				}
				return buildFullAsset(a), 0
			},
			want: protocol.Asset{
				AssetType:  protocol.AssetTypeDocument,
				AssetID:    99,
				ParentType: 0,
				ParentID:   0,
				Owner:      "",
				CreatedAt:  0,
				UpdatedAt:  0,
				ConvID:     7,
				Preview:    "",
				Payload:    "",
			},
		},
		{
			name: "non-zero offset",
			buildData: func() ([]byte, int) {
				a := protocol.Asset{
					AssetType:  protocol.AssetTypeAgenda,
					AssetID:    555,
					ParentType: 1,
					ParentID:   200,
					Owner:      "bob",
					CreatedAt:  1600000000,
					UpdatedAt:  1600002000,
					ConvID:     10,
					Preview:    "preview",
					Payload:    "payload",
				}
				assetBytes := buildFullAsset(a)
				prefix := []byte{0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE}
				buf := make([]byte, len(prefix)+len(assetBytes))
				copy(buf, prefix)
				copy(buf[len(prefix):], assetBytes)
				return buf, len(prefix)
			},
			want: protocol.Asset{
				AssetType:  protocol.AssetTypeAgenda,
				AssetID:    555,
				ParentType: 1,
				ParentID:   200,
				Owner:      "bob",
				CreatedAt:  1600000000,
				UpdatedAt:  1600002000,
				ConvID:     10,
				Preview:    "preview",
				Payload:    "payload",
			},
		},
		{
			name: "truncated data",
			buildData: func() ([]byte, int) {
				return []byte{0x00, 0x01, 0x00}, 0 // only 3 bytes, not enough for asset_id
			},
			want: protocol.Asset{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data, offset := tt.buildData()
			got, _ := protocol.ParseAssetFull(data, offset)

			if got.AssetType != tt.want.AssetType {
				t.Errorf("AssetType = %d, want %d", got.AssetType, tt.want.AssetType)
			}
			if got.AssetID != tt.want.AssetID {
				t.Errorf("AssetID = %d, want %d", got.AssetID, tt.want.AssetID)
			}
			if got.ParentType != tt.want.ParentType {
				t.Errorf("ParentType = %d, want %d", got.ParentType, tt.want.ParentType)
			}
			if got.ParentID != tt.want.ParentID {
				t.Errorf("ParentID = %d, want %d", got.ParentID, tt.want.ParentID)
			}
			if got.Owner != tt.want.Owner {
				t.Errorf("Owner = %q, want %q", got.Owner, tt.want.Owner)
			}
			if got.CreatedAt != tt.want.CreatedAt {
				t.Errorf("CreatedAt = %d, want %d", got.CreatedAt, tt.want.CreatedAt)
			}
			if got.UpdatedAt != tt.want.UpdatedAt {
				t.Errorf("UpdatedAt = %d, want %d", got.UpdatedAt, tt.want.UpdatedAt)
			}
			if got.ConvID != tt.want.ConvID {
				t.Errorf("ConvID = %d, want %d", got.ConvID, tt.want.ConvID)
			}
			if got.Preview != tt.want.Preview {
				t.Errorf("Preview = %q, want %q", got.Preview, tt.want.Preview)
			}
			if got.Payload != tt.want.Payload {
				t.Errorf("Payload = %q, want %q", got.Payload, tt.want.Payload)
			}
		})
	}
}

func TestParseAssetHeader(t *testing.T) {
	tests := []struct {
		name  string
		asset protocol.Asset
	}{
		{
			name: "valid header",
			asset: protocol.Asset{
				AssetType:  protocol.AssetTypeNote,
				AssetID:    777,
				ParentType: 2,
				ParentID:   300,
				Owner:      "charlie",
				CreatedAt:  1700000000,
				UpdatedAt:  1700005000,
				ConvID:     55,
				Preview:    "note preview",
			},
		},
		{
			name: "empty strings",
			asset: protocol.Asset{
				AssetType:  protocol.AssetTypeFile,
				AssetID:    1,
				ParentType: 0,
				ParentID:   0,
				Owner:      "",
				CreatedAt:  0,
				UpdatedAt:  0,
				ConvID:     0,
				Preview:    "",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data := buildAssetHeader(tt.asset)
			got, _ := protocol.ParseAssetHeader(data, 0)

			if got.AssetType != tt.asset.AssetType {
				t.Errorf("AssetType = %d, want %d", got.AssetType, tt.asset.AssetType)
			}
			if got.AssetID != tt.asset.AssetID {
				t.Errorf("AssetID = %d, want %d", got.AssetID, tt.asset.AssetID)
			}
			if got.ParentType != tt.asset.ParentType {
				t.Errorf("ParentType = %d, want %d", got.ParentType, tt.asset.ParentType)
			}
			if got.ParentID != tt.asset.ParentID {
				t.Errorf("ParentID = %d, want %d", got.ParentID, tt.asset.ParentID)
			}
			if got.Owner != tt.asset.Owner {
				t.Errorf("Owner = %q, want %q", got.Owner, tt.asset.Owner)
			}
			if got.CreatedAt != tt.asset.CreatedAt {
				t.Errorf("CreatedAt = %d, want %d", got.CreatedAt, tt.asset.CreatedAt)
			}
			if got.UpdatedAt != tt.asset.UpdatedAt {
				t.Errorf("UpdatedAt = %d, want %d", got.UpdatedAt, tt.asset.UpdatedAt)
			}
			if got.ConvID != tt.asset.ConvID {
				t.Errorf("ConvID = %d, want %d", got.ConvID, tt.asset.ConvID)
			}
			if got.Preview != tt.asset.Preview {
				t.Errorf("Preview = %q, want %q", got.Preview, tt.asset.Preview)
			}
			if got.Payload != "" {
				t.Errorf("Payload should be empty for header parse, got %q", got.Payload)
			}
		})
	}
}

func TestContentHash(t *testing.T) {
	tests := []struct {
		name string
		a    []byte
		b    []byte
		same bool
	}{
		{
			name: "same input same hash",
			a:    []byte("hello world"),
			b:    []byte("hello world"),
			same: true,
		},
		{
			name: "different input different hash",
			a:    []byte("hello"),
			b:    []byte("world"),
			same: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ha := contentHash(tt.a)
			hb := contentHash(tt.b)
			if tt.same && ha != hb {
				t.Errorf("expected same hash, got %d != %d", ha, hb)
			}
			if !tt.same && ha == hb {
				t.Errorf("expected different hashes, got %d == %d", ha, hb)
			}
		})
	}

	t.Run("empty input non-zero", func(t *testing.T) {
		h := contentHash([]byte{})
		// FNV-1a offset basis is non-zero
		expected := fnv.New64a()
		expected.Write([]byte{})
		if h == 0 {
			t.Error("expected non-zero hash for empty input")
		}
		if h != expected.Sum64() {
			t.Errorf("hash = %d, want %d", h, expected.Sum64())
		}
	})
}

func TestParseAssetTypes(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  []uint16
	}{
		{
			name:  "multiple values",
			input: "1,2,4,5",
			want:  []uint16{1, 2, 4, 5},
		},
		{
			name:  "single value",
			input: "1",
			want:  []uint16{1},
		},
		{
			name:  "spaces around values",
			input: "1, 2, 4",
			want:  []uint16{1, 2, 4},
		},
		{
			name:  "empty string",
			input: "",
			want:  []uint16{},
		},
		{
			name:  "invalid value skipped",
			input: "1,abc,3",
			want:  []uint16{1, 3},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseAssetTypes(tt.input)
			if len(got) != len(tt.want) {
				t.Fatalf("len = %d, want %d; got %v", len(got), len(tt.want), got)
			}
			for i := range tt.want {
				if got[i] != tt.want[i] {
					t.Errorf("index %d: got %d, want %d", i, got[i], tt.want[i])
				}
			}
		})
	}
}

func TestEnvOrDefault(t *testing.T) {
	t.Run("returns default when not set", func(t *testing.T) {
		got := envOrDefault("NRC_TEST_UNSET_VAR_XYZ", "fallback")
		if got != "fallback" {
			t.Errorf("got %q, want %q", got, "fallback")
		}
	})

	t.Run("returns env value when set", func(t *testing.T) {
		t.Setenv("NRC_TEST_SET_VAR_XYZ", "custom_value")
		got := envOrDefault("NRC_TEST_SET_VAR_XYZ", "fallback")
		if got != "custom_value" {
			t.Errorf("got %q, want %q", got, "custom_value")
		}
	})
}

func TestLoadConfigIndexesTasksAndFiles(t *testing.T) {
	t.Setenv("EMBED_TASKS", "")
	t.Setenv("EMBED_ASSET_TYPES", "")
	cfg := loadConfig()
	if !cfg.EmbedTasks {
		t.Fatal("tasks should be indexed by default")
	}
	want := []uint16{1, 2, 3, 4, 5}
	if len(cfg.EmbedAssetTypes) != len(want) {
		t.Fatalf("asset defaults = %v, want %v", cfg.EmbedAssetTypes, want)
	}
	for i := range want {
		if cfg.EmbedAssetTypes[i] != want[i] {
			t.Fatalf("asset defaults = %v, want %v", cfg.EmbedAssetTypes, want)
		}
	}
}

func TestParseAssetFullMultipleTruncated(t *testing.T) {
	// Build 2 complete assets, then truncate so a 3rd cannot parse.
	a1 := protocol.Asset{
		AssetType: protocol.AssetTypeComment, AssetID: 1, Owner: "a",
		CreatedAt: 100, UpdatedAt: 200, ConvID: 10,
		Preview: "p1", Payload: "body1",
	}
	a2 := protocol.Asset{
		AssetType: protocol.AssetTypeDocument, AssetID: 2, Owner: "b",
		CreatedAt: 300, UpdatedAt: 400, ConvID: 10,
		Preview: "p2", Payload: "body2",
	}
	data := append(buildFullAsset(a1), buildFullAsset(a2)...)
	// Add a partial 3rd asset (just 1 byte, not enough for asset_type)
	data = append(data, 0x00)

	count := 3
	offset := 0
	var assets []protocol.Asset
	for i := 0; i < count; i++ {
		asset, newOffset := protocol.ParseAssetFull(data, offset)
		if newOffset <= offset {
			break
		}
		offset = newOffset
		assets = append(assets, asset)
	}

	if len(assets) != 2 {
		t.Fatalf("expected 2 parsed assets, got %d", len(assets))
	}
	if assets[0].AssetID != 1 {
		t.Errorf("first asset ID = %d, want 1", assets[0].AssetID)
	}
	if assets[1].AssetID != 2 {
		t.Errorf("second asset ID = %d, want 2", assets[1].AssetID)
	}
	// The key assertion: count (3) != len(assets) (2), so this is a truncated list
	if len(assets) == count {
		t.Error("expected partial parse (len != count), but they matched")
	}
}

func TestParseAssetHeaderMultipleTruncated(t *testing.T) {
	a1 := protocol.Asset{
		AssetType: protocol.AssetTypeNote, AssetID: 10, Owner: "x",
		CreatedAt: 500, UpdatedAt: 600, ConvID: 20,
		Preview: "preview1",
	}
	data := buildAssetHeader(a1)
	// Add a single trailing byte — not enough for even the asset_type u16
	data = append(data, 0x00)

	count := 2
	offset := 0
	var assets []protocol.Asset
	for i := 0; i < count; i++ {
		asset, newOffset := protocol.ParseAssetHeader(data, offset)
		if newOffset <= offset {
			break
		}
		offset = newOffset
		assets = append(assets, asset)
	}

	if len(assets) != 1 {
		t.Fatalf("expected 1 parsed asset, got %d", len(assets))
	}
	if assets[0].AssetID != 10 {
		t.Errorf("asset ID = %d, want 10", assets[0].AssetID)
	}
	if len(assets) == count {
		t.Error("expected partial parse (len != count), but they matched")
	}
}
