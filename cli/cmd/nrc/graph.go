package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

var directionNames = map[uint8]string{
	0: "both",
	1: "outgoing",
	2: "incoming",
}

var directionCodes = map[string]uint8{
	"both":     0,
	"outgoing": 1,
	"incoming": 2,
}

type graphNodeEntry struct {
	Type  string `json:"type"`
	ID    uint64 `json:"id"`
	Depth uint8  `json:"depth,omitempty"`
}

type graphEdgeEntry struct {
	ID         uint64 `json:"id"`
	SourceType string `json:"source_type"`
	SourceID   uint64 `json:"source_id"`
	TargetType string `json:"target_type"`
	TargetID   uint64 `json:"target_id"`
	Relation   string `json:"relation"`
	CreatedBy  string `json:"created_by"`
}

type graphWalkEnvelope struct {
	RoomID    int64            `json:"room_id"`
	RoomName  string           `json:"room_name"`
	RoomFlag  string           `json:"room_flag"`
	StartType string           `json:"start_type"`
	StartID   uint64           `json:"start_id"`
	Truncated bool             `json:"truncated"`
	Nodes     []graphNodeEntry `json:"nodes"`
	Edges     []graphEdgeEntry `json:"edges"`
}

type graphPathEnvelope struct {
	RoomID     int64            `json:"room_id"`
	RoomName   string           `json:"room_name"`
	RoomFlag   string           `json:"room_flag"`
	FromType   string           `json:"from_type"`
	FromID     uint64           `json:"from_id"`
	ToType     string           `json:"to_type"`
	ToID       uint64           `json:"to_id"`
	Found      bool             `json:"found"`
	PathLength uint8            `json:"path_length"`
	Nodes      []graphNodeEntry `json:"nodes"`
	Edges      []graphEdgeEntry `json:"edges"`
}

type graphDegreeEntry struct {
	Type   string `json:"type"`
	ID     uint64 `json:"id"`
	Degree uint16 `json:"degree"`
}

type graphDegreeEnvelope struct {
	RoomID   int64              `json:"room_id"`
	RoomName string             `json:"room_name"`
	RoomFlag string             `json:"room_flag"`
	Entries  []graphDegreeEntry `json:"entries"`
}

type graphCommonEnvelope struct {
	RoomID   int64            `json:"room_id"`
	RoomName string           `json:"room_name"`
	RoomFlag string           `json:"room_flag"`
	AType    string           `json:"a_type"`
	AID      uint64           `json:"a_id"`
	BType    string           `json:"b_type"`
	BID      uint64           `json:"b_id"`
	Nodes    []graphNodeEntry `json:"nodes"`
	Edges    []graphEdgeEntry `json:"edges"`
}

var graphCmd = &cobra.Command{
	Use:   "graph",
	Short: "Query the workspace knowledge graph",
}

