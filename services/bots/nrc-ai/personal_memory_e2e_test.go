package main

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	memory "nrc-ai/personal_memory"
)

// NRC_AI_E2E_BIN runs main's opt-in store and worker against a local model fixture.
func TestPersonalMemoryProcess(t *testing.T) {
	bin := os.Getenv("NRC_AI_E2E_BIN")
	if bin == "" {
		t.Skip("set NRC_AI_E2E_BIN to the built AI service")
	}
	bin, err := filepath.Abs(bin)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("LLM_MAX_OUTPUT_TOKENS", "16384")
	modelCalls := make(chan string, 10)
	summaryText := strings.Repeat("Historical evidence. ", 20)
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var call struct {
			Model     string
			MaxTokens int64 `json:"max_tokens"`
		}
		if json.Unmarshal(body, &call) != nil || call.Model != "summary-fixture" {
			t.Error("wrong summary model", string(body))
		}
		if call.MaxTokens != 16384 {
			t.Error("summary did not inherit shared output limit", call.MaxTokens)
		}
		modelCalls <- string(body)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"choices":[{"index":0,"message":{"role":"assistant","content":%q},"finish_reason":"stop"}]}`, summaryText)
	}))
	defer provider.Close()
	dir := t.TempDir()
	path := filepath.Join(dir, "private", "memory.db")
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	url := fmt.Sprintf("http://127.0.0.1:%d", port)
	var process *exec.Cmd
	stop := func() {
		if process != nil {
			process.Process.Signal(os.Interrupt)
			if err := process.Wait(); err != nil {
				t.Error("AI shutdown", err)
			}
			process = nil
		}
	}
	defer stop()
	start := func() {
		log, err := os.Create(filepath.Join(dir, "ai.log"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { log.Close() })
		process = exec.Command(bin)
		process.Dir = dir
		process.Env = append(os.Environ(), "NRC_JWT_SECRET="+testAIKey, "NRC_JWT_ISSUER=test-issuer", "NRC_PERSONAL_MEMORY_PATH="+path, "NRC_MEMORY_SUMMARY_MODEL=summary-fixture", fmt.Sprintf("AI_PORT=%d", port), "LLM_PROVIDER=openai-compat", "LLM_MODEL=ask-fixture", "LLM_API_KEY=fixture", "LLM_BASE_URL="+provider.URL, "NRC_SERVER=ws://127.0.0.1:1", "NRC_VOICE_OPENAI_API_KEY=")
		process.Stdout, process.Stderr = log, log
		if err := process.Start(); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(10 * time.Second)
		for {
			resp, err := http.Get(url + "/health")
			if err == nil {
				resp.Body.Close()
				if resp.StatusCode == 200 {
					break
				}
			}
			if time.Now().After(deadline) {
				data, _ := os.ReadFile(log.Name())
				t.Fatal("startup", string(data))
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	id := testAIIdentity("ws")
	post := func(body string) memory.Retention {
		req, _ := http.NewRequest("POST", url+"/ask/memory", strings.NewReader(body))
		req.Header.Set("X-NRC-AI-Auth", testAIToken(id))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		data, _ := io.ReadAll(resp.Body)
		var p memory.Retention
		if resp.StatusCode != 200 || json.Unmarshal(data, &p) != nil {
			t.Fatal(resp.StatusCode, string(data))
		}
		return p
	}
	start()
	if p := post(`{"workspace":"ws","operation":"inspect"}`); !p.Enabled {
		t.Fatal("first inspection did not enable personal memory by default")
	}
	p := post(`{"workspace":"ws","operation":"configure","confirm":true,"policy":{"enabled":true,"epoch":0,"max_bytes":8192,"max_segments":10}}`)
	if !p.Enabled {
		t.Fatal("consent not saved")
	}
	stop()
	// Seed exact captured originals through the storage API while the process is
	// stopped. The running process must discover, summarize and merge them itself.
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s, err := store.Lookup(t.Context(), id.owner(), "ws")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		text := strings.Repeat(fmt.Sprintf("private evidence %d ", i), 40)
		if i == 0 {
			text = strings.Repeat("\\", 32600)
		}
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: text}}); err != nil {
			t.Fatal(err)
		}
	}
	short, err := store.Personal(id.owner(), "short", true)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if _, err := short.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "user", Text: fmt.Sprintf("private evidence %d", i)}}); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	// The queue is derived: exercise startup reconstruction from originals and
	// nodes rather than relying on the seeding process's queue schema/version.
	seedDB, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = seedDB.Exec(`DROP TRIGGER summary_ready_INSERT; DROP TRIGGER summary_ready_UPDATE; DROP TRIGGER summary_ready_segment; DROP TABLE summary_ready;`)
	seedDB.Close()
	if err != nil {
		t.Fatal(err)
	}
	start()
	if p := post(`{"workspace":"ws","operation":"inspect"}`); !p.Enabled {
		t.Fatal("restart lost consent")
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	deadline := time.Now().Add(10 * time.Second)
	for {
		var state, summary string
		err := db.QueryRow(`SELECT state,summary FROM nodes WHERE owner=? AND workspace='ws' AND lo=0 AND hi=1`, id.owner()).Scan(&state, &summary)
		if err == nil && state == "ready" && summary == summaryText {
			err = db.QueryRow(`SELECT state,summary FROM nodes WHERE owner=? AND workspace='short' AND lo=0 AND hi=1`, id.owner()).Scan(&state, &summary)
			if err == nil && state == "ready" && summary == "user: private evidence 0\nuser: private evidence 1" {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("background parent not built", state, summary, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(modelCalls) != 3 {
		t.Fatal("expected three calls for large sources and none for short sources", len(modelCalls))
	}
	for i := 0; i < 3; i++ {
		if body := <-modelCalls; !strings.Contains(body, "UNTRUSTED HISTORICAL EVIDENCE") {
			t.Fatal("missing evidence boundary", body)
		}
	}
	t.Log("real AI process: consent survived restart; long leaves/parent used three model calls; short leaves/parent stayed exact without calls")
	p = post(`{"workspace":"ws","operation":"configure","confirm":true,"policy":{"enabled":false,"epoch":1,"max_bytes":8192,"max_segments":10}}`)
	if p.Enabled {
		t.Fatal("disable failed")
	}
	stop()
	start()
	if p := post(`{"workspace":"ws","operation":"inspect"}`); p.Enabled {
		t.Fatal("restart silently enabled retention")
	}
	stop()
	t.Log("saved disablement survived second restart; clean worker shutdown")
}

// NRC_RECEIPT_E2E_BIN must point to a locally built NRC server. The test starts
// its own isolated installation; it never accepts a shared server URL.
func startReceiptNRC(t *testing.T) string {
	t.Helper()
	bin := os.Getenv("NRC_RECEIPT_E2E_BIN")
	if bin == "" {
		t.Skip("set NRC_RECEIPT_E2E_BIN to a locally built Odin server")
	}
	bin, err := filepath.Abs(bin)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for shard := 0; shard < 256; shard++ {
		path := filepath.Join(dir, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", shard))
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "active.wal"), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	// Same generation-1 layout fixture as test/e2e/server_harness_test.go.
	manifest, err := base64.StdEncoding.DecodeString("TlJDTAABAAAAAAAAAAAAAQIBAAAAAAAAAAABAAABAACsNnTeRP92XA==")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "data", "storage-layout.manifest"), manifest, 0600); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	log, err := os.Create(filepath.Join(dir, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { log.Close() })
	cmd := exec.Command(bin)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), fmt.Sprintf("NRC_PORT=%d", port), "NRC_THREAD_COUNT=1", "NRC_STORAGE_BULK_EXECUTORS=1", "NRC_JWT_SECRET=receipt-local-jwt", "NRC_BOT_SECRET=receipt-local-bot")
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Signal(os.Interrupt); cmd.Wait() })
	address := fmt.Sprintf("127.0.0.1:%d", port)
	deadline := time.Now().Add(15 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			data, _ := os.ReadFile(log.Name())
			t.Fatalf("server startup: %s", data)
		}
		time.Sleep(50 * time.Millisecond)
	}
	return address
}

// Only the provider URL is overlaid in the child binary. main, signal handling,
// HTTP approval, NRC dispatch and SQLite recovery all run in that real process.
func TestVoiceApprovalSIGTERM(t *testing.T) {
	address := startReceiptNRC(t)
	connection := make(chan *websocket.Conn, 1)
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/live/sessions" {
			w.WriteHeader(201)
			fmt.Fprint(w, `{"session":{"id":"fixture"},"transport":{"sdp":"answer"}}`)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/attach") {
			conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
			if err != nil {
				t.Error(err)
				return
			}
			connection <- conn
			return
		}
		var request struct {
			Model    string
			Messages []struct{ Role string }
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
		}
		w.Header().Set("Content-Type", "application/json")
		if request.Model == "ask-fixture" && request.Messages[len(request.Messages)-1].Role != "tool" {
			fmt.Fprint(w, `{"choices":[{"index":0,"message":{"role":"assistant","tool_calls":[{"id":"proposal","type":"function","function":{"name":"propose_create_task","arguments":"{\"title\":\"SIGTERM approval proof\",\"description\":\"Persist before exit\",\"priority\":7}"}}]},"finish_reason":"tool_calls"}]}`)
			return
		}
		fmt.Fprint(w, `{"choices":[{"index":0,"message":{"role":"assistant","content":"Task proposed for explicit approval."},"finish_reason":"stop"}]}`)
	}))
	defer provider.Close()
	buildDir := t.TempDir()
	source, err := os.ReadFile("voice.go")
	if err != nil {
		t.Fatal(err)
	}
	old := `baseURL: "https://api.openai.com/v1"`
	if strings.Count(string(source), old) != 1 {
		t.Fatal("provider URL overlay no longer matches")
	}
	voicePath, _ := filepath.Abs("voice.go")
	overlayVoice := filepath.Join(buildDir, "voice.go")
	if err := os.WriteFile(overlayVoice, []byte(strings.Replace(string(source), old, "baseURL: "+fmt.Sprintf("%q", provider.URL), 1)), 0600); err != nil {
		t.Fatal(err)
	}
	replacements := map[string]string{voicePath: overlayVoice}
	if os.Getenv("NRC_SIGTERM_NEGATIVE_CONTROL") == "1" {
		// Deliberately bypass the drain to prove this scenario detects early exit.
		mainSource, err := os.ReadFile("main.go")
		if err != nil {
			t.Fatal(err)
		}
		old := "if err := <-shutdownDone; err != nil {"
		if strings.Count(string(mainSource), old) != 1 {
			t.Fatal("negative control no longer matches")
		}
		mainPath, _ := filepath.Abs("main.go")
		overlayMain := filepath.Join(buildDir, "main.go")
		if err := os.WriteFile(overlayMain, []byte(strings.Replace(string(mainSource), old, "if err := error(nil); err != nil {", 1)), 0600); err != nil {
			t.Fatal(err)
		}
		replacements[mainPath] = overlayMain
	}
	overlay, _ := json.Marshal(map[string]any{"Replace": replacements})
	overlayPath := filepath.Join(buildDir, "overlay.json")
	if err := os.WriteFile(overlayPath, overlay, 0600); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(buildDir, "nrc-ai")
	build := exec.Command("go", "build", "-race", "-overlay", overlayPath, "-o", bin, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatal(err, string(output))
	}
	for _, phase := range []string{"ack-held", "ack-complete", "ack-lost"} {
		t.Run(phase, func(t *testing.T) {
			uncertain := phase == "ack-lost"
			dir := t.TempDir()
			workspace := "sigterm-" + phase
			identity := testAIIdentity(workspace)
			path := filepath.Join(dir, "private", "memory.db")
			var db *sql.DB
			ack, release := make(chan struct{}), make(chan struct{})
			unblock := sync.OnceFunc(func() { close(release) })
			var once sync.Once
			proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				headers := http.Header{}
				for _, key := range []string{"X-NRC-User-Type", "X-NRC-Bot-Secret", "X-NRC-Bot-Nickname"} {
					headers.Set(key, r.Header.Get(key))
				}
				up, _, err := websocket.DefaultDialer.Dial("ws://"+address+r.URL.Path, headers)
				if err != nil {
					t.Error(err)
					return
				}
				defer up.Close()
				down, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer down.Close()
				go func() {
					defer up.Close()
					for {
						kind, data, err := down.ReadMessage()
						if err != nil {
							return
						}
						msg, _ := protocol.ReadMessage(data)
						if msg != nil && msg.Opcode == protocol.C_CreateTask {
							var state string
							if err := db.QueryRow(`SELECT state FROM receipts WHERE workspace=?`, workspace).Scan(&state); err != nil || state != "outcome_unknown" {
								t.Error("dispatch without durable consumption", state, err)
							}
						}
						if up.WriteMessage(kind, data) != nil {
							return
						}
					}
				}()
				for {
					kind, data, err := up.ReadMessage()
					if err != nil {
						return
					}
					msg, _ := protocol.ReadMessage(data)
					if msg != nil && msg.Opcode == protocol.S_TaskCreated {
						once.Do(func() { close(ack) })
						<-release
					}
					if down.WriteMessage(kind, data) != nil {
						return
					}
				}
			}))
			defer proxy.Close()
			defer unblock()
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			port := listener.Addr().(*net.TCPAddr).Port
			listener.Close()
			url := fmt.Sprintf("http://127.0.0.1:%d", port)
			var process *exec.Cmd
			var exited chan error
			start := func() {
				log, err := os.CreateTemp(dir, "ai-*.log")
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() {
					data, _ := os.ReadFile(log.Name())
					t.Logf("AI process log:\n%s", data)
					log.Close()
				})
				process = exec.Command(bin)
				process.Dir = dir
				process.Env = append(os.Environ(), "GORACE=atexit_sleep_ms=0", "NRC_JWT_SECRET="+testAIKey, "NRC_JWT_ISSUER=test-issuer", "NRC_PERSONAL_MEMORY_PATH="+path, "NRC_MEMORY_SUMMARY_MODEL=summary-fixture", fmt.Sprintf("AI_PORT=%d", port), "LLM_PROVIDER=openai-compat", "LLM_MODEL=ask-fixture", "LLM_API_KEY=fixture", "LLM_BASE_URL="+provider.URL, "NRC_SERVER=ws"+strings.TrimPrefix(proxy.URL, "http"), "NRC_BOT_SECRET=receipt-local-bot", "NRC_VOICE_OPENAI_API_KEY=fixture")
				process.Stdout, process.Stderr = log, log
				if err := process.Start(); err != nil {
					t.Fatal(err)
				}
				exited = make(chan error, 1)
				go func(cmd *exec.Cmd, done chan error) { done <- cmd.Wait() }(process, exited)
				deadline := time.Now().Add(10 * time.Second)
				for {
					resp, err := http.Get(url + "/health")
					if err == nil {
						resp.Body.Close()
						if resp.StatusCode == 200 {
							break
						}
					}
					if time.Now().After(deadline) {
						t.Fatal("AI did not start")
					}
					time.Sleep(20 * time.Millisecond)
				}
			}
			defer func() {
				if process != nil {
					process.Process.Kill()
					select {
					case <-exited:
					case <-time.After(3 * time.Second):
					}
				}
			}()
			start()
			db, err = sql.Open("sqlite", path)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			post := func(route string, value any) (int, []byte) {
				body, _ := json.Marshal(value)
				req, _ := http.NewRequest("POST", url+route, strings.NewReader(string(body)))
				req.Header.Set("X-NRC-AI-Auth", testAIToken(identity))
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					return 0, []byte(err.Error())
				}
				defer resp.Body.Close()
				data, _ := io.ReadAll(resp.Body)
				return resp.StatusCode, data
			}
			if code, data := post("/ask/memory", map[string]any{"workspace": workspace, "operation": "configure", "confirm": true, "policy": map[string]any{"enabled": true, "epoch": 0, "max_bytes": 65536, "max_segments": 50}}); code != 200 {
				t.Fatal(code, string(data))
			}
			code, data := post("/voice/create", voiceRequest{Workspace: workspace, SDP: "offer", ExecutionPolicy: "private", RequireMemory: true})
			var created struct{ ID string }
			if code != 200 || json.Unmarshal(data, &created) != nil {
				t.Fatal(code, string(data))
			}
			conn := <-connection
			defer conn.Close()
			conn.WriteJSON(map[string]string{"type": "session.input_transcript.delta", "event_id": "one", "delta": "Create the SIGTERM approval proof task"})
			conn.WriteJSON(map[string]any{"type": "session.delegation.created", "delegation": map[string]string{"id": "d", "target": "client"}})
			conn.SetReadDeadline(time.Now().Add(15 * time.Second))
			var event map[string]any
			if err := conn.ReadJSON(&event); err != nil || event["type"] != "session.commentary.append" {
				t.Fatal(event, err)
			}
			code, data = post("/voice/status", voiceRequest{Workspace: workspace, ID: created.ID})
			var status struct {
				Revision uint64
				Result   *askResponse
			}
			if code != 200 || json.Unmarshal(data, &status) != nil || status.Result == nil || len(status.Result.ProposedActions) != 1 {
				t.Fatal("proposal", code, string(data))
			}
			apply := voiceRequest{Workspace: workspace, ID: created.ID, Revision: status.Revision, PlanID: status.Result.PlanID, ActionIDs: []string{status.Result.ProposedActions[0].ID}}
			done := make(chan struct{})
			go func() { post("/voice/apply", apply); close(done) }() // Lose the response deliberately.
			select {
			case <-ack:
			case <-time.After(10 * time.Second):
				t.Fatal("no real NRC acknowledgement")
			}
			t.Log("NRC committed task; SQLite consumption was durable before dispatch; acknowledgement held")
			if phase == "ack-complete" {
				unblock()
				<-done
			}
			if err := process.Process.Signal(syscall.SIGTERM); err != nil {
				t.Fatal(err)
			}
			// Ignore approval commentary in the already-completed control case.
			for {
				if err := conn.ReadJSON(&event); err != nil {
					t.Fatal("provider did not observe session.close", err)
				}
				if event["type"] == "session.close" {
					break
				}
			}
			conn.WriteJSON(map[string]string{"type": "session.closed", "reason": "close_requested"})
			if phase == "ack-held" {
				select {
				case err := <-exited:
					t.Fatal("AI exited before held acknowledgement was released", err)
				case <-time.After(300 * time.Millisecond):
				}
			}
			if !uncertain {
				unblock()
			}
			select {
			case err := <-exited:
				if err != nil {
					t.Fatal("unclean SIGTERM", err)
				}
			case <-time.After(50 * time.Second):
				t.Fatal("AI did not drain")
			}
			unblock()
			<-done
			t.Log("SIGTERM sent session.close, waited for approval and exited cleanly")
			var state string
			if err := db.QueryRow(`SELECT state FROM segments WHERE channel='voice' AND seq=0`).Scan(&state); err != nil || state != "complete" {
				t.Fatal("capture not finalized", state, err)
			}
			start()
			recovery := map[string]any{"workspace": workspace, "channel": "voice", "session_id": status.Result.AgentSessionID, "plan_id": apply.PlanID, "action_id": apply.ActionIDs[0]}
			code, data = post("/ask/receipt/status", recovery)
			var receipt memory.Receipt
			wantState := "applied"
			if uncertain {
				wantState = "outcome_unknown"
			}
			if code != 200 || json.Unmarshal(data, &receipt) != nil || receipt.State != wantState {
				t.Fatal("receipt after SIGTERM/restart", code, string(data))
			}
			var result struct {
				ID uint64 `json:"created_task_id"`
			}
			if json.Unmarshal(receipt.Result, &result) != nil || !uncertain && result.ID == 0 || uncertain && result.ID != 0 {
				t.Fatal("missing durable task ID", string(data))
			}
			if code, _ := post("/voice/apply", apply); code != 404 {
				t.Fatal("old voice approval replayable", code)
			}
			wm := NewWorkspaceManager(t.Context(), Config{NRCServer: "ws://" + address, NRCNickname: "proof-reader", NRCBotSecret: "receipt-local-bot"})
			client, err := wm.GetOrCreateClient(workspace)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Stop()
			if err := waitForClientReady(t.Context(), client, 5*time.Second); err != nil {
				t.Fatal(err)
			}
			page, err := client.ListTasksPage(t.Context(), 0, 0x1f, 100, nil)
			if err != nil || !page.Success || len(page.Tasks) != 1 || !uncertain && page.Tasks[0].ID != result.ID || page.Tasks[0].Title != "SIGTERM approval proof" {
				t.Fatal("NRC state/replay", page, err)
			}
			t.Logf("restart recovered %s receipt task_id=%d; real NRC tasks=%d actual_task_id=%d; replay refused", receipt.State, result.ID, len(page.Tasks), page.Tasks[0].ID)
			process.Process.Signal(syscall.SIGTERM)
			select {
			case err := <-exited:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("restart shutdown")
			}
			process = nil
		})
	}
}

func TestPersonalReceiptRealServer(t *testing.T) {
	address := startReceiptNRC(t)
	for _, scenario := range []string{"voice-forget-pending", "voice-forget-complete", "chat"} {
		t.Run(scenario, func(t *testing.T) {
			channel := "voice"
			if scenario == "chat" {
				channel = "chat"
			}
			uncertain := scenario == "voice-forget-pending"
			workspace := "receipt-" + scenario
			identity := testAIIdentity(workspace)
			path := filepath.Join(t.TempDir(), "private", "memory.db")
			store, err := memory.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { store.Close() }()
			sessions := newAgentSessionStore(time.Hour, 5)
			session, _ := sessions.getOrCreate(identity.owner(), workspace, 0, 0, "", agentModePlan)
			sessions.setExecutionPolicy(session.ID, "private", true)
			plan, _ := sessions.startPlan(session.ID)
			_, action, err := sessions.addCreateTaskAction(session.ID, plan.ID, "Private rollout review", "Private approval details", 7)
			if err != nil {
				t.Fatal(err)
			}
			db, err := sql.Open("sqlite", path)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			consumed, acknowledged := make(chan string, 1), make(chan struct{}, 1)
			release := make(chan struct{})
			unblock := sync.OnceFunc(func() { close(release) })
			defer unblock()
			// Forward every byte to the real server. Only delay the first create
			// acknowledgement, after independently observing durable consumption.
			proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				headers := http.Header{}
				for _, key := range []string{"X-NRC-User-Type", "X-NRC-Bot-Secret", "X-NRC-Bot-Nickname"} {
					headers.Set(key, r.Header.Get(key))
				}
				up, _, err := websocket.DefaultDialer.Dial("ws://"+address+r.URL.Path, headers)
				if err != nil {
					t.Error(err)
					http.Error(w, "upstream", 502)
					return
				}
				defer up.Close()
				down, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer down.Close()
				go func() {
					defer up.Close()
					for {
						kind, data, err := down.ReadMessage()
						if err != nil {
							return
						}
						msg, _ := protocol.ReadMessage(data)
						if msg != nil && msg.Opcode == protocol.C_CreateTask {
							var state string
							err := db.QueryRow(`SELECT state FROM receipts WHERE owner=? AND workspace=? AND channel=? AND session=? AND plan=? AND action=?`, identity.owner(), workspace, channel, session.ID, plan.ID, action.ID).Scan(&state)
							if err != nil {
								state = err.Error()
							}
							select {
							case consumed <- state:
							default:
							}
						}
						if up.WriteMessage(kind, data) != nil {
							return
						}
					}
				}()
				for {
					kind, data, err := up.ReadMessage()
					if err != nil {
						return
					}
					msg, _ := protocol.ReadMessage(data)
					if msg != nil && msg.Opcode == protocol.S_TaskCreated {
						select {
						case acknowledged <- struct{}{}:
						default:
						}
						<-release
					}
					if down.WriteMessage(kind, data) != nil {
						return
					}
				}
			}))
			defer proxy.Close()
			cfg := Config{NRCServer: "ws" + strings.TrimPrefix(proxy.URL, "http"), NRCNickname: "receipt-writer", NRCBotSecret: "receipt-local-bot"}
			wm := NewWorkspaceManager(t.Context(), cfg)
			client, err := wm.GetOrCreateClient(workspace)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Stop()
			apply := handleAskApply(wm, sessions)
			v := newVoiceService("", "", nil, apply)
			ctx, err := withPersonalMemory(context.WithValue(t.Context(), aiIdentityKey{}, identity), store, identity, true)
			if err != nil {
				t.Fatal(err)
			}
			a, _ := personalMemoryFor(ctx, identity, "private")
			// Seed only provider reasoning. Approval dispatch, NRC writes, SQLite
			// persistence, authenticated HTTP and recovery remain production code.
			v.sessions["voice-fixture"] = &voiceSession{id: "voice-fixture", owner: identity.owner(), workspace: workspace, identity: identity, memory: a, closed: false, revision: 3, resultRevision: 3, result: &askResponse{AgentSessionID: session.ID, PlanID: plan.ID, ProposedActions: []ProposedAction{action}}}
			// No audio transport is needed for receipt validation. Closing is set
			// after approval starts to represent the already-ended audio session.
			auth, err := newAIAuthentication(testAIKey, "test-issuer")
			if err != nil {
				t.Fatal(err)
			}
			serve := func(memoryStore *memory.Store, voice *voiceService) *httptest.Server {
				mux := http.NewServeMux()
				voice.register(mux)
				mux.HandleFunc("POST /ask/apply", apply)
				mux.HandleFunc("POST /ask/memory", handlePersonalRetention)
				mux.HandleFunc("POST /ask/receipt/status", handlePersonalRecovery(true))
				return httptest.NewServer(auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					id := r.Context().Value(aiIdentityKey{}).(aiIdentity)
					ctx, err := withPersonalMemory(r.Context(), memoryStore, id, true)
					if err != nil {
						http.Error(w, err.Error(), 500)
						return
					}
					mux.ServeHTTP(w, r.WithContext(ctx))
				})))
			}
			api := serve(store, v)
			defer func() { api.Close() }()
			post := func(route, body string) (int, []byte) {
				req, _ := http.NewRequest("POST", api.URL+route, strings.NewReader(body))
				req.Header.Set("X-NRC-AI-Auth", testAIToken(identity))
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Error(err)
					return 0, nil
				}
				defer resp.Body.Close()
				data, _ := io.ReadAll(resp.Body)
				return resp.StatusCode, data
			}
			body := fmt.Sprintf(`{"workspace":%q,"id":"voice-fixture","revision":3,"agent_session_id":%q,"plan_id":%q,"action_ids":[%q]}`, workspace, session.ID, plan.ID, action.ID)
			route := "/ask/apply"
			if channel == "voice" {
				route = "/voice/apply"
			}
			done := make(chan struct{})
			go func() { post(route, body); close(done) }() // Deliberately discard the Apply response.
			defer unblock()
			select {
			case state := <-consumed:
				if state != "outcome_unknown" {
					t.Fatal("uncommitted approval dispatched", state)
				}
				t.Log("before dispatch: durable receipt=outcome_unknown")
			case <-time.After(10 * time.Second):
				t.Fatal("no create reached NRC")
			}
			select {
			case <-acknowledged:
			case <-time.After(10 * time.Second):
				t.Fatal("no NRC create acknowledgement")
			}
			if !uncertain {
				unblock()
				<-done
			}
			if channel == "voice" {
				s := v.sessions["voice-fixture"]
				s.mu.Lock()
				s.closed = true
				s.mu.Unlock()
				code, data := post("/ask/memory", fmt.Sprintf(`{"workspace":%q,"operation":"forget_all","epoch":0,"confirm":true}`, workspace))
				if code != 200 {
					t.Fatal(code, string(data))
				}
				if uncertain {
					// Force cancellation to win over acknowledgement delivery.
					select {
					case <-done:
					case <-time.After(10 * time.Second):
						t.Fatal("cancelled Apply did not finish")
					}
				}
				code, data = post("/voice/status", body)
				if code != 200 || !strings.Contains(string(data), `"closed":true`) || strings.Contains(string(data), `"transcript"`) {
					t.Fatal(code, string(data))
				}
				t.Logf("forgot history (acknowledgement held=%t): receipt-only status returned", uncertain)
			}
			unblock()
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				t.Fatal("Apply did not finish")
			}
			recoveryBody := fmt.Sprintf(`{"workspace":%q,"channel":%q,"session_id":%q,"plan_id":%q,"action_id":%q}`, workspace, channel, session.ID, plan.ID, action.ID)
			checkReceipt := func() uint64 {
				code, data := post("/ask/receipt/status", recoveryBody)
				var receipt memory.Receipt
				wantState := "applied"
				if uncertain {
					wantState = "outcome_unknown"
				}
				if code != 200 || json.Unmarshal(data, &receipt) != nil || receipt.State != wantState || strings.Contains(string(data), "Private") {
					t.Fatal("durable recovery", code, string(data))
				}
				var ids struct {
					ID uint64 `json:"created_task_id"`
				}
				if err := json.Unmarshal(receipt.Result, &ids); err != nil || !uncertain && ids.ID == 0 || uncertain && ids.ID != 0 {
					t.Fatal("missing task ID", string(data), err)
				}
				t.Logf("durable recovery: state=%s task_id=%d; no private text", receipt.State, ids.ID)
				return ids.ID
			}
			taskID := checkReceipt()
			if channel == "voice" {
				code, data := post("/voice/status", body)
				if code != 200 || !strings.Contains(string(data), fmt.Sprintf(`"action_id":%q`, action.ID)) || !uncertain && !strings.Contains(string(data), fmt.Sprintf(`"id":%d`, taskID)) || strings.Contains(string(data), "Private") || strings.Contains(string(data), `"transcript"`) {
					t.Fatal("voice recovery", code, string(data))
				}
				t.Log("lost Apply response recovered via sanitized voice status")
			}
			code, _ := post(route, body)
			if channel == "voice" && code != 409 || channel == "chat" && code != 200 {
				t.Fatal("replay status", code)
			}
			page, err := client.ListTasksPage(t.Context(), 0, 0x1f, 100, nil)
			if err != nil || !page.Success || len(page.Tasks) != 1 || !uncertain && page.Tasks[0].ID != taskID || page.Tasks[0].Title != "Private rollout review" {
				t.Fatal("real NRC state", page, err)
			}
			t.Logf("real NRC query after replay: tasks=%d ID=%d title preserved", len(page.Tasks), page.Tasks[0].ID)
			api.Close()
			sessions.reset(session.ID)
			if err := db.Close(); err != nil {
				t.Fatal(err)
			}
			if err := store.Close(); err != nil {
				t.Fatal(err)
			}
			store, err = memory.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			api = serve(store, newVoiceService("", "", nil, nil))
			if recovered := checkReceipt(); recovered != taskID {
				t.Fatal("restart changed receipt", recovered)
			}
			if channel == "voice" {
				if code, _ := post("/voice/status", body); code != 404 {
					t.Fatal("ephemeral session survived restart", code)
				}
			}
			t.Log("reopened SQLite and new HTTP service: durable receipt recovered without voice session")
		})
	}
}
