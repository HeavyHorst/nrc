package main

import (
	"fmt"
	"time"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

type statusResponse struct {
	Running           bool   `json:"running"`
	Workspace         string `json:"workspace"`
	Room              int64  `json:"room"`
	ActiveConnections int32  `json:"active_connections"`
	ServerTimestampNS int64  `json:"server_timestamp_ns"`
}

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show server status",
	Run: func(cmd *cobra.Command, args []string) {
		s, err := conn.Dial("")
		if err != nil {
			conn.Fail(err)
		}
		defer s.Close()

		msg := &protocol.Message{
			Opcode: protocol.C_Stats,
			Data:   protocol.EncodeStats(time.Now().UnixNano()),
		}

		resp, err := s.SendAndRecv(msg)
		if err != nil {
			conn.Fail(err)
		}

		if resp.Opcode != protocol.S_StatsResponse {
			output.Error("unexpected_response", fmt.Sprintf("Unexpected response: %d (expected %d for S_StatsResponse)", resp.Opcode, protocol.S_StatsResponse), false)
		}

		metrics, err := protocol.DecodeStats(resp.Data)
		if err != nil {
			output.Error("unexpected_response", fmt.Sprintf("Error parsing stats response: %v", err), false)
		}

		if !output.Human() {
			output.OutputJSON(statusResponse{
				Running:           true,
				Workspace:         s.Config.WorkspaceID,
				Room:              s.Config.RoomID,
				ActiveConnections: metrics.ActiveConnections,
				ServerTimestampNS: metrics.ServerTimestamp,
			})
			return
		}
		output.PrintSuccess("Server is running")
		output.PrintSuccess("Workspace:       %s", s.Config.WorkspaceID)
		output.PrintSuccess("Room:            %d", s.Config.RoomID)
		output.PrintSuccess("Active Conn:     %d", metrics.ActiveConnections)
		output.PrintSuccess("Server Time:     %s", time.Unix(0, metrics.ServerTimestamp).UTC().Format(time.RFC3339Nano))
	},
}

var (
	usersRoomFlag string
)

type userListEnvelope struct {
	Users []output.User `json:"users"`
}

var usersCmd = &cobra.Command{
	Use:   "users",
	Short: "List online users",
	Run: func(cmd *cobra.Command, args []string) {
		s, err := conn.DialChat(usersRoomFlag)
		if err != nil {
			conn.Fail(err)
		}
		defer s.Close()

		msg := &protocol.Message{
			Opcode: protocol.C_SubscribeConvs,
			Data:   protocol.EncodeSubscribeConvs(s.RoomID),
		}
		if err := s.Client.Send(msg); err != nil {
			output.Error("connection_failed", fmt.Sprintf("Error sending request: %v", err), true)
		}

		resp, ok := s.Client.RecvSkipServerReady(protocol.S_RoomPresenceUpdate)
		if !ok {
			output.Error("connection_failed", "Connection closed", true)
		}

		if resp.Opcode == protocol.S_ErrorResponse {
			output.Error("server_error", conn.DecodeServerError(resp.Data).Error(), false)
		}

		if resp.Opcode != protocol.S_RoomPresenceUpdate {
			output.Error("unexpected_response", fmt.Sprintf("Unexpected response: %d (expected %d for S_RoomPresenceUpdate)", resp.Opcode, protocol.S_RoomPresenceUpdate), false)
		}

		presence, err := protocol.DecodePresenceUpdate(resp.Data)
		if err != nil {
			output.PrintError("Error parsing users: %v", err)
		}

		users := make([]output.User, 0, len(presence.Users))
		for i, u := range presence.Users {
			statusStr := "offline"
			if u.IsAuthenticated {
				statusStr = "online"
			}
			users = append(users, output.User{
				ID:       fmt.Sprintf("%d", i),
				Nickname: u.Username,
				Status:   statusStr,
			})
		}

		if useJSONOutput(cmd) {
			output.OutputJSON(userListEnvelope{Users: users})
		} else {
			output.OutputUsersTable(users)
		}
	},
}

func init() {
	usersCmd.Flags().StringVar(&usersRoomFlag, "room", "", "Room name or ID (default: configured room, or 'lobby')")
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(usersCmd)
}
