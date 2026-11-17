package e2e

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func chronicleJWTHeader(t *testing.T, subject, workspace, kind, capability string) http.Header {
	t.Helper()
	claims, err := json.Marshal(map[string]any{
		"sub": subject, "username": subject, "workspace": workspace,
		"user_type": kind, "capability": capability,
		"iss": e2eJWTIssuer, "aud": e2eJWTAudience, "exp": time.Now().Add(time.Hour).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	message := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`)) + "." + base64.RawURLEncoding.EncodeToString(claims)
	mac := hmac.New(sha256.New, []byte(e2eJWTSecret))
	mac.Write([]byte(message))
	return http.Header{"X-NRC-Auth": {message + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))}}
}

func mustChronicle(t *testing.T, conn *websocket.Conn, request protocol.ChronicleRequest, status string) *protocol.ChronicleResponse {
	t.Helper()
	wire, err := protocol.EncodeChronicleRequest(request, 817)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
		t.Fatal(err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_Chronicle, 32)
	response, err := protocol.DecodeChronicleResponse(payload)
	if err != nil {
		t.Fatal(err)
	}
	if request.Op == "gaps" || request.Op == "status" {
		var object map[string]json.RawMessage
		if err := json.Unmarshal(payload[4:], &object); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"sources", "inputs", "entries", "gaps"} {
			if len(object[key]) == 0 || object[key][0] != '[' {
				t.Fatalf("%s is not a public JSON array: %s", key, object[key])
			}
		}
	}
	if response.Status != status || response.CorrelationID != 817 {
		t.Fatalf("chronicle %s: %+v, want %s", request.Op, response, status)
	}
	return response
}

func TestChronicleServiceAuthorizationAndResultLifecycle(t *testing.T) {
	const ws = "chronicle-service"
	server := startServerInWorkDirWithEnv(t, t.TempDir(), map[string]string{
		"NRC_CHRONICLE_WORKSPACES":       ws,
		"NRC_CHRONICLE_SERVICE_SUBJECTS": `{"chronicle-service":["worker"]}`,
		"NRC_CHRONICLE_DELETE_SUBJECTS":  `{"chronicle-service":["human"]}`,
		"NRC_THREAD_COUNT":               "1",
	})
	defer server.stop(t)
	connect := func(headers http.Header) *websocket.Conn {
		t.Helper()
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(ws), headers)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 15*time.Second)
		mustExpectServerReady(t, c)
		return c
	}
	human := connect(chronicleJWTHeader(t, "human", ws, "user", ""))
	reader := connect(chronicleJWTHeader(t, "reader", ws, "user", ""))
	worker := connect(chronicleJWTHeader(t, "worker", ws, "bot", "chronicle"))
	competitor := connect(chronicleJWTHeader(t, "worker", ws, "bot", "chronicle"))
	createNoteAssetAndRead(t, human, protocol.WorkspaceDataConvID, mustNotePreviewJSON(t, "Plan geändert", ""))
	claim := protocol.ChronicleRequest{Op: "claim", Consumer: protocol.ChronicleConsumerVersion, Limit: 32}
	mustChronicle(t, reader, claim, "forbidden")
	// Both sockets submit before either response is consumed. Exactly one
	// claim may commit; the other must observe the durable active lease.
	wire, err := protocol.EncodeChronicleRequest(claim, 817)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []*websocket.Conn{worker, competitor} {
		if err := c.WriteMessage(websocket.BinaryMessage, wire); err != nil {
			t.Fatal(err)
		}
	}
	var r *protocol.ChronicleResponse
	busy := 0
	for _, c := range []*websocket.Conn{worker, competitor} {
		response, err := protocol.DecodeChronicleResponse(mustReadUntilOpcode(t, c, protocol.S_Chronicle, 32))
		if err != nil {
			t.Fatal(err)
		}
		switch response.Status {
		case "claimed":
			if r != nil {
				t.Fatal("two overlapping claims committed")
			}
			r = response
			worker = c
		case "busy":
			busy++
		default:
			t.Fatalf("claim response: %+v", response)
		}
	}
	if r == nil || busy != 1 {
		t.Fatalf("claim competition: claimed=%v busy=%d", r, busy)
	}
	if len(r.Sources) != 1 || r.Generation == "" || r.Epoch == "" {
		t.Fatalf("invalid claim: %+v", r)
	}
	for _, c := range []*websocket.Conn{reader, worker} {
		status := mustChronicle(t, c, protocol.ChronicleRequest{Op: "status", NoteID: r.NoteID}, "ok")
		if status.CanDelete || status.Pending != 1 || status.Processing != 1 || status.Failed != 0 {
			t.Fatalf("read authority/live processing: %+v", status)
		}
	}
	if !mustChronicle(t, human, protocol.ChronicleRequest{Op: "status"}, "ok").CanDelete {
		t.Fatal("authorized human lacks can_delete")
	}
	mustChronicle(t, reader, protocol.ChronicleRequest{Op: "chunk", Consumer: claim.Consumer, Epoch: r.Epoch, Generation: r.Generation, Cursor: r.Sources[0], Length: 16}, "forbidden")
	mustChronicle(t, reader, protocol.ChronicleRequest{Op: "gaps", Limit: 16}, "ok")
	mustChronicle(t, worker, claim, "busy")
	job := protocol.ChronicleRequest{Op: "reserve", Consumer: claim.Consumer, Epoch: r.Epoch, Generation: r.Generation, Sources: r.Sources, InputTokens: 200, OutputTokens: 1000}
	mustChronicle(t, worker, job, "reserved")
	mustChronicle(t, worker, job, "reserved")
	job.Op = "commit"
	job.Outcome = "result"
	job.Summary = "Der Plan wurde angelegt."
	job.Model = "fake"
	job.PromptVersion = "p1"
	job.SchemaVersion = "s1"
	job.InputTokens, job.OutputTokens = 60, 20
	mustChronicle(t, worker, job, "committed")
	mustChronicle(t, worker, job, "committed")
	usage := mustChronicle(t, reader, protocol.ChronicleRequest{Op: "status"}, "ok")
	if usage.Calls != 1 || usage.InputTokens != 60 || usage.OutputTokens != 20 {
		t.Fatalf("confirmed usage/replay accounting: %+v", usage)
	}
	page := mustChronicle(t, reader, protocol.ChronicleRequest{Op: "history", Limit: 16}, "ok")
	if len(page.Entries) != 1 || page.Entries[0].Summary != job.Summary {
		t.Fatalf("history: %+v", page)
	}
	deletion := protocol.ChronicleRequest{Op: "delete", NoteID: r.NoteID}
	mustChronicle(t, reader, deletion, "forbidden")
	mustChronicle(t, worker, deletion, "forbidden")
	mustChronicle(t, human, deletion, "deleted")
	replay := mustChronicle(t, worker, job, "deleted")
	if replay.Summary != "" {
		t.Fatalf("deleted prose replayed: %+v", replay)
	}
	page = mustChronicle(t, reader, protocol.ChronicleRequest{Op: "history", Limit: 16}, "ok")
	if len(page.Entries) != 0 {
		t.Fatalf("deleted history visible: %+v", page)
	}
	// Even an allowlisted worker cannot obtain service authority with a legacy
	// bot secret, a foreign workspace token, or an ordinary bot JWT.
	legacy := connect(http.Header{"X-NRC-User-Type": {"bot"}, "X-NRC-Bot-Secret": {metricsBotSecret}, "X-NRC-Bot-Nickname": {"worker"}})
	mustChronicle(t, legacy, claim, "forbidden")
	ordinaryBot := connect(chronicleJWTHeader(t, "worker", ws, "bot", ""))
	mustChronicle(t, ordinaryBot, claim, "forbidden")
	for _, header := range []http.Header{chronicleJWTHeader(t, "worker", "other", "bot", "chronicle"), chronicleJWTHeader(t, "stranger", ws, "bot", "chronicle")} {
		c, response, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(ws), header)
		if c != nil {
			c.Close()
		}
		if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("invalid service identity accepted: response=%v err=%v", response, err)
		}
		response.Body.Close()
	}
	// The service capability restricts the whole connection, not just the new API.
	if err := sendProtocolMessage(worker, protocol.C_CreateTask, protocol.EncodeTaskCreate(0, "forbidden", "", 1)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, worker, protocol.S_ErrorResponse, 16)
	status := mustChronicle(t, reader, protocol.ChronicleRequest{Op: "status"}, "ok")
	if status.RawBytes != 0 || status.Pending != 0 || status.Calls != 1 {
		t.Fatalf("terminal accounting: %+v", status)
	}
	// Readers can observe a real compact loss receipt without gaining service
	// authority. A no-change Ack is successful processing, never a loss.
	for _, outcome := range []string{"gap", "ack"} {
		createNoteAssetAndRead(t, human, protocol.WorkspaceDataConvID, mustNotePreviewJSON(t, outcome, ""))
		claimed := mustChronicle(t, worker, claim, "claimed")
		terminal := protocol.ChronicleRequest{Op: "commit", Consumer: claim.Consumer, Epoch: claimed.Epoch, Generation: claimed.Generation, Sources: claimed.Sources, Outcome: outcome}
		if outcome == "gap" {
			terminal.Reason = "token_limit"
		} else {
			reservation := terminal
			reservation.Op = "reserve"
			reservation.InputTokens, reservation.OutputTokens = 100, 1000
			mustChronicle(t, worker, reservation, "reserved")
			terminal.Model, terminal.PromptVersion, terminal.SchemaVersion = "fake", "p1", "s1"
		}
		want := "gap"
		if outcome == "ack" {
			want = "acknowledged"
		}
		mustChronicle(t, worker, terminal, want)
		scoped := mustChronicle(t, reader, protocol.ChronicleRequest{Op: "status", NoteID: claimed.NoteID}, "ok")
		if scoped.Pending != 0 || scoped.Processing != 0 || scoped.Failed != 0 {
			t.Fatalf("terminal scoped status: %+v", scoped)
		}
		wantCalls := uint64(1)
		if outcome == "ack" {
			wantCalls = 2
		}
		if scoped.Calls != wantCalls {
			t.Fatalf("note scope changed workspace call budget: %+v", scoped)
		}
		gaps := mustChronicle(t, reader, protocol.ChronicleRequest{Op: "gaps", NoteID: claimed.NoteID, Limit: 1}, "ok")
		if outcome == "gap" {
			if scoped.GapCount != 1 || scoped.Acknowledged != 0 || len(gaps.Gaps) != 1 || gaps.Gaps[0].FirstSource != claimed.Sources[0] || gaps.Gaps[0].Reason != "token_limit" || !gaps.Gaps[0].SourceAvailable {
				t.Fatalf("loss receipt/status: %+v / %+v", gaps, scoped)
			}
			end := mustChronicle(t, reader, protocol.ChronicleRequest{Op: "gaps", NoteID: claimed.NoteID, Cursor: gaps.Cursor, Limit: 1}, "ok")
			if len(end.Gaps) != 0 || end.More || end.Cursor != gaps.Cursor {
				t.Fatalf("exclusive gap cursor: %+v", end)
			}
		} else if scoped.Acknowledged != 1 || scoped.GapCount != 0 || len(gaps.Gaps) != 0 {
			t.Fatalf("Ack incorrectly reported as loss: %+v / %+v", gaps, scoped)
		}
		if gaps.Chunk != "" || gaps.Summary != "" || len(gaps.Inputs) != 0 {
			t.Fatalf("reader received source data: %+v", gaps)
		}
	}
}
