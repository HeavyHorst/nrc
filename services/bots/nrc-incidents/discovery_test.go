package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestMonitorDiscoveryProtocol(t *testing.T) {
	for _, mode := range []string{"complete", "failed-page", "repeated-cursor"} {
		t.Run(mode, func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				up := websocket.Upgrader{}
				c, err := up.Upgrade(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer c.Close()
				ready, _ := (&p.Message{Opcode: p.S_ServerReady}).Write()
				_ = c.WriteMessage(websocket.BinaryMessage, ready)
				_, wire, err := c.ReadMessage()
				if err != nil {
					return
				}
				n := requests.Add(1)
				if binary.BigEndian.Uint16(wire) != p.C_ListAssetsPaged || binary.BigEndian.Uint16(wire[10:]) != p.AssetTypeMonitor {
					t.Error("wrong discovery request")
				}
				if n == 2 && mode == "failed-page" {
					return
				}
				var b bytes.Buffer
				more := uint8(0)
				cursor := uint64(0)
				at := int64(0)
				ids := []uint64{1}
				if n == 1 || mode == "repeated-cursor" {
					more = 1
					cursor = 2
					at = 100
					ids = []uint64{3, 2}
				}
				for _, v := range []any{uint64(0), uint8(0), more, at, cursor, uint32(3), uint16(len(ids)), uint32(1)} {
					_ = binary.Write(&b, binary.BigEndian, v)
				}
				for _, id := range ids {
					preview := `{"evaluator":"checker","enabled":false}`
					if id == 2 {
						preview = `{"evaluator":"someone-else"}`
					}
					for _, v := range []any{uint16(p.AssetTypeMonitor), id, uint16(0), uint64(0), uint16(0), int64(100), int64(100), uint64(0), uint8(0), uint32(0), uint16(len(preview))} {
						_ = binary.Write(&b, binary.BigEndian, v)
					}
					b.WriteString(preview)
					_ = binary.Write(&b, binary.BigEndian, uint16(0))
				}
				response, _ := (&p.Message{Opcode: p.S_AssetListPage, Data: b.Bytes()}).Write()
				_ = c.WriteMessage(websocket.BinaryMessage, response)
			}))
			defer server.Close()
			s := nrcSource{server: "ws" + strings.TrimPrefix(server.URL, "http"), workspace: "w", nickname: "checker", secret: "test"}
			ids, err := s.discover(context.Background())
			if mode == "complete" {
				if err != nil || !reflect.DeepEqual(ids, []uint64{1, 3}) {
					t.Fatalf("%v %v", ids, err)
				}
			} else if err == nil || ids != nil {
				t.Fatalf("published partial discovery: %v %v", ids, err)
			}
		})
	}
}

func TestDynamicMonitorLoopsAndHistoryScope(t *testing.T) {
	set := newMonitorSet([]uint64{1})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan uint64, 10)
	stopped := make(chan uint64, 10)
	done := make(chan struct{})
	go func() {
		defer close(done)
		runMonitorLoops(ctx, set, 2, func(ctx context.Context, id uint64) time.Duration {
			started <- id
			<-ctx.Done()
			stopped <- id
			return time.Hour
		})
	}()
	await := func(ch <-chan uint64, want uint64) {
		t.Helper()
		select {
		case got := <-ch:
			if got != want {
				t.Fatalf("got %d want %d", got, want)
			}
		case <-time.After(4 * time.Second):
			t.Fatal("monitor reconciliation timed out")
		}
	}
	await(started, 1)
	set.replace([]uint64{1, 2})
	await(started, 2)
	set.replace([]uint64{2})
	await(stopped, 1)
	set.replace([]uint64{1, 2})
	await(started, 1)
	// The history endpoint follows exactly the same current set, including removal.
	api := newHistoryAPI(newHistoryWriter(), "w", "test", set)
	read := func(id string) int {
		r := httptest.NewRequest("GET", "/v1/history/"+id+"/runs?from=2026-11-16T00:00:00Z&to=2026-11-17T00:00:00Z&resolution=raw&acceptance=confirmed", nil)
		r.Header.Set("Authorization", "Bearer test")
		w := httptest.NewRecorder()
		api.ServeHTTP(w, r)
		return w.Code
	}
	if read("1") != 503 || read("3") != 404 {
		t.Fatal("wrong dynamic history scope")
	}
	set.replace([]uint64{2, 3})
	if read("1") != 404 || read("3") != 503 {
		t.Fatal("history scope not refreshed")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		t.Fatal("shutdown stuck")
	}
}

