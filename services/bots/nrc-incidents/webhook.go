package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

type deliverySource interface {
	asset(context.Context, uint64) (p.Asset, error)
	delivery(context.Context, p.MonitorDelivery) (p.MonitorDeliveryResult, error)
}

func (s nrcSource) delivery(ctx context.Context, r p.MonitorDelivery) (p.MonitorDeliveryResult, error) {
	r.CorrelationID = 1
	wire, err := p.EncodeMonitorDelivery(r)
	if err != nil {
		return p.MonitorDeliveryResult{}, err
	}
	b, err := s.request(ctx, wire, p.S_MonitorDelivery, 1)
	if err != nil {
		return p.MonitorDeliveryResult{}, err
	}
	result, err := p.DecodeMonitorDeliveryResult(b)
	if err == nil && result.CorrelationID != 1 {
		err = errors.New("invalid delivery correlation")
	}
	return result, err
}

type webhookEnvelope struct {
	Version     int             `json:"version"`
	Kind        string          `json:"kind"`
	Workspace   string          `json:"workspace"`
	MonitorID   string          `json:"monitor_id"`
	Route       string          `json:"route"`
	DeliveryID  string          `json:"delivery_id"`
	SyncVersion string          `json:"sync_version,omitempty"`
	Event       json.RawMessage `json:"event,omitempty"`
	IncidentIDs []string        `json:"incident_ids"`
}

// Resolve before claiming: a missing local secret must not consume all ten leases.
func dispatchLane(ctx context.Context, source deliverySource, workspace string, monitor uint64, route string) error {
	id, err := strconv.ParseUint(route, 10, 64)
	if err != nil || id == 0 || strconv.FormatUint(id, 10) != route {
		return errors.New("unresolvable webhook route")
	}
	a, err := source.asset(ctx, id)
	if err != nil {
		return err
	}
	config, err := p.DecodeMonitorSource(a)
	if err != nil || config.Kind != "webhook" {
		return errors.New("invalid webhook route")
	}
	secret := ""
	if config.SecretRef != "" {
		secret = os.Getenv("NRC_MONITOR_SECRET_" + config.SecretRef)
		if secret == "" || strings.ContainsAny(secret, "\r\n") {
			return errors.New("webhook credential unavailable")
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	r := p.MonitorDelivery{MonitorID: monitor, Stream: 1, Action: 1, Route: route}
	claim, err := source.delivery(ctx, r)
	if err != nil {
		return err
	} // Unknown claim outcome: wait for the next poll, never guess credentials.
	if claim.State == 3 {
		return errors.New("webhook lane blocked by dead delivery")
	}
	if claim.State != 2 {
		return nil
	}
	r.ID, err = strconv.ParseUint(claim.ID, 10, 64)
	if err != nil || r.ID == 0 {
		return errors.New("invalid delivery ID")
	}
	r.Generation, err = strconv.ParseInt(claim.Generation, 10, 64)
	if err != nil || r.Generation <= 0 {
		return errors.New("invalid delivery generation")
	}
	lease, err := strconv.ParseInt(claim.LeaseUntil, 10, 64)
	if err != nil {
		return errors.New("invalid delivery lease")
	}
	ctx, leaseCancel := context.WithDeadline(ctx, time.Unix(0, lease).Add(-5*time.Second))
	defer leaseCancel()
	settle := func(action uint8) error {
		r.Action = action
		result, err := source.delivery(ctx, r)
		if err == nil && (result.State != 4 || result.ID != claim.ID || result.Generation != claim.Generation) {
			return errors.New("invalid delivery settlement")
		}
		return err
	}
	body := webhookEnvelope{Version: 1, Kind: "incident_transition", Workspace: workspace, MonitorID: strconv.FormatUint(monitor, 10), Route: route, DeliveryID: claim.ID}
	if claim.SyncVersion != "0" && claim.SyncVersion != "" {
		version, err := strconv.ParseInt(claim.SyncVersion, 10, 64)
		if err != nil || version <= 0 {
			return errors.New("invalid resync version")
		}
		body.Kind, body.SyncVersion = "webhook_resync", claim.SyncVersion
		body.IncidentIDs = []string{}
		pageRequest := p.MonitorDelivery{MonitorID: monitor, Stream: 1, Action: 7, Route: route, Generation: version}
		for {
			page, err := source.delivery(ctx, pageRequest)
			if err != nil {
				return err
			}
			if page.ID != claim.ID || page.Generation != claim.Generation || page.SyncVersion != claim.SyncVersion {
				return errors.New("resync token changed")
			}
			if page.State == 7 {
				return settle(2)
			} // Obsolete token; never publish its partial set.
			if page.State != 6 {
				return errors.New("invalid resync page")
			}
			last := pageRequest.ID
			for _, text := range page.IncidentIDs {
				id, err := strconv.ParseUint(text, 10, 64)
				if err != nil || id <= last {
					return errors.New("invalid resync incident order")
				}
				last = id
				body.IncidentIDs = append(body.IncidentIDs, text)
			}
			// Paused instances can retain incidents beyond the active-instance cap.
			if len(body.IncidentIDs) > 65536 {
				return errors.New("resync exceeds dispatcher memory bound")
			}
			if page.NextID == "0" {
				break
			}
			next, err := strconv.ParseUint(page.NextID, 10, 64)
			if err != nil || next <= pageRequest.ID || next != last {
				return errors.New("invalid resync cursor")
			}
			pageRequest.ID = next
		}
	} else {
		if !json.Valid([]byte(claim.Payload)) {
			return errors.New("invalid webhook event")
		}
		body.Event = json.RawMessage(claim.Payload)
	}
	deadline, _ := ctx.Deadline()
	if time.Until(deadline) < 20*time.Second {
		return errors.New("insufficient webhook lease time")
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return err
	}
	key := sha256.Sum256([]byte(workspace + "\x00" + claim.ID))
	action := postWebhook(ctx, config, secret, hex.EncodeToString(key[:]), encoded)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return settle(action)
}

// No redirects: never leak a bearer token or turn a POST into a GET.
// HTTP delivery is at-least-once; receivers deduplicate Idempotency-Key.
func postWebhook(ctx context.Context, config p.MonitorSource, secret, key string, body []byte) uint8 {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, config.BaseURL, bytes.NewReader(body))
	if err != nil {
		return 4
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", key)
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: config.InsecureTLS}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return 3
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return 2
	}
	if resp.StatusCode == 408 || resp.StatusCode == 429 || resp.StatusCode >= 500 {
		return 3
	}
	return 4
}

