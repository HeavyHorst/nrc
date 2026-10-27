package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"charm.land/fantasy"
	"google.golang.org/adk/tool"
	"google.golang.org/adk/tool/functiontool"
	"google.golang.org/genai"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type timingTestModel struct {
	fantasy.LanguageModel
	response *fantasy.Response
	err      error
}

func (m timingTestModel) Generate(context.Context, fantasy.Call) (*fantasy.Response, error) {
	time.Sleep(15 * time.Millisecond)
	return m.response, m.err
}

func TestAskModelTiming(t *testing.T) {
	for _, failed := range []bool{false, true} {
		t.Run(fmt.Sprint(failed), func(t *testing.T) {
			var logs bytes.Buffer
			ctx := context.WithValue(t.Context(), askTimingLoggerKey{}, slog.New(slog.NewJSONHandler(&logs, nil)).With("request_id", "request-17", "attempt", 2))
			response := &fantasy.Response{Usage: fantasy.Usage{InputTokens: 31, OutputTokens: 19, ReasoningTokens: 7, CacheReadTokens: 11}}
			var wantErr error
			status := "ok"
			if failed {
				response, wantErr, status = nil, context.DeadlineExceeded, "error"
			}
			got, err := (timedAskModel{timingTestModel{response: response, err: wantErr}}).Generate(ctx, fantasy.Call{})
			if got != response || err != wantErr {
				t.Fatal("instrumentation changed the provider result")
			}
			var entry map[string]any
			if err := json.Unmarshal(logs.Bytes(), &entry); err != nil {
				t.Fatal(err)
			}
			if entry["request_id"] != "request-17" || entry["attempt"] != float64(2) || entry["status"] != status || entry["duration_ms"] == nil {
				t.Fatalf("missing timing/correlation: %v", entry)
			}
			if entry["duration_ms"].(float64) < 15 {
				t.Fatalf("provider wait not measured: %v", entry)
			}
			if !failed && (entry["input_tokens"] != float64(31) || entry["output_tokens"] != float64(19) || entry["reasoning_tokens"] != float64(7) || entry["cache_read_tokens"] != float64(11)) {
				t.Fatalf("incorrect provider usage: %v", entry)
			}
		})
	}
}

type fantasyToolInfoTestTool struct {
	declaration *genai.FunctionDeclaration
}

func (t fantasyToolInfoTestTool) Name() string                            { return "test_tool" }
func (t fantasyToolInfoTestTool) Description() string                     { return "test tool" }
func (t fantasyToolInfoTestTool) IsLongRunning() bool                     { return false }
func (t fantasyToolInfoTestTool) Declaration() *genai.FunctionDeclaration { return t.declaration }
func (t fantasyToolInfoTestTool) Run(tool.Context, any) (map[string]any, error) {
	return map[string]any{}, nil
}

func TestGetAssetOutputIncludesExactTimestampStrings(t *testing.T) {
	// Nanosecond timestamps exceed JSON's commonly supported exact integer range.
	out := adkGetAssetOutput{
		CreatedAt: "1791352800123456789",
		UpdatedAt: "1791360000987654321",
	}
	data, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	if got := fields["created_at"]; got != "1791352800123456789" {
		t.Fatalf("created_at = %#v, want exact creation timestamp string", got)
	}
	if got := fields["updated_at"]; got != "1791360000987654321" {
		t.Fatalf("updated_at = %#v, want exact modification timestamp string", got)
	}
}

func TestListedAssetTimestampsAndCursorPrecision(t *testing.T) {
	result := adkAssetResultFromAsset(protocol.Asset{AssetID: 17, AssetType: protocol.AssetTypeNote, CreatedAt: 1791352800123456789, UpdatedAt: 1791360000987654321}, false, 100)
	if result.CreatedAt != "1791352800123456789" || result.UpdatedAt != "1791360000987654321" {
		t.Fatalf("wrong timestamp mapping: %+v", result)
	}
	cursor := &adkAssetPageCursor{UpdatedAt: result.UpdatedAt, AssetID: "18446744073709551615"}
	decoded, err := cursor.decode()
	if err != nil || decoded.AssetID != ^uint64(0) || decoded.UpdatedAt != 1791360000987654321 {
		t.Fatalf("precision lost: %+v, %v", decoded, err)
	}
	for _, invalid := range []*adkAssetPageCursor{{UpdatedAt: "bad", AssetID: "1"}, {UpdatedAt: "1", AssetID: "0"}, {UpdatedAt: "1", AssetID: "18446744073709551616"}} {
		if _, err := invalid.decode(); err == nil {
			t.Fatalf("invalid cursor accepted: %+v", invalid)
		}
	}
}

