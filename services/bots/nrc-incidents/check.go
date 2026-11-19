package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

type monitorConfig struct {
	Version    int      `json:"version"`
	Name       string   `json:"name"`
	Unit       string   `json:"unit,omitempty"` // Display metadata only, not used by evaluation.
	Evaluator  string   `json:"evaluator"`
	Enabled    bool     `json:"enabled"`
	Interval   int64    `json:"interval_ns"`
	Timeout    int64    `json:"timeout_ns"`
	Failures   uint32   `json:"failures"`
	Recoveries uint32   `json:"recoveries"`
	Missing    uint32   `json:"missing"`
	Webhooks   []string `json:"webhooks"`
}

type condition struct {
	Field string `json:"field"`
	Path  string `json:"path,omitempty"` // RFC 6901 JSON Pointer, for field=json.
	Op    string `json:"op"`
	Value any    `json:"value"`
	Unit  string `json:"unit,omitempty"` // Display only; comparisons always use raw values.
}

type checkDefinition struct {
	Kind            string      `json:"kind"`
	URL             string      `json:"url,omitempty"`
	Address         string      `json:"address,omitempty"`
	Conditions      []condition `json:"conditions,omitempty"`
	InsecureTLS     bool        `json:"insecure_tls,omitempty"`
	FollowRedirects bool        `json:"follow_redirects,omitempty"`
	Query           string      `json:"query,omitempty"`
	IdentityLabels  []string    `json:"identity_labels,omitempty"`
	Trigger         *threshold  `json:"trigger,omitempty"`
	Recovery        *threshold  `json:"recovery,omitempty"`
	SourceID        string      `json:"source_id,omitempty"`
	SourceRevision  string      `json:"source_revision,omitempty"`
}

func decodeStrict(data string, v any) error {
	d := json.NewDecoder(strings.NewReader(data))
	d.UseNumber()
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("trailing JSON")
	}
	return nil
}

func parseMonitor(a p.Asset) (monitorConfig, checkDefinition, error) {
	var c monitorConfig
	var d checkDefinition
	if a.AssetType != p.AssetTypeMonitor || a.PayloadEncoding != 0 || a.UpdatedAt <= 0 {
		return c, d, errors.New("invalid monitor asset")
	}
	if err := decodeStrict(a.Preview, &c); err != nil {
		return c, d, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(a.Preview), &fields); err != nil {
		return c, d, err
	}
	if unit, present := fields["unit"]; present && bytes.Equal(bytes.TrimSpace(unit), []byte("null")) {
		return c, d, errors.New("monitor unit must be a string")
	}
	if c.Unit != "" && c.Unit != "number" && c.Unit != "percent" && c.Unit != "bytes" {
		return c, d, errors.New("monitor unit must be empty, number, percent or bytes")
	}
	if c.Version != 1 || c.Name == "" || c.Evaluator == "" || c.Interval <= 0 || c.Timeout <= 0 || c.Timeout > c.Interval || c.Failures == 0 || c.Recoveries == 0 || c.Missing == 0 {
		return c, d, errors.New("invalid monitor policy")
	}
	if err := decodeStrict(a.Payload, &d); err != nil {
		return c, d, err
	}
	if d.Kind == "victoriametrics" || d.Kind == "victorialogs" {
		return c, d, validateQuery(d)
	}
	if d.Query != "" || len(d.IdentityLabels) != 0 || d.Trigger != nil || d.Recovery != nil || d.SourceID != "" || d.SourceRevision != "" {
		return c, d, errors.New("query fields require a Victoria check")
	}
	switch d.Kind {
	case "http":
		u, err := url.Parse(d.URL)
		if err != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.Fragment != "" || d.Address != "" || len(d.Conditions) == 0 || len(d.Conditions) > 32 {
			return c, d, errors.New("invalid HTTP check")
		}
	case "tcp":
		host, port, err := net.SplitHostPort(d.Address)
		portNumber, portErr := strconv.Atoi(port)
		if err != nil || host == "" || portErr != nil || portNumber < 1 || portNumber > 65535 || d.URL != "" || len(d.Conditions) != 0 || d.InsecureTLS || d.FollowRedirects {
			return c, d, errors.New("invalid TCP check")
		}
	default:
		return c, d, errors.New("unsupported check kind")
	}
	for _, test := range d.Conditions {
		if test.Unit != "" {
			if _, ok := test.Value.(json.Number); !ok {
				return c, d, errors.New("condition unit requires a numeric value")
			}
			switch test.Unit {
			case "number", "bytes", "bits", "nanoseconds", "microseconds", "milliseconds", "seconds", "percent", "percent_ratio":
			default:
				return c, d, errors.New("unsupported condition display unit")
			}
		}
		switch test.Field {
		case "status", "latency_ns", "certificate_remaining_ns":
			if _, ok := test.Value.(json.Number); !ok || test.Path != "" {
				return c, d, errors.New("numeric condition required")
			}
		case "json":
			if test.Path != "" && !strings.HasPrefix(test.Path, "/") {
				return c, d, errors.New("JSON path must be a JSON Pointer")
			}
		default:
			return c, d, errors.New("unsupported condition field")
		}
		if _, err := compare(test.Value, test.Op, test.Value); err != nil {
			return c, d, err
		}
	}
	return c, d, nil
}

