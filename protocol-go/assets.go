package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"sync"
	"unicode/utf8"

	"github.com/klauspost/compress/zstd"
)

const (
	maxAssetAttachments = MaxAttachmentsPerTask
	maxFileIDLength     = 128
	maxFilenameLength   = 255
	maxMimeTypeLength   = 100
)

var (
	assetZstdEncoderOnce sync.Once
	assetZstdEncoder     *zstd.Encoder
	assetZstdEncoderErr  error

	assetZstdDecoderOnce sync.Once
	assetZstdDecoder     *zstd.Decoder
	assetZstdDecoderErr  error
)

// Asset represents an asset returned by protocol-go asset decoders.
//
// High-level decode helpers such as DecodeAssetFull, DecodeAssetCreated,
// DecodeAssetUpdated, DecodeAssetListResponse, and DecodeAssetListPage return
// payloads normalized to plain text in Payload. Low-level wire parsers such as
// ParseAssetFull retain the on-the-wire representation.
type Asset struct {
	AssetType       uint16
	AssetID         uint64
	ParentType      uint16
	ParentID        uint64
	Owner           string
	CreatedAt       int64
	UpdatedAt       int64
	ConvID          uint64
	PayloadEncoding uint8
	PayloadRawLen   uint32
	Preview         string
	Payload         string
	Attachments     []Attachment
}

// AssetCreatedResponse represents a decoded S_AssetCreated payload.
// Wire format: asset(full) + correlation_id(4)
type AssetCreatedResponse struct {
	Asset         Asset
	CorrelationID uint32
}

// AssetUpdatedResponse represents a decoded S_AssetUpdated payload.
// Wire format: asset(full) + correlation_id(4)
type AssetUpdatedResponse struct {
	Asset         Asset
	CorrelationID uint32
}

// AssetDeletedResponse represents a decoded S_AssetDeleted payload.
// Wire format: conv_id(8) + asset_id(8) + correlation_id(4)
type AssetDeletedResponse struct {
	ConvID        uint64
	AssetID       uint64
	CorrelationID uint32
}

// AssetFullResponse represents a decoded S_AssetFull payload.
// Wire format: asset(full) + correlation_id(4)
type AssetFullResponse struct {
	Asset         Asset
	CorrelationID uint32
}

// AssetListResponse represents a decoded S_AssetList payload.
// Wire format: conv_id(8) + full_content(1) + count(2) + assets... + correlation_id(4)
type AssetListResponse struct {
	ConvID        uint64
	FullContent   bool
	Assets        []Asset
	CorrelationID uint32
}

// AssetListPageResponse represents a decoded S_AssetListPage payload.
// Wire format: conv_id(8) + full_content(1) + has_more(1) + next_cursor_updated_at(8) + next_cursor_asset_id(8) + total_count(4) + count(2) + assets...
type AssetListPageResponse struct {
	ConvID              uint64
	FullContent         bool
	HasMore             bool
	NextCursorUpdatedAt int64
	NextCursorAssetID   uint64
	TotalCount          uint32
	Assets              []Asset
	CorrelationID       uint32
}

// NoteProjectListResponse represents a decoded S_NoteProjectList payload.
// Wire format: conv_id(8) + count(2) + correlation_id(4) + projects...
type NoteProjectListResponse struct {
	ConvID        uint64
	Projects      []string
	CorrelationID uint32
}

// NoteTagListResponse represents a decoded S_NoteTagList payload.
// Wire format: conv_id(8) + count(2) + correlation_id(4) + tags...
type NoteTagListResponse struct {
	ConvID        uint64
	Tags          []string
	CorrelationID uint32
}

func EncodeSearchCustomers(convID int64, limit uint16, afterCompanyID uint64, includeArchived bool, query string, correlationID uint32) ([]byte, error) {
	if len(query) > 256 {
		return nil, fmt.Errorf("customer query exceeds 256 bytes")
	}
	if !utf8.ValidString(query) {
		return nil, fmt.Errorf("customer query is not valid UTF-8")
	}
	buf := make([]byte, 25+len(query))
	binary.BigEndian.PutUint64(buf, uint64(convID))
	binary.BigEndian.PutUint16(buf[8:], limit)
	binary.BigEndian.PutUint64(buf[10:], afterCompanyID)
	if includeArchived {
		buf[18] = 1
	}
	binary.BigEndian.PutUint16(buf[19:], uint16(len(query)))
	copy(buf[21:], query)
	binary.BigEndian.PutUint32(buf[21+len(query):], correlationID)
	return buf, nil
}

type CustomerSearchPageResponse struct {
	ConvID        uint64
	HasMore       bool
	NextCompanyID uint64
	TotalCount    uint32
	Assets        []Asset
	CorrelationID uint32
}

