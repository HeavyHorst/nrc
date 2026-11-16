package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	p "github.com/heavyhorst/nrc/protocol-go"
)

type threshold struct {
	Op    string      `json:"op"`
	Value json.Number `json:"value"`
}

func validateQuery(d checkDefinition) error {
	for _, ref := range []string{d.SourceID, d.SourceRevision} {
		for _, c := range ref {
			if c < '0' || c > '9' {
				return errors.New("source references require decimal digits")
			}
		}
	}
	id, idErr := strconv.ParseUint(d.SourceID, 10, 64)
	revision, revErr := strconv.ParseInt(d.SourceRevision, 10, 64)
	if idErr != nil || revErr != nil || id == 0 || revision <= 0 || d.URL != "" || d.InsecureTLS || d.Address != "" || len(d.Conditions) != 0 || d.FollowRedirects || strings.TrimSpace(d.Query) == "" || len(d.Query) > 32768 || len(d.IdentityLabels) == 0 || len(d.IdentityLabels) > 32 || d.Trigger == nil {
		return errors.New("invalid Victoria query definition")
	}
	// LogsQL options override request parameters. Conservatively disallow this
	// option anywhere in a monitoring query, including quoted text.
	if d.Kind == "victorialogs" && strings.Contains(strings.ToLower(d.Query), "allow_partial_response") {
		return errors.New("partial response override forbidden")
	}
	seen := map[string]bool{}
	for _, label := range d.IdentityLabels {
		if label == "" || len(label) > 256 || !utf8.ValidString(label) || seen[label] {
			return errors.New("invalid identity labels")
		}
		seen[label] = true
	}
	for _, t := range []*threshold{d.Trigger, d.Recovery} {
		if t == nil {
			continue
		}
		if t.Op != "<" && t.Op != "<=" && t.Op != ">" && t.Op != ">=" {
			return errors.New("threshold requires ordered comparison")
		}
		if !json.Valid([]byte(t.Value)) {
			return errors.New("threshold must be numeric")
		}
		if _, err := decimal(t.Value); err != nil {
			return err
		}
	}
	if d.Recovery != nil {
		trigger, _ := decimal(d.Trigger.Value)
		recovery, _ := decimal(d.Recovery.Value)
		below := strings.HasPrefix(d.Trigger.Op, "<")
		if below == strings.HasPrefix(d.Recovery.Op, "<") {
			return errors.New("recovery must oppose trigger")
		}
		order := trigger.Cmp(recovery)
		if (below && order > 0) || (!below && order < 0) || (order == 0 && strings.HasSuffix(d.Trigger.Op, "=") && strings.HasSuffix(d.Recovery.Op, "=")) {
			return errors.New("overlapping thresholds")
		}
	}
	return nil
}

// An error always returns zero observations. Never publish a valid prefix of
// an incomplete result: omitted identities would otherwise become absent.
func runQuery(ctx context.Context, d checkDefinition, source p.MonitorSource) ([]p.MonitorObservation, error) {
	fail := errors.New("Victoria evaluation failed or incomplete")
	endpoint := strings.TrimRight(source.BaseURL, "/") + "/api/v1/query"
	if d.Kind == "victorialogs" {
		endpoint = strings.TrimRight(source.BaseURL, "/") + "/select/logsql/stats_query"
	}
	secret := ""
	if source.SecretRef != "" {
		secret = os.Getenv("NRC_MONITOR_SECRET_" + source.SecretRef)
		if secret == "" || strings.ContainsAny(secret, "\r\n") {
			return nil, fail
		}
	}
	at := time.Now().Unix()
	form := url.Values{"query": {d.Query}, "time": {strconv.FormatInt(at, 10)}}
	if d.Kind == "victoriametrics" {
		form.Set("deny_partial_response", "1")
	} else {
		form.Set("allow_partial_response", "0")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, fail
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: source.InsecureTLS}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fail
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fail
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, (4<<20)+1))
	if err != nil || len(body) > 4<<20 || !utf8.Valid(body) {
		return nil, fail
	}
	var reply struct {
		Status    string   `json:"status"`
		IsPartial bool     `json:"isPartial"`
		Warnings  []string `json:"warnings"`
		Data      struct {
			ResultType string          `json:"resultType"`
			Result     json.RawMessage `json:"result"`
		} `json:"data"`
	}
	if json.Unmarshal(body, &reply) != nil || reply.Status != "success" || reply.IsPartial || len(reply.Warnings) != 0 || reply.Data.ResultType != "vector" {
		return nil, fail
	}
	var rows []struct {
		Metric map[string]json.RawMessage `json:"metric"`
		Value  []json.RawMessage          `json:"value"`
	}
	raw := bytes.TrimSpace(reply.Data.Result)
	if len(raw) == 0 || raw[0] != '[' || json.Unmarshal(raw, &rows) != nil || len(rows) > p.MaxMonitorInstances {
		return nil, fail
	}
	observations := make([]p.MonitorObservation, 0, len(rows))
	seen := map[string]bool{}
	for _, row := range rows {
		if len(row.Value) != 2 {
			return nil, fail
		}
		var stamp json.Number
		var value string
		if len(row.Value[0]) == 0 || row.Value[0][0] == '"' || json.Unmarshal(row.Value[0], &stamp) != nil || json.Unmarshal(row.Value[1], &value) != nil {
			return nil, fail
		}
		ts, err := stamp.Float64()
		if err != nil || math.IsNaN(ts) || math.IsInf(ts, 0) || math.Abs(ts-float64(at)) > 1 {
			return nil, fail
		}
		// API samples are strings, so validate their JSON number grammar before
		// exact comparison. NaN/Inf cannot become passing observations.
		if !json.Valid([]byte(value)) || len(value) == 0 || (value[0] != '-' && (value[0] < '0' || value[0] > '9')) {
			return nil, fail
		}
		n := json.Number(value)
		numeric, err := strconv.ParseFloat(value, 64)
		if err != nil || math.IsInf(numeric, 0) || math.IsNaN(numeric) {
			return nil, fail
		}
		trigger, err := compare(n, d.Trigger.Op, d.Trigger.Value)
		if err != nil {
			return nil, fail
		}
		condition := uint8(0)
		if trigger {
			condition = 1
		} else if d.Recovery != nil {
			recovered, err := compare(n, d.Recovery.Op, d.Recovery.Value)
			if err != nil {
				return nil, fail
			}
			if !recovered {
				condition = 2
			}
		}
		labels := make(map[string]string, len(d.IdentityLabels))
		for _, raw := range row.Metric {
			var label string
			if len(raw) == 0 || raw[0] != '"' || json.Unmarshal(raw, &label) != nil {
				return nil, fail
			}
		}
		for _, key := range d.IdentityLabels {
			raw, ok := row.Metric[key]
			if !ok {
				return nil, fail
			}
			var v string
			if json.Unmarshal(raw, &v) != nil {
				return nil, fail
			}
			labels[key] = v
		}
		identity, _ := json.Marshal(labels) // encoding/json sorts map keys.
		if len(identity) > 4096 || seen[string(identity)] {
			return nil, fail
		}
		seen[string(identity)] = true
		observations = append(observations, p.MonitorObservation{Identity: string(identity), Condition: condition, Value: numeric})
	}
	sort.Slice(observations, func(i, j int) bool { return observations[i].Identity < observations[j].Identity })
	// The complete wire frame has a tighter bound than rows × identity length.
	if _, err := p.EncodeApplyMonitorRun(p.ApplyMonitorRun{MonitorID: 1, Revision: 1, Sequence: 1, Observations: observations}); err != nil {
		return nil, fail
	}
	return observations, nil
}