var graphWalkCmd = &cobra.Command{
	Use:   "walk",
	Short: "Traverse the graph from a start node",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		startTypeFlag, _ := cmd.Flags().GetString("start-type")
		startIDFlag, _ := cmd.Flags().GetString("start-id")
		depth, _ := cmd.Flags().GetUint8("depth")
		relationFlags, _ := cmd.Flags().GetStringSlice("relation")
		directionFlag, _ := cmd.Flags().GetString("direction")
		jsonOutput := useJSONOutput(cmd)

		startType, err := parseGraphTargetType(startTypeFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		startID, err := parseUint64Arg(startIDFlag, "start ID")
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		relationMask, err := parseRelationMask(relationFlags)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		direction, err := parseDirection(directionFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_GraphQuery,
			Data:   protocol.EncodeGraphQuery(s.RoomID, startType, startID, depth, relationMask, direction, 0),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_GraphQueryResult {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		result, err := protocol.DecodeGraphQueryResult(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing graph walk result: %v", err)
		}

		if jsonOutput {
			output.OutputTopLevelJSON(graphWalkEnvelope{RoomID: s.RoomID, RoomName: conn.GetRoomName(s.RoomID), RoomFlag: roomFlag, StartType: targetTypeName(result.StartType), StartID: result.StartID, Truncated: result.Truncated, Nodes: graphNodesToJSON(result.Nodes), Edges: graphEdgesToJSON(result.Edges)})
			return
		}

		fmt.Println("Scope: workspace")
		fmt.Printf("Start: %s:%d\n", targetTypeName(result.StartType), result.StartID)
		fmt.Printf("Direction: %s\n", directionName(direction))
		fmt.Printf("Truncated: %t\n\n", result.Truncated)
		printGraphNodes(result.Nodes)
		fmt.Println()
		printGraphEdges(result.Edges)
		if len(result.Edges) == 0 {
			fmt.Println("\nNo graph edges found in this workspace.")
		}
	},
}

var graphPathCmd = &cobra.Command{
	Use:   "path",
	Short: "Find a shortest path between two nodes",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		fromTypeFlag, _ := cmd.Flags().GetString("from-type")
		fromIDFlag, _ := cmd.Flags().GetString("from-id")
		toTypeFlag, _ := cmd.Flags().GetString("to-type")
		toIDFlag, _ := cmd.Flags().GetString("to-id")
		maxDepth, _ := cmd.Flags().GetUint8("max-depth")
		relationFlags, _ := cmd.Flags().GetStringSlice("relation")
		directionFlag, _ := cmd.Flags().GetString("direction")
		jsonOutput := useJSONOutput(cmd)

		fromType, err := parseGraphTargetType(fromTypeFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		fromID, err := parseUint64Arg(fromIDFlag, "from ID")
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		toType, err := parseGraphTargetType(toTypeFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		toID, err := parseUint64Arg(toIDFlag, "to ID")
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		relationMask, err := parseRelationMask(relationFlags)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		direction, err := parseDirection(directionFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_GraphShortestPath,
			Data:   protocol.EncodeGraphShortestPath(s.RoomID, fromType, fromID, toType, toID, relationMask, direction, maxDepth, 0),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_GraphShortestPathResult {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		result, err := protocol.DecodeGraphShortestPathResult(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing graph path result: %v", err)
		}

		if jsonOutput {
			output.OutputTopLevelJSON(graphPathEnvelope{RoomID: s.RoomID, RoomName: conn.GetRoomName(s.RoomID), RoomFlag: roomFlag, FromType: targetTypeName(result.FromType), FromID: result.FromID, ToType: targetTypeName(result.ToType), ToID: result.ToID, Found: result.Found, PathLength: result.PathLength, Nodes: shortestPathNodesToJSON(result.Nodes), Edges: graphEdgesToJSON(result.Edges)})
			return
		}

		fmt.Println("Scope: workspace")
		fmt.Printf("From: %s:%d\n", targetTypeName(result.FromType), result.FromID)
		fmt.Printf("To: %s:%d\n", targetTypeName(result.ToType), result.ToID)
		fmt.Printf("Direction: %s\n", directionName(direction))
		fmt.Printf("Found: %t\n", result.Found)
		fmt.Printf("Path Length: %d\n\n", result.PathLength)

		if !result.Found {
			fmt.Println("No path found in this workspace.")
			return
		}

		printShortestPathNodes(result.Nodes)
		fmt.Println()
		printGraphEdges(result.Edges)
	},
}

var graphDegreeCmd = &cobra.Command{
	Use:   "degree",
	Short: "Rank nodes by degree",
	Args:  cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		top, _ := cmd.Flags().GetUint16("top")
		typeFlag, _ := cmd.Flags().GetString("type")
		relationFlags, _ := cmd.Flags().GetStringSlice("relation")
		jsonOutput := useJSONOutput(cmd)

		if top < 1 || top > 100 {
			conn.FatalInvalid("--top must be between 1 and 100")
		}
		typeFilter, err := parseGraphTypeFilter(typeFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		relationMask, err := parseRelationMask(relationFlags)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_GraphDegree,
			Data:   protocol.EncodeGraphDegree(s.RoomID, top, typeFilter, relationMask),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_GraphDegreeResult {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		result, err := protocol.DecodeGraphDegreeResult(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing graph degree result: %v", err)
		}
		entries := graphDegreeEntriesToJSON(result.Entries)

		if jsonOutput {
			output.OutputJSON(graphDegreeEnvelope{RoomID: s.RoomID, RoomName: conn.GetRoomName(s.RoomID), RoomFlag: roomFlag, Entries: entries})
			return
		}

		fmt.Print("Scope: workspace\n\n")
		table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"RANK", "TYPE", "ID", "DEGREE"}))
		for i, entry := range entries {
			table.Append(fmt.Sprintf("%d", i+1), entry.Type, fmt.Sprintf("%d", entry.ID), fmt.Sprintf("%d", entry.Degree))
		}
		table.Render()
	},
}

var graphCommonCmd = &cobra.Command{
	Use:     "common",
	Aliases: []string{"common-neighbors"},
	Short:   "Find common neighbors of two nodes",
	Args:    cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		aTypeFlag, _ := cmd.Flags().GetString("a-type")
		aIDFlag, _ := cmd.Flags().GetString("a-id")
		bTypeFlag, _ := cmd.Flags().GetString("b-type")
		bIDFlag, _ := cmd.Flags().GetString("b-id")
		relationFlags, _ := cmd.Flags().GetStringSlice("relation")
		directionFlag, _ := cmd.Flags().GetString("direction")
		jsonOutput := useJSONOutput(cmd)

		aType, err := parseGraphTargetType(aTypeFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		aID, err := parseUint64Arg(aIDFlag, "A ID")
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		bType, err := parseGraphTargetType(bTypeFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		bID, err := parseUint64Arg(bIDFlag, "B ID")
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		relationMask, err := parseRelationMask(relationFlags)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		direction, err := parseDirection(directionFlag)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_GraphCommonNeighbors,
			Data:   protocol.EncodeGraphCommonNeighbors(s.RoomID, aType, aID, bType, bID, relationMask, direction),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_GraphCommonNeighborsResult {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		result, err := protocol.DecodeGraphCommonNeighborsResult(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing common neighbors result: %v", err)
		}
		nodes := shortestPathNodesToJSON(result.Nodes)
		edges := graphEdgesToJSON(result.Edges)

		if jsonOutput {
			output.OutputTopLevelJSON(graphCommonEnvelope{RoomID: s.RoomID, RoomName: conn.GetRoomName(s.RoomID), RoomFlag: roomFlag, AType: targetTypeName(result.AType), AID: result.AID, BType: targetTypeName(result.BType), BID: result.BID, Nodes: nodes, Edges: edges})
			return
		}

		fmt.Println("Scope: workspace")
		fmt.Printf("A: %s:%d\n", targetTypeName(result.AType), result.AID)
		fmt.Printf("B: %s:%d\n", targetTypeName(result.BType), result.BID)
		fmt.Printf("Direction: %s\n\n", directionName(direction))
		printShortestPathNodes(result.Nodes)
		fmt.Println()
		printGraphEdges(result.Edges)
	},
}

func parseGraphTargetType(value string) (uint16, error) {
	targetType, ok := targetTypeCodes[strings.ToLower(strings.TrimSpace(value))]
	if !ok {
		return 0, fmt.Errorf("invalid target type: %s (use asset or task)", value)
	}
	return targetType, nil
}

func parseGraphTypeFilter(value string) (uint16, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "all":
		return 0, nil
	case "asset", "assets":
		return 1, nil
	case "task", "tasks":
		return 2, nil
	default:
		return 0, fmt.Errorf("invalid type filter: %s (use all, assets, or tasks)", value)
	}
}

func parseUint64Arg(value, label string) (uint64, error) {
	parsed, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid %s: %w", label, err)
	}
	return parsed, nil
}

func parseRelationMask(values []string) (uint16, error) {
	if len(values) == 0 {
		return 0, nil
	}

	var mask uint16
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			part = strings.TrimSpace(strings.ToLower(part))
			if part == "" || part == "all" || part == "*" {
				continue
			}
			relation, ok := relationCodes[part]
			if !ok {
				return 0, fmt.Errorf("invalid relation: %s (use references, related-to, depends-on, blocks, derived-from, supersedes)", part)
			}
			mask |= 1 << (relation - 1)
		}
	}

	return mask, nil
}

func parseDirection(value string) (uint8, error) {
	direction, ok := directionCodes[strings.ToLower(strings.TrimSpace(value))]
	if !ok {
		return 0, fmt.Errorf("invalid direction: %s (use both, outgoing, incoming)", value)
	}
	return direction, nil
}

func directionName(direction uint8) string {
	if name, ok := directionNames[direction]; ok {
		return name
	}
	return fmt.Sprintf("unknown(%d)", direction)
}

func graphNodesToJSON(nodes []protocol.GraphNode) []graphNodeEntry {
	out := make([]graphNodeEntry, 0, len(nodes))
	for _, node := range nodes {
		out = append(out, graphNodeEntry{Type: targetTypeName(node.Type), ID: node.ID, Depth: node.Depth})
	}
	return out
}

func shortestPathNodesToJSON(nodes []protocol.GraphShortestPathNode) []graphNodeEntry {
	out := make([]graphNodeEntry, 0, len(nodes))
	for _, node := range nodes {
		out = append(out, graphNodeEntry{Type: targetTypeName(node.Type), ID: node.ID})
	}
	return out
}

func graphDegreeEntriesToJSON(entries []protocol.GraphDegreeEntry) []graphDegreeEntry {
	out := make([]graphDegreeEntry, 0, len(entries))
	for _, entry := range entries {
		out = append(out, graphDegreeEntry{Type: targetTypeName(entry.Type), ID: entry.ID, Degree: entry.Degree})
	}
	return out
}

func graphEdgesToJSON(edges []protocol.Edge) []graphEdgeEntry {
	out := make([]graphEdgeEntry, 0, len(edges))
	for _, edge := range edges {
		out = append(out, graphEdgeEntry{
			ID:         edge.EdgeID,
			SourceType: targetTypeName(edge.SourceType),
			SourceID:   edge.SourceID,
			TargetType: targetTypeName(edge.TargetType),
			TargetID:   edge.TargetID,
			Relation:   relationName(edge.Relation),
			CreatedBy:  edge.CreatedBy,
		})
	}
	return out
}

func printGraphNodes(nodes []protocol.GraphNode) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"TYPE", "ID", "DEPTH"}))
	for _, node := range nodes {
		table.Append(targetTypeName(node.Type), fmt.Sprintf("%d", node.ID), fmt.Sprintf("%d", node.Depth))
	}
	table.Render()
}