func DecodeCustomerSearchPage(data []byte) (*CustomerSearchPageResponse, error) {
	if len(data) < 27 || data[8] > 1 {
		return nil, fmt.Errorf("invalid customer search page header")
	}
	r := &CustomerSearchPageResponse{ConvID: binary.BigEndian.Uint64(data), HasMore: data[8] == 1, NextCompanyID: binary.BigEndian.Uint64(data[9:]), TotalCount: binary.BigEndian.Uint32(data[17:]), CorrelationID: binary.BigEndian.Uint32(data[23:])}
	count, offset := int(binary.BigEndian.Uint16(data[21:])), 27
	r.Assets = make([]Asset, 0, count)
	for i := 0; i < count; i++ {
		asset, next, err := parseAssetHeaderStrict(data, offset)
		if err != nil {
			return nil, err
		}
		r.Assets = append(r.Assets, asset)
		offset = next
	}
	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in customer search page")
	}
	return r, nil
}

func parseAssetFullStrict(data []byte, offset int) (Asset, int, error) {
	var a Asset
	start := offset

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing asset_type")
	}
	a.AssetType = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing asset_id")
	}
	a.AssetID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing parent_type")
	}
	a.ParentType = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing parent_id")
	}
	a.ParentID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing owner length")
	}
	ownerLen := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	if len(data) < offset+ownerLen {
		return a, start, fmt.Errorf("response too short: owner bytes truncated")
	}
	a.Owner = string(data[offset : offset+ownerLen])
	offset += ownerLen

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing created_at")
	}
	a.CreatedAt = int64(binary.BigEndian.Uint64(data[offset:]))
	offset += 8

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing updated_at")
	}
	a.UpdatedAt = int64(binary.BigEndian.Uint64(data[offset:]))
	offset += 8

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing conv_id")
	}
	a.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+1 {
		return a, start, fmt.Errorf("response too short: missing payload_encoding")
	}
	a.PayloadEncoding = data[offset]
	if a.PayloadEncoding != AssetPayloadEncodingPlain && a.PayloadEncoding != AssetPayloadEncodingZstd {
		return a, start, fmt.Errorf("unsupported payload_encoding: %d", a.PayloadEncoding)
	}
	offset += 1

	if len(data) < offset+4 {
		return a, start, fmt.Errorf("response too short: missing payload_raw_len")
	}
	a.PayloadRawLen = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing preview length")
	}
	previewLen := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	if len(data) < offset+previewLen {
		return a, start, fmt.Errorf("response too short: preview bytes truncated")
	}
	a.Preview = string(data[offset : offset+previewLen])
	offset += previewLen

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing payload length")
	}
	payloadLen := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	if len(data) < offset+payloadLen {
		return a, start, fmt.Errorf("response too short: payload bytes truncated")
	}
	a.Payload = string(data[offset : offset+payloadLen])
	offset += payloadLen

	attachments, newOffset, err := parseAssetAttachmentsStrict(data, offset)
	if err != nil {
		return a, start, err
	}
	a.Attachments = attachments
	offset = newOffset

	return a, offset, nil
}

func parseAssetHeaderStrict(data []byte, offset int) (Asset, int, error) {
	var a Asset
	start := offset

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing asset_type")
	}
	a.AssetType = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing asset_id")
	}
	a.AssetID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing parent_type")
	}
	a.ParentType = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing parent_id")
	}
	a.ParentID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing owner length")
	}
	ownerLen := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	if len(data) < offset+ownerLen {
		return a, start, fmt.Errorf("response too short: owner bytes truncated")
	}
	a.Owner = string(data[offset : offset+ownerLen])
	offset += ownerLen

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing created_at")
	}
	a.CreatedAt = int64(binary.BigEndian.Uint64(data[offset:]))
	offset += 8

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing updated_at")
	}
	a.UpdatedAt = int64(binary.BigEndian.Uint64(data[offset:]))
	offset += 8

	if len(data) < offset+8 {
		return a, start, fmt.Errorf("response too short: missing conv_id")
	}
	a.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+1 {
		return a, start, fmt.Errorf("response too short: missing payload_encoding")
	}
	a.PayloadEncoding = data[offset]
	if a.PayloadEncoding != AssetPayloadEncodingPlain && a.PayloadEncoding != AssetPayloadEncodingZstd {
		return a, start, fmt.Errorf("unsupported payload_encoding: %d", a.PayloadEncoding)
	}
	offset += 1

	if len(data) < offset+4 {
		return a, start, fmt.Errorf("response too short: missing payload_raw_len")
	}
	a.PayloadRawLen = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	if len(data) < offset+2 {
		return a, start, fmt.Errorf("response too short: missing preview length")
	}
	previewLen := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	if len(data) < offset+previewLen {
		return a, start, fmt.Errorf("response too short: preview bytes truncated")
	}
	a.Preview = string(data[offset : offset+previewLen])
	offset += previewLen

	attachments, newOffset, err := parseAssetAttachmentsStrict(data, offset)
	if err != nil {
		return a, start, err
	}
	a.Attachments = attachments
	offset = newOffset

	return a, offset, nil
}

