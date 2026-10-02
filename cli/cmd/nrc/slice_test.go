package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// TestAssetTypeNamesCoverEveryProtocolType keeps the CLI's name tables complete.
// Both tables are hand-written, so a type added to protocol-go without a name
// here would be selectable on the wire but rejected as an argument and printed
// as "unknown(N)" in output.
func TestAssetTypeNamesCoverEveryProtocolType(t *testing.T) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate cli source directory")
	}
	source, err := os.ReadFile(filepath.Join(filepath.Dir(currentFile), "..", "..", "..", "protocol-go", "opcodes.go"))
	if err != nil {
		t.Fatalf("read protocol-go/opcodes.go: %v", err)
	}
	declared := regexp.MustCompile(`(?m)^\s*(AssetType[A-Za-z0-9_]*)\s+uint16\s*=\s*(\d+)`).FindAllStringSubmatch(string(source), -1)
	if len(declared) == 0 {
		t.Fatal("no asset type constants found in protocol-go/opcodes.go")
	}

	for _, match := range declared {
		value, err := strconv.Atoi(match[2])
		if err != nil {
			t.Fatalf("parse %s: %v", match[1], err)
		}
		name := assetTypeName(uint16(value))
		if name == "" || regexp.MustCompile(`^unknown\(`).MatchString(name) {
			t.Errorf("protocol-go declares %s = %d but the CLI has no name for it", match[1], value)
			continue
		}
		parsed, err := parseAssetTypeName(name)
		if err != nil {
			t.Errorf("CLI names asset type %d %q but cannot parse that name back: %v", value, name, err)
			continue
		}
		if parsed != uint16(value) {
			t.Errorf("asset type %d is named %q but %q parses to %d", value, name, name, parsed)
		}
	}
}

// TestSliceCommandSurface pins the shape of the slice command family so a
// renamed or dropped subcommand is a test failure rather than a surprise for
// whoever reads the skill.
func TestSliceCommandSurface(t *testing.T) {
	for _, path := range [][]string{
		{"slice", "list"},
		{"slice", "get"},
		{"slice", "members"},
		{"slice", "create"},
		{"slice", "assign"},
		{"slice", "unassign"},
		{"slice", "update"},
		{"slice", "close"},
		{"slice", "reopen"},
		{"slice", "delete"},
	} {
		cmd, _, err := rootCmd.Find(path)
		if err != nil || cmd.Name() != path[len(path)-1] {
			t.Fatalf("missing command %v: %v", path, err)
		}
	}
	for _, path := range [][]string{
		{"slice", "create"},
		{"slice", "assign"},
		{"slice", "unassign"},
		{"slice", "update"},
		{"slice", "close"},
		{"slice", "reopen"},
		{"slice", "delete"},
	} {
		cmd, _, err := rootCmd.Find(path)
		if err != nil {
			t.Fatalf("missing command %v: %v", path, err)
		}
		if cmd.Annotations["mutation"] != "true" {
			t.Errorf("%v must be annotated as a mutation", path)
		}
	}
	for _, path := range [][]string{{"slice", "list"}, {"slice", "get"}, {"slice", "members"}} {
		cmd, _, err := rootCmd.Find(path)
		if err != nil {
			t.Fatalf("missing command %v: %v", path, err)
		}
		if cmd.Annotations["mutation"] == "true" {
			t.Errorf("%v is a read and must not be annotated as a mutation", path)
		}
	}
	if _, err := parseSlicePreview(""); err == nil {
		t.Error("an empty slice preview must not decode")
	}
	if _, err := parseSlicePreview(`{"version":1,"name":""}`); err == nil {
		t.Error("a slice preview without a name must not decode")
	}
	if _, err := parseSlicePreview(`{"version":2,"name":"Alpha"}`); err == nil {
		t.Error("a slice preview with an unknown version must not decode")
	}
	slice, err := parseSlicePreview(`{"version":1,"name":"Alpha","owner":"rene","outcome":"Ship it.","closed":true,"closed_at":7,"closed_by":"rene"}`)
	if err != nil {
		t.Fatalf("valid slice preview rejected: %v", err)
	}
	if slice.Name != "Alpha" || slice.Owner != "rene" || slice.Outcome != "Ship it." || !slice.Closed || slice.ClosedBy != "rene" {
		t.Fatalf("unexpected decoded slice: %+v", slice)
	}
	if protocol.AssetTypeSlice != 11 {
		t.Fatalf("AssetTypeSlice = %d, want 11", protocol.AssetTypeSlice)
	}
}

