package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

var relationNames = map[uint16]string{
	1: "references",
	2: "related-to",
	3: "depends-on",
	4: "blocks",
	5: "derived-from",
	6: "supersedes",
	7: "member-of",
}

var relationCodes = map[string]uint16{
	"references":   1,
	"related-to":   2,
	"depends-on":   3,
	"blocks":       4,
	"derived-from": 5,
	"supersedes":   6,
	"member-of":    7,
}

var targetTypeNames = map[uint16]string{
	1: "asset",
	2: "task",
}

var targetTypeCodes = map[string]uint16{
	"asset": 1,
	"task":  2,
}

type edgeEntry struct {
	ID         uint64 `json:"id"`
	SourceType string `json:"source_type"`
	SourceID   uint64 `json:"source_id"`
	TargetType string `json:"target_type"`
	TargetID   uint64 `json:"target_id"`
	Relation   string `json:"relation"`
	CreatedBy  string `json:"created_by"`
	CreatedAt  string `json:"created_at"`
}

func edgeResource(edge protocol.Edge) edgeEntry {
	return edgeEntry{ID: edge.EdgeID, SourceType: targetTypeName(edge.SourceType), SourceID: edge.SourceID, TargetType: targetTypeName(edge.TargetType), TargetID: edge.TargetID, Relation: relationName(edge.Relation), CreatedBy: edge.CreatedBy, CreatedAt: time.Unix(0, edge.CreatedAt).Format(time.DateTime)}
}

func relationName(r uint16) string {
	if name, ok := relationNames[r]; ok {
		return name
	}
	return fmt.Sprintf("unknown(%d)", r)
}

func targetTypeName(t uint16) string {
	if name, ok := targetTypeNames[t]; ok {
		return name
	}
	return fmt.Sprintf("unknown(%d)", t)
}

var edgeCmd = &cobra.Command{
	Use:   "edge",
	Short: "Manage knowledge graph edges",
}

var edgeListCmd = &cobra.Command{
	Use:   "list",
	Short: "List edges",
	Long:  "List edges using the paged server API. All pages are followed automatically; --page-size controls the number requested per round trip.",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)
		pageSize, _ := cmd.Flags().GetInt("page-size")
		sourceTypeFlag, _ := cmd.Flags().GetString("source-type")
		sourceIDFlag, _ := cmd.Flags().GetString("source-id")
		targetTypeFlag, _ := cmd.Flags().GetString("target-type")
		targetIDFlag, _ := cmd.Flags().GetString("target-id")
		if pageSize < 1 || pageSize > 250 {
			conn.Fatal("Invalid page-size: must be 1–250")
		}

		sourceType, sourceID, hasSourceFilter := parseEdgeListEndpointFilter("source", sourceTypeFlag, sourceIDFlag)
		targetType, targetID, hasTargetFilter := parseEdgeListEndpointFilter("target", targetTypeFlag, targetIDFlag)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		var rawEdges []protocol.Edge
		if hasSourceFilter {
			rawEdges, err = fetchIncidentEdges(s, sourceType, sourceID, uint16(pageSize))
		} else if hasTargetFilter {
			rawEdges, err = fetchIncidentEdges(s, targetType, targetID, uint16(pageSize))
		} else {
			rawEdges, err = fetchAllEdgesPaged(s, uint16(pageSize))
		}
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		edges := make([]edgeEntry, 0, len(rawEdges))
		for _, edge := range rawEdges {
			if hasSourceFilter && (edge.SourceType != sourceType || edge.SourceID != sourceID) {
				continue
			}
			if hasTargetFilter && (edge.TargetType != targetType || edge.TargetID != targetID) {
				continue
			}

			edges = append(edges, edgeResource(edge))
		}

		if jsonOutput {
			output.OutputJSON(edges)
		} else {
			table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "SOURCE_TYPE", "SOURCE_ID", "TARGET_TYPE", "TARGET_ID", "RELATION", "CREATED_BY"}))
			for _, e := range edges {
				table.Append(
					fmt.Sprintf("%d", e.ID),
					e.SourceType,
					fmt.Sprintf("%d", e.SourceID),
					e.TargetType,
					fmt.Sprintf("%d", e.TargetID),
					e.Relation,
					e.CreatedBy,
				)
			}
			table.Render()
		}
	},
}

func fetchAllEdgesPaged(s *conn.Session, pageSize uint16) ([]protocol.Edge, error) {
	edges := make([]protocol.Edge, 0)
	var after uint64
	for {
		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_ListAllEdgesPaged,
			Data:   protocol.EncodeListAllEdgesPaged(s.RoomID, pageSize, after, 0),
		})
		if err != nil {
			return nil, err
		}
		if resp.Opcode != protocol.S_AllEdgeListPage {
			return nil, fmt.Errorf("unexpected edge page response: %d", resp.Opcode)
		}
		page, err := protocol.DecodeAllEdgeListPage(resp.Data)
		if err != nil {
			return nil, fmt.Errorf("parsing edge page: %w", err)
		}
		edges = append(edges, page.Edges...)
		if !page.HasMore {
			return edges, nil
		}
		if len(page.Edges) == 0 || page.NextEdgeID <= after {
			return nil, fmt.Errorf("edge pagination cursor did not advance")
		}
		after = page.NextEdgeID
	}
}

