package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

var dmCmd = &cobra.Command{
	Use:   "dm",
	Short: "Direct messages",
}

var dmStartCmd = &cobra.Command{
	Use:   "start <username>",
	Short: "Start DM conversation",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		s, err := conn.Dial("")
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_StartDM,
			Data:   protocol.EncodeStartDM(args[0]),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_DMStarted {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		dm, err := protocol.DecodeDMStarted(resp.Data)
		if err != nil {
			conn.Fatal("Error decoding response: %v", err)
		}

		onlineStr := "offline"
		if dm.Online {
			onlineStr = "online"
		}

		output.Mutation("started", "dm", dm.ConvID, fmt.Sprintf("DM started with %s (conv_id: %d, status: %s)", dm.Username, dm.ConvID, onlineStr), map[string]any{"conv_id": dm.ConvID, "username": dm.Username, "status": onlineStr}, nil)
	},
}

var dmListCmd = &cobra.Command{
	Use:   "list",
	Short: "List DM conversations",
	Run: func(cmd *cobra.Command, args []string) {
		jsonOutput := useJSONOutput(cmd)

		s, err := conn.Dial("")
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_ListDMs,
			Data:   protocol.EncodeListDMs(),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_DMList {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		dmList, err := protocol.DecodeDMList(resp.Data)
		if err != nil {
			conn.Fatal("Error decoding response: %v", err)
		}

		type dmEntry struct {
			ConvID   uint64 `json:"conv_id"`
			Username string `json:"username"`
			Status   string `json:"status"`
			LastSeen string `json:"last_seen"`
		}

		entries := make([]dmEntry, 0, len(dmList.Entries))
		for _, e := range dmList.Entries {
			status := "offline"
			if e.Online {
				status = "online"
			}
			lastSeen := ""
			if e.LastSeen > 0 {
				lastSeen = time.Unix(int64(e.LastSeen), 0).Format(time.DateTime)
			}
			entries = append(entries, dmEntry{
				ConvID:   e.ConvID,
				Username: e.Username,
				Status:   status,
				LastSeen: lastSeen,
			})
		}

		if jsonOutput {
			output.OutputJSON(entries)
		} else {
			table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"CONV_ID", "USERNAME", "STATUS", "LAST_SEEN"}))
			for _, e := range entries {
				table.Append(
					fmt.Sprintf("%d", e.ConvID),
					e.Username,
					e.Status,
					e.LastSeen,
				)
			}
			table.Render()
		}
	},
}

var dmLeaveCmd = &cobra.Command{
	Use:   "leave <conv-id>",
	Short: "Leave DM conversation",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		convID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid conv-id: %v", err)
		}

		s, err := conn.Dial("")
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_LeaveDM,
			Data:   protocol.EncodeLeaveDM(convID),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_DMLeft {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("left", "dm", convID, fmt.Sprintf("Left DM conversation %d", convID), nil, nil)
	},
}

func init() {

	dmCmd.AddCommand(dmStartCmd, dmListCmd, dmLeaveCmd)
	rootCmd.AddCommand(dmCmd)
}