func dispatchMonitor(ctx context.Context, source deliverySource, workspace string, monitor uint64) error {
	r := p.MonitorDelivery{MonitorID: monitor, Stream: 1, Action: 6}
	for pages := 0; pages < 8; pages++ { // Server reserves at most 256 lanes per monitor.
		page, err := source.delivery(ctx, r)
		if err != nil {
			return err
		}
		if page.State != 5 {
			return errors.New("invalid route discovery")
		}
		last := r.Route
		for _, route := range page.Routes {
			if route <= last {
				return errors.New("invalid route order")
			}
			last = route
			if err := dispatchLane(ctx, source, workspace, monitor, route); err != nil && ctx.Err() == nil {
				slog.Warn("webhook lane unavailable", "monitor_id", monitor, "route", route)
			}
		}
		if page.NextRoute == "" {
			return nil
		}
		if page.NextRoute != last || last <= r.Route {
			return errors.New("invalid route cursor")
		}
		r.Route = page.NextRoute
	}
	return nil
}

func dispatchWebhooks(ctx context.Context, ids *monitorSet, workers int, source deliverySource, workspace string) {
	runMonitorLoops(ctx, ids, workers, func(ctx context.Context, id uint64) time.Duration {
		if err := dispatchMonitor(ctx, source, workspace, id); err != nil && ctx.Err() == nil {
			slog.Warn("webhook discovery failed", "monitor_id", id)
		}
		return 5 * time.Second
	})
}