func TestListTasksToolPaginationAndMetadata(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	wm := &WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}
	listing, err := newADKListTasksTool(wm, newADKAssetSourceCache(time.Minute, 10))
	if err != nil {
		t.Fatal(err)
	}
	runnable := listing.(adkRunnableTool)
	toolCtx := newFantasyADKToolContext(context.WithValue(context.WithValue(ctx, workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0)), "list")
	var cursor *adkTaskPageCursor
	for pageNumber := 0; pageNumber < 2; pageNumber++ {
		input := map[string]any{"limit": 37}
		if cursor != nil {
			input["cursor"] = map[string]any{"sort_at": cursor.SortAt, "task_id": cursor.TaskID}
		}
		done := make(chan adkListTasksOutput, 1)
		go func() {
			result, err := runnable.Run(toolCtx, input)
			if err != nil {
				t.Error(err)
				done <- adkListTasksOutput{}
				return
			}
			data, err := json.Marshal(result)
			if err != nil {
				t.Error(err)
			}
			var out adkListTasksOutput
			if err := json.Unmarshal(data, &out); err != nil {
				t.Error(err)
			}
			done <- out
		}()
		var msg *protocol.Message
		select {
		case msg = <-requests:
		case <-ctx.Done():
			t.Fatal("missing task request")
		}
		if msg.Opcode != protocol.C_ListTasksPaged || msg.Data[8] != 0x1f || binary.BigEndian.Uint16(msg.Data[9:]) != 37 {
			t.Fatalf("wrong task scope/statuses/limit: %x", msg.Data)
		}
		if pageNumber == 1 && (msg.Data[11] != 1 || binary.BigEndian.Uint64(msg.Data[12:]) != 1791360000987654321 || binary.BigEndian.Uint64(msg.Data[20:]) != 9007199254740993) {
			t.Fatalf("wrong continuation cursor: %x", msg.Data)
		}
		id := binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:])
		// A Done task's updated_at differs from the sort cursor: do not substitute one for the other.
		c.settleTaskPage(id, &protocol.TaskListPage{Success: true, TotalCount: 2, HasMore: pageNumber == 0, NextCursor: protocol.TaskPageCursor{SortAt: 1791360000987654321, TaskID: 9007199254740993}, Tasks: []*protocol.Task{{ID: uint64(9007199254740993 + pageNumber), BlockedBy: ^uint64(0), Status: protocol.TaskStatusDone, Title: "done", CreatedAt: 1791352800123456789, UpdatedAt: 1791359900111222333}}}, nil)
		out := <-done
		if out.Count != 1 || out.TotalCount != 2 || len(out.Results) != 1 || out.Results[0].TaskID != fmt.Sprint(9007199254740993+pageNumber) || out.Results[0].BlockedBy != "18446744073709551615" || out.Results[0].CreatedAt != "1791352800123456789" || out.Results[0].UpdatedAt != "1791359900111222333" {
			t.Fatalf("wrong tool metadata: %+v", out)
		}
		if pageNumber == 0 && (out.NextCursor == nil || out.NextCursor.SortAt != "1791360000987654321" || out.NextCursor.TaskID != "9007199254740993") {
			t.Fatalf("wrong next cursor: %+v", out)
		}
		if pageNumber == 1 && (out.HasMore || out.NextCursor != nil) {
			t.Fatalf("last page still has cursor: %+v", out)
		}
		cursor = out.NextCursor
	}
}

