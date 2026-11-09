package main

import (
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/charmbracelet/openai-go/option"
)

// Coordinate only concurrent writes of an identical prefix in the same private
// epoch. No prompt text, completed entries, or assumptions about provider TTLs
// are retained. Provider response headers release followers, including streams.
var promptCacheWrites = struct {
	sync.Mutex
	active map[[32]byte]chan struct{}
}{active: make(map[[32]byte]chan struct{})}

func coordinatedCacheRequest(req *http.Request, next option.MiddlewareNext, payload map[string]json.RawMessage, prefix []json.RawMessage) (*http.Response, error) {
	a, ok := req.Context().Value(personalMemoryKey{}).(*personalMemoryAccess)
	if !ok {
		return next(req)
	}
	encoded, err := json.Marshal([]any{a.owner, a.workspace, a.scope.Epoch(), req.URL.String(), req.Header.Get("Authorization"), payload["model"], payload["instructions"], payload["tools"], prefix})
	if err != nil {
		return nil, err
	}
	key := sha256.Sum256(encoded)
	promptCacheWrites.Lock()
	if done := promptCacheWrites.active[key]; done != nil {
		promptCacheWrites.Unlock()
		timer := time.NewTimer(time.Second)
		defer timer.Stop()
		select {
		case <-req.Context().Done():
			return nil, req.Context().Err()
		case <-done:
		case <-timer.C:
			// A cache optimization must not inherit a slow leader's latency.
		}
		if err := req.Context().Err(); err != nil {
			return nil, err
		}
		return next(req)
	}
	// Saturation must not turn a cache optimization into admission control.
	if len(promptCacheWrites.active) >= 1024 {
		promptCacheWrites.Unlock()
		return next(req)
	}
	done := make(chan struct{})
	promptCacheWrites.active[key] = done
	promptCacheWrites.Unlock()
	defer func() {
		promptCacheWrites.Lock()
		delete(promptCacheWrites.active, key)
		close(done)
		promptCacheWrites.Unlock()
	}()
	return next(req)
}
