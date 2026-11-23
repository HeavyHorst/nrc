package protocol

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
)

func TestPortalWriteProofWire(t *testing.T) {
	proof := PortalWriteProof{ID: "809", Revision: "23", ServiceKey: strings.Repeat("a7", 32)}
	const correlation = 329
	asset := Asset{AssetType: AssetTypeTicketEntry, ParentType: ParentTypeAsset, ParentID: 90, Payload: "customer reply"}
	legacy, err := EncodeCreateAssetWithAttachmentsAndCorrelation(0, asset.AssetType, asset.ParentType, asset.ParentID, asset.Preview, asset.Payload, nil, correlation)
	if err != nil {
		t.Fatal(err)
	}
	const requester = "customer@example.test"
	assetBody, err := EncodePortalTicketCreate(asset, requester, proof, correlation)
	if err != nil {
		t.Fatal(err)
	}
	if len(assetBody) != len(legacy)+80+len(requester) || !bytes.HasPrefix(assetBody, legacy) || !bytes.HasSuffix(assetBody, []byte(requester)) {
		t.Fatal("asset proof must trail the unchanged asset body and correlation")
	}
	suffix := assetBody[len(legacy):]
	if binary.BigEndian.Uint64(suffix) != 809 || binary.BigEndian.Uint64(suffix[8:]) != 23 || string(suffix[16:80]) != proof.ServiceKey {
		t.Fatal("asset proof fields were not encoded as expected")
	}
	q := ReviewRequest{Op: "close", RunID: "2", Source: "portal", Identity: requester, IfRevision: "5", Decision: "accepted"}
	legacyReview, err := EncodeReviewRequest(q, correlation)
	if err != nil {
		t.Fatal(err)
	}
	q.PortalProof = &proof
	frame, err := EncodeReviewRequest(q, correlation)
	if err != nil {
		t.Fatal(err)
	}
	if len(frame) != len(legacyReview)+81 || frame[2] != 0 || !bytes.Equal(frame[3:83], suffix[:80]) || !bytes.Equal(frame[83:], legacyReview[2:]) {
		t.Fatal("review proof must precede unchanged JSON and correlation, with a non-JSON marker")
	}
	proof.Revision = ""
	if _, err := EncodeReviewRequest(q, correlation); err == nil {
		t.Fatal("a missing account revision must not fall back to an unguarded close")
	}
	if _, err := EncodePortalTicketCreate(asset, requester, proof, correlation); err == nil {
		t.Fatal("a missing account revision must not fall back to an unguarded reply")
	}
}
