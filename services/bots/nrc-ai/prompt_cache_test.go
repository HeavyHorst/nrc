package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	memory "nrc-ai/personal_memory"
)

func TestCacheWriteCoordinationScopeAndCancellation(t *testing.T) {
	for _, variant := range []string{"same", "owner", "workspace", "prefix", "cancel", "timeout", "failure"} {
		t.Run(variant, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var dispatched atomic.Int32
				release := make(chan struct{})
				results := make(chan error, 2)
				failed := errors.New("leader transport failed")
				next := func(r *http.Request) (*http.Response, error) {
					dispatched.Add(1)
					if r.Header.Get("Test-Leader") == "yes" {
						<-release
						if variant == "failure" {
							return nil, failed
						}
					}
					return &http.Response{StatusCode: 200, Body: http.NoBody}, nil
				}
				request := func(leader bool) (*http.Request, context.CancelFunc) {
					a := &personalMemoryAccess{owner: "alice", workspace: "team", scope: &memory.Scope{}}
					prefix := "stable"
					if !leader {
						switch variant {
						case "owner":
							a.owner = "bob"
						case "workspace":
							a.workspace = "other"
						case "prefix":
							prefix = "changed"
						}
					}
					ctx, cancel := context.WithCancel(context.WithValue(context.WithValue(t.Context(), personalMemoryKey{}, a), askCacheBoundaryKey{}, 0))
					r := httptest.NewRequest("POST", "https://provider.invalid/responses", strings.NewReader(fmt.Sprintf(`{"model":"gpt-6.1-terra","input":[{"role":"user","content":[{"type":"input_text","text":%q}]}]}`, prefix))).WithContext(ctx)
					if leader {
						r.Header.Set("Test-Leader", "yes")
					}
					return r, cancel
				}
				first, cancelFirst := request(true)
				defer cancelFirst()
				go func() { _, err := openAIAskCacheBoundary(first, next); results <- err }()
				synctest.Wait()
				second, cancelSecond := request(false)
				defer cancelSecond()
				go func() { _, err := openAIAskCacheBoundary(second, next); results <- err }()
				synctest.Wait()
				want := int32(2)
				if variant == "same" || variant == "cancel" || variant == "timeout" || variant == "failure" {
					want = 1
				}
				if dispatched.Load() != want {
					t.Fatalf("dispatches before prefix ready: got %d want %d", dispatched.Load(), want)
				}
				if variant == "timeout" {
					time.Sleep(time.Second)
					synctest.Wait()
					if dispatched.Load() != 2 {
						t.Fatal("waiter inherited unbounded leader delay")
					}
				}
				if variant == "cancel" {
					cancelSecond()
					synctest.Wait()
					if err := <-results; !errors.Is(err, context.Canceled) {
						t.Fatal(err)
					}
				}
				close(release)
				if err := <-results; err != nil && !(variant == "failure" && errors.Is(err, failed)) {
					t.Fatal(err)
				}
				if variant != "cancel" {
					if err := <-results; err != nil && !(variant == "failure" && errors.Is(err, failed)) {
						t.Fatal(err)
					}
				}
				finalCount := int32(2)
				if variant == "cancel" {
					finalCount = 1
				}
				if dispatched.Load() != finalCount {
					t.Fatalf("final dispatches: got %d want %d", dispatched.Load(), finalCount)
				}
			})
		})
	}
}