// TestSliceDeleteRefusesWhatItWouldTakeWithIt pins the delete rule: a slice that
// carries nothing is deleted without ceremony, and one that carries work is
// refused until the caller says --force. The refusal has to name what is at
// stake, because that is the whole reason the flag exists.
func TestSliceDeleteRefusesWhatItWouldTakeWithIt(t *testing.T) {
	if refusal := sliceDeleteRefusal("Draft", 0, &sliceRecord{}); refusal != "" {
		t.Errorf("an empty slice should be deletable without --force, got %q", refusal)
	}
	if refusal := sliceDeleteRefusal("Draft", 0, nil); refusal != "" {
		t.Errorf("a slice without a readable record should still be deletable, got %q", refusal)
	}

	withMembers := sliceDeleteRefusal("Shard hardening", 3, &sliceRecord{Owner: "rene", Outcome: "Restart-safe."})
	for _, want := range []string{`"Shard hardening"`, "3 members", "an owner", "an outcome", "--force", "3 memberships", "themselves stay"} {
		if !strings.Contains(withMembers, want) {
			t.Errorf("refusal %q does not mention %q", withMembers, want)
		}
	}

	singular := sliceDeleteRefusal("Alpha", 1, &sliceRecord{})
	if !strings.Contains(singular, "1 member.") {
		t.Errorf("refusal %q should say one member, not one members", singular)
	}
	if strings.Contains(singular, "memberships") {
		t.Errorf("refusal %q should not promise memberships that do not exist", singular)
	}

	recorded := sliceDeleteRefusal("Alpha", 0, &sliceRecord{Outcome: "Ship it."})
	if !strings.Contains(recorded, "an outcome") || !strings.Contains(recorded, "its record") {
		t.Errorf("refusal %q should name the record it deletes", recorded)
	}
}

// TestSliceEdgeMemberReadsEitherDirection pins the membership reading: the edge
// is matched as an unordered pair, so a member is named whether the edge was
// written member -> slice or slice -> member, and the slice itself is never
// reported as its own member.
func TestSliceEdgeMemberReadsEitherDirection(t *testing.T) {
	const sliceID = uint64(11)
	memberFirst := protocol.Edge{EdgeID: 1, SourceType: protocol.TargetTypeTask, SourceID: 13, TargetType: protocol.TargetTypeAsset, TargetID: sliceID}
	targetType, memberID, found := sliceEdgeMember(memberFirst, sliceID)
	if !found || targetType != protocol.TargetTypeTask || memberID != 13 {
		t.Fatalf("member -> slice edge resolved to %d/%d (%v)", targetType, memberID, found)
	}

	sliceFirst := protocol.Edge{EdgeID: 2, SourceType: protocol.TargetTypeAsset, SourceID: sliceID, TargetType: protocol.TargetTypeAsset, TargetID: 12}
	targetType, memberID, found = sliceEdgeMember(sliceFirst, sliceID)
	if !found || targetType != protocol.TargetTypeAsset || memberID != 12 {
		t.Fatalf("slice -> member edge resolved to %d/%d (%v)", targetType, memberID, found)
	}

	if _, _, found := sliceEdgeMember(protocol.Edge{EdgeID: 3, SourceType: protocol.TargetTypeAsset, SourceID: sliceID, TargetType: protocol.TargetTypeAsset, TargetID: sliceID}, sliceID); found {
		t.Fatal("a slice is not its own member")
	}
	if _, _, found := sliceEdgeMember(protocol.Edge{EdgeID: 4, SourceType: protocol.TargetTypeTask, SourceID: 1, TargetType: protocol.TargetTypeTask, TargetID: 2}, sliceID); found {
		t.Fatal("an edge that does not touch the slice is not a membership")
	}
}
