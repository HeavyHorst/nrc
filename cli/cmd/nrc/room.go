package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

type roomEntry struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	Label     string `json:"label"`
	IsDefault bool   `json:"is_default"`
}
type roomListEnvelope struct {
	DefaultRoomID int64       `json:"default_room_id"`
	Rooms         []roomEntry `json:"rooms"`
}

var roomCmd = &cobra.Command{
	Use:   "room",
	Short: "Inspect known room mappings",
}

var roomListCmd = &cobra.Command{
	Use:   "list",
	Short: "List known rooms and the configured default",
	Run: func(cmd *cobra.Command, args []string) {
		jsonOutput := useJSONOutput(cmd)

		cfg, err := config.Load()
		if err != nil {
			output.Error("command_failed", fmt.Sprintf("Error loading config: %v", err), false)
		}

		rooms := knownRooms(cfg.RoomID)
		assetRooms, err := fetchRoomMappingAssets()
		if err == nil {
			rooms = mergeRooms(rooms, assetRooms, cfg.RoomID)
		} else if !jsonOutput {
			fmt.Fprintf(os.Stderr, "Warning: could not load persisted room mappings: %v\n", err)
		}
		if jsonOutput {
			output.OutputJSON(roomListEnvelope{DefaultRoomID: cfg.RoomID, Rooms: rooms})
			return
		}

		fmt.Printf("Default room: %d (%s)\n\n", cfg.RoomID, conn.GetRoomName(cfg.RoomID))
		table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "NAME", "LABEL", "DEFAULT"}))
		for _, room := range rooms {
			defaultMark := ""
			if room.IsDefault {
				defaultMark = "yes"
			}
			table.Append(
				fmt.Sprintf("%d", room.ID),
				room.Name,
				room.Label,
				defaultMark,
			)
		}
		table.Render()
	},
}

type roomMappingPayload struct {
	NormalizedName string `json:"normalized_name"`
	DisplayName    string `json:"display_name"`
	ConvID         string `json:"conv_id"`
}

func knownRooms(defaultRoomID int64) []roomEntry {
	rooms := make([]roomEntry, 0, len(conn.RoomMap))
	for name, id := range conn.RoomMap {
		rooms = append(rooms, roomEntry{
			ID:        id,
			Name:      name,
			Label:     conn.GetRoomName(id),
			IsDefault: id == defaultRoomID,
		})
	}

	sort.Slice(rooms, func(i, j int) bool {
		if rooms[i].ID == rooms[j].ID {
			return rooms[i].Name < rooms[j].Name
		}
		return rooms[i].ID < rooms[j].ID
	})

	return rooms
}

func fetchRoomMappingAssets() ([]roomEntry, error) {
	s, err := conn.Dial("")
	if err != nil {
		return nil, err
	}
	defer s.Close()

	resp, err := s.SendAndRecv(&protocol.Message{
		Opcode: protocol.C_ListAssets,
		Data:   protocol.EncodeListAssets(protocol.WorkspaceDataConvID, true, protocol.AssetTypeRoomMapping, true),
	})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != protocol.S_AssetList {
		return nil, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}

	assetList, err := protocol.DecodeAssetListResponse(resp.Data)
	if err != nil {
		return nil, err
	}

	rooms := make([]roomEntry, 0, len(assetList.Assets))
	for _, asset := range assetList.Assets {
		var payload roomMappingPayload
		if err := json.Unmarshal([]byte(asset.Payload), &payload); err != nil {
			continue
		}

		name := strings.TrimSpace(payload.NormalizedName)
		if name == "" {
			name = strings.TrimSpace(asset.Preview)
		}
		if name == "" || payload.ConvID == "" {
			continue
		}

		id, err := strconv.ParseInt(payload.ConvID, 10, 64)
		if err != nil {
			continue
		}

		label := strings.TrimSpace(payload.DisplayName)
		if label == "" {
			label = strings.ToUpper(name)
		}

		rooms = append(rooms, roomEntry{
			ID:    id,
			Name:  strings.ToLower(name),
			Label: strings.ToUpper(label),
		})
	}

	return rooms, nil
}

func mergeRooms(defaultRooms []roomEntry, assetRooms []roomEntry, defaultRoomID int64) []roomEntry {
	byID := make(map[int64]roomEntry, len(defaultRooms)+len(assetRooms))
	for _, room := range defaultRooms {
		byID[room.ID] = room
	}
	for _, room := range assetRooms {
		if existing, ok := byID[room.ID]; ok && existing.Name != "" {
			continue
		}
		room.IsDefault = room.ID == defaultRoomID
		byID[room.ID] = room
	}

	rooms := make([]roomEntry, 0, len(byID))
	for _, room := range byID {
		room.IsDefault = room.ID == defaultRoomID
		rooms = append(rooms, room)
	}
	sort.Slice(rooms, func(i, j int) bool {
		if rooms[i].ID == rooms[j].ID {
			return rooms[i].Name < rooms[j].Name
		}
		return rooms[i].ID < rooms[j].ID
	})
	return rooms
}

func init() {
	roomCmd.AddCommand(roomListCmd)
	rootCmd.AddCommand(roomCmd)
}