// Bound decimal conversion before allocating big integers: a short JSON token
// can otherwise request an enormous power of ten through its exponent.
func decimal(n json.Number) (*big.Rat, error) {
	s := string(n)
	if len(s) > 128 {
		return nil, errors.New("number exceeds 128 characters")
	}
	if i := strings.IndexAny(s, "eE"); i >= 0 {
		exponent, err := strconv.Atoi(s[i+1:])
		if err != nil || exponent < -308 || exponent > 308 {
			return nil, errors.New("number exponent outside -308..308")
		}
	}
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return nil, errors.New("invalid decimal number")
	}
	return r, nil
}

func compare(actual any, op string, expected any) (bool, error) {
	if op != "==" && op != "!=" && op != "<" && op != ">" && op != "<=" && op != ">=" {
		return false, errors.New("unsupported comparison")
	}
	switch want := expected.(type) {
	case json.Number:
		wantNumber, err := decimal(want)
		if err != nil {
			return false, err
		}
		got, ok := actual.(json.Number)
		if !ok {
			return false, nil
		}
		gotNumber, err := decimal(got)
		if err != nil {
			return false, err
		}
		order := gotNumber.Cmp(wantNumber)
		switch op {
		case "==":
			return order == 0, nil
		case "!=":
			return order != 0, nil
		case "<":
			return order < 0, nil
		case ">":
			return order > 0, nil
		case "<=":
			return order <= 0, nil
		case ">=":
			return order >= 0, nil
		}
	case string, bool:
		if op != "==" && op != "!=" {
			return false, errors.New("strings and booleans support equality only")
		}
		sameType := false
		switch want.(type) {
		case string:
			_, sameType = actual.(string)
		case bool:
			_, sameType = actual.(bool)
		}
		if !sameType {
			return false, nil
		}
		if op == "==" {
			return actual == expected, nil
		}
		return actual != expected, nil
	default:
		return false, errors.New("condition value must be number, string or boolean")
	}
	panic("unreachable comparison")
}

func jsonPointer(value any, path string) (any, bool) {
	if path == "" {
		return value, true
	}
	for _, key := range strings.Split(path[1:], "/") {
		key = strings.ReplaceAll(strings.ReplaceAll(key, "~1", "/"), "~0", "~")
		switch v := value.(type) {
		case map[string]any:
			var ok bool
			value, ok = v[key]
			if !ok {
				return nil, false
			}
		case []any:
			i, err := strconv.Atoi(key)
			if err != nil || i < 0 || i >= len(v) || strconv.Itoa(i) != key {
				return nil, false
			}
			value = v[i]
		default:
			return nil, false
		}
	}
	return value, true
}

type checkResult struct {
	Observation p.MonitorObservation
	Duration    time.Duration
	Diagnostics *checkDiagnostics
}

type conditionDiagnostic struct {
	Index          int    `json:"index"`
	State          string `json:"state"`
	Reason         string `json:"reason,omitempty"`
	ActualType     string `json:"actual_type,omitempty"`
	Actual         string `json:"actual,omitempty"`
	Truncated      bool   `json:"truncated,omitempty"`
	ExpectedNumber string `json:"expected_number,omitempty"`
}

type checkDiagnostics struct {
	Version    int                   `json:"version"`
	Error      string                `json:"error,omitempty"`
	Conditions []conditionDiagnostic `json:"conditions"`
}

