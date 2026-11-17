package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

// The existing technical history protocol is C_ListHistory(62)/S_HistoryPage(168).
// Its JSON contract uses camelCase, unlike the separate AI Chronicle contract.
type technicalHistoryEvent struct {
	ID              string   `json:"id"`
	Timestamp       string   `json:"timestamp"`
	ActorID         string   `json:"actorId"`
	ActorName       string   `json:"actorName"`
	EntityType      string   `json:"entityType"`
	EntityID        string   `json:"entityId"`
	EntityLabel     string   `json:"entityLabel,omitempty"`
	AssetType       uint16   `json:"assetType,omitempty"`
	EntityAvailable bool     `json:"entityAvailable,omitempty"`
	Action          string   `json:"action"`
	Fields          []string `json:"fields"`
	SourceType      string   `json:"sourceType,omitempty"`
	SourceID        string   `json:"sourceId,omitempty"`
	SourceLabel     string   `json:"sourceLabel,omitempty"`
	SourceAssetType uint16   `json:"sourceAssetType,omitempty"`
	SourceAvailable bool     `json:"sourceAvailable,omitempty"`
	TargetType      string   `json:"targetType,omitempty"`
	TargetID        string   `json:"targetId,omitempty"`
	TargetLabel     string   `json:"targetLabel,omitempty"`
	TargetAssetType uint16   `json:"targetAssetType,omitempty"`
	TargetAvailable bool     `json:"targetAvailable,omitempty"`
}

type technicalHistoryPage struct {
	Events     []technicalHistoryEvent `json:"events"`
	NextBefore string                  `json:"nextBefore"`
}

func readTechnicalHistory(s *conn.Session, kind byte, entity, before uint64, limit int) (*technicalHistoryPage, error) {
	if kind > 3 || (kind == 0 && entity != 0) || (kind != 0 && entity == 0) || limit < 1 || limit > 100 {
		return nil, &conn.InvalidArgumentError{Err: fmt.Errorf("history requires limit 1..100 and either all entities or a task/asset/edge ID")}
	}
	body := make([]byte, 31) // scope remains workspace 0
	body[8] = kind
	binary.BigEndian.PutUint64(body[9:], entity)
	binary.BigEndian.PutUint64(body[17:], before)
	binary.BigEndian.PutUint16(body[25:], uint16(limit))
	binary.BigEndian.PutUint32(body[27:], historyCorrelation)
	m, err := s.SendAndRecv(&protocol.Message{Opcode: 62, Data: body})
	if err != nil {
		return nil, err
	}
	if m.Opcode != 168 || len(m.Data) < 6 || len(m.Data)+2 > protocol.MaxProtocolPayloadSize || binary.BigEndian.Uint32(m.Data) != historyCorrelation {
		return nil, fmt.Errorf("invalid technical history response opcode/length/correlation")
	}
	var response struct {
		Events     []technicalHistoryEvent `json:"events"`
		NextBefore string                  `json:"nextBefore"`
		Error      string                  `json:"error"`
	}
	if err := json.Unmarshal(m.Data[4:], &response); err != nil {
		return nil, fmt.Errorf("decode technical history: %w", err)
	}
	if response.Error != "" {
		return nil, &conn.ServerError{Message: response.Error, OriginOpcode: 62, CorrelationID: historyCorrelation}
	}
	next, err := historyDecimal(response.NextBefore, false)
	if err != nil || len(response.Events) > limit || (before != 0 && next >= before) {
		return nil, fmt.Errorf("invalid technical history page cursor/size")
	}
	previous := before
	for i, e := range response.Events {
		id, err := historyDecimal(e.ID, true)
		if err != nil || ((i > 0 || before != 0) && id >= previous) {
			return nil, fmt.Errorf("technical history events are not descending exclusive IDs")
		}
		previous = id
	}
	if next != 0 && (len(response.Events) == 0 || next != previous) {
		return nil, fmt.Errorf("technical history cursor does not match last event")
	}
	if response.Events == nil {
		response.Events = []technicalHistoryEvent{}
	}
	return &technicalHistoryPage{response.Events, response.NextBefore}, nil
}

var historyCmd = &cobra.Command{Use: "history", Short: "Read canonical technical change history (not AI summaries)"}

func init() {
	list := &cobra.Command{
		Use: "list", Short: "Read one page of technical history, newest first", Args: cobra.NoArgs,
		Run: func(cmd *cobra.Command, args []string) {
			kindName, _ := cmd.Flags().GetString("kind")
			entityText, _ := cmd.Flags().GetString("id")
			beforeText, _ := cmd.Flags().GetString("before")
			limit, _ := cmd.Flags().GetInt("limit")
			kinds := map[string]byte{"all": 0, "task": 1, "asset": 2, "edge": 3}
			kind, ok := kinds[kindName]
			if !ok {
				conn.FatalInvalid("--kind must be all, task, asset or edge (notes are assets)")
				return
			}
			entity, err := historyDecimal(entityText, kind != 0)
			if err != nil {
				conn.Fail(err)
				return
			}
			before, err := historyDecimal(beforeText, false)
			if err != nil {
				conn.Fail(err)
				return
			}
			if (kind == 0 && entity != 0) || limit < 1 || limit > 100 {
				conn.FatalInvalid("--limit must be 1..100; --id requires --kind task, asset or edge")
				return
			}
			s, err := conn.Dial("")
			if err != nil {
				conn.Fail(err)
				return
			}
			defer s.Close()
			page, err := readTechnicalHistory(s, kind, entity, before, limit)
			if err != nil {
				conn.Fail(err)
				return
			}
			if useJSONOutput(cmd) {
				output.OutputJSON(page)
				return
			}
			for _, e := range page.Events {
				fmt.Printf("%s  %s  %s  %s:%s  %s  %s  fields=%s\n", e.ID, e.Timestamp, e.ActorName, e.EntityType, e.EntityID, e.EntityLabel, e.Action, strings.Join(e.Fields, ","))
			}
			fmt.Printf("Technical events: %d  nextBefore=%s (0=end)\n", len(page.Events), page.NextBefore)
		},
	}
	list.Flags().String("kind", "all", "Entity kind: all, task, asset (including notes), edge")
	list.Flags().String("id", "0", "Entity ID; required when kind is not all; related edge events are included")
	list.Flags().String("before", "0", "Exclusive descending event ID cursor; 0 starts at newest")
	list.Flags().Int("limit", 50, "Maximum events in one page (1..100)")
	historyCmd.AddCommand(list)
	rootCmd.AddCommand(historyCmd)
}
