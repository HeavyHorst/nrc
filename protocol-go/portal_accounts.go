package protocol

import (
	"encoding/binary"
	"encoding/json"
	"errors"
)

const PortalAccountImportLimit = 64

type PortalAccount struct {
	ID           string `json:"id,omitempty"`
	Revision     string `json:"revision,omitempty"`
	Login        string `json:"login"`
	Requester    string `json:"requester"`
	Name         string `json:"name"`
	CompanyID    string `json:"company_id"`
	ContactID    string `json:"contact_id,omitempty"`
	PasswordHash string `json:"password_hash,omitempty"`
	Disabled     bool   `json:"disabled,omitempty"`
}

type PortalAccountRequest struct {
	Op           string          `json:"op"`
	ID           string          `json:"id,omitempty"`
	Cursor       string          `json:"cursor,omitempty"`
	IfRevision   string          `json:"if_revision,omitempty"`
	Login        string          `json:"login,omitempty"`
	Requester    string          `json:"requester,omitempty"`
	ServiceKey   string          `json:"service_key,omitempty"`
	PasswordHash string          `json:"password_hash,omitempty"`
	Accounts     []PortalAccount `json:"accounts,omitempty"`
	DryRun       bool            `json:"dry_run,omitempty"`
}

type PortalAccountResponse struct {
	Status        string          `json:"status"`
	Cursor        string          `json:"cursor"`
	Account       *PortalAccount  `json:"account"`
	Accounts      []PortalAccount `json:"accounts"`
	ImportRow     int             `json:"import_row"`
	ImportReason  string          `json:"import_reason"`
	CorrelationID uint32          `json:"-"`
}

func EncodePortalAccountRequest(q PortalAccountRequest, correlation uint32) ([]byte, error) {
	payload, err := json.Marshal(q)
	if err != nil || len(q.Accounts) > PortalAccountImportLimit || len(payload)+6 > 131072 {
		return nil, errors.New("invalid portal account request size")
	}
	frame := make([]byte, 0, len(payload)+6)
	frame = binary.BigEndian.AppendUint16(frame, C_PortalAccount)
	frame = append(frame, payload...)
	return binary.BigEndian.AppendUint32(frame, correlation), nil
}

// DecodePortalAccountResponse accepts the response body without its opcode.
func DecodePortalAccountResponse(body []byte) (*PortalAccountResponse, error) {
	var r PortalAccountResponse
	if len(body) < 6 || json.Unmarshal(body[4:], &r) != nil || r.Status == "" {
		return nil, errors.New("invalid portal account response")
	}
	r.CorrelationID = binary.BigEndian.Uint32(body)
	return &r, nil
}
