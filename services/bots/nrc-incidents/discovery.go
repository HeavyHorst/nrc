package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"slices"
	"sync"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

// One current set drives checks, outgoing webhooks and history authorization.
type monitorSet struct {
	mu  sync.RWMutex
	ids []uint64
}

func newMonitorSet(ids []uint64) *monitorSet { s := &monitorSet{}; s.replace(ids); return s }
func (s *monitorSet) replace(ids []uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ids = slices.Clone(ids)
	slices.Sort(s.ids)
}
func (s *monitorSet) snapshot() []uint64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return slices.Clone(s.ids)
}
func (s *monitorSet) contains(id uint64) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := slices.BinarySearch(s.ids, id)
	return ok
}

// Only fixed categories cross the logging boundary, never a peer's error text.
type discoveryFailure string

func (e discoveryFailure) Error() string { return "monitor discovery: " + string(e) }

func (s nrcSource) discover(ctx context.Context) ([]uint64, error) {
	ids := map[uint64]bool{}
	var at int64
	var cursor uint64
	bytes := 0
	for pageNo := 0; pageNo < 128; pageNo++ {
		wire, _ := (&p.Message{Opcode: p.C_ListAssetsPaged, Data: p.EncodeListAssetsPagedWithCorrelation(0, p.AssetTypeMonitor, false, 128, pageNo != 0, at, cursor, 1)}).Write()
		body, err := s.request(ctx, wire, p.S_AssetListPage, 1)
		if err != nil {
			if deadline, ok := ctx.Deadline(); ok && !time.Now().Before(deadline) {
				return nil, discoveryFailure("timeout")
			}
			if errors.Is(ctx.Err(), context.Canceled) {
				return nil, discoveryFailure("canceled")
			}
			if errors.Is(err, errRejected) {
				return nil, discoveryFailure("rejected")
			}
			return nil, discoveryFailure("request_failed")
		}
		bytes += len(body)
		if bytes > 16<<20 {
			return nil, discoveryFailure("byte_limit")
		}
		page, err := p.DecodeAssetListPage(body)
		if err != nil {
			return nil, discoveryFailure("invalid_page")
		}
		if page.CorrelationID != 1 {
			return nil, discoveryFailure("invalid_correlation")
		}
		for _, a := range page.Assets {
			if a.AssetType != p.AssetTypeMonitor || a.ConvID != 0 || a.AssetID == 0 {
				return nil, discoveryFailure("invalid_asset")
			}
			var c struct {
				Evaluator string `json:"evaluator"`
			}
			if json.Unmarshal([]byte(a.Preview), &c) != nil {
				return nil, discoveryFailure("invalid_preview")
			}
			if c.Evaluator == s.nickname {
				ids[a.AssetID] = true
			}
			if len(ids) > 1024 {
				return nil, discoveryFailure("assigned_monitor_limit")
			}
		}
		if !page.HasMore {
			result := make([]uint64, 0, len(ids))
			for id := range ids {
				result = append(result, id)
			}
			slices.Sort(result)
			return result, nil
		}
		if page.NextCursorAssetID == 0 || page.NextCursorUpdatedAt <= 0 || pageNo > 0 && (page.NextCursorUpdatedAt > at || page.NextCursorUpdatedAt == at && page.NextCursorAssetID >= cursor) {
			return nil, discoveryFailure("nonadvancing_cursor")
		}
		at, cursor = page.NextCursorUpdatedAt, page.NextCursorAssetID
	}
	return nil, discoveryFailure("page_limit")
}

func refreshMonitors(ctx context.Context, set *monitorSet, discover func(context.Context) ([]uint64, error), interval time.Duration) {
	for {
		readCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		ids, err := discover(readCtx)
		cancel()
		if err == nil {
			set.replace(ids)
		} else if ctx.Err() == nil {
			reason := "unclassified"
			var failure discoveryFailure
			if errors.As(err, &failure) {
				reason = string(failure)
			}
			slog.Warn("monitor discovery failed; retaining last complete set", "reason", reason)
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

// Reconcile individual loops without restarting unchanged monitors. The shared
// semaphore bounds work across additions, and a removed loop drains before reuse.
func runMonitorLoops(ctx context.Context, set *monitorSet, workers int, run func(context.Context, uint64) time.Duration) {
	type loop struct {
		cancel context.CancelFunc
		done   chan struct{}
	}
	active := map[uint64]loop{}
	semaphore := make(chan struct{}, workers)
	defer func() {
		for _, l := range active {
			l.cancel()
		}
		for _, l := range active {
			<-l.done
		}
	}()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		ids := set.snapshot()
		for id, l := range active {
			if _, ok := slices.BinarySearch(ids, id); !ok {
				l.cancel()
				<-l.done
				delete(active, id)
			}
		}
		for _, id := range ids {
			if _, ok := active[id]; ok {
				continue
			}
			child, cancel := context.WithCancel(ctx)
			done := make(chan struct{})
			active[id] = loop{cancel, done}
			go func() {
				defer close(done)
				for {
					select {
					case <-child.Done():
						return
					case semaphore <- struct{}{}:
					}
					if child.Err() != nil {
						<-semaphore
						return
					}
					delay := run(child, id)
					<-semaphore
					timer := time.NewTimer(max(delay, time.Second))
					select {
					case <-child.Done():
						timer.Stop()
						return
					case <-timer.C:
					}
				}
			}()
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
