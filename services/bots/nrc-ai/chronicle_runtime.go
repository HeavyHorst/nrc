package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type chronicleWorkspace struct {
	name, token string
}

// Separate restricted sockets, never Sullivan's general-purpose NRCClient.
// Each pool lane uses one socket at a time; there is no local raw-data queue.
type chronicleSession struct {
	server, workspace, token string
	conn                     *websocket.Conn
	correlation              uint32
}

func (s *chronicleSession) close() {
	if s.conn != nil {
		s.conn.Close()
		s.conn = nil
	}
}

func (s *chronicleSession) connect(ctx context.Context) error {
	u, err := url.Parse(s.server)
	if err != nil || (u.Scheme != "ws" && u.Scheme != "wss") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("invalid chronicle server URL")
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/" + s.workspace
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	conn, response, err := dialer.DialContext(ctx, u.String(), http.Header{"X-NRC-Auth": {s.token}})
	if response != nil && response.Body != nil {
		response.Body.Close()
	}
	if err != nil {
		return errors.New("chronicle connection refused")
	}
	s.conn = conn
	conn.SetReadLimit(protocol.MaxProtocolPayloadSize)
	return nil
}

func (s *chronicleSession) call(ctx context.Context, q protocol.ChronicleRequest) (*protocol.ChronicleResponse, error) {
	s.correlation++
	wire, err := protocol.EncodeChronicleRequest(q, s.correlation)
	if err != nil {
		return nil, errors.New("invalid chronicle request")
	}
	// Only these operations have exact durable replay semantics. Never blindly
	// re-claim or re-release after an unknown transport outcome.
	attempts := 1
	if q.Op == "commit" || q.Op == "reserve" {
		attempts = 2
	}
	for attempt := 0; attempt < attempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if s.conn == nil {
			if err := s.connect(ctx); err != nil {
				return nil, err
			}
		}
		requestCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		conn := s.conn
		stop := context.AfterFunc(requestCtx, func() { conn.Close() })
		r, err := protocol.RetryDatabaseRequest(requestCtx, protocol.C_Chronicle, s.correlation, func(ctx context.Context) (*protocol.Message, error) {
			deadline, _ := ctx.Deadline()
			conn.SetWriteDeadline(deadline)
			conn.SetReadDeadline(deadline)
			if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				return nil, err
			}
			for skipped := 0; skipped < 16; skipped++ {
				kind, data, err := conn.ReadMessage()
				if err != nil {
					return nil, err
				}
				if kind != websocket.BinaryMessage || len(data) < 2 {
					return nil, errors.New("invalid chronicle frame")
				}
				op := binary.BigEndian.Uint16(data)
				if op == protocol.S_ServerReady {
					ready, err := protocol.ParseServerReady(data)
					if err != nil || !ready.IsAuthenticated {
						return nil, errors.New("unauthenticated chronicle connection")
					}
					continue
				}
				return &protocol.Message{Opcode: op, Data: data[2:]}, nil
			}
			return nil, errors.New("unexpected chronicle traffic")
		})
		stopped := stop()
		cancel()
		if err != nil || !stopped {
			s.close()
			continue
		}
		if r.Opcode != protocol.S_Chronicle {
			return nil, errors.New("chronicle request rejected")
		}
		answer, err := protocol.DecodeChronicleResponse(r.Data)
		if err != nil || answer.CorrelationID != s.correlation {
			s.close()
			return nil, errors.New("invalid chronicle response")
		}
		return answer, nil
	}
	return nil, errors.New("chronicle transport outcome unknown")
}

