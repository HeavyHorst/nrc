package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

type webhookFixture struct {
	config               p.MonitorSource
	claim                p.MonitorDeliveryResult
	pages                []p.MonitorDeliveryResult
	settled              []uint8
	claims               int
	lostSettlement       bool
	commitLostSettlement bool
}

func (f *webhookFixture) asset(_ context.Context, id uint64) (p.Asset, error) {
	if id != 9 {
		return p.Asset{}, errors.New("wrong route asset")
	}
	b, _ := json.Marshal(f.config)
	return p.Asset{AssetType: p.AssetTypeMonitorSource, AssetID: 9, Preview: string(b)}, nil
}
func (f *webhookFixture) delivery(_ context.Context, r p.MonitorDelivery) (p.MonitorDeliveryResult, error) {
	if r.MonitorID != 7 || r.Stream != 1 {
		return p.MonitorDeliveryResult{}, errors.New("wrong monitor")
	}
	if r.Action == 6 {
		return p.MonitorDeliveryResult{State: 5, Routes: []string{"9"}}, nil
	}
	if r.Route != "9" {
		return p.MonitorDeliveryResult{}, errors.New("wrong lane")
	}
	if r.Action == 1 {
		f.claims++
		return f.claim, nil
	}
	if r.Action == 7 {
		if r.Generation != 11 || len(f.pages) == 0 {
			return p.MonitorDeliveryResult{}, errors.New("wrong resync request")
		}
		page := f.pages[0]
		f.pages = f.pages[1:]
		return page, nil
	}
	if r.ID != 12 || r.Generation != 3 {
		return p.MonitorDeliveryResult{}, errors.New("wrong settlement")
	}
	f.settled = append(f.settled, r.Action)
	if f.lostSettlement {
		if f.commitLostSettlement {
			f.claim.State = 0
		}
		return p.MonitorDeliveryResult{}, errors.New("lost settlement response")
	}
	return p.MonitorDeliveryResult{State: 4, ID: "12", Generation: "3"}, nil
}
func newWebhookFixture(url string) *webhookFixture {
	return &webhookFixture{config: p.MonitorSource{Version: 1, Name: "ops", Kind: "webhook", BaseURL: url}, claim: p.MonitorDeliveryResult{State: 2, ID: "12", Generation: "3", LeaseUntil: strconv.FormatInt(time.Now().Add(time.Minute).UnixNano(), 10), SyncVersion: "0", Payload: `{"version":1,"incident_id":"44","incident":{"status":"firing"}}`}}
}

// Script only the server boundary; dispatch, HTTP and contexts remain real.
type scriptedWebhookSource struct {
	*webhookFixture
	respond func(context.Context, p.MonitorDelivery) (p.MonitorDeliveryResult, error)
}

func (s scriptedWebhookSource) delivery(ctx context.Context, r p.MonitorDelivery) (p.MonitorDeliveryResult, error) {
	return s.respond(ctx, r)
}

func TestWebhookResyncSizeBoundary(t *testing.T) {
	for _, count := range []int{65536, 65537} {
		t.Run(strconv.Itoa(count), func(t *testing.T) {
			var posts atomic.Int32
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				posts.Add(1)
				var body webhookEnvelope
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				if len(body.IncidentIDs) != count {
					t.Errorf("received %d IDs, want %d", len(body.IncidentIDs), count)
				}
				for i, id := range body.IncidentIDs {
					if id != strconv.Itoa(i+1) {
						t.Errorf("wrong ID at %d: %s", i, id)
						break
					}
				}
				w.WriteHeader(204)
			}))
			defer s.Close()
			f := newWebhookFixture(s.URL)
			f.claim.SyncVersion = "11"
			var cursor uint64
			source := scriptedWebhookSource{f, func(ctx context.Context, r p.MonitorDelivery) (p.MonitorDeliveryResult, error) {
				if r.Action != 7 {
					return f.delivery(ctx, r)
				}
				if r.ID != cursor {
					t.Fatalf("cursor %d, want %d", r.ID, cursor)
				}
				page := p.MonitorDeliveryResult{State: 6, ID: "12", Generation: "3", SyncVersion: "11", NextID: "0"}
				end := min(cursor+32, uint64(count))
				for id := cursor + 1; id <= end; id++ {
					page.IncidentIDs = append(page.IncidentIDs, strconv.FormatUint(id, 10))
				}
				cursor = end
				if end < uint64(count) {
					page.NextID = strconv.FormatUint(end, 10)
				}
				return page, nil
			}}
			err := dispatchLane(context.Background(), source, "w", 7, "9")
			if count == 65536 {
				if err != nil || posts.Load() != 1 || len(f.settled) != 1 || f.settled[0] != 2 {
					t.Fatalf("boundary rejected: %v, posts %d, settlements %v", err, posts.Load(), f.settled)
				}
			} else if err == nil || !strings.Contains(err.Error(), "memory bound") || posts.Load() != 0 || len(f.settled) != 0 {
				t.Fatalf("over-limit set published: %v, posts %d, settlements %v", err, posts.Load(), f.settled)
			}
		})
	}
}

