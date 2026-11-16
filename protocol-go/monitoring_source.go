package protocol

import (
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
)

// MonitorSource is stored as a shared asset preview. SecretRef is a name only;
// the sidecar resolves NRC_MONITOR_SECRET_<name>, never arbitrary environment keys.
type MonitorSource struct {
	Version     int    `json:"version"`
	Name        string `json:"name"`
	Kind        string `json:"kind"`
	BaseURL     string `json:"base_url"`
	SecretRef   string `json:"secret_ref,omitempty"`
	InsecureTLS bool   `json:"insecure_tls,omitempty"`
	Retention   string `json:"retention,omitempty"`
}

func DecodeMonitorSource(a Asset) (MonitorSource, error) {
	var source MonitorSource
	fail := errors.New("invalid monitoring source")
	if a.AssetType != AssetTypeMonitorSource || a.ParentType != ParentTypeNone || a.ParentID != 0 || a.Payload != "" || a.PayloadEncoding != 0 || len(a.Attachments) != 0 {
		return source, fail
	}
	d := json.NewDecoder(strings.NewReader(a.Preview))
	d.DisallowUnknownFields()
	if d.Decode(&source) != nil || d.Decode(new(any)) != io.EOF {
		return source, fail
	}
	if source.Version != 1 || strings.TrimSpace(source.Name) == "" || len(source.Name) > 256 || (source.Kind != "victoriametrics" && source.Kind != "victorialogs" && source.Kind != "webhook") || !validMonitorSourceURL(source.BaseURL) || len(source.SecretRef) > 64 || len(source.Retention) > 256 || source.Kind == "webhook" && source.Retention != "" {
		return source, fail
	}
	for _, c := range source.SecretRef {
		if !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_' {
			return source, fail
		}
	}
	return source, nil
}

// Keep the same source URL contract as monitoring_assets.odin. No credentials,
// query, fragment or scoped IPv6; an explicit port must be in 1..65535.
func validMonitorSourceURL(raw string) bool {
	if len(raw) > 2048 || (!strings.HasPrefix(raw, "http://") && !strings.HasPrefix(raw, "https://")) {
		return false
	}
	for _, c := range raw {
		if c <= ' ' || c == 127 || strings.ContainsRune("@?#\\", c) {
			return false
		}
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || strings.HasSuffix(u.Host, ":") {
		return false
	}
	if strings.HasPrefix(u.Host, "[") {
		ip, err := netip.ParseAddr(u.Hostname())
		if err != nil || !ip.Is6() || ip.Zone() != "" {
			return false
		}
	} else {
		for _, c := range u.Hostname() {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_') {
				return false
			}
		}
	}
	if u.Port() != "" {
		port, err := strconv.ParseUint(u.Port(), 10, 16)
		if err != nil || port == 0 {
			return false
		}
	}
	return true
}
