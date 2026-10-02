package output

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestAttachmentJSONPreservesMetadataFieldsAndAddsURL(t *testing.T) {
	encoded, err := json.Marshal(Attachment{FileID: "att_one", Filename: "report.pdf", URL: "https://files.example/files/att_one"})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range [][]byte{[]byte(`"FileId":"att_one"`), []byte(`"Filename":"report.pdf"`), []byte(`"url":"https://files.example/files/att_one"`)} {
		if !bytes.Contains(encoded, want) {
			t.Fatalf("attachment JSON %s missing %s", encoded, want)
		}
	}
}

func TestProjectObjectArrayAndEnvelope(t *testing.T) {
	if err := Configure(false, false, "id"); err != nil {
		t.Fatal(err)
	}
	got, err := project([]map[string]any{{"id": 1, "title": "x"}})
	if err != nil {
		t.Fatal(err)
	}
	if got.([]any)[0].(map[string]any)["id"] != json.Number("1") {
		t.Fatalf("unexpected projection: %#v", got)
	}
	got, err = project(map[string]any{"tasks": []map[string]any{{"id": 2, "title": "y"}}, "next": "c"})
	if err != nil {
		t.Fatal(err)
	}
	if got.(map[string]any)["next"] != "c" {
		t.Fatalf("metadata lost: %#v", got)
	}
	if err := Configure(false, true, "missing"); err != nil {
		t.Fatal(err)
	}
	if _, err = project(map[string]any{"id": 1}); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestProjectionUsesExplicitEnvelopeAndValidatesEmptyCollections(t *testing.T) {
	if err := Configure(false, false, "id"); err != nil {
		t.Fatal(err)
	}
	got, err := project(map[string]any{"attachments": []any{map[string]any{"id": 99}}, "related_notes": []any{}, "id": 7, "title": "note"})
	if err != nil {
		t.Fatal(err)
	}
	if got.(map[string]any)["id"] != json.Number("7") || len(got.(map[string]any)) != 1 {
		t.Fatalf("single resource projected as collection: %#v", got)
	}

	if err := Configure(false, false, "id,title,content,related_notes"); err != nil {
		t.Fatal(err)
	}
	got, err = project(map[string]any{
		"id":            7,
		"title":         "note",
		"content":       "body",
		"tags":          []string{"cli", "agents"},
		"related_notes": []any{},
	})
	if err != nil {
		t.Fatal(err)
	}
	projected := got.(map[string]any)
	if projected["id"] != json.Number("7") || projected["title"] != "note" || projected["content"] != "body" || len(projected) != 4 {
		t.Fatalf("single resource with scalar tags projected as collection: %#v", got)
	}

	if err := Configure(false, false, "missing"); err != nil {
		t.Fatal(err)
	}
	if _, err := project(map[string]any{"tasks": []any{}, "next": "cursor"}); err == nil {
		t.Fatal("unknown field accepted for empty collection")
	}
	if err := Configure(false, false, "id"); err != nil {
		t.Fatal(err)
	}
	got, err = project(map[string]any{"notes": []any{map[string]any{"id": 2}}, "tasks": []any{map[string]any{"id": 1}}, "next": "cursor"})
	if err != nil {
		t.Fatal(err)
	}
	if got.(map[string]any)["tasks"].([]any)[0].(map[string]any)["id"] != json.Number("1") {
		t.Fatalf("deterministic tasks envelope not selected: %#v", got)
	}
	if len(got.(map[string]any)["notes"].([]any)[0].(map[string]any)) != 1 {
		t.Fatalf("non-selected envelope changed: %#v", got)
	}
	if got.(map[string]any)["next"] != "cursor" {
		t.Fatal("metadata lost")
	}
}

func TestRenderCompactPrettyAndJSONLine(t *testing.T) {
	v := map[string]any{"a": 1, "b": map[string]any{"c": 2}}
	_ = Configure(false, false, "")
	compact, err := RenderJSON(v, false)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(compact, []byte("\n")) {
		t.Fatalf("compact output contains newline: %q", compact)
	}
	_ = Configure(false, true, "")
	prettyBytes, err := RenderJSON(v, false)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(prettyBytes, []byte("\n  \"")) {
		t.Fatalf("pretty output not indented: %q", prettyBytes)
	}
	line, err := RenderJSON(v, true)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(line, []byte("\n")) {
		t.Fatalf("JSONL event not compact: %q", line)
	}
}

func TestConfigureRejectsHumanFields(t *testing.T) {
	if Configure(true, false, "id") == nil {
		t.Fatal("expected incompatible flag error")
	}
}

func TestRenderErrorPrettyIgnoresFields(t *testing.T) {
	_ = Configure(false, true, "definitely_unknown")
	b, err := RenderError("server_error", "failed", false)
	if err != nil || !bytes.Contains(b, []byte("\n")) || !bytes.Contains(b, []byte(`"retryable": false`)) {
		t.Fatalf("error=%s err=%v", b, err)
	}
}

func TestBatchEnvelopeProjectionHandlesEmptyResults(t *testing.T) {
	type result struct {
		Index int    `json:"index"`
		ID    uint64 `json:"id,omitempty"`
	}
	type envelope struct {
		Atomic  bool     `json:"atomic"`
		Results []result `json:"results"`
	}
	_ = Configure(false, false, "id")
	if _, err := RenderJSON(envelope{Results: []result{}}, false); err != nil {
		t.Fatal(err)
	}
	b, err := RenderJSON(envelope{Results: []result{{Index: 0}}}, false)
	if err != nil || !bytes.Contains(b, []byte(`"results":[{}]`)) {
		t.Fatalf("batch projection=%s err=%v", b, err)
	}
}

func TestProjectionUsesActualEnvelopeDTO(t *testing.T) {
	type searchItem struct {
		Score   float64 `json:"score"`
		Preview string  `json:"preview"`
	}
	type searchEnvelope struct {
		Results []searchItem `json:"results"`
		Cursor  string       `json:"cursor"`
	}
	_ = Configure(false, false, "score")
	got, err := RenderJSON(searchEnvelope{Results: []searchItem{{Score: 1, Preview: "x"}}}, false)
	if err != nil || !bytes.Contains(got, []byte(`"score":1`)) || bytes.Contains(got, []byte("preview")) {
		t.Fatalf("got=%s err=%v", got, err)
	}
	_ = Configure(false, false, "preview")
	if _, err = RenderJSON(struct {
		Results []struct {
			ID uint64 `json:"id"`
		} `json:"results"`
	}{}, false); err == nil {
		t.Fatal("divergent empty DTO accepted wrong field")
	}
}

func TestProjectionTypedMapSlicesAndScalarArrays(t *testing.T) {
	type room struct {
		RoomID int64  `json:"room_id"`
		Name   string `json:"name"`
	}
	_ = Configure(false, false, "room_id")
	if _, err := RenderJSON(map[string][]room{"rooms": {}}, false); err != nil {
		t.Fatal(err)
	}
	for _, value := range []any{[]string{}, []string{"x"}} {
		if _, err := RenderJSON(value, false); err == nil {
			t.Fatalf("scalar array accepted: %#v", value)
		}
	}
}

func TestProjectionPreservesExactNumbers(t *testing.T) {
	t.Cleanup(func() { _ = Configure(false, false, "") })
	type record struct {
		ID        uint64          `json:"id"`
		Metadata  json.RawMessage `json:"metadata"`
		UpdatedAt int64           `json:"updated_at"`
	}
	r := record{18446744073709551615, json.RawMessage(`{"custom":9007199254740993}`), 1789290000000000001}
	_ = Configure(false, false, "id,metadata,updated_at")
	for _, input := range []any{r, struct {
		Entries []record `json:"entries"`
		Next    uint64   `json:"next_edge_id"`
	}{[]record{r}, 18446744073709551613}, struct {
		Edges []record `json:"edges"`
		Next  uint64   `json:"next_edge_id"`
	}{[]record{r}, 18446744073709551613}} {
		data, err := RenderJSON(input, false)
		if err != nil {
			t.Fatal(err)
		}
		for _, exact := range []string{`"id":18446744073709551615`, `"custom":9007199254740993`, `"updated_at":1789290000000000001`} {
			if !bytes.Contains(data, []byte(exact)) {
				t.Fatalf("precision lost: %s lacks %s", data, exact)
			}
		}
		if _, single := input.(record); !single && !bytes.Contains(data, []byte(`"next_edge_id":18446744073709551613`)) {
			t.Fatalf("cursor rounded: %s", data)
		}
	}
}
