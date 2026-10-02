package main

import (
	"testing"

	"google.golang.org/adk/tool"
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
