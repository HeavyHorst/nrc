package main

import (
	"fmt"
	"os"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

func fetchMetadataList(s *conn.Session, request, response uint16) ([]string, error) {
	r, err := s.SendAndRecv(&p.Message{Opcode: request, Data: p.EncodeListTaskProjects(p.WorkspaceDataConvID, 0)})
	values := make([]string, 0)
	for {
		if err != nil {
			return nil, err
		}
		if r.Opcode != response {
			return nil, fmt.Errorf("unexpected response: %d", r.Opcode)
		}
		var page *p.StringList
		switch response {
		case p.S_SliceOwners:
			page, err = p.DecodeSliceOwners(r.Data)
		case p.S_TicketAssignees:
			page, err = p.DecodeTicketAssignees(r.Data)
		case p.S_CalendarPeople:
			page, err = p.DecodeCalendarPeople(r.Data)
		default:
			return nil, fmt.Errorf("unknown metadata list: %d", response)
		}
		if err != nil {
			return nil, err
		}
		if page.ConvID != p.WorkspaceDataConvID || page.CorrelationID != 0 {
			return nil, fmt.Errorf("metadata list scope or correlation mismatch")
		}
		if len(values) > 0 && len(page.Values) > 0 && page.Values[0] <= values[len(values)-1] {
			return nil, fmt.Errorf("metadata list order did not advance")
		}
		values = append(values, page.Values...)
		if !page.HasMore {
			return values, nil
		}
		var ok bool
		r, ok = s.Client.RecvSkipServerReady(0)
		if !ok {
			return nil, &conn.ConnectionError{Err: fmt.Errorf("connection closed")}
		}
		if r.Opcode == p.S_ErrorResponse {
			return nil, conn.DecodeServerError(r.Data)
		}
	}
}

func metadataListCommand(name, header string, request, response uint16) *cobra.Command {
	c := &cobra.Command{
		Use: name, Short: "List workspace " + name,
		Long: "List sorted unique nonempty workspace " + name + ", independent of loaded records, date ranges, and list filters.",
		Args: cobra.NoArgs,
		Run: func(cmd *cobra.Command, args []string) {
			room, _ := cmd.Flags().GetString("room")
			s, err := conn.Dial(room)
			if err != nil {
				conn.Fatal("Error: %v", err)
				return
			}
			defer s.Close()
			values, err := fetchMetadataList(s, request, response)
			if err != nil {
				conn.Fatal("Error: %v", err)
				return
			}
			if useJSONOutput(cmd) {
				output.OutputJSON(values)
				return
			}
			table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{header}))
			for _, v := range values {
				table.Append(v)
			}
			table.Render()
		},
	}
	return c
}

func init() {
	sliceCmd.AddCommand(metadataListCommand("owners", "OWNER", p.C_ListSliceOwners, p.S_SliceOwners))
	calendar := &cobra.Command{Use: "calendar", Short: "Read workspace calendar metadata"}
	people := metadataListCommand("people", "PERSON", p.C_ListCalendarPeople, p.S_CalendarPeople)
	people.Long += " Includes task assignees and appointment organizers, participants, and overrides."
	calendar.AddCommand(people)
	rootCmd.AddCommand(calendar)
}
