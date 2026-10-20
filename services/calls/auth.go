package calls

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

type Identity struct {
	Username  string `json:"username"`
	Sub       string `json:"sub"`
	Workspace string `json:"workspace"`
	Iss       string `json:"iss"`
	Aud       string `json:"aud"`
	Nbf       int64  `json:"nbf"`
	Exp       int64  `json:"exp"`
}

var workspacePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
var denied = errors.New("not authorized or unavailable")

func validUsername(s string) bool {
	return len(s) > 0 && len(s) <= 255 && utf8.ValidString(s) && !strings.ContainsAny(s, "\x00\r\n")
}

func sign(key string, claims any) string {
	h := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	b, _ := json.Marshal(claims)
	p := h + "." + base64.RawURLEncoding.EncodeToString(b)
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte(p))
	return p + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
func verify(token, key, issuer, audience string) (Identity, error) {
	var c Identity
	if len(token) > 8192 {
		return c, denied
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return c, denied
	}
	h, e := base64.RawURLEncoding.Strict().DecodeString(parts[0])
	if e != nil {
		return c, denied
	}
	var header struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
	}
	dec := json.NewDecoder(bytes.NewReader(h))
	dec.DisallowUnknownFields()
	if dec.Decode(&header) != nil || dec.Decode(new(any)) != io.EOF || header.Alg != "HS256" || header.Typ != "JWT" {
		return c, denied
	}
	sig, e := base64.RawURLEncoding.Strict().DecodeString(parts[2])
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte(parts[0] + "." + parts[1]))
	if e != nil || !hmac.Equal(sig, m.Sum(nil)) {
		return c, denied
	}
	b, e := base64.RawURLEncoding.Strict().DecodeString(parts[1])
	if e != nil || json.Unmarshal(b, &c) != nil {
		return c, denied
	}
	now := time.Now().Unix()
	if c.Iss != issuer || c.Aud != audience || c.Sub != c.Username || !validUsername(c.Username) || !workspacePattern.MatchString(c.Workspace) || c.Nbf <= 0 || c.Nbf > now || c.Exp <= now || c.Exp <= c.Nbf {
		return Identity{}, denied
	}
	return c, nil
}
