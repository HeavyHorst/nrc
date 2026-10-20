package calls

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/coder/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type Authorizer interface {
	Partner(context.Context, Identity, string) (string, error)
}
type NRCAuthorizer struct{ Server, Secret, Issuer, Audience string }

func (a NRCAuthorizer) list(ctx context.Context, id Identity, dm uint64) (string, error) {
	u, e := url.Parse(a.Server)
	if e != nil {
		return "", e
	}
	u.Path = "/" + id.Workspace
	id.Iss = a.Issuer
	id.Aud = a.Audience
	id.Nbf = time.Now().Unix() - 2
	id.Exp = time.Now().Add(30 * time.Second).Unix()
	c, _, e := websocket.Dial(ctx, u.String(), &websocket.DialOptions{HTTPHeader: http.Header{"X-Nrc-Auth": {sign(a.Secret, id)}}})
	if e != nil {
		return "", e
	}
	defer c.CloseNow()
	c.SetReadLimit(1 << 20)
	b, _ := (&protocol.Message{Opcode: protocol.C_ListDMs, Data: protocol.EncodeListDMsWithCorrelation(1)}).Write()
	if e = c.Write(ctx, websocket.MessageBinary, b); e != nil {
		return "", e
	}
	for {
		_, b, e = c.Read(ctx)
		if e != nil {
			return "", e
		}
		m, e := protocol.ReadMessage(b)
		if e != nil {
			return "", e
		}
		if m.Opcode != protocol.S_DMList {
			continue
		}
		l, e := protocol.DecodeDMList(m.Data)
		if e != nil {
			return "", e
		}
		if l.CorrelationID != 1 {
			continue
		}
		for _, entry := range l.Entries {
			if entry.ConvID == dm && validUsername(entry.Username) && entry.Username != id.Username {
				return entry.Username, nil
			}
		}
		return "", denied
	}
}
func (a NRCAuthorizer) Partner(ctx context.Context, id Identity, dm string) (string, error) {
	n, e := strconv.ParseUint(dm, 10, 64)
	if e != nil || strconv.FormatUint(n, 10) != dm || n&protocol.DMConvFlag == 0 {
		return "", denied
	}
	partner, e := a.list(ctx, id, n)
	if e != nil {
		return "", denied
	}
	other := id
	other.Username = partner
	other.Sub = partner
	back, e := a.list(ctx, other, n)
	if e != nil || back != id.Username {
		return "", denied
	}
	return partner, nil
}