func assetListingPagePayload(assetType uint16, assetID uint64, hasMore bool, correlationID uint32) []byte {
	// One authoritative header record; two pages intentionally tie on updated_at.
	var b bytes.Buffer
	write := func(v any) { _ = binary.Write(&b, binary.BigEndian, v) }
	write(uint64(0)) // workspace scope
	write(uint8(0))  // headers only
	if hasMore {
		write(uint8(1))
	} else {
		write(uint8(0))
	}
	write(int64(1791360000987654321))
	write(assetID)
	write(uint32(2))
	write(uint16(1))
	write(correlationID)
	write(assetType)
	write(assetID)
	write(uint16(0)) // parent type
	write(uint64(0)) // parent id
	write(uint16(0)) // owner length
	write(int64(1791352800123456789))
	write(int64(1791360000987654321))
	write(uint64(0)) // conv id
	write(uint8(0))  // encoding
	write(uint32(0)) // payload length
	preview := `{"title":"Record","project":"repo","tags":["incident"]}`
	write(uint16(len(preview)))
	b.WriteString(preview)
	write(uint16(0)) // attachments
	return b.Bytes()
}

func TestAssetListingToolsTwoDecodedPages(t *testing.T) {
	for _, tc := range []struct {
		tool, assetType, project, tag string
		wantType                      uint16
	}{
		{"list_notes", "file", "repo", "", protocol.AssetTypeNote},
		{"list_notes", "", "", "incident", protocol.AssetTypeNote},
		{"list_assets", "company", "", "", protocol.AssetTypeCustomerCompany},
	} {
		t.Run(tc.tool+tc.assetType+tc.project+tc.tag, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			c.taskSnapshots[0] = true // avoid unrelated subscription traffic
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			cache := newADKAssetSourceCache(time.Minute, 10)
			listing, err := newADKListAssetsTool(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, cache, tc.tool)
			if err != nil {
				t.Fatal(err)
			}
			toolCtx := newFantasyADKToolContext(context.WithValue(context.WithValue(ctx, workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0)), "list")
			var cursor *adkAssetPageCursor
			for pageNumber := 0; pageNumber < 2; pageNumber++ {
				input := map[string]any{"asset_type": tc.assetType, "project": tc.project, "tag": tc.tag, "limit": 1}
				if cursor != nil {
					input["cursor"] = map[string]any{"updated_at": cursor.UpdatedAt, "asset_id": cursor.AssetID}
				}
				done := make(chan adkListNotesOutput, 1)
				go func() {
					result, err := listing.(adkRunnableTool).Run(toolCtx, input)
					if err != nil {
						t.Error(err)
						done <- adkListNotesOutput{}
						return
					}
					data, err := json.Marshal(result)
					if err != nil {
						t.Error(err)
					}
					var out adkListNotesOutput
					if err := json.Unmarshal(data, &out); err != nil {
						t.Error(err)
					}
					done <- out
				}()
				var msg *protocol.Message
				select {
				case msg = <-requests:
				case <-ctx.Done():
					t.Fatal("missing asset request")
				}
				wantOpcode := uint16(protocol.C_ListAssetsPaged)
				if tc.project != "" {
					wantOpcode = protocol.C_ListAssetsPagedByProject
				}
				if tc.tag != "" {
					wantOpcode = protocol.C_ListAssetsPagedByTag
				}
				if msg.Opcode != wantOpcode || binary.BigEndian.Uint16(msg.Data[8:]) != tc.wantType || binary.BigEndian.Uint16(msg.Data[11:]) != 1 {
					t.Fatalf("wrong request: %x", msg.Data)
				}
				offset := 14
				if pageNumber == 1 {
					if msg.Data[13] != 1 || binary.BigEndian.Uint64(msg.Data[14:]) != 1791360000987654321 || binary.BigEndian.Uint64(msg.Data[22:]) != 9007199254740995 {
						t.Fatalf("lost continuation cursor: %x", msg.Data)
					}
					offset = 30
				} else if msg.Data[13] != 0 {
					t.Fatal("unexpected first-page cursor")
				}
				filter := tc.project + tc.tag
				if filter != "" {
					n := int(binary.BigEndian.Uint16(msg.Data[offset:]))
					if string(msg.Data[offset+2:offset+2+n]) != filter {
						t.Fatalf("changed filter: %x", msg.Data)
					}
					offset += 2 + n
				}
				correlationID := binary.BigEndian.Uint32(msg.Data[offset:])
				assetID := uint64(9007199254740995 - pageNumber*2)
				c.handleAssetListPage(assetListingPagePayload(tc.wantType, assetID, pageNumber == 0, correlationID))
				out := <-done
				if out.Count != 1 || out.TotalCount != 2 || len(out.Results) != 1 || out.Results[0].AssetID != fmt.Sprint(assetID) || out.Results[0].CreatedAt != "1791352800123456789" || out.Results[0].UpdatedAt != "1791360000987654321" {
					t.Fatalf("wrong metadata: %+v", out)
				}
				if pageNumber == 0 && (out.NextCursor == nil || out.NextCursor.AssetID != "9007199254740995" || out.NextCursor.UpdatedAt != "1791360000987654321") {
					t.Fatalf("wrong returned cursor: %+v", out)
				}
				if pageNumber == 1 && (out.HasMore || out.NextCursor != nil) {
					t.Fatalf("last page cursor: %+v", out)
				}
				cursor = out.NextCursor
			}
			if len(cache.get("ws", 0)) != 2 {
				t.Fatal("source cache lost a page")
			}
		})
	}
}

