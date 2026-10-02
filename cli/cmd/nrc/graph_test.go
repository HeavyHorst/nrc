package main

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestParseGraphTypeFilter(t *testing.T) {
	tests := map[string]uint16{
		"":        0,
		"all":     0,
		"asset":   1,
		"ASSETS":  1,
		"task":    2,
		" tasks ": 2,
	}
	for input, want := range tests {
		got, err := parseGraphTypeFilter(input)
		if err != nil || got != want {
			t.Fatalf("parseGraphTypeFilter(%q) = %d, %v; want %d, nil", input, got, err, want)
		}
	}
	if _, err := parseGraphTypeFilter("message"); err == nil {
		t.Fatal("invalid graph degree type filter accepted")
	}
}

func TestGraphDegreeEntriesToJSON(t *testing.T) {
	got := graphDegreeEntriesToJSON([]protocol.GraphDegreeEntry{
		{Type: 1, ID: 7, Degree: 4},
		{Type: 2, ID: 9, Degree: 3},
	})
	want := []graphDegreeEntry{
		{Type: "asset", ID: 7, Degree: 4},
		{Type: "task", ID: 9, Degree: 3},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("degree entries = %#v, want %#v", got, want)
	}
}

func TestGraphDegreeEnvelopeProjectsEntryFields(t *testing.T) {
	if err := output.Configure(false, false, "type,id"); err != nil {
		t.Fatal(err)
	}
	defer output.Configure(false, false, "")

	data, err := output.RenderJSON(graphDegreeEnvelope{
		RoomID:   7,
		RoomName: "engineering",
		Entries:  []graphDegreeEntry{{Type: "asset", ID: 9, Degree: 4}},
	}, false)
	if err != nil {
		t.Fatal(err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["room_id"] != float64(7) {
		t.Fatalf("degree envelope metadata missing: %s", data)
	}
	entry := decoded["entries"].([]any)[0].(map[string]any)
	if entry["type"] != "asset" || entry["id"] != float64(9) {
		t.Fatalf("projected degree entry = %s", data)
	}
	if _, exists := entry["degree"]; exists {
		t.Fatalf("unselected degree field retained: %s", data)
	}
}

func TestGraphDegreeAndCommonCommandsRegistered(t *testing.T) {
	degree, _, err := graphCmd.Find([]string{"degree"})
	if err != nil || degree != graphDegreeCmd {
		t.Fatalf("graph degree command missing: command=%v err=%v", degree, err)
	}
	if degree.Flags().Lookup("top") == nil || degree.Flags().Lookup("type") == nil || degree.Flags().Lookup("relation") == nil {
		t.Fatal("graph degree flags missing")
	}
	if err := degree.Args(degree, []string{"25"}); err == nil {
		t.Fatal("graph degree accepted a positional argument")
	}

	common, _, err := graphCmd.Find([]string{"common-neighbors"})
	if err != nil || common != graphCommonCmd {
		t.Fatalf("graph common alias missing: command=%v err=%v", common, err)
	}
	for _, name := range []string{"a-type", "a-id", "b-type", "b-id", "relation", "direction"} {
		if common.Flags().Lookup(name) == nil {
			t.Fatalf("graph common flag --%s missing", name)
		}
	}
	if err := common.Args(common, []string{"task:1"}); err == nil {
		t.Fatal("graph common accepted a positional argument")
	}
}
