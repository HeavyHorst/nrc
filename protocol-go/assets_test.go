package protocol

import (
	"bytes"
	"encoding/binary"
	"reflect"
	"strings"
	"testing"
)

func buildFullAssetBinary(a Asset) []byte {
	attachments := EncodeAttachments(a.Attachments)
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

func buildAssetHeaderBinary(a Asset) []byte {
	attachments := EncodeAttachments(a.Attachments)
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

func assertAssetEqual(t *testing.T, got, want Asset) {
	t.Helper()
	if got.AssetType != want.AssetType {
		t.Errorf("AssetType = %d, want %d", got.AssetType, want.AssetType)
	}
	if got.AssetID != want.AssetID {
		t.Errorf("AssetID = %d, want %d", got.AssetID, want.AssetID)
	}
	if got.ParentType != want.ParentType {
		t.Errorf("ParentType = %d, want %d", got.ParentType, want.ParentType)
	}
	if got.ParentID != want.ParentID {
		t.Errorf("ParentID = %d, want %d", got.ParentID, want.ParentID)
	}
	if got.Owner != want.Owner {
		t.Errorf("Owner = %q, want %q", got.Owner, want.Owner)
	}
	if got.CreatedAt != want.CreatedAt {
		t.Errorf("CreatedAt = %d, want %d", got.CreatedAt, want.CreatedAt)
	}
	if got.UpdatedAt != want.UpdatedAt {
		t.Errorf("UpdatedAt = %d, want %d", got.UpdatedAt, want.UpdatedAt)
	}
	if got.ConvID != want.ConvID {
		t.Errorf("ConvID = %d, want %d", got.ConvID, want.ConvID)
	}
	if got.PayloadEncoding != want.PayloadEncoding {
		t.Errorf("PayloadEncoding = %d, want %d", got.PayloadEncoding, want.PayloadEncoding)
	}
	if got.PayloadRawLen != want.PayloadRawLen {
		t.Errorf("PayloadRawLen = %d, want %d", got.PayloadRawLen, want.PayloadRawLen)
	}
	if got.Preview != want.Preview {
		t.Errorf("Preview = %q, want %q", got.Preview, want.Preview)
	}
	if got.Payload != want.Payload {
		t.Errorf("Payload = %q, want %q", got.Payload, want.Payload)
	}
	if len(got.Attachments) == 0 && len(want.Attachments) == 0 {
		return
	}
	if !reflect.DeepEqual(got.Attachments, want.Attachments) {
		t.Errorf("Attachments = %#v, want %#v", got.Attachments, want.Attachments)
	}
}

func TestParseAssetFull(t *testing.T) {
	want := Asset{
		AssetType: AssetTypeDocument, AssetID: 1001,
		ParentType: ParentTypeTask, ParentID: 500,
		Owner: "alice", CreatedAt: 1700000000, UpdatedAt: 1700001000,
		ConvID: 42, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: uint32(len("full document body")), Preview: "hello world", Payload: "full document body",
	}

	data := buildFullAssetBinary(want)
	got, endOff := ParseAssetFull(data, 0)

	if endOff != len(data) {
		t.Errorf("offset = %d, want %d", endOff, len(data))
	}
	assertAssetEqual(t, got, want)
}

func TestParseAssetFullNonZeroOffset(t *testing.T) {
	want := Asset{AssetType: AssetTypeAgenda, AssetID: 555, Owner: "bob", ConvID: 10, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: uint32(len("pay")), Preview: "p", Payload: "pay"}
	assetBytes := buildFullAssetBinary(want)
	prefix := []byte{0xDE, 0xAD, 0xBE, 0xEF}
	data := append(prefix, assetBytes...)

	got, endOff := ParseAssetFull(data, len(prefix))
	if endOff != len(data) {
		t.Errorf("offset = %d, want %d", endOff, len(data))
	}
	assertAssetEqual(t, got, want)
}

func TestParseAssetFullTruncated(t *testing.T) {
	want := Asset{AssetType: AssetTypeComment, AssetID: 1, Owner: "x", ConvID: 1, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: uint32(len("body")), Preview: "p", Payload: "body"}
	data := buildFullAssetBinary(want)

	got, _ := ParseAssetFull(data[:3], 0)
	if got.AssetID != 0 {
		t.Errorf("expected zero AssetID for truncated data, got %d", got.AssetID)
	}
}

func TestParseAssetHeader(t *testing.T) {
	want := Asset{
		AssetType: AssetTypeNote, AssetID: 777,
		ParentType: ParentTypeAsset, ParentID: 300,
		Owner: "charlie", CreatedAt: 1700000000, UpdatedAt: 1700005000,
		ConvID: 55, Preview: "note preview",
	}

	data := buildAssetHeaderBinary(want)
	got, endOff := ParseAssetHeader(data, 0)

	if endOff != len(data) {
		t.Errorf("offset = %d, want %d", endOff, len(data))
	}
	if got.Payload != "" {
		t.Errorf("Payload should be empty for header parse, got %q", got.Payload)
	}
	if got.AssetType != want.AssetType {
		t.Errorf("AssetType = %d, want %d", got.AssetType, want.AssetType)
	}
	if got.AssetID != want.AssetID {
		t.Errorf("AssetID = %d, want %d", got.AssetID, want.AssetID)
	}
	if got.Preview != want.Preview {
		t.Errorf("Preview = %q, want %q", got.Preview, want.Preview)
	}
}

func TestParseAssetFullMultiple(t *testing.T) {
	a1 := Asset{AssetType: AssetTypeComment, AssetID: 1, Owner: "a", ConvID: 10, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: uint32(len("body1")), Preview: "p1", Payload: "body1"}
	a2 := Asset{AssetType: AssetTypeDocument, AssetID: 2, Owner: "b", ConvID: 10, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: uint32(len("body2")), Preview: "p2", Payload: "body2"}
	data := append(buildFullAssetBinary(a1), buildFullAssetBinary(a2)...)

	got1, off := ParseAssetFull(data, 0)
	if got1.AssetID != 1 {
		t.Errorf("first AssetID = %d, want 1", got1.AssetID)
	}
	got2, off2 := ParseAssetFull(data, off)
	if got2.AssetID != 2 {
		t.Errorf("second AssetID = %d, want 2", got2.AssetID)
	}
	if off2 != len(data) {
		t.Errorf("final offset = %d, want %d", off2, len(data))
	}
}

func TestDecodeAssetCreated(t *testing.T) {
	wantAsset := Asset{
		AssetType:       AssetTypeNote,
		AssetID:         111,
		ParentType:      ParentTypeNone,
		ParentID:        0,
		Owner:           "alice",
		CreatedAt:       1700000100,
		UpdatedAt:       1700000100,
		ConvID:          42,
		PayloadEncoding: AssetPayloadEncodingPlain,
		PayloadRawLen:   uint32(len("payload")),
		Preview:         "preview",
		Payload:         "payload",
	}

	payload := buildFullAssetBinary(wantAsset)
	buf := make([]byte, 0, len(payload)+4)
	buf = append(buf, payload...)
	corr := make([]byte, 4)
	binary.BigEndian.PutUint32(corr, 77)
	buf = append(buf, corr...)

	decoded, err := DecodeAssetCreated(buf)
	if err != nil {
		t.Fatalf("DecodeAssetCreated error: %v", err)
	}

	if decoded.CorrelationID != 77 {
		t.Fatalf("CorrelationID = %d, want 77", decoded.CorrelationID)
	}
	assertAssetEqual(t, decoded.Asset, wantAsset)
}

func TestDecodeAssetCreatedMissingCorrelationID(t *testing.T) {
	asset := Asset{AssetType: AssetTypeNote, AssetID: 1, Owner: "a", ConvID: 2, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: uint32(len("x")), Preview: "p", Payload: "x"}
	payload := buildFullAssetBinary(asset)

	_, err := DecodeAssetCreated(payload)
	if err == nil {
		t.Fatal("expected error for missing correlation_id")
	}
}

func TestDecodeAssetCreatedTrailingBytes(t *testing.T) {
	asset := Asset{AssetType: AssetTypeNote, AssetID: 1, Owner: "a", ConvID: 2, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: uint32(len("x")), Preview: "p", Payload: "x"}
	payload := buildFullAssetBinary(asset)
	buf := make([]byte, 0, len(payload)+5)
	buf = append(buf, payload...)
	corr := make([]byte, 4)
	binary.BigEndian.PutUint32(corr, 1)
	buf = append(buf, corr...)
	buf = append(buf, 0xff)

	_, err := DecodeAssetCreated(buf)
	if err == nil {
		t.Fatal("expected error for trailing bytes")
	}
}

func TestDecodeAssetFullDecodesZstdPayload(t *testing.T) {
	rawPayload := strings.Repeat("educap-manual-", 32)
	compressedPayload, rawLen, err := CompressAssetPayloadZstd(rawPayload)
	if err != nil {
		t.Fatalf("CompressAssetPayloadZstd error: %v", err)
	}

	asset := Asset{
		AssetType:       AssetTypeNote,
		AssetID:         42,
		Owner:           "alice",
		ConvID:          7,
		PayloadEncoding: AssetPayloadEncodingZstd,
		PayloadRawLen:   rawLen,
		Preview:         "preview",
		Payload:         compressedPayload,
	}

	decoded, err := DecodeAssetFull(buildFullAssetBinary(asset))
	if err != nil {
		t.Fatalf("DecodeAssetFull error: %v", err)
	}

	if decoded.Payload != rawPayload {
		t.Fatalf("Payload = %q, want %q", decoded.Payload, rawPayload)
	}
	if decoded.PayloadEncoding != AssetPayloadEncodingPlain {
		t.Fatalf("PayloadEncoding = %d, want %d", decoded.PayloadEncoding, AssetPayloadEncodingPlain)
	}
	if decoded.PayloadRawLen != uint32(len(rawPayload)) {
		t.Fatalf("PayloadRawLen = %d, want %d", decoded.PayloadRawLen, len(rawPayload))
	}
}

func TestDecodeAssetCreatedDecodesZstdPayload(t *testing.T) {
	rawPayload := strings.Repeat("search-index-", 24)
	compressedPayload, rawLen, err := CompressAssetPayloadZstd(rawPayload)
	if err != nil {
		t.Fatalf("CompressAssetPayloadZstd error: %v", err)
	}

	asset := Asset{
		AssetType:       AssetTypeDocument,
		AssetID:         77,
		Owner:           "bot",
		ConvID:          9,
		PayloadEncoding: AssetPayloadEncodingZstd,
		PayloadRawLen:   rawLen,
		Preview:         "preview",
		Payload:         compressedPayload,
	}

	payload := append(buildFullAssetBinary(asset), []byte{0, 0, 0, 5}...)
	decoded, err := DecodeAssetCreated(payload)
	if err != nil {
		t.Fatalf("DecodeAssetCreated error: %v", err)
	}

	if decoded.Asset.Payload != rawPayload {
		t.Fatalf("Payload = %q, want %q", decoded.Asset.Payload, rawPayload)
	}
	if decoded.Asset.PayloadEncoding != AssetPayloadEncodingPlain {
		t.Fatalf("PayloadEncoding = %d, want %d", decoded.Asset.PayloadEncoding, AssetPayloadEncodingPlain)
	}
}

func TestEncodeCreateAssetWireFormat(t *testing.T) {
	data := EncodeCreateAsset(42, AssetTypeDocument, ParentTypeTask, 100, "prev", "payload")
	off := 0
	convID := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if convID != 42 {
		t.Errorf("convID = %d, want 42", convID)
	}
	assetType := binary.BigEndian.Uint16(data[off:])
	off += 2
	if assetType != AssetTypeDocument {
		t.Errorf("assetType = %d, want %d", assetType, AssetTypeDocument)
	}
	parentType := binary.BigEndian.Uint16(data[off:])
	off += 2
	if parentType != ParentTypeTask {
		t.Errorf("parentType = %d, want %d", parentType, ParentTypeTask)
	}
	parentID := binary.BigEndian.Uint64(data[off:])
	off += 8
	if parentID != 100 {
		t.Errorf("parentID = %d, want 100", parentID)
	}
	if data[off] != AssetPayloadEncodingPlain {
		t.Errorf("payloadEncoding = %d, want %d", data[off], AssetPayloadEncodingPlain)
	}
	off += 1
	rawLen := binary.BigEndian.Uint32(data[off:])
	if rawLen != uint32(len("payload")) {
		t.Errorf("payloadRawLen = %d, want %d", rawLen, len("payload"))
	}
	off += 4
	prevLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	off += int(prevLen)
	payLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	off += int(payLen)
	attachmentCount := binary.BigEndian.Uint16(data[off:])
	off += 2
	if attachmentCount != 0 {
		t.Errorf("attachment_count = %d, want 0", attachmentCount)
	}
	corr := binary.BigEndian.Uint32(data[off:])
	off += 4
	if corr != 0 {
		t.Errorf("correlation_id = %d, want 0", corr)
	}
	if off != len(data) {
		t.Errorf("consumed %d bytes, data is %d", off, len(data))
	}
}

func TestEncodeCreateAssetWithCorrelationWireFormat(t *testing.T) {
	data := EncodeCreateAssetWithCorrelation(42, AssetTypeDocument, ParentTypeTask, 100, "prev", "payload", 0x01020304)

	if len(data) < 4 {
		t.Fatalf("encoded create asset payload too short: %d", len(data))
	}
	gotCorr := binary.BigEndian.Uint32(data[len(data)-4:])
	if gotCorr != 0x01020304 {
		t.Fatalf("correlation_id = 0x%08X, want 0x01020304", gotCorr)
	}
}

func TestEncodeCreateAndUpdateAssetWithAttachmentsWireFormat(t *testing.T) {
	attachments := []Attachment{{FileId: "att-note-1", Filename: "diagram.png", Size: 42, MimeType: "image/png", UploadedAt: 123}}

	createData, err := EncodeCreateAssetWithAttachmentsAndCorrelation(42, AssetTypeNote, ParentTypeNone, 0, "prev", "payload", attachments, 0x01020304)
	if err != nil {
		t.Fatalf("EncodeCreateAssetWithAttachmentsAndCorrelation error: %v", err)
	}
	if binary.BigEndian.Uint32(createData[len(createData)-4:]) != 0x01020304 {
		t.Fatalf("create correlation suffix mismatch")
	}
	decodedCreateAttachments, err := DecodeAttachments(bytes.NewReader(createData[len(createData)-4-len(EncodeAttachments(attachments)) : len(createData)-4]))
	if err != nil {
		t.Fatalf("Decode create attachments error: %v", err)
	}
	if !reflect.DeepEqual(decodedCreateAttachments, attachments) {
		t.Fatalf("create attachments = %#v, want %#v", decodedCreateAttachments, attachments)
	}

	updateData, err := EncodeUpdateAssetWithAttachmentsAndCorrelation(42, 9, "prev", "payload", attachments, 0x05060708)
	if err != nil {
		t.Fatalf("EncodeUpdateAssetWithAttachmentsAndCorrelation error: %v", err)
	}
	if binary.BigEndian.Uint32(updateData[len(updateData)-4:]) != 0x05060708 {
		t.Fatalf("update correlation suffix mismatch")
	}
	decodedUpdateAttachments, err := DecodeAttachments(bytes.NewReader(updateData[len(updateData)-4-len(EncodeAttachments(attachments)) : len(updateData)-4]))
	if err != nil {
		t.Fatalf("Decode update attachments error: %v", err)
	}
	if !reflect.DeepEqual(decodedUpdateAttachments, attachments) {
		t.Fatalf("update attachments = %#v, want %#v", decodedUpdateAttachments, attachments)
	}
}

func TestEncodeAssetWithAttachmentsRejectsInvalidMetadata(t *testing.T) {
	tooMany := make([]Attachment, MaxAttachmentsPerTask+1)
	if _, err := EncodeCreateAssetWithAttachments(42, AssetTypeNote, ParentTypeNone, 0, "p", "x", tooMany); err == nil {
		t.Fatalf("expected too many attachments error")
	}
	if _, err := EncodeUpdateAssetWithAttachments(42, 1, "p", "x", []Attachment{{FileId: strings.Repeat("x", maxFileIDLength+1)}}); err == nil {
		t.Fatalf("expected file_id length error")
	}
}

func TestEncodeUpdateAssetWireFormat(t *testing.T) {
	data := EncodeUpdateAsset(10, 20, "p", "pay")
	if len(data) != 8+8+1+4+2+1+2+3+2+4 {
		t.Errorf("unexpected length %d", len(data))
	}
}

func TestEncodeDeleteAssetWireFormat(t *testing.T) {
	data := EncodeDeleteAsset(10, 20)
	if len(data) != 20 {
		t.Fatalf("expected 20 bytes, got %d", len(data))
	}
}

func TestEncodeGetAssetWireFormat(t *testing.T) {
	data := EncodeGetAsset(10, 20)
	if len(data) != 20 {
		t.Fatalf("expected 20 bytes, got %d", len(data))
	}
}

func TestEncodeListAssetsWireFormat(t *testing.T) {
	data := EncodeListAssets(10, true, AssetTypeDocument, false)
	off := 0
	off += 8 // conv_id
	if data[off] != 1 {
		t.Errorf("filter_by_type = %d, want 1", data[off])
	}
	off += 1
	assetType := binary.BigEndian.Uint16(data[off:])
	off += 2
	if assetType != AssetTypeDocument {
		t.Errorf("assetType = %d, want %d", assetType, AssetTypeDocument)
	}
	if data[off] != 0 {
		t.Errorf("full_content = %d, want 0", data[off])
	}
	off += 1
	if got := binary.BigEndian.Uint32(data[off:]); got != 0 {
		t.Errorf("correlation_id = %d, want 0", got)
	}
}

func TestEncodeListAssetsPagedWireFormat(t *testing.T) {
	data := EncodeListAssetsPaged(55, AssetTypeNote, true, 25, true, 123456789, 777)
	off := 0

	convID := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if convID != 55 {
		t.Fatalf("conv_id = %d, want 55", convID)
	}

	assetType := binary.BigEndian.Uint16(data[off:])
	off += 2
	if assetType != AssetTypeNote {
		t.Fatalf("asset_type = %d, want %d", assetType, AssetTypeNote)
	}

	if data[off] != 1 {
		t.Fatalf("full_content = %d, want 1", data[off])
	}
	off += 1

	limit := binary.BigEndian.Uint16(data[off:])
	off += 2
	if limit != 25 {
		t.Fatalf("limit = %d, want 25", limit)
	}

	if data[off] != 1 {
		t.Fatalf("has_cursor = %d, want 1", data[off])
	}
	off += 1

	cursorUpdatedAt := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if cursorUpdatedAt != 123456789 {
		t.Fatalf("cursor_updated_at = %d, want 123456789", cursorUpdatedAt)
	}

	cursorAssetID := binary.BigEndian.Uint64(data[off:])
	off += 8
	if cursorAssetID != 777 {
		t.Fatalf("cursor_asset_id = %d, want 777", cursorAssetID)
	}

	if got := binary.BigEndian.Uint32(data[off:]); got != 0 {
		t.Fatalf("correlation_id = %d, want 0", got)
	}
	off += 4

	if off != len(data) {
		t.Fatalf("encoded length mismatch: consumed=%d total=%d", off, len(data))
	}
}

func TestEncodeListAssetsPagedByProjectWireFormat(t *testing.T) {
	data := EncodeListAssetsPagedByProject(55, AssetTypeNote, false, 25, true, 123456789, 777, "infra")
	off := 0

	convID := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if convID != 55 {
		t.Fatalf("conv_id = %d, want 55", convID)
	}

	assetType := binary.BigEndian.Uint16(data[off:])
	off += 2
	if assetType != AssetTypeNote {
		t.Fatalf("asset_type = %d, want %d", assetType, AssetTypeNote)
	}

	if data[off] != 0 {
		t.Fatalf("full_content = %d, want 0", data[off])
	}
	off += 1

	limit := binary.BigEndian.Uint16(data[off:])
	off += 2
	if limit != 25 {
		t.Fatalf("limit = %d, want 25", limit)
	}

	if data[off] != 1 {
		t.Fatalf("has_cursor = %d, want 1", data[off])
	}
	off += 1

	cursorUpdatedAt := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if cursorUpdatedAt != 123456789 {
		t.Fatalf("cursor_updated_at = %d, want 123456789", cursorUpdatedAt)
	}

	cursorAssetID := binary.BigEndian.Uint64(data[off:])
	off += 8
	if cursorAssetID != 777 {
		t.Fatalf("cursor_asset_id = %d, want 777", cursorAssetID)
	}

	projectLen := int(binary.BigEndian.Uint16(data[off:]))
	off += 2
	if project := string(data[off : off+projectLen]); project != "infra" {
		t.Fatalf("project = %q, want %q", project, "infra")
	}
	off += projectLen

	if got := binary.BigEndian.Uint32(data[off:]); got != 0 {
		t.Fatalf("correlation_id = %d, want 0", got)
	}
	off += 4

	if off != len(data) {
		t.Fatalf("encoded length mismatch: consumed=%d total=%d", off, len(data))
	}
}

func TestEncodeListAssetsPagedByProjectWithoutCursorWireFormat(t *testing.T) {
	data := EncodeListAssetsPagedByProjectWithCorrelation(10, AssetTypeNote, false, 0, false, 0, 0, "ops", 0x01020304)
	if wantLen := 20 + len("ops"); len(data) != wantLen {
		t.Fatalf("encoded length = %d, want %d", len(data), wantLen)
	}
	if data[13] != 0 {
		t.Fatalf("has_cursor = %d, want 0", data[13])
	}
	if got := binary.BigEndian.Uint16(data[14:16]); got != uint16(len("ops")) {
		t.Fatalf("project_len = %d, want %d", got, len("ops"))
	}
	if got := string(data[16:19]); got != "ops" {
		t.Fatalf("project = %q, want %q", got, "ops")
	}
	if got := binary.BigEndian.Uint32(data[19:23]); got != 0x01020304 {
		t.Fatalf("correlation_id = 0x%08X, want 0x01020304", got)
	}
}

func TestEncodeListAssetsPagedByTagWireFormat(t *testing.T) {
	data := EncodeListAssetsPagedByTagWithCorrelation(10, AssetTypeNote, false, 0, false, 0, 0, "ops", 0x01020304)
	if wantLen := 20 + len("ops"); len(data) != wantLen {
		t.Fatalf("encoded length = %d, want %d", len(data), wantLen)
	}
	if data[13] != 0 {
		t.Fatalf("has_cursor = %d, want 0", data[13])
	}
	if got := binary.BigEndian.Uint16(data[14:16]); got != uint16(len("ops")) {
		t.Fatalf("tag_len = %d, want %d", got, len("ops"))
	}
	if got := string(data[16:19]); got != "ops" {
		t.Fatalf("tag = %q, want %q", got, "ops")
	}
	if got := binary.BigEndian.Uint32(data[19:23]); got != 0x01020304 {
		t.Fatalf("correlation_id = 0x%08X, want 0x01020304", got)
	}
}

func TestEncodeListNoteProjectsWireFormat(t *testing.T) {
	data := EncodeListNoteProjectsWithCorrelation(42, 0xAABBCCDD)
	if len(data) != 12 {
		t.Fatalf("encoded length = %d, want 12", len(data))
	}
	if got := int64(binary.BigEndian.Uint64(data[0:8])); got != 42 {
		t.Fatalf("conv_id = %d, want 42", got)
	}
	if got := binary.BigEndian.Uint32(data[8:12]); got != 0xAABBCCDD {
		t.Fatalf("correlation_id = 0x%08X, want 0xAABBCCDD", got)
	}
}

func TestEncodeListNoteTagsWireFormat(t *testing.T) {
	data := EncodeListNoteTagsWithCorrelation(42, 0xAABBCCDD)
	if len(data) != 12 {
		t.Fatalf("encoded length = %d, want 12", len(data))
	}
	if got := int64(binary.BigEndian.Uint64(data[0:8])); got != 42 {
		t.Fatalf("conv_id = %d, want 42", got)
	}
	if got := binary.BigEndian.Uint32(data[8:12]); got != 0xAABBCCDD {
		t.Fatalf("correlation_id = 0x%08X, want 0xAABBCCDD", got)
	}
}

func TestDecodeAssetListPage(t *testing.T) {
	asset1 := Asset{
		AssetType:       AssetTypeNote,
		AssetID:         5,
		Owner:           "a",
		CreatedAt:       10,
		UpdatedAt:       100,
		ConvID:          44,
		PayloadEncoding: AssetPayloadEncodingPlain,
		PayloadRawLen:   3,
		Preview:         "p1",
		Attachments:     []Attachment{{FileId: "att-page-1", Filename: "page.png", Size: 10, MimeType: "image/png", UploadedAt: 11}},
	}
	asset2 := Asset{
		AssetType:       AssetTypeNote,
		AssetID:         4,
		Owner:           "b",
		CreatedAt:       11,
		UpdatedAt:       90,
		ConvID:          44,
		PayloadEncoding: AssetPayloadEncodingPlain,
		PayloadRawLen:   2,
		Preview:         "p2",
	}

	payload := make([]byte, 0, 128)
	header := make([]byte, 36)
	binary.BigEndian.PutUint64(header[0:], 44)
	header[8] = 0
	header[9] = 1
	binary.BigEndian.PutUint64(header[10:], uint64(90))
	binary.BigEndian.PutUint64(header[18:], 4)
	binary.BigEndian.PutUint32(header[26:], 17)
	binary.BigEndian.PutUint16(header[30:], 2)
	binary.BigEndian.PutUint32(header[32:], 0x11223344)
	payload = append(payload, header...)
	payload = append(payload, buildAssetHeaderBinary(asset1)...)
	payload = append(payload, buildAssetHeaderBinary(asset2)...)

	decoded, err := DecodeAssetListPage(payload)
	if err != nil {
		t.Fatalf("DecodeAssetListPage error: %v", err)
	}
	if decoded.ConvID != 44 {
		t.Fatalf("ConvID = %d, want 44", decoded.ConvID)
	}
	if decoded.FullContent {
		t.Fatalf("FullContent = true, want false")
	}
	if !decoded.HasMore {
		t.Fatalf("HasMore = false, want true")
	}
	if decoded.NextCursorUpdatedAt != 90 {
		t.Fatalf("NextCursorUpdatedAt = %d, want 90", decoded.NextCursorUpdatedAt)
	}
	if decoded.NextCursorAssetID != 4 {
		t.Fatalf("NextCursorAssetID = %d, want 4", decoded.NextCursorAssetID)
	}
	if decoded.TotalCount != 17 {
		t.Fatalf("TotalCount = %d, want 17", decoded.TotalCount)
	}
	if len(decoded.Assets) != 2 {
		t.Fatalf("asset count = %d, want 2", len(decoded.Assets))
	}
	if decoded.Assets[0].AssetID != 5 || decoded.Assets[1].AssetID != 4 {
		t.Fatalf("decoded asset IDs = [%d,%d], want [5,4]", decoded.Assets[0].AssetID, decoded.Assets[1].AssetID)
	}
	if !reflect.DeepEqual(decoded.Assets[0].Attachments, asset1.Attachments) {
		t.Fatalf("decoded page attachments = %#v, want %#v", decoded.Assets[0].Attachments, asset1.Attachments)
	}
	if len(decoded.Assets[1].Attachments) != 0 {
		t.Fatalf("decoded empty page attachments = %#v, want empty", decoded.Assets[1].Attachments)
	}
	if decoded.CorrelationID != 0x11223344 {
		t.Fatalf("CorrelationID = 0x%08X, want 0x11223344", decoded.CorrelationID)
	}
}

func TestDecodeNoteProjectList(t *testing.T) {
	payload := make([]byte, 0, 64)
	header := make([]byte, 14)
	binary.BigEndian.PutUint64(header[0:], 44)
	binary.BigEndian.PutUint16(header[8:], 2)
	binary.BigEndian.PutUint32(header[10:], 0x11223344)
	payload = append(payload, header...)

	project1 := []byte("infra")
	len1 := make([]byte, 2)
	binary.BigEndian.PutUint16(len1, uint16(len(project1)))
	payload = append(payload, len1...)
	payload = append(payload, project1...)

	project2 := []byte("ops")
	len2 := make([]byte, 2)
	binary.BigEndian.PutUint16(len2, uint16(len(project2)))
	payload = append(payload, len2...)
	payload = append(payload, project2...)

	decoded, err := DecodeNoteProjectList(payload)
	if err != nil {
		t.Fatalf("DecodeNoteProjectList error: %v", err)
	}
	if decoded.ConvID != 44 {
		t.Fatalf("ConvID = %d, want 44", decoded.ConvID)
	}
	if decoded.CorrelationID != 0x11223344 {
		t.Fatalf("CorrelationID = 0x%08X, want 0x11223344", decoded.CorrelationID)
	}
	if !reflect.DeepEqual(decoded.Projects, []string{"infra", "ops"}) {
		t.Fatalf("Projects = %v, want %v", decoded.Projects, []string{"infra", "ops"})
	}
}

func TestDecodeNoteTagList(t *testing.T) {
	payload := make([]byte, 0)
	conv := make([]byte, 8)
	binary.BigEndian.PutUint64(conv, 42)
	payload = append(payload, conv...)
	count := make([]byte, 2)
	binary.BigEndian.PutUint16(count, 2)
	payload = append(payload, count...)
	corr := make([]byte, 4)
	binary.BigEndian.PutUint32(corr, 0x01020304)
	payload = append(payload, corr...)

	tag1 := []byte("infra")
	len1 := make([]byte, 2)
	binary.BigEndian.PutUint16(len1, uint16(len(tag1)))
	payload = append(payload, len1...)
	payload = append(payload, tag1...)
	tag2 := []byte("ops")
	len2 := make([]byte, 2)
	binary.BigEndian.PutUint16(len2, uint16(len(tag2)))
	payload = append(payload, len2...)
	payload = append(payload, tag2...)

	decoded, err := DecodeNoteTagList(payload)
	if err != nil {
		t.Fatalf("DecodeNoteTagList error: %v", err)
	}
	if decoded.ConvID != 42 || decoded.CorrelationID != 0x01020304 {
		t.Fatalf("header = conv:%d corr:%08X", decoded.ConvID, decoded.CorrelationID)
	}
	if !reflect.DeepEqual(decoded.Tags, []string{"infra", "ops"}) {
		t.Fatalf("tags = %v", decoded.Tags)
	}
}

func TestDecodeAssetListResponseFullContentDecodesZstdPayload(t *testing.T) {
	rawPayload := strings.Repeat("full-list-asset-", 20)
	compressedPayload, rawLen, err := CompressAssetPayloadZstd(rawPayload)
	if err != nil {
		t.Fatalf("CompressAssetPayloadZstd error: %v", err)
	}

	asset := Asset{
		AssetType:       AssetTypeNote,
		AssetID:         91,
		Owner:           "indexer",
		CreatedAt:       1,
		UpdatedAt:       2,
		ConvID:          44,
		PayloadEncoding: AssetPayloadEncodingZstd,
		PayloadRawLen:   rawLen,
		Preview:         "preview",
		Payload:         compressedPayload,
	}

	payload := make([]byte, 0, 128)
	header := make([]byte, 15)
	binary.BigEndian.PutUint64(header[0:], 44)
	header[8] = 1
	binary.BigEndian.PutUint16(header[9:], 1)
	binary.BigEndian.PutUint32(header[11:], 0xDEADBEEF)
	payload = append(payload, header...)
	payload = append(payload, buildFullAssetBinary(asset)...)

	decoded, err := DecodeAssetListResponse(payload)
	if err != nil {
		t.Fatalf("DecodeAssetListResponse error: %v", err)
	}
	if len(decoded.Assets) != 1 {
		t.Fatalf("asset count = %d, want 1", len(decoded.Assets))
	}
	if decoded.Assets[0].Payload != rawPayload {
		t.Fatalf("Payload = %q, want %q", decoded.Assets[0].Payload, rawPayload)
	}
	if decoded.Assets[0].PayloadEncoding != AssetPayloadEncodingPlain {
		t.Fatalf("PayloadEncoding = %d, want %d", decoded.Assets[0].PayloadEncoding, AssetPayloadEncodingPlain)
	}
}

func TestDecodeAssetListPageFullContentDecodesZstdPayload(t *testing.T) {
	rawPayload := strings.Repeat("paged-list-asset-", 18)
	compressedPayload, rawLen, err := CompressAssetPayloadZstd(rawPayload)
	if err != nil {
		t.Fatalf("CompressAssetPayloadZstd error: %v", err)
	}

	asset := Asset{
		AssetType:       AssetTypeNote,
		AssetID:         92,
		Owner:           "indexer",
		CreatedAt:       1,
		UpdatedAt:       2,
		ConvID:          44,
		PayloadEncoding: AssetPayloadEncodingZstd,
		PayloadRawLen:   rawLen,
		Preview:         "preview",
		Payload:         compressedPayload,
	}

	payload := make([]byte, 0, 128)
	header := make([]byte, 36)
	binary.BigEndian.PutUint64(header[0:], 44)
	header[8] = 1
	header[9] = 0
	binary.BigEndian.PutUint64(header[10:], 0)
	binary.BigEndian.PutUint64(header[18:], 0)
	binary.BigEndian.PutUint32(header[26:], 1)
	binary.BigEndian.PutUint16(header[30:], 1)
	binary.BigEndian.PutUint32(header[32:], 0xAABBCCDD)
	payload = append(payload, header...)
	payload = append(payload, buildFullAssetBinary(asset)...)

	decoded, err := DecodeAssetListPage(payload)
	if err != nil {
		t.Fatalf("DecodeAssetListPage error: %v", err)
	}
	if len(decoded.Assets) != 1 {
		t.Fatalf("asset count = %d, want 1", len(decoded.Assets))
	}
	if decoded.Assets[0].Payload != rawPayload {
		t.Fatalf("Payload = %q, want %q", decoded.Assets[0].Payload, rawPayload)
	}
	if decoded.Assets[0].PayloadEncoding != AssetPayloadEncodingPlain {
		t.Fatalf("PayloadEncoding = %d, want %d", decoded.Assets[0].PayloadEncoding, AssetPayloadEncodingPlain)
	}
}

func TestCompressAndDecodeAssetPayloadZstd(t *testing.T) {
	rawPayload := strings.Repeat("compress-me-", 128)
	compressedPayload, rawLen, err := CompressAssetPayloadZstd(rawPayload)
	if err != nil {
		t.Fatalf("CompressAssetPayloadZstd error: %v", err)
	}
	if rawLen != uint32(len(rawPayload)) {
		t.Fatalf("rawLen = %d, want %d", rawLen, len(rawPayload))
	}
	if bytes.Equal([]byte(rawPayload), []byte(compressedPayload)) {
		t.Fatalf("expected compressed payload to differ from raw payload")
	}

	decoded, err := DecodeAssetPayload(Asset{
		PayloadEncoding: AssetPayloadEncodingZstd,
		PayloadRawLen:   rawLen,
		Payload:         compressedPayload,
	})
	if err != nil {
		t.Fatalf("DecodeAssetPayload(zstd) error: %v", err)
	}
	if decoded != rawPayload {
		t.Fatalf("decoded payload mismatch")
	}
}

func TestEncodeAssetPayloadRespectsUint16WireLimit(t *testing.T) {
	maxPayload := strings.Repeat("x", MaxPayloadLength)
	data := EncodeCreateAsset(42, AssetTypeNote, ParentTypeNone, 0, "", maxPayload)
	if data == nil {
		t.Fatal("maximum payload was rejected")
	}

	oversizedPayload := maxPayload + "x"
	if data := EncodeCreateAsset(42, AssetTypeNote, ParentTypeNone, 0, "", oversizedPayload); data != nil {
		t.Fatal("oversized payload was encoded despite exceeding uint16 wire limit")
	}
	if _, err := EncodeUpdateAssetWithAttachments(42, 1, "", oversizedPayload, nil); err == nil {
		t.Fatal("oversized update payload was accepted")
	}
}

func TestDecodeAssetPayloadPlainRawLenMismatch(t *testing.T) {
	_, err := DecodeAssetPayload(Asset{
		PayloadEncoding: AssetPayloadEncodingPlain,
		PayloadRawLen:   3,
		Payload:         "abcd",
	})
	if err == nil {
		t.Fatalf("expected raw length mismatch error")
	}
}

func TestEncodeCreateAssetZstdWithCorrelationWireFormat(t *testing.T) {
	payload := strings.Repeat("payload-", 64)
	data, err := EncodeCreateAssetZstdWithCorrelation(42, AssetTypeDocument, ParentTypeTask, 100, "prev", payload, 0x01020304)
	if err != nil {
		t.Fatalf("EncodeCreateAssetZstdWithCorrelation error: %v", err)
	}

	if len(data) < 4 {
		t.Fatalf("encoded payload too short: %d", len(data))
	}
	gotCorr := binary.BigEndian.Uint32(data[len(data)-4:])
	if gotCorr != 0x01020304 {
		t.Fatalf("correlation_id = 0x%08X, want 0x01020304", gotCorr)
	}

	off := 8 + 2 + 2 + 8
	if data[off] != AssetPayloadEncodingZstd {
		t.Fatalf("payloadEncoding = %d, want %d", data[off], AssetPayloadEncodingZstd)
	}
	off += 1
	gotRawLen := binary.BigEndian.Uint32(data[off:])
	if gotRawLen != uint32(len(payload)) {
		t.Fatalf("payloadRawLen = %d, want %d", gotRawLen, len(payload))
	}
}

func TestEncodeUpdateAssetZstdWireFormat(t *testing.T) {
	payload := strings.Repeat("update-payload-", 32)
	data, err := EncodeUpdateAssetZstd(10, 20, "p", payload)
	if err != nil {
		t.Fatalf("EncodeUpdateAssetZstd error: %v", err)
	}

	off := 8 + 8
	if data[off] != AssetPayloadEncodingZstd {
		t.Fatalf("payloadEncoding = %d, want %d", data[off], AssetPayloadEncodingZstd)
	}
	off += 1
	gotRawLen := binary.BigEndian.Uint32(data[off:])
	if gotRawLen != uint32(len(payload)) {
		t.Fatalf("payloadRawLen = %d, want %d", gotRawLen, len(payload))
	}
}

func TestEncodeUpdateAssetWithCorrelationWireFormat(t *testing.T) {
	data := EncodeUpdateAssetWithCorrelation(10, 20, "p", "payload", 0xABCD0102)
	if len(data) < 4 {
		t.Fatalf("encoded payload too short: %d", len(data))
	}
	gotCorr := binary.BigEndian.Uint32(data[len(data)-4:])
	if gotCorr != 0xABCD0102 {
		t.Fatalf("correlation_id = 0x%08X, want 0xABCD0102", gotCorr)
	}
}

func TestEncodeDeleteAssetWithCorrelationWireFormat(t *testing.T) {
	data := EncodeDeleteAssetWithCorrelation(10, 20, 0x11223344)
	if len(data) != 20 {
		t.Fatalf("expected 20 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[16:20]); got != 0x11223344 {
		t.Fatalf("correlation_id = 0x%08X, want 0x11223344", got)
	}
}

func TestDecodeAssetUpdated(t *testing.T) {
	asset := Asset{AssetType: AssetTypeNote, AssetID: 9, Owner: "u", ConvID: 1, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: 1, Preview: "p", Payload: "x"}
	payload := append(buildFullAssetBinary(asset), []byte{0, 0, 0, 7}...)

	decoded, err := DecodeAssetUpdated(payload)
	if err != nil {
		t.Fatalf("DecodeAssetUpdated error: %v", err)
	}
	if decoded.CorrelationID != 7 {
		t.Fatalf("CorrelationID = %d, want 7", decoded.CorrelationID)
	}
}

func TestDecodeAssetCreatedWithAttachments(t *testing.T) {
	attachments := []Attachment{{FileId: "att-note-1", Filename: "diagram.png", Size: 42, MimeType: "image/png", UploadedAt: 123}}
	asset := Asset{AssetType: AssetTypeNote, AssetID: 9, Owner: "u", ConvID: 1, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: 1, Preview: "p", Payload: "x", Attachments: attachments}
	payload := buildFullAssetBinary(asset)
	payload = append(payload, []byte{0, 0, 0, 7}...)

	decoded, err := DecodeAssetCreated(payload)
	if err != nil {
		t.Fatalf("DecodeAssetCreated error: %v", err)
	}
	if decoded.CorrelationID != 7 {
		t.Fatalf("CorrelationID = %d, want 7", decoded.CorrelationID)
	}
	if !reflect.DeepEqual(decoded.Asset.Attachments, attachments) {
		t.Fatalf("Attachments = %#v, want %#v", decoded.Asset.Attachments, attachments)
	}
}

func TestDecodeAssetDeleted(t *testing.T) {
	payload := make([]byte, 20)
	binary.BigEndian.PutUint64(payload[0:8], 1)
	binary.BigEndian.PutUint64(payload[8:16], 2)
	binary.BigEndian.PutUint32(payload[16:20], 3)

	decoded, err := DecodeAssetDeleted(payload)
	if err != nil {
		t.Fatalf("DecodeAssetDeleted error: %v", err)
	}
	if decoded.ConvID != 1 || decoded.AssetID != 2 || decoded.CorrelationID != 3 {
		t.Fatalf("unexpected decoded asset deleted payload: %+v", decoded)
	}
}

func TestDecodeAssetListResponseCorrelation(t *testing.T) {
	asset := Asset{AssetType: AssetTypeNote, AssetID: 1, Owner: "u", ConvID: 5, PayloadEncoding: AssetPayloadEncodingPlain, PayloadRawLen: 1, Preview: "p", Attachments: []Attachment{{FileId: "att-list-1", Filename: "list.pdf", Size: 22, MimeType: "application/pdf", UploadedAt: 33}}}
	payload := make([]byte, 0, 128)
	header := make([]byte, 15)
	binary.BigEndian.PutUint64(header[0:], 5)
	header[8] = 0
	binary.BigEndian.PutUint16(header[9:], 1)
	binary.BigEndian.PutUint32(header[11:], 0xDEADBEEF)
	payload = append(payload, header...)
	payload = append(payload, buildAssetHeaderBinary(asset)...)

	decoded, err := DecodeAssetListResponse(payload)
	if err != nil {
		t.Fatalf("DecodeAssetListResponse error: %v", err)
	}
	if decoded.CorrelationID != 0xDEADBEEF {
		t.Fatalf("CorrelationID = 0x%08X, want 0xDEADBEEF", decoded.CorrelationID)
	}
	if !reflect.DeepEqual(decoded.Assets[0].Attachments, asset.Attachments) {
		t.Fatalf("decoded list attachments = %#v, want %#v", decoded.Assets[0].Attachments, asset.Attachments)
	}
}