func TestDiscoveryFailureKeepsLastCompleteSet(t *testing.T) {
	set := newMonitorSet([]uint64{7})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	second := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	calls := 0
	go func() {
		defer close(done)
		refreshMonitors(ctx, set, func(ctx context.Context) ([]uint64, error) {
			calls++
			if calls == 1 {
				return []uint64{99}, errors.New("incomplete page")
			}
			if calls == 2 {
				close(second)
				select {
				case <-release:
					return []uint64{8}, nil
				case <-ctx.Done():
					return nil, ctx.Err()
				}
			}
			<-ctx.Done()
			return nil, ctx.Err()
		}, time.Millisecond)
	}()
	select {
	case <-second:
	case <-time.After(time.Second):
		t.Fatal("discovery not retried")
	}
	if !reflect.DeepEqual(set.snapshot(), []uint64{7}) {
		t.Fatal("partial result replaced set")
	}
	close(release)
	deadline := time.Now().Add(time.Second)
	for !set.contains(8) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !reflect.DeepEqual(set.snapshot(), []uint64{8}) {
		t.Fatal("complete result not published")
	}
	cancel()
	<-done
}

// Use real wire pages rather than changing production budgets for tests.
func discoveryPage(t *testing.T, assets []p.Asset, more bool, paddedBytes int) []byte {
	t.Helper()
	encode := func() []byte {
		var b bytes.Buffer
		last := p.Asset{}
		if more {
			last = assets[len(assets)-1]
		}
		flag := uint8(0)
		if more {
			flag = 1
		}
		for _, v := range []any{uint64(0), uint8(0), flag, last.UpdatedAt, last.AssetID, uint32(len(assets)), uint16(len(assets)), uint32(1)} {
			_ = binary.Write(&b, binary.BigEndian, v)
		}
		for _, a := range assets {
			for _, v := range []any{uint16(p.AssetTypeMonitor), a.AssetID, uint16(0), uint64(0), uint16(0), int64(100), a.UpdatedAt, uint64(0), uint8(0), uint32(0), uint16(len(a.Preview))} {
				_ = binary.Write(&b, binary.BigEndian, v)
			}
			b.WriteString(a.Preview)
			_ = binary.Write(&b, binary.BigEndian, uint16(0))
		}
		return b.Bytes()
	}
	body := encode()
	if paddedBytes == 0 {
		return body
	}
	remaining := paddedBytes - len(body)
	if remaining < 0 {
		t.Error("padding smaller than page")
		return nil
	}
	for i := range assets {
		n := min(remaining, 65535-len(assets[i].Preview))
		assets[i].Preview += strings.Repeat(" ", n)
		remaining -= n
	}
	if remaining != 0 {
		t.Error("padding cannot fit previews")
		return nil
	}
	return encode()
}

func discoveryPeer(t *testing.T, page func(int, []byte) []byte) nrcSource {
	t.Helper()
	var mu sync.Mutex
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		up := websocket.Upgrader{}
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		ready, _ := (&p.Message{Opcode: p.S_ServerReady}).Write()
		_ = c.WriteMessage(websocket.BinaryMessage, ready)
		_, wire, err := c.ReadMessage()
		if err != nil {
			return
		}
		mu.Lock()
		calls++
		body := page(calls, wire)
		mu.Unlock()
		if body == nil {
			return
		}
		response, _ := (&p.Message{Opcode: p.S_AssetListPage, Data: body}).Write()
		_ = c.WriteMessage(websocket.BinaryMessage, response)
	}))
	t.Cleanup(server.Close)
	return nrcSource{server: "ws" + strings.TrimPrefix(server.URL, "http"), workspace: "w", nickname: "checker", secret: "test"}
}

func TestDiscoveryBudgets(t *testing.T) {
	for _, tc := range []struct {
		name                           string
		count, perPage, pad, lastExtra int
		reason                         discoveryFailure
	}{
		{name: "1024 assigned", count: 1024, perPage: 128},
		{name: "1025 assigned", count: 1025, perPage: 128, reason: "assigned_monitor_limit"},
		{name: "128 pages", count: 128, perPage: 1},
		{name: "129 pages", count: 129, perPage: 1, reason: "page_limit"},
		// A normal NRC frame cannot exhaust 16 MiB in 128 pages. Oversized but
		// decodable peer pages exercise this independent aggregate safety bound.
		{name: "16 MiB", count: 256, perPage: 4, pad: 262144},
		{name: "16 MiB plus one", count: 256, perPage: 4, pad: 262144, lastExtra: 1, reason: "byte_limit"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := discoveryPeer(t, func(n int, wire []byte) []byte {
				if n > 128 {
					t.Error("requested beyond page budget")
				}
				end := min(n*tc.perPage, tc.count)
				rows := []p.Asset{}
				for i := (n - 1) * tc.perPage; i < end; i++ {
					rows = append(rows, p.Asset{AssetID: uint64(tc.count - i), UpdatedAt: 100, Preview: `{"evaluator":"checker"}`})
				}
				pad := tc.pad
				if end == tc.count {
					pad += tc.lastExtra
				}
				return discoveryPage(t, rows, end < tc.count, pad)
			})
			ids, err := s.discover(context.Background())
			if tc.reason != "" {
				if err != tc.reason || ids != nil {
					t.Fatalf("got %v %v, want %v without partial IDs", ids, err, tc.reason)
				}
				return
			}
			if err != nil || len(ids) != tc.count {
				t.Fatalf("count=%d err=%v", len(ids), err)
			}
			for i, id := range ids {
				if id != uint64(i+1) {
					t.Fatalf("missing or duplicate ID: %d at %d", id, i)
				}
			}
		})
	}
}