func printShortestPathNodes(nodes []protocol.GraphShortestPathNode) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"TYPE", "ID"}))
	for _, node := range nodes {
		table.Append(targetTypeName(node.Type), fmt.Sprintf("%d", node.ID))
	}
	table.Render()
}

func printGraphEdges(edges []protocol.Edge) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "SOURCE", "RELATION", "TARGET", "CREATED_BY"}))
	for _, edge := range edges {
		table.Append(
			fmt.Sprintf("%d", edge.EdgeID),
			fmt.Sprintf("%s:%d", targetTypeName(edge.SourceType), edge.SourceID),
			relationName(edge.Relation),
			fmt.Sprintf("%s:%d", targetTypeName(edge.TargetType), edge.TargetID),
			edge.CreatedBy,
		)
	}
	table.Render()
}

func init() {
	graphWalkCmd.Flags().String("start-type", "", "Start node type (asset or task)")
	graphWalkCmd.Flags().String("start-id", "", "Start node ID")
	graphWalkCmd.Flags().Uint8("depth", 2, "Traversal depth (1-4)")
	graphWalkCmd.Flags().StringSlice("relation", nil, "Relation filter (repeat or use comma-separated values)")
	graphWalkCmd.Flags().String("direction", "both", "Traversal direction: both, outgoing, incoming")
	graphWalkCmd.MarkFlagRequired("start-type")
	graphWalkCmd.MarkFlagRequired("start-id")

	graphPathCmd.Flags().String("from-type", "", "Source node type (asset or task)")
	graphPathCmd.Flags().String("from-id", "", "Source node ID")
	graphPathCmd.Flags().String("to-type", "", "Destination node type (asset or task)")
	graphPathCmd.Flags().String("to-id", "", "Destination node ID")
	graphPathCmd.Flags().Uint8("max-depth", 4, "Maximum search depth (1-4)")
	graphPathCmd.Flags().StringSlice("relation", nil, "Relation filter (repeat or use comma-separated values)")
	graphPathCmd.Flags().String("direction", "both", "Traversal direction: both, outgoing, incoming")
	graphPathCmd.MarkFlagRequired("from-type")
	graphPathCmd.MarkFlagRequired("from-id")
	graphPathCmd.MarkFlagRequired("to-type")
	graphPathCmd.MarkFlagRequired("to-id")

	graphDegreeCmd.Flags().Uint16("top", 10, "Number of ranked nodes to return (1-100)")
	graphDegreeCmd.Flags().String("type", "all", "Node type filter: all, assets, or tasks")
	graphDegreeCmd.Flags().StringSlice("relation", nil, "Relation filter (repeat or use comma-separated values)")

	graphCommonCmd.Flags().String("a-type", "", "First node type (asset or task)")
	graphCommonCmd.Flags().String("a-id", "", "First node ID")
	graphCommonCmd.Flags().String("b-type", "", "Second node type (asset or task)")
	graphCommonCmd.Flags().String("b-id", "", "Second node ID")
	graphCommonCmd.Flags().StringSlice("relation", nil, "Relation filter (repeat or use comma-separated values)")
	graphCommonCmd.Flags().String("direction", "both", "Traversal direction: both, outgoing, incoming")
	graphCommonCmd.MarkFlagRequired("a-type")
	graphCommonCmd.MarkFlagRequired("a-id")
	graphCommonCmd.MarkFlagRequired("b-type")
	graphCommonCmd.MarkFlagRequired("b-id")

	graphCmd.AddCommand(graphWalkCmd, graphPathCmd, graphDegreeCmd, graphCommonCmd)
	rootCmd.AddCommand(graphCmd)
}