func fetchIncidentEdges(s *conn.Session, targetType uint16, targetID uint64, pageSize uint16) ([]protocol.Edge, error) {
	edges := make([]protocol.Edge, 0)
	var after uint64
	for {
		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_ListEdgesPaged,
			Data:   protocol.EncodeListEdgesPaged(s.RoomID, targetType, targetID, pageSize, after, 0),
		})
		if err != nil {
			return nil, err
		}
		if resp.Opcode != protocol.S_EdgeListPage {
			return nil, fmt.Errorf("unexpected incident edge page response: %d", resp.Opcode)
		}
		page, err := protocol.DecodeEdgeListPage(resp.Data)
		if err != nil {
			return nil, fmt.Errorf("parsing incident edge page: %w", err)
		}
		edges = append(edges, page.Edges...)
		if !page.HasMore {
			return edges, nil
		}
		if len(page.Edges) == 0 || page.NextEdgeID <= after {
			return nil, fmt.Errorf("edge pagination cursor did not advance")
		}
		after = page.NextEdgeID
	}
}

func parseEdgeListEndpointFilter(prefix, typeFlag, idFlag string) (uint16, uint64, bool) {
	if typeFlag == "" && idFlag == "" {
		return 0, 0, false
	}
	if typeFlag == "" || idFlag == "" {
		conn.Fatal("Both --%s-type and --%s-id are required when filtering by %s", prefix, prefix, prefix)
	}

	typeCode, ok := targetTypeCodes[strings.ToLower(typeFlag)]
	if !ok {
		conn.Fatal("Invalid %s-type: %s (use asset or task)", prefix, typeFlag)
	}
	id, err := strconv.ParseUint(idFlag, 10, 64)
	if err != nil {
		conn.Fatal("Invalid %s-id: %v", prefix, err)
	}

	return typeCode, id, true
}

var edgeCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create edge",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		sourceTypeFlag, _ := cmd.Flags().GetString("source-type")
		sourceIDFlag, _ := cmd.Flags().GetString("source-id")
		targetTypeFlag, _ := cmd.Flags().GetString("target-type")
		targetIDFlag, _ := cmd.Flags().GetString("target-id")
		relationFlag, _ := cmd.Flags().GetString("relation")

		st, ok := targetTypeCodes[strings.ToLower(sourceTypeFlag)]
		if !ok {
			conn.Fatal("Invalid source-type: %s (use asset or task)", sourceTypeFlag)
		}
		sid, err := strconv.ParseUint(sourceIDFlag, 10, 64)
		if err != nil {
			conn.Fatal("Invalid source-id: %v", err)
		}
		tt, ok := targetTypeCodes[strings.ToLower(targetTypeFlag)]
		if !ok {
			conn.Fatal("Invalid target-type: %s (use asset or task)", targetTypeFlag)
		}
		tid, err := strconv.ParseUint(targetIDFlag, 10, 64)
		if err != nil {
			conn.Fatal("Invalid target-id: %v", err)
		}
		rel, ok := relationCodes[strings.ToLower(relationFlag)]
		if !ok {
			conn.Fatal("Invalid relation: %s (use references, related-to, depends-on, blocks, derived-from, supersedes, member-of)", relationFlag)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_CreateEdge,
			Data:   protocol.EncodeCreateEdge(s.RoomID, st, sid, tt, tid, rel),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_EdgeCreated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		created, err := protocol.DecodeEdgeCreated(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing created edge: %v", err)
		}

		output.Mutation("created", "edge", created.Edge.EdgeID, fmt.Sprintf("Edge created: %d", created.Edge.EdgeID), edgeResource(created.Edge), nil)
	},
}

var edgeDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete edge",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		edgeID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid edge ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_DeleteEdge,
			Data:   protocol.EncodeDeleteEdge(s.RoomID, edgeID),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_EdgeDeleted {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("deleted", "edge", edgeID, "Edge deleted", nil, nil)
	},
}

func init() {
	edgeListCmd.Flags().Int("page-size", 250, "Edges requested per page, 1–250; all pages are followed")
	edgeListCmd.Flags().String("source-type", "", "Filter by source type (asset or task)")
	edgeListCmd.Flags().String("source-id", "", "Filter by source ID")
	edgeListCmd.Flags().String("target-type", "", "Filter by target type (asset or task)")
	edgeListCmd.Flags().String("target-id", "", "Filter by target ID")

	edgeCreateCmd.Flags().String("source-type", "", "Source type (asset or task)")
	edgeCreateCmd.Flags().String("source-id", "", "Source ID")
	edgeCreateCmd.Flags().String("target-type", "", "Target type (asset or task)")
	edgeCreateCmd.Flags().String("target-id", "", "Target ID")
	edgeCreateCmd.Flags().String("relation", "", "Relation (references, related-to, depends-on, blocks, derived-from, supersedes, member-of)")
	edgeCreateCmd.MarkFlagRequired("source-type")
	edgeCreateCmd.MarkFlagRequired("source-id")
	edgeCreateCmd.MarkFlagRequired("target-type")
	edgeCreateCmd.MarkFlagRequired("target-id")
	edgeCreateCmd.MarkFlagRequired("relation")

	edgeCmd.AddCommand(edgeListCmd, edgeCreateCmd, edgeDeleteCmd)
	rootCmd.AddCommand(edgeCmd)
}