func TestDiscoveryTimeout(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	entered := make(chan struct{})
	s := discoveryPeer(t, func(_ int, _ []byte) []byte { close(entered); <-release; return nil })
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	ids, err := s.discover(ctx)
	select {
	case <-entered:
	default:
		t.Fatal("timeout did not exercise an in-flight page")
	}
	if err != discoveryFailure("timeout") || ids != nil {
		t.Fatalf("%v %v", ids, err)
	}
}

func TestDiscoveryLiveCursorMove(t *testing.T) {
	rows := []p.Asset{{AssetID: 3, UpdatedAt: 300, Preview: `{"evaluator":"checker"}`}, {AssetID: 2, UpdatedAt: 200, Preview: `{"evaluator":"checker"}`}, {AssetID: 1, UpdatedAt: 100, Preview: `{"evaluator":"checker"}`}}
	s := discoveryPeer(t, func(n int, wire []byte) []byte {
		// The unread second monitor moves ahead of the first page's cursor.
		if n == 2 {
			rows[1].UpdatedAt = 400
		}
		sorted := slices.Clone(rows)
		slices.SortFunc(sorted, func(a, b p.Asset) int {
			if a.UpdatedAt > b.UpdatedAt {
				return -1
			}
			return 1
		})
		eligible := []p.Asset{}
		for _, a := range sorted {
			if wire[15] != 0 {
				at := int64(binary.BigEndian.Uint64(wire[16:]))
				id := binary.BigEndian.Uint64(wire[24:])
				if a.UpdatedAt > at || a.UpdatedAt == at && a.AssetID >= id {
					continue
				}
			}
			eligible = append(eligible, a)
		}
		return discoveryPage(t, eligible[:min(1, len(eligible))], len(eligible) > 1, 0)
	})
	set := newMonitorSet([]uint64{1, 2, 3})
	// Drive the actual publication loop through two successful live scans.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	between := make(chan struct{})
	resume := make(chan struct{})
	third := make(chan struct{})
	done := make(chan struct{})
	passes := 0
	go func() {
		defer close(done)
		refreshMonitors(ctx, set, func(ctx context.Context) ([]uint64, error) {
			passes++
			if passes == 2 {
				close(between)
				select {
				case <-resume:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
			}
			if passes == 3 {
				close(third)
				<-ctx.Done()
				return nil, ctx.Err()
			}
			return s.discover(ctx)
		}, time.Millisecond)
	}()
	select {
	case <-between:
	case <-time.After(3 * time.Second):
		t.Fatal("first live scan did not finish")
	}
	if !reflect.DeepEqual(set.snapshot(), []uint64{1, 3}) {
		t.Fatal("successful live scan should publish its observed set", set.snapshot())
	}
	close(resume)
	select {
	case <-third:
	case <-time.After(3 * time.Second):
		t.Fatal("second live scan did not finish")
	}
	if !reflect.DeepEqual(set.snapshot(), []uint64{1, 2, 3}) {
		t.Fatal("next scan did not converge", set.snapshot())
	}
	cancel()
	<-done
}

func TestDiscoveryFailureLogging(t *testing.T) {
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
	defer slog.SetDefault(previous)
	for _, failure := range []error{discoveryFailure("assigned_monitor_limit"), discoveryFailure("byte_limit"), discoveryFailure("page_limit"), discoveryFailure("timeout"), discoveryFailure("request_failed"), errors.New("https://private.example/?token=SECRET")} {
		ctx, cancel := context.WithCancel(context.Background())
		calls := 0
		refreshMonitors(ctx, newMonitorSet([]uint64{7}), func(ctx context.Context) ([]uint64, error) {
			calls++
			if calls == 2 {
				cancel()
				return nil, ctx.Err()
			}
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) > 30*time.Second || time.Until(deadline) < 29*time.Second {
				t.Error("discovery pass lacks its 30 second deadline")
			}
			return nil, failure
		}, time.Millisecond)
		cancel()
	}
	if strings.Contains(logs.String(), "SECRET") || strings.Contains(logs.String(), "private.example") {
		t.Fatal("raw discovery error leaked into logs")
	}
	decoder := json.NewDecoder(&logs)
	for _, want := range []string{"assigned_monitor_limit", "byte_limit", "page_limit", "timeout", "request_failed", "unclassified"} {
		var row struct {
			Reason string `json:"reason"`
		}
		if err := decoder.Decode(&row); err != nil || row.Reason != want {
			t.Fatalf("logged %q %v, want %q", row.Reason, err, want)
		}
	}
}
