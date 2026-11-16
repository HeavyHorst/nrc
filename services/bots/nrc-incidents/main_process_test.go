package main

import (
	"bytes"
	"context"
	"flag"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Run the actual entry point in a subprocess: flag state, umask and signals
// must not affect the parent test runner.
func TestSidecarProcessHelper(t *testing.T) {
	if os.Getenv("NRC_INCIDENTS_TEST_PROCESS") != "1" {
		return
	}
	for i, arg := range os.Args {
		if arg == "--" {
			os.Args = append([]string{os.Args[0]}, os.Args[i+1:]...)
			flag.CommandLine = flag.NewFlagSet("nrc-incidents", flag.ExitOnError)
			main()
			return
		}
	}
	t.Fatal("missing child arguments")
}

func TestHistoryListenerProcess(t *testing.T) {
	const secret = "local-test-history-token-32-characters"
	for _, tc := range []struct {
		name, secret, wantError string
		enabled, occupied       bool
	}{
		{name: "default-off"},
		{name: "discovery-default"},
		{name: "missing-secret", enabled: true, wantError: "history listener requires NRC_HISTORY_SECRET"},
		{name: "short-secret", enabled: true, secret: "short", wantError: "history listener requires NRC_HISTORY_SECRET"},
		{name: "whitespace-secret", enabled: true, secret: secret + " ", wantError: "history listener requires NRC_HISTORY_SECRET"},
		{name: "bind-error", enabled: true, occupied: true, secret: secret, wantError: "history listener unavailable"},
		{name: "serve-and-sigterm", enabled: true, secret: secret},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requested := make(chan struct{}, 1)
			nrc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				select {
				case requested <- struct{}{}:
				default:
				}
				http.Error(w, "test NRC unavailable", 503)
			}))
			defer nrc.Close()
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			address := listener.Addr().String()
			defer listener.Close()
			if !tc.occupied {
				listener.Close()
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			args := []string{"-test.run=^TestSidecarProcessHelper$", "--", "-server", "ws" + strings.TrimPrefix(nrc.URL, "http"), "-workspace", "ops", "-workers", "1", "-history", filepath.Join(t.TempDir(), "history.duckdb")}
			if tc.name != "discovery-default" {
				args = append(args, "-monitors", "1")
			}
			if tc.enabled {
				args = append(args, "-history-listen", address)
			}
			cmd := exec.CommandContext(ctx, os.Args[0], args...)
			for _, entry := range os.Environ() {
				if strings.HasPrefix(entry, "NRC_") {
					continue
				}
				cmd.Env = append(cmd.Env, entry)
			}
			cmd.Env = append(cmd.Env, "NRC_INCIDENTS_TEST_PROCESS=1", "NRC_BOT_SECRET=local-test-bot-secret", "NRC_HISTORY_SECRET="+tc.secret)
			var output bytes.Buffer
			cmd.Stdout = &output
			cmd.Stderr = &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			var waitErr error
			go func() { waitErr = cmd.Wait(); close(done) }()
			defer func() { cancel(); <-done }()
			if tc.wantError != "" {
				<-done
				if waitErr == nil || !strings.Contains(output.String(), tc.wantError) {
					t.Fatalf("startup: %v %s", waitErr, output.String())
				}
				return
			}
			select {
			case <-requested: // Scheduler reached its first real NRC request.
			case <-done:
				t.Fatalf("unexpected startup exit: %v %s", waitErr, output.String())
			case <-ctx.Done():
				t.Fatal("scheduler did not start")
			}
			client := &http.Client{Timeout: time.Second}
			defer client.CloseIdleConnections()
			if tc.enabled {
				q := "/v1/history/1/runs?from=" + time.Now().UTC().Truncate(time.Hour).Format(time.RFC3339) + "&to=" + time.Now().UTC().Truncate(time.Hour).Add(time.Hour).Format(time.RFC3339) + "&resolution=raw&acceptance=all"
				deadline := time.Now().Add(5 * time.Second)
				for {
					r, _ := http.NewRequest("GET", "http://"+address+q, nil)
					r.Header.Set("Authorization", "Bearer "+secret)
					resp, err := client.Do(r)
					if err == nil {
						body, readErr := io.ReadAll(resp.Body)
						resp.Body.Close()
						if resp.StatusCode == 200 && readErr == nil && strings.Contains(string(body), `"rows":[]`) {
							break
						}
						if resp.StatusCode != 503 {
							t.Fatalf("listener response: %d %s", resp.StatusCode, body)
						}
					}
					if time.Now().After(deadline) {
						t.Fatal("listener never served history", err)
					}
					time.Sleep(10 * time.Millisecond)
				}
				resp, err := client.Get("http://" + address + q)
				if err != nil {
					t.Fatal(err)
				}
				resp.Body.Close()
				if resp.StatusCode != 401 {
					t.Fatal("listener skipped auth", resp.StatusCode)
				}
			}
			if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
				t.Fatal(err)
			}
			select {
			case <-done:
			case <-time.After(7 * time.Second):
				t.Fatal("SIGTERM did not drain sidecar")
			}
			if waitErr != nil || !strings.Contains(output.String(), "sidecar stopped") {
				t.Fatalf("shutdown: %v %s", waitErr, output.String())
			}
			if tc.enabled {
				if conn, err := net.DialTimeout("tcp", address, time.Second); err == nil {
					conn.Close()
					t.Fatal("listener remained open after shutdown")
				}
			}
		})
	}
}