func TestAssetListingRejectsNonNoteFilters(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	c.taskSnapshots[0] = true
	listing, err := newADKListAssetsTool(&WorkspaceManager{ctx: t.Context(), clients: map[string]*NRCClient{"ws": c}}, newADKAssetSourceCache(time.Minute, 10), "list_assets")
	if err != nil {
		t.Fatal(err)
	}
	ctx := newFantasyADKToolContext(context.WithValue(context.WithValue(t.Context(), workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0)), "list")
	for _, filter := range []string{"project", "tag"} {
		_, err := listing.(adkRunnableTool).Run(ctx, map[string]any{"asset_type": "file", filter: "scope"})
		if err == nil || !strings.Contains(err.Error(), "filters require notes") {
			t.Fatalf("non-note %s filter accepted: %v", filter, err)
		}
	}
	select {
	case <-requests:
		t.Fatal("invalid request was sent")
	default:
	}
}

func TestGenericAssetCitationKeepsNewTypesInSources(t *testing.T) {
	for _, typeName := range []string{"Comment", "Document", "File", "Agenda", "Note", "Reminder", "Company", "Contact", "Activity", "Slice", "Appointment", "RoomMapping", "room_mapping", "Ticket", "TicketEntry", "ticket_entry"} {
		answer := "[" + typeName + ":9007199254740993] [Asset:9007199254740993]"
		sources := sourcesFromAnswerRefs(answer, nil, map[uint64]string{9007199254740993: typeName + " record"})
		if len(sources) != 1 || sources[0].Type != "asset" || sources[0].ID != 9007199254740993 || sources[0].Title != typeName+" record" {
			t.Fatalf("lost source: %+v", sources)
		}
		missing := sourcesFromAnswerRefs("["+typeName+":42]", nil, nil)
		if len(missing) != 1 || missing[0].Type != "asset" {
			t.Fatalf("lost uncached typed source: %+v", missing)
		}
	}
	sources := sourcesFromAnswerRefs("[Task:42] #42 [Slice:42] [ task : 43 ]", []protocol.Task{{ID: 42, Title: "Task title"}}, map[uint64]string{42: "Slice name"})
	if len(sources) != 3 || sources[0].Type != "task" || sources[0].Title != "Task title" || sources[1].Title != "Task #43" || sources[2].Type != "asset" || sources[2].Title != "Slice name" {
		t.Fatalf("task and slice identities must stay separate: %+v", sources)
	}
}