func loadChronicleWorkspaces(path string) ([]chronicleWorkspace, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, errors.New("cannot open chronicle token file")
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 256<<10 {
		return nil, errors.New("chronicle token file exceeds size bound")
	}
	// Provision short-lived, workspace-scoped JWTs externally. The worker needs
	// neither the signing secret nor the broad legacy bot credential.
	d := json.NewDecoder(io.LimitReader(f, (256<<10)+1))
	open, err := d.Token()
	if err != nil || open != json.Delim('{') {
		return nil, errors.New("invalid chronicle token map")
	}
	var workspaces []chronicleWorkspace
	seen := map[string]bool{}
	for d.More() {
		key, err := d.Token()
		name, ok := key.(string)
		var token string
		if err != nil || !ok || !aiWorkspacePattern.MatchString(name) || seen[name] || len(workspaces) >= 16 || d.Decode(&token) != nil || strings.TrimSpace(token) == "" || len(token) > 8192 || strings.ContainsAny(token, "\r\n") {
			return nil, errors.New("invalid chronicle workspace credential")
		}
		seen[name] = true
		workspaces = append(workspaces, chronicleWorkspace{name, token})
	}
	if _, err = d.Token(); err != nil || d.Decode(new(any)) != io.EOF || len(workspaces) == 0 {
		return nil, errors.New("invalid chronicle token map")
	}
	sort.Slice(workspaces, func(i, j int) bool { return workspaces[i].name < workspaces[j].name })
	return workspaces, nil
}

// Standalone mode of the existing AI binary: no chat model initialization,
// HTTP tools, subscriptions, canonical writes, or shared bot secret.
func runChronicle(ctx context.Context, server, tokenFile string, provider chronicleProvider) error {
	workspaces, err := loadChronicleWorkspaces(tokenFile)
	if err != nil {
		return err
	}
	runChroniclePool(ctx, workspaces, func(ctx context.Context, workspace chronicleWorkspace) (string, error) {
		s := chronicleSession{server: server, workspace: workspace.name, token: workspace.token}
		defer s.close()
		worker := chronicleWorker{call: s.call, provider: provider, now: time.Now}
		return worker.step(ctx)
	})
	return nil
}

const chronicleLanes = 10

// Bound all active steps (including counting and inference) process-wide, even
// if more than one runner is started. Each owns its own restricted socket.
var chronicleSlots = make(chan struct{}, chronicleLanes)

func chronicleProgress(status string) bool {
	switch status {
	case "committed", "acknowledged", "gap", "staged", "changed":
		return true
	}
	return false
}

// Round-robin admission, not fixed workspace partitions: one workspace can use
// every lane. Only workspace metadata and completion statuses are scheduled;
// raw inputs remain server-side until an admitted step claims them.
func runChroniclePool(ctx context.Context, workspaces []chronicleWorkspace, step func(context.Context, chronicleWorkspace) (string, error)) {
	if len(workspaces) == 0 {
		return
	}
	type completion struct {
		workspace int
		status    string
		err       error
	}
	done := make(chan completion, chronicleLanes)
	readyAt := make([]time.Time, len(workspaces))
	active, next := 0, 0
	for {
		now := time.Now()
		for ctx.Err() == nil && active < chronicleLanes {
			chosen := -1
			for offset := 0; offset < len(workspaces); offset++ {
				i := (next + offset) % len(workspaces)
				if !readyAt[i].After(now) {
					chosen = i
					break
				}
			}
			if chosen < 0 {
				break
			}
			next = (chosen + 1) % len(workspaces)
			active++
			go func(i int) {
				stepCtx, cancel := context.WithTimeout(ctx, 4*time.Minute)
				defer cancel()
				select {
				case chronicleSlots <- struct{}{}:
				case <-stepCtx.Done():
					done <- completion{i, "waiting", stepCtx.Err()}
					return
				}
				status, err := step(stepCtx, workspaces[i])
				<-chronicleSlots
				done <- completion{i, status, err}
			}(chosen)
		}
		if ctx.Err() != nil {
			// The completion channel holds every admitted step; no sender can
			// be stranded while cancellation closes sockets/provider requests.
			for ; active > 0; active-- {
				<-done
			}
			return
		}
		wait := 5 * time.Second
		if active < chronicleLanes {
			for _, at := range readyAt {
				wait = min(wait, max(0, time.Until(at)))
			}
		}
		timer := time.NewTimer(wait)
		select {
		case result := <-done:
			active--
			if result.err == nil && chronicleProgress(result.status) {
				readyAt[result.workspace] = time.Time{}
			} else {
				readyAt[result.workspace] = time.Now().Add(5 * time.Second)
			}
			// Never log provider errors, payloads, summaries, or credentials.
			if result.err != nil || result.status != "waiting" {
				slog.Info("chronicle step", "workspace", workspaces[result.workspace].name, "status", result.status, "failed", result.err != nil)
			}
		case <-ctx.Done():
		case <-timer.C:
		}
		timer.Stop()
	}
}