func parseAssetAttachmentsStrict(data []byte, offset int) ([]Attachment, int, error) {
	start := offset
	if len(data) < offset+2 {
		return nil, start, fmt.Errorf("response too short: missing attachment count")
	}
	count := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	attachments := make([]Attachment, 0, count)
	for i := 0; i < count; i++ {
		if len(data) < offset+2 {
			return nil, start, fmt.Errorf("response too short: missing attachment file_id length")
		}
		fileIDLen := int(binary.BigEndian.Uint16(data[offset:]))
		offset += 2
		if len(data) < offset+fileIDLen {
			return nil, start, fmt.Errorf("response too short: attachment file_id truncated")
		}
		fileID := string(data[offset : offset+fileIDLen])
		offset += fileIDLen

		if len(data) < offset+2 {
			return nil, start, fmt.Errorf("response too short: missing attachment filename length")
		}
		filenameLen := int(binary.BigEndian.Uint16(data[offset:]))
		offset += 2
		if len(data) < offset+filenameLen {
			return nil, start, fmt.Errorf("response too short: attachment filename truncated")
		}
		filename := string(data[offset : offset+filenameLen])
		offset += filenameLen

		if len(data) < offset+8 {
			return nil, start, fmt.Errorf("response too short: missing attachment size")
		}
		size := int64(binary.BigEndian.Uint64(data[offset:]))
		offset += 8

		if len(data) < offset+2 {
			return nil, start, fmt.Errorf("response too short: missing attachment mime_type length")
		}
		mimeTypeLen := int(binary.BigEndian.Uint16(data[offset:]))
		offset += 2
		if len(data) < offset+mimeTypeLen {
			return nil, start, fmt.Errorf("response too short: attachment mime_type truncated")
		}
		mimeType := string(data[offset : offset+mimeTypeLen])
		offset += mimeTypeLen

		if len(data) < offset+8 {
			return nil, start, fmt.Errorf("response too short: missing attachment uploaded_at")
		}
		uploadedAt := int64(binary.BigEndian.Uint64(data[offset:]))
		offset += 8

		attachments = append(attachments, Attachment{FileId: fileID, Filename: filename, Size: size, MimeType: mimeType, UploadedAt: uploadedAt})
	}
	return attachments, offset, nil
}

// ParseAssetFull parses a full asset (with payload) from binary data at offset.
func ParseAssetFull(data []byte, offset int) (Asset, int) {
	a, newOffset, err := parseAssetFullStrict(data, offset)
	if err != nil {
		return Asset{}, offset
	}
	return a, newOffset
}

// ParseAssetHeader parses an asset header (without payload) from binary data at offset.
func ParseAssetHeader(data []byte, offset int) (Asset, int) {
	a, newOffset, err := parseAssetHeaderStrict(data, offset)
	if err != nil {
		return Asset{}, offset
	}
	return a, newOffset
}

func normalizeDecodedAsset(asset Asset) (Asset, error) {
	payload, err := DecodeAssetPayload(asset)
	if err != nil {
		return Asset{}, err
	}
	asset.Payload = payload
	asset.PayloadEncoding = AssetPayloadEncodingPlain
	asset.PayloadRawLen = uint32(len(payload))
	return asset, nil
}

// DecodeAssetFull decodes an S_AssetFull response (no conv_id prefix, just the asset).
func DecodeAssetFull(data []byte) (Asset, error) {
	asset, offset, err := parseAssetFullStrict(data, 0)
	if err != nil {
		return Asset{}, err
	}
	if offset != len(data) && offset+4 != len(data) {
		return Asset{}, fmt.Errorf("unexpected trailing bytes in asset full payload: %d", len(data)-offset)
	}
	asset, err = normalizeDecodedAsset(asset)
	if err != nil {
		return Asset{}, err
	}
	return asset, nil
}

// DecodeAssetCreated decodes an S_AssetCreated payload.
// Wire format: asset(full) + correlation_id(4)
func DecodeAssetCreated(data []byte) (*AssetCreatedResponse, error) {
	asset, correlationID, err := decodeAssetWithCorrelation(data)
	if err != nil {
		return nil, err
	}

	return &AssetCreatedResponse{Asset: asset, CorrelationID: correlationID}, nil
}

// DecodeAssetUpdated decodes an S_AssetUpdated payload.
// Wire format: asset(full) + correlation_id(4)
func DecodeAssetUpdated(data []byte) (*AssetUpdatedResponse, error) {
	asset, correlationID, err := decodeAssetWithCorrelation(data)
	if err != nil {
		return nil, err
	}

	return &AssetUpdatedResponse{Asset: asset, CorrelationID: correlationID}, nil
}

// DecodeAssetDeleted decodes an S_AssetDeleted payload.
// Wire format: conv_id(8) + asset_id(8) + correlation_id(4)
func DecodeAssetDeleted(data []byte) (*AssetDeletedResponse, error) {
	if len(data) != 20 {
		return nil, fmt.Errorf("asset deleted payload size mismatch: got %d want 20", len(data))
	}

	return &AssetDeletedResponse{
		ConvID:        binary.BigEndian.Uint64(data[0:8]),
		AssetID:       binary.BigEndian.Uint64(data[8:16]),
		CorrelationID: binary.BigEndian.Uint32(data[16:20]),
	}, nil
}

