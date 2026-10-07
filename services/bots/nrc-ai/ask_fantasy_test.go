package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"charm.land/fantasy"
	"google.golang.org/adk/tool"
	"google.golang.org/adk/tool/functiontool"
	"google.golang.org/genai"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

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
	listing, err := newADKListTasksTool(wm)
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
	for _, typeName := range []string{"Company", "Contact", "Activity", "Slice", "Appointment", "RoomMapping"} {
		answer := typeName + " [Asset:9007199254740993]"
		sources := sourcesFromAnswerRefs(answer, nil, map[uint64]string{9007199254740993: typeName + " record"})
		if len(sources) != 1 || sources[0].ID != 9007199254740993 || sources[0].Title != typeName+" record" {
			t.Fatalf("lost source: %+v", sources)
		}
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
	for _, name := range []string{"all", "task", "0", "13", "unknown"} {
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