// Preserve exact decimal text, and only retain configured scalar observations.
// Never copy whole JSON objects, response bodies or transport error strings.
func diagnosticActual(row *conditionDiagnostic, value any) {
	switch v := value.(type) {
	case json.Number:
		row.ActualType, row.Actual = "number", string(v)
	case string:
		row.ActualType, row.Actual = "string", v
	case bool:
		row.ActualType, row.Actual = "boolean", strconv.FormatBool(v)
	case nil:
		row.ActualType = "null"
	default:
		row.ActualType = "non_scalar"
	}
	runes := []rune(row.Actual)
	if len(runes) > 256 {
		row.Actual, row.Truncated = string(runes[:256]), true
	}
}

// Target failures are failing observations, not incomplete query results. No
// full response bodies, URLs, headers or transport errors are retained.
func runCheck(ctx context.Context, d checkDefinition) checkResult {
	start := time.Now()
	r := checkResult{Observation: p.MonitorObservation{Identity: `{"target":"default"}`, Condition: 1}}
	r.Diagnostics = &checkDiagnostics{Version: 1, Conditions: make([]conditionDiagnostic, len(d.Conditions))}
	for i := range r.Diagnostics.Conditions {
		r.Diagnostics.Conditions[i] = conditionDiagnostic{Index: i, State: "unavailable"}
		if number, ok := d.Conditions[i].Value.(json.Number); ok {
			r.Diagnostics.Conditions[i].ExpectedNumber = string(number)
		}
	}
	fail := func(reason string) {
		r.Diagnostics.Error = reason
		for i := range r.Diagnostics.Conditions {
			r.Diagnostics.Conditions[i].Reason = reason
		}
	}
	finish := func(ok bool) checkResult {
		r.Duration = time.Since(start)
		if ok {
			r.Observation.Condition = 0
			r.Observation.Value = 1
		}
		return r
	}
	if d.Kind == "tcp" {
		conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", d.Address)
		if err != nil {
			fail("connect_failed")
			return finish(false)
		}
		conn.Close()
		return finish(true)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// Explicit per-check opt-out; never changes the shared default transport.
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: d.InsecureTLS}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	if !d.FollowRedirects {
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, d.URL, nil)
	if err != nil {
		fail("invalid_request")
		return finish(false)
	}
	resp, err := client.Do(req)
	if err != nil {
		fail("request_failed")
		return finish(false)
	}
	defer resp.Body.Close()
	// Read bounded decompressed bytes. Oversized/invalid JSON cannot pass a JSON condition.
	body, err := io.ReadAll(io.LimitReader(resp.Body, (1<<20)+1))
	if err != nil || len(body) > 1<<20 {
		fail("body_unavailable")
		return finish(false)
	}
	elapsed := time.Since(start)
	var document any
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	jsonOK := decoder.Decode(&document) == nil && decoder.Decode(new(any)) == io.EOF
	passed := true
	for i, test := range d.Conditions {
		row := &r.Diagnostics.Conditions[i]
		var actual any
		switch test.Field {
		case "status":
			actual = json.Number(strconv.Itoa(resp.StatusCode))
		case "latency_ns":
			actual = json.Number(strconv.FormatInt(int64(elapsed), 10))
		case "certificate_remaining_ns":
			if resp.TLS == nil || len(resp.TLS.PeerCertificates) == 0 {
				row.Reason, passed = "certificate_unavailable", false
				continue
			}
			actual = json.Number(strconv.FormatInt(int64(time.Until(resp.TLS.PeerCertificates[0].NotAfter)), 10))
		case "json":
			var ok bool
			if !jsonOK {
				row.Reason, passed = "invalid_json", false
				continue
			}
			actual, ok = jsonPointer(document, test.Path)
			if !ok {
				row.Reason, passed = "missing_field", false
				continue
			}
		default:
			row.Reason, passed = "unsupported_condition", false
			continue
		}
		diagnosticActual(row, actual)
		ok, err := compare(actual, test.Op, test.Value)
		row.State = "pass"
		if err != nil || !ok {
			row.State, passed = "fail", false
			if err != nil {
				row.Reason = "invalid_comparison"
			}
		}
	}
	return finish(passed)
}

func monitorError(id uint64, reason string) error { return fmt.Errorf("monitor %d: %s", id, reason) }