// DecodeAssetFullResponse decodes an S_AssetFull payload.
// Wire format: asset(full) + correlation_id(4)
func DecodeAssetFullResponse(data []byte) (*AssetFullResponse, error) {
	asset, correlationID, err := decodeAssetWithCorrelation(data)
	if err != nil {
		return nil, err
	}

	return &AssetFullResponse{Asset: asset, CorrelationID: correlationID}, nil
}

func decodeAssetWithCorrelation(data []byte) (Asset, uint32, error) {
	asset, offset, err := parseAssetFullStrict(data, 0)
	if err != nil {
		return Asset{}, 0, err
	}
	if offset+4 > len(data) {
		return Asset{}, 0, fmt.Errorf("missing asset correlation_id suffix")
	}

	correlationID := binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if offset != len(data) {
		return Asset{}, 0, fmt.Errorf("unexpected trailing bytes in asset payload: %d", len(data)-offset)
	}

	asset, err = normalizeDecodedAsset(asset)
	if err != nil {
		return Asset{}, 0, err
	}

	return asset, correlationID, nil
}

// DecodeAssetList decodes an S_AssetList response.
// Format: conv_id(8) + full_content(1) + count(2) + assets...
func DecodeAssetList(data []byte, full bool) ([]Asset, error) {
	resp, err := DecodeAssetListResponse(data)
	if err != nil {
		return nil, err
	}

	if resp.FullContent != full {
		return nil, fmt.Errorf("asset list full_content mismatch: payload=%t decode_arg=%t", resp.FullContent, full)
	}

	return resp.Assets, nil
}