func TestWebhookResyncInterruptedPaging(t *testing.T) {
	for _, mode := range []string{"budget", "deadline", "cancel"} {
		t.Run(mode, func(t *testing.T) {
			var posts atomic.Int32
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { posts.Add(1); w.WriteHeader(204) }))
			defer s.Close()
			synctest.Test(t, func(t *testing.T) {
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				f := newWebhookFixture(s.URL)
				f.claim.SyncVersion = "11"
				pages := 0
				source := scriptedWebhookSource{f, func(ctx context.Context, r p.MonitorDelivery) (p.MonitorDeliveryResult, error) {
					if r.Action != 7 {
						return f.delivery(ctx, r)
					}
					pages++
					page := p.MonitorDeliveryResult{State: 6, ID: "12", Generation: "3", SyncVersion: "11", IncidentIDs: []string{"44"}, NextID: "44"}
					if pages == 1 {
						return page, nil
					}
					if r.ID != 44 {
						t.Fatalf("wrong second cursor: %d", r.ID)
					}
					if mode == "cancel" {
						cancel()
					}
					if mode == "deadline" {
						<-ctx.Done()
						return p.MonitorDeliveryResult{}, ctx.Err()
					}
					if mode == "budget" {
						time.Sleep(26 * time.Second)
					} // Leaves 19s: insufficient for POST + settlement.
					if ctx.Err() != nil {
						return p.MonitorDeliveryResult{}, ctx.Err()
					}
					page.IncidentIDs = []string{"91"}
					page.NextID = "0"
					return page, nil
				}}
				err := dispatchLane(ctx, source, "w", 7, "9")
				if err == nil || pages != 2 || posts.Load() != 0 || len(f.settled) != 0 {
					t.Fatalf("interrupted snapshot published: %v, pages %d, posts %d, settlements %v", err, pages, posts.Load(), f.settled)
				}
				if mode == "deadline" && !errors.Is(err, context.DeadlineExceeded) {
					t.Fatal(err)
				}
				if mode == "cancel" && !errors.Is(err, context.Canceled) {
					t.Fatal(err)
				}
				if mode == "budget" && !strings.Contains(err.Error(), "insufficient webhook lease time") {
					t.Fatal(err)
				}
			})
		})
	}
}

func TestWebhookDiscoveryPagination(t *testing.T) {
	f := newWebhookFixture("http://unused.invalid")
	claims := map[string]int{}
	var cursors []string
	// All lanes use the same fixture endpoint; their identities still differ.
	source := webhookDiscoverySource{scriptedWebhookSource{f, func(ctx context.Context, r p.MonitorDelivery) (p.MonitorDeliveryResult, error) {
		if r.Action == 1 {
			claims[r.Route]++
			return p.MonitorDeliveryResult{State: 0}, nil
		}
		if r.Action != 6 {
			t.Fatalf("unexpected action %d", r.Action)
		}
		cursors = append(cursors, r.Route)
		start := 100
		if r.Route != "" {
			n, err := strconv.Atoi(r.Route)
			if err != nil {
				t.Fatal(err)
			}
			start = n + 1
		}
		page := p.MonitorDeliveryResult{State: 5}
		for id := start; id < min(start+32, 165); id++ {
			page.Routes = append(page.Routes, strconv.Itoa(id))
		}
		if start+32 < 165 {
			page.NextRoute = page.Routes[len(page.Routes)-1]
		}
		return page, nil
	}}}
	for pass := 0; pass < 2; pass++ {
		if err := dispatchMonitor(context.Background(), source, "w", 7); err != nil {
			t.Fatal(err)
		}
	}
	if strings.Join(cursors, ",") != ",131,163,,131,163" {
		t.Fatalf("wrong discovery continuation/restart: %v", cursors)
	}
	if len(claims) != 65 {
		t.Fatalf("visited %d lanes", len(claims))
	}
	for id := 100; id < 165; id++ {
		if claims[strconv.Itoa(id)] != 2 {
			t.Fatalf("lane %d not visited once per pass", id)
		}
	}
}

