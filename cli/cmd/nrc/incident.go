package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"text/tabwriter"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

type incidentRecord struct {
	ID             uint64 `json:"id"`
	Revision       string `json:"revision"`
	Title          string `json:"title"`
	MonitorID      string `json:"monitor_id"`
	InstanceID     string `json:"instance_id"`
	Episode        string `json:"episode"`
	Status         string `json:"status"`
	OpenedAt       string `json:"opened_at"`
	ClosedAt       string `json:"closed_at"`
	AcknowledgedBy string `json:"acknowledged_by"`
	AcknowledgedAt string `json:"acknowledged_at"`
	AssignedTo     string `json:"assigned_to"`
}

func incidentRecordFrom(a p.Asset) (incidentRecord, error) {
	var r incidentRecord
	err := json.Unmarshal([]byte(a.Preview), &r)
	r.ID, r.Revision = a.AssetID, strconv.FormatInt(a.UpdatedAt, 10)
	return r, err
}

func newIncidentCommand() *cobra.Command {
	c := &cobra.Command{Use: "incident", Short: "Inspect, acknowledge and assign automatically created incidents"}
	c.Long = "Incidents are created and recovered by monitoring. Acknowledgment records human awareness; assignment records responsibility. Neither changes the technical status."
	get := &cobra.Command{Use: "get <id>", Short: "Show an incident and its current revision", Args: cobra.ExactArgs(1)}
	get.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		id, err := customerID(args[0])
		if err != nil {
			return err
		}
		a, err := customerAsset(s, id, p.AssetTypeIncident)
		if err != nil {
			return err
		}
		r, err := incidentRecordFrom(a)
		if err != nil {
			return err
		}
		if useJSONOutput(cmd) {
			output.OutputJSON(r)
		} else {
			b, err := json.MarshalIndent(r, "", "  ")
			if err != nil {
				return err
			}
			fmt.Println(string(b))
		}
		return nil
	})
	list := &cobra.Command{Use: "list", Short: "List incidents, including closed ones (newest edits first)", Args: cobra.NoArgs}
	list.Flags().Int("limit", 50, "Page size, 1–250")
	list.Flags().String("cursor", "", "Resume from next_cursor")
	list.Run = customerRun(func(cmd *cobra.Command, _ []string, s *conn.Session) error {
		page, err := monitoringAssetPage(cmd, s, p.AssetTypeIncident)
		if err != nil {
			return err
		}
		entries := make([]incidentRecord, 0, len(page.Assets))
		for _, a := range page.Assets {
			r, err := incidentRecordFrom(a)
			if err != nil {
				return err
			}
			entries = append(entries, r)
		}
		next := ""
		if page.HasMore {
			next = encodeNoteCursor(page.NextCursorUpdatedAt, page.NextCursorAssetID)
		}
		if useJSONOutput(cmd) {
			output.OutputJSON(map[string]any{"entries": entries, "has_more": page.HasMore, "next_cursor": next, "total_count": page.TotalCount})
		} else {
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			fmt.Fprintln(w, "ID\tSTATUS\tACKNOWLEDGED BY\tASSIGNED TO\tTITLE")
			for _, r := range entries {
				fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n", r.ID, r.Status, r.AcknowledgedBy, r.AssignedTo, r.Title)
			}
			w.Flush()
			if page.HasMore {
				fmt.Println("Next cursor:", next)
			}
		}
		return nil
	})
	c.AddCommand(get, list, incidentActionCommand(false), incidentActionCommand(true))
	return c
}

func incidentActionCommand(assign bool) *cobra.Command {
	c := &cobra.Command{Use: "ack <id>", Short: "Acknowledge an incident without resolving it", Args: cobra.ExactArgs(1), Annotations: map[string]string{"mutation": "true"}}
	if assign {
		c.Use, c.Short, c.Args = "assign <id> [assignee]", "Assign responsibility, or clear it with --clear", cobra.RangeArgs(1, 2)
		c.Flags().Bool("clear", false, "Remove the assignment")
	}
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		id, err := customerID(args[0])
		if err != nil {
			return err
		}
		action, assignee := p.AcknowledgeIncident, ""
		if assign {
			clear, _ := cmd.Flags().GetBool("clear")
			if clear && len(args) != 1 || !clear && (len(args) != 2 || args[1] == "") {
				return &conn.InvalidArgumentError{Err: fmt.Errorf("provide an assignee or --clear, not both")}
			}
			action = p.AssignIncident
			if !clear {
				assignee = args[1]
			}
		}
		a, err := customerAsset(s, id, p.AssetTypeIncident)
		if err != nil {
			return err
		}
		wire, err := p.EncodeActOnIncident(p.ActOnIncident{IncidentID: id, Revision: a.UpdatedAt, Action: action, Assignee: assignee})
		if err != nil {
			return &conn.InvalidArgumentError{Err: err}
		}
		resp, err := s.SendAndRecv(&p.Message{Opcode: p.C_ActOnIncident, Data: wire[2:]})
		if err != nil {
			var serverError *conn.ServerError
			if errors.As(err, &serverError) {
				return err
			}
			// A fresh CLI invocation reads a new revision, so it is not a replay.
			return &conn.CommandError{Err: fmt.Errorf("incident action outcome unconfirmed; inspect the incident before retrying: %w", err)}
		}
		if resp.Opcode != p.S_IncidentActionApplied {
			return fmt.Errorf("unexpected incident action response: %d", resp.Opcode)
		}
		receipt, err := p.DecodeIncidentActionApplied(resp.Data)
		if err != nil {
			return err
		}
		if receipt.IncidentID != id || receipt.CorrelationID != 0 {
			return fmt.Errorf("incident action receipt does not match request")
		}
		if useJSONOutput(cmd) {
			output.OutputJSON(map[string]any{"id": id, "revision": strconv.FormatInt(receipt.Revision, 10), "replayed": receipt.Replayed})
		} else {
			fmt.Printf("Incident %d updated (revision %d); technical status unchanged.\n", id, receipt.Revision)
		}
		return nil
	})
	return c
}

func init() { rootCmd.AddCommand(newIncidentCommand()) }