// DecodeAssetListResponse decodes an S_AssetList payload.
// Format: conv_id(8) + full_content(1) + count(2) + correlation_id(4) + assets...
func DecodeAssetListResponse(data []byte) (*AssetListResponse, error) {
	if len(data) < 15 {
		return nil, fmt.Errorf("response too short")
	}

	resp := &AssetListResponse{}
	offset := 0

	resp.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	resp.FullContent = data[offset] == 1
	offset += 1

	count := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2

	resp.CorrelationID = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	resp.Assets = make([]Asset, 0, count)
	for i := 0; i < count; i++ {
		var a Asset
		var err error
		if resp.FullContent {
			a, offset, err = parseAssetFullStrict(data, offset)
		} else {
			a, offset, err = parseAssetHeaderStrict(data, offset)
		}
		if err != nil {
			return nil, fmt.Errorf("asset list decode failed at index %d: %w", i, err)
		}
		if resp.FullContent {
			a, err = normalizeDecodedAsset(a)
			if err != nil {
				return nil, fmt.Errorf("asset list decode failed at index %d: %w", i, err)
			}
		}
		resp.Assets = append(resp.Assets, a)
	}

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in asset list payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeAssetListPage decodes an S_AssetListPage response.
func DecodeAssetListPage(data []byte) (*AssetListPageResponse, error) {
	if len(data) < 36 {
		return nil, fmt.Errorf("response too short")
	}

	offset := 0
	resp := &AssetListPageResponse{}

	resp.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	resp.FullContent = data[offset] == 1
	offset += 1

	resp.HasMore = data[offset] == 1
	offset += 1

	resp.NextCursorUpdatedAt = int64(binary.BigEndian.Uint64(data[offset:]))
	offset += 8

	resp.NextCursorAssetID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	resp.TotalCount = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	count := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2

	resp.CorrelationID = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	resp.Assets = make([]Asset, 0, count)
	for i := 0; i < count; i++ {
		var a Asset
		var err error
		if resp.FullContent {
			a, offset, err = parseAssetFullStrict(data, offset)
		} else {
			a, offset, err = parseAssetHeaderStrict(data, offset)
		}
		if err != nil {
			return nil, fmt.Errorf("asset list page decode failed at index %d: %w", i, err)
		}
		if resp.FullContent {
			a, err = normalizeDecodedAsset(a)
			if err != nil {
				return nil, fmt.Errorf("asset list page decode failed at index %d: %w", i, err)
			}
		}
		resp.Assets = append(resp.Assets, a)
	}

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in asset list page payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeNoteProjectList decodes an S_NoteProjectList response.
func DecodeNoteProjectList(data []byte) (*NoteProjectListResponse, error) {
	if len(data) < 14 {
		return nil, fmt.Errorf("response too short")
	}

	offset := 0
	resp := &NoteProjectListResponse{}

	resp.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	count := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2

	resp.CorrelationID = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	resp.Projects = make([]string, 0, count)
	for i := 0; i < count; i++ {
		if len(data) < offset+2 {
			return nil, fmt.Errorf("note project list decode failed at index %d: missing project length", i)
		}

		projectLen := int(binary.BigEndian.Uint16(data[offset:]))
		offset += 2
		if len(data) < offset+projectLen {
			return nil, fmt.Errorf("note project list decode failed at index %d: project bytes truncated", i)
		}

		resp.Projects = append(resp.Projects, string(data[offset:offset+projectLen]))
		offset += projectLen
	}

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in note project list payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeNoteTagList decodes an S_NoteTagList response.
func DecodeNoteTagList(data []byte) (*NoteTagListResponse, error) {
	if len(data) < 14 {
		return nil, fmt.Errorf("response too short")
	}

	offset := 0
	resp := &NoteTagListResponse{}

	resp.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	count := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2

	resp.CorrelationID = binary.BigEndian.Uint32(data[offset:])
	offset += 4

	resp.Tags = make([]string, 0, count)
	for i := 0; i < count; i++ {
		if len(data) < offset+2 {
			return nil, fmt.Errorf("note tag list decode failed at index %d: missing tag length", i)
		}

		tagLen := int(binary.BigEndian.Uint16(data[offset:]))
		offset += 2
		if len(data) < offset+tagLen {
			return nil, fmt.Errorf("note tag list decode failed at index %d: tag bytes truncated", i)
		}

		resp.Tags = append(resp.Tags, string(data[offset:offset+tagLen]))
		offset += tagLen
	}

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in note tag list payload: %d", len(data)-offset)
	}

	return resp, nil
}

func getAssetZstdEncoder() (*zstd.Encoder, error) {
	assetZstdEncoderOnce.Do(func() {
		assetZstdEncoder, assetZstdEncoderErr = zstd.NewWriter(nil)
	})
	return assetZstdEncoder, assetZstdEncoderErr
}

func getAssetZstdDecoder() (*zstd.Decoder, error) {
	assetZstdDecoderOnce.Do(func() {
		assetZstdDecoder, assetZstdDecoderErr = zstd.NewReader(nil)
	})
	return assetZstdDecoder, assetZstdDecoderErr
}

// CompressAssetPayloadZstd compresses an asset payload and returns compressed bytes as string plus raw length.
func CompressAssetPayloadZstd(payload string) (compressedPayload string, rawLen uint32, err error) {
	if len(payload) > MaxPayloadLength {
		return "", 0, fmt.Errorf("payload too large: %d > %d", len(payload), MaxPayloadLength)
	}

	encoder, err := getAssetZstdEncoder()
	if err != nil {
		return "", 0, fmt.Errorf("failed to initialize zstd encoder: %w", err)
	}

	compressed := encoder.EncodeAll([]byte(payload), nil)
	if len(compressed) > MaxPayloadLength {
		return "", 0, fmt.Errorf("compressed payload too large: %d > %d", len(compressed), MaxPayloadLength)
	}

	return string(compressed), uint32(len(payload)), nil
}

// DecodeAssetPayload decodes an asset payload to plain text using metadata.
func DecodeAssetPayload(asset Asset) (string, error) {
	switch asset.PayloadEncoding {
	case AssetPayloadEncodingPlain:
		if asset.PayloadRawLen != uint32(len(asset.Payload)) {
			return "", fmt.Errorf("plain payload_raw_len mismatch: raw_len=%d payload_len=%d", asset.PayloadRawLen, len(asset.Payload))
		}
		return asset.Payload, nil
	case AssetPayloadEncodingZstd:
		decoder, err := getAssetZstdDecoder()
		if err != nil {
			return "", fmt.Errorf("failed to initialize zstd decoder: %w", err)
		}

		decoded, err := decoder.DecodeAll([]byte(asset.Payload), nil)
		if err != nil {
			return "", fmt.Errorf("failed to decode zstd asset payload: %w", err)
		}
		if len(decoded) != int(asset.PayloadRawLen) {
			return "", fmt.Errorf("decoded payload_raw_len mismatch: raw_len=%d decoded_len=%d", asset.PayloadRawLen, len(decoded))
		}

		return string(decoded), nil
	default:
		return "", fmt.Errorf("unsupported asset payload encoding: %d", asset.PayloadEncoding)
	}
}

// EncodeCreateAsset encodes C_CreateAsset request.
func EncodeCreateAsset(convID int64, assetType, parentType uint16, parentID uint64, preview, payload string) []byte {
	return EncodeCreateAssetWithMetadataAndCorrelation(
		convID,
		assetType,
		parentType,
		parentID,
		AssetPayloadEncodingPlain,
		uint32(len(payload)),
		preview,
		payload,
		0,
	)
}

// EncodeCreateAssetWithCorrelation encodes C_CreateAsset request with a trailing correlation_id.
func EncodeCreateAssetWithCorrelation(convID int64, assetType, parentType uint16, parentID uint64, preview, payload string, correlationID uint32) []byte {
	return EncodeCreateAssetWithMetadataAndCorrelation(
		convID,
		assetType,
		parentType,
		parentID,
		AssetPayloadEncodingPlain,
		uint32(len(payload)),
		preview,
		payload,
		correlationID,
	)
}

// EncodeCreateAssetWithAttachments encodes C_CreateAsset request with attachments.
func EncodeCreateAssetWithAttachments(convID int64, assetType, parentType uint16, parentID uint64, preview, payload string, attachments []Attachment) ([]byte, error) {
	return EncodeCreateAssetWithAttachmentsAndCorrelation(convID, assetType, parentType, parentID, preview, payload, attachments, 0)
}

// EncodeCreateAssetWithAttachmentsAndCorrelation encodes C_CreateAsset request
// with attachments and a trailing correlation_id.
func EncodeCreateAssetWithAttachmentsAndCorrelation(convID int64, assetType, parentType uint16, parentID uint64, preview, payload string, attachments []Attachment, correlationID uint32) ([]byte, error) {
	return EncodeCreateAssetWithMetadataAttachmentsAndCorrelation(convID, assetType, parentType, parentID, AssetPayloadEncodingPlain, uint32(len(payload)), preview, payload, attachments, correlationID)
}

// EncodeCreateAssetZstd encodes C_CreateAsset with zstd-compressed payload and metadata.
func EncodeCreateAssetZstd(convID int64, assetType, parentType uint16, parentID uint64, preview, payload string) ([]byte, error) {
	return EncodeCreateAssetZstdWithCorrelation(convID, assetType, parentType, parentID, preview, payload, 0)
}

// EncodeCreateAssetZstdWithCorrelation encodes C_CreateAsset with zstd payload and trailing correlation_id.
func EncodeCreateAssetZstdWithCorrelation(convID int64, assetType, parentType uint16, parentID uint64, preview, payload string, correlationID uint32) ([]byte, error) {
	compressedPayload, rawLen, err := CompressAssetPayloadZstd(payload)
	if err != nil {
		return nil, err
	}

	return EncodeCreateAssetWithMetadataAndCorrelation(
		convID,
		assetType,
		parentType,
		parentID,
		AssetPayloadEncodingZstd,
		rawLen,
		preview,
		compressedPayload,
		correlationID,
	), nil
}

// EncodeCreateAssetWithMetadataAndCorrelation encodes C_CreateAsset with
// explicit payload metadata and trailing correlation_id.
func EncodeCreateAssetWithMetadataAndCorrelation(convID int64, assetType, parentType uint16, parentID uint64, payloadEncoding uint8, payloadRawLen uint32, preview, payload string, correlationID uint32) []byte {
	data, _ := EncodeCreateAssetWithMetadataAttachmentsAndCorrelation(convID, assetType, parentType, parentID, payloadEncoding, payloadRawLen, preview, payload, nil, correlationID)
	return data
}

// EncodeCreateAssetWithMetadataAttachmentsAndCorrelation encodes C_CreateAsset
// with explicit payload metadata, attachments, and trailing correlation_id.
func EncodeCreateAssetWithMetadataAttachmentsAndCorrelation(convID int64, assetType, parentType uint16, parentID uint64, payloadEncoding uint8, payloadRawLen uint32, preview, payload string, attachments []Attachment, correlationID uint32) ([]byte, error) {
	if err := validateAssetPayloadForEncode(payloadEncoding, payloadRawLen, preview, payload); err != nil {
		return nil, err
	}
	if err := validateAssetAttachmentsForEncode(attachments); err != nil {
		return nil, err
	}
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, assetType)
	binary.Write(buf, binary.BigEndian, parentType)
	binary.Write(buf, binary.BigEndian, parentID)
	buf.WriteByte(payloadEncoding)
	binary.Write(buf, binary.BigEndian, payloadRawLen)
	writeString(buf, preview)
	writeString(buf, payload)
	buf.Write(EncodeAttachments(attachments))
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes(), nil
}

// EncodeUpdateAsset encodes C_UpdateAsset request.
func EncodeUpdateAsset(convID int64, assetID uint64, preview, payload string) []byte {
	return EncodeUpdateAssetWithMetadataAndCorrelation(convID, assetID, AssetPayloadEncodingPlain, uint32(len(payload)), preview, payload, 0)
}

// EncodeUpdateAssetWithCorrelation encodes C_UpdateAsset request with a trailing correlation_id.
func EncodeUpdateAssetWithCorrelation(convID int64, assetID uint64, preview, payload string, correlationID uint32) []byte {
	return EncodeUpdateAssetWithMetadataAndCorrelation(convID, assetID, AssetPayloadEncodingPlain, uint32(len(payload)), preview, payload, correlationID)
}

// EncodeUpdateAssetWithAttachments encodes C_UpdateAsset request with attachments.
func EncodeUpdateAssetWithAttachments(convID int64, assetID uint64, preview, payload string, attachments []Attachment) ([]byte, error) {
	return EncodeUpdateAssetWithAttachmentsAndCorrelation(convID, assetID, preview, payload, attachments, 0)
}

// EncodeUpdateAssetWithAttachmentsAndCorrelation encodes C_UpdateAsset request
// with attachments and a trailing correlation_id.
func EncodeUpdateAssetWithAttachmentsAndCorrelation(convID int64, assetID uint64, preview, payload string, attachments []Attachment, correlationID uint32) ([]byte, error) {
	return EncodeUpdateAssetWithMetadataAttachmentsAndCorrelation(convID, assetID, AssetPayloadEncodingPlain, uint32(len(payload)), preview, payload, attachments, correlationID)
}

// EncodeUpdateAssetWithMetadata encodes C_UpdateAsset with explicit payload metadata.
func EncodeUpdateAssetWithMetadata(convID int64, assetID uint64, payloadEncoding uint8, payloadRawLen uint32, preview, payload string) []byte {
	return EncodeUpdateAssetWithMetadataAndCorrelation(convID, assetID, payloadEncoding, payloadRawLen, preview, payload, 0)
}

// EncodeUpdateAssetWithMetadataAndCorrelation encodes C_UpdateAsset with explicit payload metadata and trailing correlation_id.
func EncodeUpdateAssetWithMetadataAndCorrelation(convID int64, assetID uint64, payloadEncoding uint8, payloadRawLen uint32, preview, payload string, correlationID uint32) []byte {
	data, _ := EncodeUpdateAssetWithMetadataAttachmentsAndCorrelation(convID, assetID, payloadEncoding, payloadRawLen, preview, payload, nil, correlationID)
	return data
}

// EncodeUpdateAssetWithMetadataAttachmentsAndCorrelation encodes C_UpdateAsset
// with explicit payload metadata, attachments, and trailing correlation_id.
func EncodeUpdateAssetWithMetadataAttachmentsAndCorrelation(convID int64, assetID uint64, payloadEncoding uint8, payloadRawLen uint32, preview, payload string, attachments []Attachment, correlationID uint32) ([]byte, error) {
	if err := validateAssetPayloadForEncode(payloadEncoding, payloadRawLen, preview, payload); err != nil {
		return nil, err
	}
	if err := validateAssetAttachmentsForEncode(attachments); err != nil {
		return nil, err
	}
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, assetID)
	buf.WriteByte(payloadEncoding)
	binary.Write(buf, binary.BigEndian, payloadRawLen)
	writeString(buf, preview)
	writeString(buf, payload)
	buf.Write(EncodeAttachments(attachments))
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes(), nil
}