func TestCalendarContextBerlinDayBoundaries(t *testing.T) {
	for _, tc := range []struct{ now, start, end string }{
		{"2026-10-06T22:30:00Z", "2026-10-07T00:00:00+02:00", "2026-10-08T00:00:00+02:00"},
		{"2026-03-29T12:00:00Z", "2026-03-29T00:00:00+01:00", "2026-03-30T00:00:00+02:00"},
		{"2026-10-25T12:00:00Z", "2026-10-25T00:00:00+02:00", "2026-10-26T00:00:00+01:00"},
	} {
		now, _ := time.Parse(time.RFC3339, tc.now)
		start, _ := time.Parse(time.RFC3339, tc.start)
		end, _ := time.Parse(time.RFC3339, tc.end)
		got := calendarContext(now)
		if !strings.Contains(got, "["+tc.start+", "+tc.end+")") || !strings.Contains(got, fmt.Sprintf("[%d, %d)", start.UnixNano(), end.UnixNano())) {
			t.Fatalf("wrong local calendar boundaries: %s", got)
		}
	}
}

func TestListAssetTypeRequiresExactType(t *testing.T) {
	for _, tc := range []struct {
		name string
		want uint16
	}{{"", protocol.AssetTypeNote}, {"file", protocol.AssetTypeFile}, {"company", protocol.AssetTypeCustomerCompany}, {"appointment", protocol.AssetTypeAppointment}, {"slice", protocol.AssetTypeSlice}} {
		got, err := parseListAssetType(tc.name)
		if err != nil || got != tc.want {
			t.Fatalf("%q: %d, %v", tc.name, got, err)
		}
	}
	for _, name := range []string{"all", "task", "0", "15", "unknown"} {
		if _, err := parseListAssetType(name); err == nil {
			t.Fatalf("accepted %q", name)
		}
	}
}

func TestAskHandlerRegistersListingTools(t *testing.T) {
	// Construction validates every tool schema without making an LLM request.
	handler, err := handleAskFantasy(nil, nil, nil, Config{LLMProvider: "openai", LLMModel: "gpt-5.6", LLMAPIKey: "test-key"}, 4096, newAgentSessionStore(time.Minute, 1))
	if err != nil || handler == nil {
		t.Fatalf("tool registration failed: %v", err)
	}
}

