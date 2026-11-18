package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"charm.land/fantasy"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// Uses only a locally built binary and disposable storage, never a shared URL.
func TestHistoryToolsRealServer(t *testing.T) {
	bin := os.Getenv("NRC_RECEIPT_E2E_BIN")
	if bin == "" {
		t.Skip("set NRC_RECEIPT_E2E_BIN to a locally built Odin server")
	}
	bin, err := filepath.Abs(bin)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	const workspace = "history-tool-e2e"
	address := fmt.Sprintf("127.0.0.1:%d", port)
	serverURL := "ws://" + address
	log, err := os.Create(filepath.Join(dir, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	cmd := exec.Command(bin)
	cmd.Dir = dir
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), fmt.Sprintf("NRC_PORT=%d", port),
		"NRC_THREAD_COUNT=1", "NRC_STORAGE_BULK_EXECUTORS=1",
		"NRC_JWT_SECRET=" + testAIKey, "NRC_BOT_SECRET=" + testAIKey,
		"NRC_JWT_ISSUER=test-issuer", "NRC_JWT_AUDIENCE=nrc",
		"NRC_CHRONICLE_WORKSPACES=" + workspace,
		// Allowlists alone must not turn an ordinary bot into a worker or human.
		`NRC_CHRONICLE_SERVICE_SUBJECTS={"history-tool-e2e":["fixture-worker","service:nrc-ai"]}`,
		`NRC_CHRONICLE_DELETE_SUBJECTS={"history-tool-e2e":["service:nrc-ai"]}`,
	}
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	defer func() {
		cmd.Process.Signal(os.Interrupt)
		select {
		case err := <-exited:
			if err != nil {
				t.Logf("server exit: %v", err)
			}
		case <-time.After(10 * time.Second):
			cmd.Process.Kill()
			<-exited
			t.Error("server did not stop gracefully")
		}
	}()
	deadline := time.Now().Add(60 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			body, _ := os.ReadFile(log.Name())
			t.Fatalf("server startup failed: %s", body)
		}
		time.Sleep(50 * time.Millisecond)
	}
	for k, v := range map[string]string{"NRC_SERVER": serverURL, "NRC_BOT_SECRET": testAIKey, "NRC_JWT_SECRET": testAIKey, "NRC_JWT_ISSUER": "test-issuer", "NRC_JWT_AUDIENCE": "nrc", "NRC_NICKNAME": "Sullivan-fixture", "NRC_TICKET_CLASSIFICATION_WORKSPACES": "", "NRC_KNOWLEDGE_GAP_SLICES": ""} {
		t.Setenv(k, v)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	connect := func(cfg Config, ws string) *NRCClient {
		t.Helper()
		c := NewNRCClient(cfg, ws)
		if err := c.connect(ctx); err != nil {
			t.Fatal(err)
		}
		done := make(chan struct{})
		go func() { defer close(done); c.readPump(ctx) }()
		t.Cleanup(func() { c.Stop(); <-done })
		ready, _ := c.ReadyState()
		select {
		case <-ready:
		case <-ctx.Done():
			t.Fatal("no server ready")
		}
		return c
	}
	c := connect(loadConfig(), workspace)
	status, err := c.ReadChronicle(ctx, 0, chronicleReadInput{Operation: "status"})
	if err != nil {
		t.Fatalf("normal Sullivan Chronicle status: %v", err)
	}
	if !status.Enabled || status.CanDelete {
		t.Fatalf("unexpected read authority: %+v", status)
	}
	t.Log("normal Sullivan handshake: Chronicle enabled, can_delete=false")

	// Seed through the real mutation path, which must remain available to the bot.
	note, err := c.CreateNote(ctx, 0, "Backup-Frist", "Freigabe am Freitag, nicht Donnerstag.", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	other, err := c.CreateNote(ctx, 0, "Anderer Inhalt", "Nicht zur Backup-Frist gehörig.", "", nil)
	if err != nil {
		t.Fatal(err)
	}

	// A separate worker identity writes deterministic fixture results through
	// the actual Chronicle transaction API. No LLM or production service is used.
	claims, _ := json.Marshal(map[string]any{"sub": "fixture-worker", "username": "fixture-worker", "workspace": workspace, "user_type": "bot", "capability": "chronicle", "iss": "test-issuer", "aud": "nrc", "exp": time.Now().Add(time.Minute).Unix()})
	unsigned := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`)) + "." + base64.RawURLEncoding.EncodeToString(claims)
	mac := hmac.New(sha256.New, []byte(testAIKey))
	mac.Write([]byte(unsigned))
	worker := chronicleSession{server: serverURL, workspace: workspace, token: unsigned + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))}
	defer worker.close()
	call := func(q protocol.ChronicleRequest, want string) *protocol.ChronicleResponse {
		t.Helper()
		r, err := worker.call(ctx, q)
		if err != nil || r.Status != want {
			t.Fatalf("worker %s: %+v %v, want %s", q.Op, r, err, want)
		}
		return r
	}
	for i := 0; i < 2; i++ {
		claim := call(protocol.ChronicleRequest{Op: "claim", Consumer: protocol.ChronicleConsumerVersion, Limit: 32}, "claimed")
		q := protocol.ChronicleRequest{Op: "reserve", Consumer: protocol.ChronicleConsumerVersion, Epoch: claim.Epoch, Generation: claim.Generation, Sources: claim.Sources, InputTokens: 100, OutputTokens: 1000}
		call(q, "reserved")
		q.Op, q.Outcome = "commit", "result"
		q.Summary = "Zusammenfassung für " + claim.NoteID
		q.Model, q.PromptVersion, q.SchemaVersion = "fixture", "p1", "s1"
		q.InputTokens, q.OutputTokens = 60, 20
		call(q, "committed")
	}
	toolCtx := context.WithValue(context.WithValue(ctx, workspaceContextKey{}, workspace), convIDContextKey{}, uint64(0))
	tools := newHistoryTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{workspace: c}})
	read := func(index int, input string) string {
		t.Helper()
		r, err := tools[index].Run(toolCtx, fantasy.ToolCall{Input: input})
		if err != nil || r.IsError {
			t.Fatalf("tool read: %s %v", r.Content, err)
		}
		return r.Content
	}
	var history historyReadPage
	if err := json.Unmarshal([]byte(read(0, fmt.Sprintf(`{"entity_type":"asset","entity_id":"%d"}`, note.AssetID))), &history); err != nil {
		t.Fatal(err)
	}
	if len(history.Events) != 1 {
		t.Fatalf("filtered history: %+v", history)
	}
	var event struct {
		EntityID string `json:"entityId"`
		ActorID  string `json:"actorId"`
	}
	if err := json.Unmarshal(history.Events[0], &event); err != nil {
		t.Fatal(err)
	}
	if event.EntityID != dataString(note.AssetID) || event.ActorID != "service:nrc-ai" {
		t.Fatalf("wrong history identity: %+v", event)
	}
	var page struct {
		Entries []protocol.ChronicleEntry `json:"entries"`
		Cursor  string                    `json:"cursor"`
		More    bool                      `json:"more"`
	}
	if err := json.Unmarshal([]byte(read(1, fmt.Sprintf(`{"note_id":"%d"}`, note.AssetID))), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 1 || page.Entries[0].NoteID != dataString(note.AssetID) || page.Entries[0].Summary != "Zusammenfassung für "+dataString(note.AssetID) {
		t.Fatalf("filtered summaries: %+v", page)
	}
	t.Logf("record filter: history=1, summaries=1 for note %d; other note %d excluded", note.AssetID, other.AssetID)
	if err := json.Unmarshal([]byte(read(1, `{"limit":1}`)), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 1 || !page.More {
		t.Fatalf("first page: %+v", page)
	}
	first := page.Entries[0].NoteID
	if err := json.Unmarshal([]byte(read(1, fmt.Sprintf(`{"limit":1,"cursor":%q}`, page.Cursor))), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 1 || page.More || page.Entries[0].NoteID == first {
		t.Fatalf("second page: %+v", page)
	}
	read(1, fmt.Sprintf(`{"operation":"gaps","note_id":"%d"}`, note.AssetID))
	read(1, fmt.Sprintf(`{"operation":"status","note_id":"%d"}`, note.AssetID))
	t.Log("Chronicle pagination: two distinct notes over two pages; filtered gaps/status readable")
	// Bypass the model allowlist to verify the actual server still denies writes.
	for _, op := range []string{"delete", "claim", "chunk", "reserve", "commit", "retry"} {
		v, err := c.correlatedDataRead(ctx, 0, protocol.C_Chronicle, func(id uint32) ([]byte, error) {
			b, err := protocol.EncodeChronicleRequest(protocol.ChronicleRequest{Op: op, NoteID: dataString(note.AssetID), Consumer: protocol.ChronicleConsumerVersion}, id)
			if err != nil {
				return nil, err
			}
			return b[2:], nil
		})
		if err != nil || v.(*protocol.ChronicleResponse).Status != "forbidden" {
			t.Fatalf("%s not forbidden: %+v %v", op, v, err)
		}
	}
	legacy := connect(Config{NRCServer: serverURL, NRCBotSecret: testAIKey, NRCNickname: "legacy-fixture"}, workspace)
	if _, err := legacy.ReadChronicle(ctx, 0, chronicleReadInput{Operation: "status"}); err == nil {
		t.Fatal("legacy bot gained Chronicle access")
	}
	foreign := connect(loadConfig(), "other-workspace")
	foreignPage, err := foreign.ReadChronicle(ctx, 0, chronicleReadInput{})
	if err != nil || len(foreignPage.Entries) != 0 {
		t.Fatalf("workspace data leaked: %+v %v", foreignPage, err)
	}
	t.Log("server denied all six mutation/worker operations and legacy reads; other workspace has no summaries")
	for _, invalid := range []string{"signature", "issuer", "audience"} {
		cfg := loadConfig()
		switch invalid {
		case "signature":
			cfg.NRCJWTSecret = "different-fixture-signing-key-not-production"
		case "issuer":
			cfg.NRCJWTIssuer = "wrong-issuer"
		case "audience":
			cfg.NRCJWTAudience = "nrc-ai"
		}
		denied := NewNRCClient(cfg, workspace)
		if err := denied.connect(ctx); err == nil {
			denied.Stop()
			t.Fatalf("invalid JWT %s fell back to legacy bot credentials", invalid)
		}
	}
	t.Log("invalid JWT signature, issuer and audience rejected despite valid legacy bot credentials")
	// A new transport must regenerate authentication and retain read access.
	c.Stop()
	c = connect(loadConfig(), workspace)
	status, err = c.ReadChronicle(ctx, 0, chronicleReadInput{Operation: "status"})
	if err != nil || status.CanDelete {
		t.Fatalf("reconnect: %+v %v", status, err)
	}
	t.Log("reconnect: authenticated Chronicle read still succeeds")
}