func validateAssetPayloadForEncode(payloadEncoding uint8, payloadRawLen uint32, preview, payload string) error {
	if len(preview) > MaxPreviewLength {
		return fmt.Errorf("preview too large: %d > %d", len(preview), MaxPreviewLength)
	}
	if len(payload) > MaxPayloadLength {
		return fmt.Errorf("payload too large: %d > %d", len(payload), MaxPayloadLength)
	}
	if payloadRawLen > MaxPayloadLength {
		return fmt.Errorf("raw payload too large: %d > %d", payloadRawLen, MaxPayloadLength)
	}
	if payloadEncoding != AssetPayloadEncodingPlain && payloadEncoding != AssetPayloadEncodingZstd {
		return fmt.Errorf("unsupported asset payload encoding: %d", payloadEncoding)
	}
	if payloadEncoding == AssetPayloadEncodingPlain && payloadRawLen != uint32(len(payload)) {
		return fmt.Errorf("plain payload_raw_len mismatch: raw_len=%d payload_len=%d", payloadRawLen, len(payload))
	}
	return nil
}

func validateAssetAttachmentsForEncode(attachments []Attachment) error {
	if len(attachments) > maxAssetAttachments {
		return fmt.Errorf("too many attachments: %d > %d", len(attachments), maxAssetAttachments)
	}
	for i, att := range attachments {
		if len(att.FileId) > maxFileIDLength {
			return fmt.Errorf("attachment %d file_id too long: %d > %d", i, len(att.FileId), maxFileIDLength)
		}
		if len(att.Filename) > maxFilenameLength {
			return fmt.Errorf("attachment %d filename too long: %d > %d", i, len(att.Filename), maxFilenameLength)
		}
		if len(att.MimeType) > maxMimeTypeLength {
			return fmt.Errorf("attachment %d mime_type too long: %d > %d", i, len(att.MimeType), maxMimeTypeLength)
		}
	}
	return nil
}

