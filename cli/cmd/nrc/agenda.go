package main

import (
	"fmt"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

var agendaCmd = &cobra.Command{
	Use:   "agenda",
	Short: "Manage workspace agenda (MEMO)",
}

var agendaShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show workspace agenda",
	RunE: func(cmd *cobra.Command, args []string) error {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonFlag := useJSONOutput(cmd)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_ListAssets,
			Data:   protocol.EncodeListAssets(s.RoomID, true, protocol.AssetTypeAgenda, true),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetList {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		assets, err := protocol.DecodeAssetList(resp.Data, true)
		if err != nil {
			conn.Fatal("Error parsing assets: %v", err)
		}
		if err := checkAgendaSelection(assets); err != nil {
			return err
		}

		if len(assets) == 0 {
			if jsonFlag {
				output.OutputJSON(map[string]string{"content": ""})
			} else {
				fmt.Println("No agenda set.")
			}
			return nil
		}

		a := assets[0]
		if jsonFlag {
			output.OutputJSON(map[string]string{"content": a.Payload})
		} else {
			fmt.Print(a.Payload)
			if len(a.Payload) > 0 && a.Payload[len(a.Payload)-1] != '\n' {
				fmt.Println()
			}
		}
		return nil
	},
}

var agendaSetCmd = &cobra.Command{
	Use:   "set <content>",
	Short: "Set workspace agenda",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		roomFlag, _ := cmd.Flags().GetString("room")
		content := args[0]

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		// List existing agenda assets
		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_ListAssets,
			Data:   protocol.EncodeListAssets(s.RoomID, true, protocol.AssetTypeAgenda, true),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetList {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		assets, err := protocol.DecodeAssetList(resp.Data, true)
		if err != nil {
			conn.Fatal("Error parsing assets: %v", err)
		}
		if err := checkAgendaSelection(assets); err != nil {
			return err
		}

		preview := content
		if len(preview) > 100 {
			preview = preview[:100]
		}

		createdAgendaID := uint64(0)
		if len(assets) > 0 {
			// Update existing agenda
			resp, err = s.SendAndRecv(&protocol.Message{
				Opcode: protocol.C_UpdateAsset,
				Data:   protocol.EncodeUpdateAsset(s.RoomID, assets[0].AssetID, preview, content),
			})
			if err != nil {
				conn.Fatal("Error: %v", err)
			}
			if resp.Opcode != protocol.S_AssetUpdated {
				output.PrintError("Unexpected response: %d", resp.Opcode)
			}
		} else {
			// Create new agenda asset
			resp, err = s.SendAndRecv(&protocol.Message{
				Opcode: protocol.C_CreateAsset,
				Data:   protocol.EncodeCreateAsset(s.RoomID, protocol.AssetTypeAgenda, protocol.ParentTypeNone, 0, preview, content),
			})
			if err != nil {
				conn.Fatal("Error: %v", err)
			}
			if resp.Opcode != protocol.S_AssetCreated {
				output.PrintError("Unexpected response: %d", resp.Opcode)
			}
			created, err := protocol.DecodeAssetCreated(resp.Data)
			if err != nil {
				conn.Fatal("Error parsing created agenda: %v", err)
			}
			createdAgendaID = created.Asset.AssetID
		}

		if createdAgendaID != 0 {
			output.PrintCreatedID("Agenda", createdAgendaID)
			return nil
		}

		output.Mutation("updated", "agenda", assets[0].AssetID, "Agenda updated", nil, nil)
		return nil
	},
}

func checkAgendaSelection(assets []protocol.Asset) error {
	if len(assets) <= 1 {
		return nil
	}
	ids := make([]uint64, len(assets))
	for i, asset := range assets {
		ids[i] = asset.AssetID
	}
	return fmt.Errorf("multiple workspace agendas exist (IDs %v); use asset get/update with an explicit ID", ids)
}

func init() {
	agendaCmd.AddCommand(agendaShowCmd, agendaSetCmd)
	rootCmd.AddCommand(agendaCmd)
}
