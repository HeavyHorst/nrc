package main

import (
	"fmt"
	"strconv"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

func monitorWebhookCommand() *cobra.Command {
	c := &cobra.Command{Use: "webhook", Short: "Inspect delivery lanes and explicitly discard blocked events"}
	for _, action := range []string{"list", "get", "discard"} {
		command := &cobra.Command{Use: action + " <monitor-id>", Args: cobra.ExactArgs(1)}
		if action == "list" {
			command.Short = "List a page of pending webhook routes"
			command.Flags().String("cursor", "", "Previous next_route")
		} else {
			command.Use = action + " <monitor-id> <route>"
			command.Args = cobra.ExactArgs(2)
			command.Short = "Inspect the current lane head without leasing it"
		}
		if action == "discard" {
			command.Short = "Discard exactly one dead event; request state resynchronization"
			command.Annotations = map[string]string{"mutation": "true"}
			command.Flags().Uint64("event", 0, "Exact blocked event ID from webhook get")
			command.Flags().Int64("generation", 0, "Exact generation from webhook get")
			command.Flags().Bool("confirm", false, "Accept permanent loss of this event notification")
			_ = command.MarkFlagRequired("event")
			_ = command.MarkFlagRequired("generation")
		}
		command.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
			id, err := customerID(args[0])
			if err != nil {
				return err
			}
			r := p.MonitorDelivery{MonitorID: id, Stream: 1}
			switch action {
			case "list":
				r.Action = 6
				r.Route, _ = cmd.Flags().GetString("cursor")
			case "get":
				r.Route = args[1]
			case "discard":
				r.Action = 5
				r.Route = args[1]
				r.ID, _ = cmd.Flags().GetUint64("event")
				r.Generation, _ = cmd.Flags().GetInt64("generation")
				confirmed, _ := cmd.Flags().GetBool("confirm")
				if !confirmed {
					return &conn.InvalidArgumentError{Err: fmt.Errorf("inspect with webhook get, then pass --event, --generation and --confirm")}
				}
			}
			wire, err := p.EncodeMonitorDelivery(r)
			if err != nil {
				return &conn.InvalidArgumentError{Err: err}
			}
			response, err := s.SendAndRecv(&p.Message{Opcode: p.C_MonitorDelivery, Data: wire[2:]})
			if err != nil {
				return err
			}
			if response.Opcode != p.S_MonitorDelivery {
				return fmt.Errorf("unexpected delivery response %d", response.Opcode)
			}
			result, err := p.DecodeMonitorDeliveryResult(response.Data)
			if err != nil {
				return err
			}
			if action == "discard" {
				if result.State != 4 || result.ID != strconv.FormatUint(r.ID, 10) || result.Generation != strconv.FormatInt(r.Generation, 10) {
					return fmt.Errorf("discard not confirmed; inspect lane before retrying the same event")
				}
				output.Mutation("discarded", "webhook", r.ID, "Blocked webhook discarded; resynchronization requested", nil, nil)
			} else {
				output.OutputJSON(result)
			}
			return nil
		})
		c.AddCommand(command)
	}
	return c
}