func TestAskStartsWithRetrieveAndLoadsOnlyRequestedTask(t *testing.T) {
	for _, scenario := range []string{"initial", "follow-up", "search-unavailable", "graph", "list_tasks", "search_tasks"} {
		t.Run(scenario, func(t *testing.T) {
			client, requests := connectedListingTestClient(t)
			if scenario == "graph" {
				client.protocolVersion.Store(graphRankProtocolVersion)
			}
			answer := "See #7."
			if scenario == "list_tasks" || scenario == "search_tasks" {
				answer = "See #11."
			}
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			wm := &WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": client}}
			store := newAgentSessionStore(time.Minute, 10)
			session, _ := store.getOrCreate("ws", 0, 0, "", agentModeAsk)
			question := "What is the rollout status?"
			if scenario == "follow-up" {
				store.appendTurn(session.ID, AgentTurn{UserText: question, Answer: "Release task #7 covers the rollout."})
				question = "And who owns it?"
			}
			var searchCalls atomic.Int32
			searchServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				searchCalls.Add(1)
				if scenario == "search-unavailable" {
					http.Error(w, "offline", http.StatusServiceUnavailable)
					return
				}
				var request protocol.SearchRequest
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
				}
				w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
				if request.Filters != nil && request.Filters.Task != nil {
					id, title, payload := uint64(11), "Discovered task", "Tool search evidence"
					if scenario == "graph" {
						id, title, payload = 70, "Graph task", "Graph-only task evidence"
						if len(request.Filters.Task.TaskIDs) != 1 || request.Filters.Task.TaskIDs[0] != 70 {
							t.Errorf("unexpected graph hydration query: %+v", request)
						}
					}
					_ = json.NewEncoder(w).Encode(protocol.SearchResponse{Results: []protocol.SearchResult{{Entity: protocol.SearchEntityIdentity{Workspace: "ws", EntityType: protocol.SearchEntityTask, EntityID: id}, Preview: title, Payload: payload, Metadata: protocol.SearchMetadata{Task: &protocol.SearchTaskMetadata{}}}}})
					return
				}
				if request.TopN != 10 || !strings.Contains(request.Query, question) {
					t.Errorf("wrong initial retrieval: %+v", request)
				}
				if scenario == "follow-up" && !strings.Contains(request.Query, "Release task #7") {
					t.Error("follow-up lost its referent")
				}
				w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
				var results []protocol.SearchResult
				for id := uint64(7); id <= 10; id++ {
					results = append(results, protocol.SearchResult{Entity: protocol.SearchEntityIdentity{Workspace: "ws", ConvID: 0, EntityType: protocol.SearchEntityTask, EntityID: id},
						Preview: fmt.Sprintf("Release task %d", id), Payload: strings.Repeat("evidence ", 100) + fmt.Sprintf("END %d", id), Metadata: protocol.SearchMetadata{Task: &protocol.SearchTaskMetadata{}}})
				}
				_ = json.NewEncoder(w).Encode(protocol.SearchResponse{Results: results})
			}))
			defer searchServer.Close()
			var modelCalls atomic.Int32
			modelServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				call := modelCalls.Add(1)
				var request struct {
					Messages []struct {
						Role    string
						Content json.RawMessage
					}
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
				}
				if searchCalls.Load() == 0 {
					t.Error("model called before initial retrieval")
				}
				prompt := string(request.Messages[1].Content)
				if !strings.Contains(prompt, "INITIAL WORKSPACE CONTEXT") {
					t.Error("missing initial context")
				}
				if scenario == "graph" && (!strings.Contains(prompt, "Graph-only task evidence") || !strings.Contains(prompt, "Graph-only asset evidence") || strings.Contains(prompt, "graph ranking unavailable")) {
					t.Error("successful graph hydration missing from first model context")
				}
				if scenario == "search-unavailable" {
					if !strings.Contains(prompt, "results are partial") || !strings.Contains(prompt, "empty results do not imply") {
						t.Error("lost retrieval failure warning")
					}
				} else if !strings.Contains(prompt, "END 7") || strings.Contains(prompt, "END 10") {
					t.Error("initial context did not apply top-three payload policy")
				}
				w.Header().Set("Content-Type", "application/json")
				if (scenario == "list_tasks" || scenario == "search_tasks") && call == 1 {
					args := `{}`
					if scenario == "search_tasks" {
						args = `{"query":"Discovered","limit":8,"statuses":[],"assignees":[],"projects":[],"priorities":[],"colors":[],"created_by":[],"completed_by":[],"task_ids":[],"external_refs":[],"blocked_by":[]}`
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"index": 0, "message": map[string]any{"role": "assistant", "tool_calls": []any{map[string]any{"id": "discover", "type": "function", "function": map[string]any{"name": scenario, "arguments": args}}}}, "finish_reason": "tool_calls"}}})
					return
				}
				if scenario == "follow-up" && call == 1 {
					fmt.Fprint(w, `{"choices":[{"index":0,"message":{"role":"assistant","tool_calls":[{"id":"read-7","type":"function","function":{"name":"get_task","arguments":"{\"task_id\":7}"}}]},"finish_reason":"tool_calls"}]}`)
					return
				}
				if scenario == "follow-up" && !strings.Contains(string(request.Messages[len(request.Messages)-1].Content), "fresh description") {
					t.Error("targeted task result did not reach model")
				}
				fmt.Fprintf(w, `{"choices":[{"index":0,"message":{"role":"assistant","content":%q},"finish_reason":"stop"}]}`, answer)
			}))
			defer modelServer.Close()
			handler, err := handleAskFantasy(wm, NewSearchClient(searchServer.URL), nil, Config{LLMProvider: "openai-compat", LLMModel: "fixture", LLMAPIKey: "test", LLMBaseURL: modelServer.URL, LLMMaxOutputTokens: 1024}, 128000, store)
			if err != nil {
				t.Fatal(err)
			}
			body, _ := json.Marshal(askRequest{Workspace: "ws", Question: question, SessionID: session.ID})
			recorder := httptest.NewRecorder()
			done := make(chan struct{})
			go func() {
				defer close(done)
				handler(recorder, httptest.NewRequest("POST", "/ask", bytes.NewReader(body)).WithContext(ctx))
			}()
			reads, graphReads, assetReads, pageReads := 0, 0, 0, 0
		loop:
			for {
				select {
				case msg := <-requests:
					if scenario == "graph" && msg.Opcode == protocol.C_GraphRank {
						graphReads++
						var b bytes.Buffer
						write := func(v any) { _ = binary.Write(&b, binary.BigEndian, v) }
						write(uint64(0))
						write(uint8(0))
						write(uint16(2))
						for _, entity := range []protocol.GraphRankEntity{{Type: entityTypeTask, ID: 70}, {Type: entityTypeAsset, ID: 71}} {
							write(entity.Type)
							write(entity.ID)
							write(float64(100))
							write(uint8(0))
						}
						write(uint16(0))
						write(binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:]))
						client.handleGraphRankResult(b.Bytes())
						continue
					}
					if scenario == "graph" && msg.Opcode == protocol.C_GetAsset {
						assetReads++
						if binary.BigEndian.Uint64(msg.Data[8:]) != 71 {
							t.Errorf("unexpected asset request: %x", msg.Data)
						}
						var b bytes.Buffer
						write := func(v any) { _ = binary.Write(&b, binary.BigEndian, v) }
						write(uint16(protocol.AssetTypeNote))
						write(uint64(71))
						write(uint16(0))
						write(uint64(0))
						write(uint16(0))
						write(int64(1))
						write(int64(2))
						write(uint64(0))
						write(uint8(0))
						write(uint32(len("Graph-only asset evidence")))
						for _, text := range []string{`{"title":"Graph note"}`, "Graph-only asset evidence"} {
							write(uint16(len(text)))
							b.WriteString(text)
						}
						write(uint16(0))
						client.handleAssetFull(b.Bytes())
						continue
					}
					if scenario == "list_tasks" && msg.Opcode == protocol.C_ListTasksPaged {
						pageReads++
						client.settleTaskPage(binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:]), &protocol.TaskListPage{Success: true, TotalCount: 1, Tasks: []*protocol.Task{{ID: 11, Title: "Discovered task"}}}, nil)
						continue
					}
					if msg.Opcode != protocol.C_GetTask {
						t.Errorf("unexpected NRC request (must not load task snapshot): %d", msg.Opcode)
						cancel()
						continue
					}
					reads++
					id := binary.BigEndian.Uint64(msg.Data[8:])
					if id != 7 {
						t.Errorf("requested task %d, want 7", id)
					}
					client.handleDataRead(protocol.S_TaskFull, dataTaskPayload(binary.BigEndian.Uint32(msg.Data[16:]), id))
				case <-done:
					break loop
				}
			}
			if recorder.Code != http.StatusOK {
				t.Fatalf("ask failed: %d %s", recorder.Code, recorder.Body.String())
			}
			var response askResponse
			if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil || response.Answer != answer {
				t.Fatalf("missing answer: %s (%v)", recorder.Body.String(), err)
			}
			if scenario == "follow-up" {
				if reads != 1 || modelCalls.Load() != 2 {
					t.Fatalf("targeted reads=%d model calls=%d", reads, modelCalls.Load())
				}
			} else if scenario == "list_tasks" || scenario == "search_tasks" {
				if reads != 0 || modelCalls.Load() != 2 || len(response.Sources) != 1 || response.Sources[0].ID != 11 || response.Sources[0].Title != "Discovered task" {
					t.Fatalf("discovered title lost without get_task: reads=%d sources=%+v", reads, response.Sources)
				}
				if scenario == "list_tasks" && pageReads != 1 {
					t.Fatalf("page reads=%d", pageReads)
				}
			} else if reads != 0 || modelCalls.Load() != 1 {
				t.Fatalf("unexpected bootstrap work: reads=%d model calls=%d", reads, modelCalls.Load())
			}
			if scenario == "graph" && (graphReads != 1 || assetReads != 1) {
				t.Fatalf("graph reads=%d asset reads=%d", graphReads, assetReads)
			}
			if answer == "See #7." && scenario != "search-unavailable" && (len(response.Sources) != 1 || response.Sources[0].ID != 7 || response.Sources[0].Title == "") {
				t.Fatalf("lost task citation without snapshot: %+v", response.Sources)
			}
		})
	}
}

