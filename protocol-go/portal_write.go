package protocol

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"unicode/utf8"
)

// PortalWriteProof is request-only authorization for an authenticated DB-mode
// portal write. ID and Revision must be captured by the original login lookup.
type PortalWriteProof struct {
	ID, Revision, ServiceKey string
}

func (p PortalWriteProof) appendTo(dst []byte) ([]byte, error) {
	id, idOK := chronicleDecimal(p.ID)
	rev, revOK := chronicleDecimal(p.Revision)
	key, err := hex.DecodeString(p.ServiceKey)
	if !idOK || id == 0 || !revOK || rev == 0 || rev > 1<<63-1 || err != nil || len(key) != 32 {
		return nil, errors.New("invalid portal write proof")
	}
	dst = binary.BigEndian.AppendUint64(dst, id)
	dst = binary.BigEndian.AppendUint64(dst, rev)
	return append(dst, p.ServiceKey...), nil
}

// EncodePortalTicketCreate returns a C_CreateAsset body without its opcode.
// The required trailer is rejected by servers without portal-write support.
func EncodePortalTicketCreate(a Asset, requester string, proof PortalWriteProof, correlation uint32) ([]byte, error) {
	if a.AssetType != AssetTypeTicket && a.AssetType != AssetTypeTicketEntry || len(requester) == 0 || len(requester) > 320 || !utf8.ValidString(requester) {
		return nil, errors.New("invalid portal ticket write")
	}
	body, err := EncodeCreateAssetWithAttachmentsAndCorrelation(0, a.AssetType, a.ParentType, a.ParentID, a.Preview, a.Payload, a.Attachments, correlation)
	if err != nil {
		return nil, err
	}
	body, err = proof.appendTo(body)
	if err != nil {
		return nil, err
	}
	return append(body, requester...), nil
}