type webhookDiscoverySource struct{ scriptedWebhookSource }

func (s webhookDiscoverySource) asset(ctx context.Context, _ uint64) (p.Asset, error) {
	return s.webhookFixture.asset(ctx, 9)
}

func TestWebhookShutdown(t *testing.T) {
	for _, phase := range []string{"http", "settlement", "scheduler"} {
		t.Run(phase, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			entered := make(chan struct{}, 1)
			release := make(chan struct{})
			var posts atomic.Int32
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				posts.Add(1)
				if phase == "http" {
					entered <- struct{}{}
					<-release
					return
				}
				w.WriteHeader(204)
			}))
			defer s.Close()
			defer close(release) // Also releases handler if the cancellation assertion fails.
			f := newWebhookFixture(s.URL)
			var completed atomic.Int32
			source := scriptedWebhookSource{f, func(ctx context.Context, r p.MonitorDelivery) (p.MonitorDeliveryResult, error) {
				if ctx.Err() != nil {
					return p.MonitorDeliveryResult{}, ctx.Err()
				}
				if phase == "scheduler" || phase == "settlement" && r.Action == 2 {
					entered <- struct{}{}
					<-ctx.Done()
					return p.MonitorDeliveryResult{}, ctx.Err()
				}
				if r.Action == 2 {
					completed.Add(1)
				}
				return f.delivery(ctx, r)
			}}
			done := make(chan error, 1)
			go func() {
				if phase == "scheduler" {
					dispatchWebhooks(ctx, newMonitorSet([]uint64{7, 8, 9}), 1, source, "w")
					done <- nil
				} else {
					done <- dispatchLane(ctx, source, "w", 7, "9")
				}
			}()
			select {
			case <-entered:
			case <-time.After(3 * time.Second):
				t.Fatal("dispatch never reached blocking phase")
			}
			cancel()
			select {
			case err := <-done:
				if phase != "scheduler" && !errors.Is(err, context.Canceled) {
					t.Fatalf("wrong shutdown error: %v", err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("shutdown stuck with work in flight or waiting on semaphore")
			}
			wantPosts := int32(1)
			if phase == "scheduler" {
				wantPosts = 0
			}
			if posts.Load() != wantPosts || completed.Load() != 0 {
				t.Fatalf("posts %d, successful settlements %d", posts.Load(), completed.Load())
			}
		})
	}
}

func TestWebhookDelivery(t *testing.T) {
	for _, tc := range []struct {
		status int
		action uint8
	}{{204, 2}, {429, 3}, {503, 3}, {408, 3}, {400, 4}, {401, 4}, {302, 4}} {
		t.Run(strconv.Itoa(tc.status), func(t *testing.T) {
			calls := 0
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Method != "POST" || r.Header.Get("Authorization") != "Bearer test-token" || r.Header.Get("Content-Type") != "application/json" || len(r.Header.Get("Idempotency-Key")) != 64 {
					t.Error("invalid HTTP request")
				}
				var body webhookEnvelope
				if json.NewDecoder(r.Body).Decode(&body) != nil || body.Workspace != "w" || body.MonitorID != "7" || body.Route != "9" || body.DeliveryID != "12" || !strings.Contains(string(body.Event), `"firing"`) {
					t.Errorf("invalid event %+v", body)
				}
				w.Header().Set("Location", "/redirected")
				w.WriteHeader(tc.status)
			}))
			defer s.Close()
			f := newWebhookFixture(s.URL)
			f.config.SecretRef = "HOOK"
			t.Setenv("NRC_MONITOR_SECRET_HOOK", "test-token")
			if err := dispatchMonitor(context.Background(), f, "w", 7); err != nil {
				t.Fatal(err)
			}
			if calls != 1 || len(f.settled) != 1 || f.settled[0] != tc.action {
				t.Fatalf("calls=%d settlements=%v", calls, f.settled)
			}
		})
	}
}