func TestFantasyToolNumericIDInputStaysExact(t *testing.T) {
	for _, id := range []uint64{42, 9007199254740993, ^uint64(0)} {
		var got uint64
		called := false
		listing, err := functiontool.New(functiontool.Config{Name: "get_asset", Description: "precision test"}, func(_ tool.Context, input adkGetAssetInput) (adkGetAssetOutput, error) {
			called, got = true, input.AssetID
			return adkGetAssetOutput{AssetID: fmt.Sprint(input.AssetID)}, nil
		})
		if err != nil {
			t.Fatal(err)
		}
		wrapped := &fantasyADKTool{tool: listing.(adkRunnableTool)}
		response, err := wrapped.Run(t.Context(), fantasy.ToolCall{ID: "id-test", Input: fmt.Sprintf(`{"asset_id":%d}`, id)})
		if err != nil || response.IsError || !called || got != id || !strings.Contains(response.Content, fmt.Sprintf(`"asset_id":"%d"`, id)) {
			t.Fatalf("ID %d became %d (called=%v, error=%v, response=%+v)", id, got, called, err, response)
		}
	}
}

func TestFantasyToolRejectsTrailingJSONBeforeInvocation(t *testing.T) {
	called := false
	listing, err := functiontool.New(functiontool.Config{Name: "get_asset", Description: "input test"}, func(_ tool.Context, _ adkGetAssetInput) (adkGetAssetOutput, error) {
		called = true
		return adkGetAssetOutput{}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	wrapped := &fantasyADKTool{tool: listing.(adkRunnableTool)}
	for _, input := range []string{`{"asset_id":42} {}`, `{"asset_id":42} broken`, `[]`} {
		response, err := wrapped.Run(t.Context(), fantasy.ToolCall{ID: "invalid", Input: input})
		if err != nil || !response.IsError || called {
			t.Fatalf("invalid input invoked tool: %q, %+v, %v", input, response, err)
		}
	}
}

func TestFantasyToolInfoUsesEmptyRequiredArray(t *testing.T) {
	info := fantasyToolInfo(fantasyToolInfoTestTool{
		declaration: &genai.FunctionDeclaration{
			Name: "test_tool",
			Parameters: &genai.Schema{
				Type: genai.TypeObject,
				Properties: map[string]*genai.Schema{
					"query": {Type: genai.TypeString},
				},
			},
		},
	})

	if info.Required == nil {
		t.Fatal("expected empty required array, got nil")
	}
	if len(info.Required) != 0 {
		t.Fatalf("expected no required fields, got %#v", info.Required)
	}
}

// The "all relations" mask is what a graph query sends when no relation filter
// was given, so it has to cover every relation the protocol names. A mask that
// stops one short silently hides those edges from the answer.
func TestAllRelationMaskCoversEveryNamedRelation(t *testing.T) {
	relations := map[string]uint16{
		"references":   protocol.RelationReferences,
		"related-to":   protocol.RelationRelatedTo,
		"depends-on":   protocol.RelationDependsOn,
		"blocks":       protocol.RelationBlocks,
		"derived-from": protocol.RelationDerivedFrom,
		"supersedes":   protocol.RelationSupersedes,
		"member-of":    protocol.RelationMemberOf,
	}
	for name, relation := range relations {
		if allRelationMask&(1<<(relation-1)) == 0 {
			t.Fatalf("allRelationMask does not cover %s (%d)", name, relation)
		}
	}
}

func TestParseRelationMaskAcceptsMembership(t *testing.T) {
	for _, value := range []string{"member-of", "member_of", "memberof", "membership", "7"} {
		mask, err := parseRelationMask([]string{value})
		if err != nil {
			t.Fatalf("parseRelationMask(%q) failed: %v", value, err)
		}
		want := uint16(1) << (protocol.RelationMemberOf - 1)
		if mask != want {
			t.Fatalf("parseRelationMask(%q) = %b, want %b", value, mask, want)
		}
	}

	if _, err := parseRelationMask([]string{"8"}); err == nil {
		t.Fatal("a relation past the last named one must be refused")
	}
	if mask, err := parseRelationMask(nil); err != nil || mask != allRelationMask {
		t.Fatalf("an empty filter must mean every relation, got %b (%v)", mask, err)
	}
}