// EncodeUpdateAssetZstd encodes C_UpdateAsset with zstd-compressed payload and metadata.
func EncodeUpdateAssetZstd(convID int64, assetID uint64, preview, payload string) ([]byte, error) {
	return EncodeUpdateAssetZstdWithCorrelation(convID, assetID, preview, payload, 0)
}

// EncodeUpdateAssetZstdWithCorrelation encodes C_UpdateAsset with zstd payload and trailing correlation_id.
func EncodeUpdateAssetZstdWithCorrelation(convID int64, assetID uint64, preview, payload string, correlationID uint32) ([]byte, error) {
	compressedPayload, rawLen, err := CompressAssetPayloadZstd(payload)
	if err != nil {
		return nil, err
	}

	return EncodeUpdateAssetWithMetadataAndCorrelation(convID, assetID, AssetPayloadEncodingZstd, rawLen, preview, compressedPayload, correlationID), nil
}

// EncodeDeleteAsset encodes C_DeleteAsset request. Format: conv_id(8) + asset_id(8)
func EncodeDeleteAsset(convID int64, assetID uint64) []byte {
	return EncodeDeleteAssetWithCorrelation(convID, assetID, 0)
}

// EncodeDeleteAssetWithCorrelation encodes C_DeleteAsset request with a trailing correlation_id.
func EncodeDeleteAssetWithCorrelation(convID int64, assetID uint64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, assetID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeGetAsset encodes C_GetAsset request. Format: conv_id(8) + asset_id(8)
func EncodeGetAsset(convID int64, assetID uint64) []byte {
	return EncodeGetAssetWithCorrelation(convID, assetID, 0)
}

// EncodeGetAssetWithCorrelation encodes C_GetAsset request with a trailing correlation_id.
func EncodeGetAssetWithCorrelation(convID int64, assetID uint64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, assetID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListAssets encodes C_ListAssets request.
func EncodeListAssets(convID int64, filterByType bool, assetType uint16, fullContent bool) []byte {
	return EncodeListAssetsWithCorrelation(convID, filterByType, assetType, fullContent, 0)
}

// EncodeListAssetsWithCorrelation encodes C_ListAssets request with a trailing correlation_id.
func EncodeListAssetsWithCorrelation(convID int64, filterByType bool, assetType uint16, fullContent bool, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	if filterByType {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	binary.Write(buf, binary.BigEndian, assetType)
	if fullContent {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListAssetsPaged encodes C_ListAssetsPaged request.
func EncodeListAssetsPaged(convID int64, assetType uint16, fullContent bool, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64) []byte {
	return EncodeListAssetsPagedWithCorrelation(convID, assetType, fullContent, limit, hasCursor, cursorUpdatedAt, cursorAssetID, 0)
}

// EncodeListAssetsPagedWithCorrelation encodes C_ListAssetsPaged request with a trailing correlation_id.
func EncodeListAssetsPagedWithCorrelation(convID int64, assetType uint16, fullContent bool, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, assetType)
	if fullContent {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	binary.Write(buf, binary.BigEndian, limit)
	if hasCursor {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}

	if hasCursor {
		binary.Write(buf, binary.BigEndian, cursorUpdatedAt)
		binary.Write(buf, binary.BigEndian, cursorAssetID)
		binary.Write(buf, binary.BigEndian, correlationID)
	} else {
		// Parser enforces a 22-byte minimum, so preserve legacy padding when no cursor is present.
		binary.Write(buf, binary.BigEndian, correlationID)
		binary.Write(buf, binary.BigEndian, uint64(0))
	}

	return buf.Bytes()
}

// EncodeListAssetsPagedByProject encodes C_ListAssetsPagedByProject request.
func EncodeListAssetsPagedByProject(convID int64, assetType uint16, fullContent bool, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64, project string) []byte {
	return EncodeListAssetsPagedByProjectWithCorrelation(convID, assetType, fullContent, limit, hasCursor, cursorUpdatedAt, cursorAssetID, project, 0)
}

// EncodeListAssetsPagedByProjectWithCorrelation encodes C_ListAssetsPagedByProject request with a trailing correlation_id.
func EncodeListAssetsPagedByProjectWithCorrelation(convID int64, assetType uint16, fullContent bool, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64, project string, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, assetType)
	if fullContent {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	binary.Write(buf, binary.BigEndian, limit)
	if hasCursor {
		buf.WriteByte(1)
		binary.Write(buf, binary.BigEndian, cursorUpdatedAt)
		binary.Write(buf, binary.BigEndian, cursorAssetID)
	} else {
		buf.WriteByte(0)
	}
	writeString(buf, project)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListAssetsPagedByTag encodes C_ListAssetsPagedByTag request.
func EncodeListAssetsPagedByTag(convID int64, assetType uint16, fullContent bool, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64, tag string) []byte {
	return EncodeListAssetsPagedByTagWithCorrelation(convID, assetType, fullContent, limit, hasCursor, cursorUpdatedAt, cursorAssetID, tag, 0)
}

// EncodeListAssetsPagedByTagWithCorrelation encodes C_ListAssetsPagedByTag request with a trailing correlation_id.
func EncodeListAssetsPagedByTagWithCorrelation(convID int64, assetType uint16, fullContent bool, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64, tag string, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, assetType)
	if fullContent {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	binary.Write(buf, binary.BigEndian, limit)
	if hasCursor {
		buf.WriteByte(1)
		binary.Write(buf, binary.BigEndian, cursorUpdatedAt)
		binary.Write(buf, binary.BigEndian, cursorAssetID)
	} else {
		buf.WriteByte(0)
	}
	writeString(buf, tag)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListNoteProjects encodes C_ListNoteProjects request.
func EncodeListNoteProjects(convID int64) []byte {
	return EncodeListNoteProjectsWithCorrelation(convID, 0)
}

// EncodeListNoteProjectsWithCorrelation encodes C_ListNoteProjects request with a trailing correlation_id.
func EncodeListNoteProjectsWithCorrelation(convID int64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListNoteTags encodes C_ListNoteTags request.
func EncodeListNoteTags(convID int64) []byte {
	return EncodeListNoteTagsWithCorrelation(convID, 0)
}

// EncodeListNoteTagsWithCorrelation encodes C_ListNoteTags request with a trailing correlation_id.
func EncodeListNoteTagsWithCorrelation(convID int64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}