func TestWebhookResyncAndLostACK(t *testing.T) {
	for _, mode := range []string{"pages", "empty", "stale", "lost-ack", "committed-lost-ack", "dead", "short-lease", "missing-secret"} {
		t.Run(mode, func(t *testing.T) {
			var bodies []string
			var keys []string
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				b, _ := io.ReadAll(r.Body)
				bodies = append(bodies, string(b))
				keys = append(keys, r.Header.Get("Idempotency-Key"))
				w.WriteHeader(200)
			}))
			defer s.Close()
			f := newWebhookFixture(s.URL)
			if mode == "dead" {
				f.claim.State = 3
			}
			if mode == "short-lease" {
				f.claim.LeaseUntil = strconv.FormatInt(time.Now().Add(10*time.Second).UnixNano(), 10)
			}
			if mode == "missing-secret" {
				f.config.SecretRef = "MISSING"
				t.Setenv("NRC_MONITOR_SECRET_MISSING", "")
			}
			if mode == "pages" || mode == "empty" || mode == "stale" {
				f.claim.SyncVersion = "11"
				page := p.MonitorDeliveryResult{ID: "12", Generation: "3", SyncVersion: "11", State: 6, NextID: "0"}
				if mode != "empty" {
					first := page
					first.IncidentIDs = []string{"40", "44"}
					first.NextID = "44"
					f.pages = append(f.pages, first)
					page.IncidentIDs = []string{"91"}
				}
				if mode == "stale" {
					page.State = 7
				}
				f.pages = append(f.pages, page)
			}
			if mode == "lost-ack" || mode == "committed-lost-ack" {
				f.lostSettlement = true
				f.commitLostSettlement = mode == "committed-lost-ack"
			}
			err := dispatchLane(context.Background(), f, "w", 7, "9")
			wantErr := mode == "lost-ack" || mode == "committed-lost-ack" || mode == "dead" || mode == "short-lease" || mode == "missing-secret"
			if (err != nil) != wantErr {
				t.Fatalf("error: %v", err)
			}
			if mode == "lost-ack" || mode == "committed-lost-ack" {
				f.lostSettlement = false
				if err := dispatchLane(context.Background(), f, "w", 7, "9"); err != nil {
					t.Fatal(err)
				}
				if mode == "committed-lost-ack" {
					if len(keys) != 1 || len(f.settled) != 1 {
						t.Fatal("committed ACK caused another delivery")
					}
				} else if len(keys) != 2 || keys[0] != keys[1] || bodies[0] != bodies[1] {
					t.Fatalf("redelivery changed identity: %v", keys)
				}
			} else if mode == "pages" || mode == "empty" {
				if len(bodies) != 1 {
					t.Fatal("missing resync")
				}
				var body webhookEnvelope
				_ = json.Unmarshal([]byte(bodies[0]), &body)
				if body.Kind != "webhook_resync" || body.SyncVersion != "11" || len(f.settled) != 1 || f.settled[0] != 2 {
					t.Fatalf("bad resync %+v", body)
				}
				if mode == "pages" && strings.Join(body.IncidentIDs, ",") != "40,44,91" {
					t.Fatal(body.IncidentIDs)
				}
				if mode == "empty" && !strings.Contains(bodies[0], `"incident_ids":[]`) {
					t.Fatal(bodies[0])
				}
			} else {
				if len(bodies) != 0 {
					t.Fatal("unexpected HTTP delivery")
				}
				if mode == "stale" && (len(f.settled) != 1 || f.settled[0] != 2) {
					t.Fatal("obsolete token not acknowledged")
				}
				if mode == "missing-secret" && f.claims != 0 {
					t.Fatal("missing secret consumed lease")
				}
			}
		})
	}
}
