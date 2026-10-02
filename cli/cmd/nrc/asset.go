package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

func parseAssetTypeName(s string) (uint16, error) {
	switch s {
	case "comment":
		return protocol.AssetTypeComment, nil
	case "document":
		return protocol.AssetTypeDocument, nil
	case "file":
		return protocol.AssetTypeFile, nil
	case "agenda":
		return protocol.AssetTypeAgenda, nil
	case "note":
		return protocol.AssetTypeNote, nil
	case "reminder":
		return protocol.AssetTypeReminder, nil
	case "room_mapping":
		return protocol.AssetTypeRoomMapping, nil
	case "company":
		return protocol.AssetTypeCustomerCompany, nil
	case "contact":
		return protocol.AssetTypeCustomerContact, nil
	case "activity":
		return protocol.AssetTypeCustomerActivity, nil
	case "slice":
		return protocol.AssetTypeSlice, nil
	case "appointment":
		return protocol.AssetTypeAppointment, nil
	default:
		return 0, fmt.Errorf("unknown asset type: %s", s)
	}
}

func assetTypeName(t uint16) string {
	switch t {
	case protocol.AssetTypeComment:
		return "comment"
	case protocol.AssetTypeDocument:
		return "document"
	case protocol.AssetTypeFile:
		return "file"
	case protocol.AssetTypeAgenda:
		return "agenda"
	case protocol.AssetTypeNote:
		return "note"
	case protocol.AssetTypeReminder:
		return "reminder"
	case protocol.AssetTypeRoomMapping:
		return "room_mapping"
	case protocol.AssetTypeCustomerCompany:
		return "company"
	case protocol.AssetTypeCustomerContact:
		return "contact"
	case protocol.AssetTypeCustomerActivity:
		return "activity"
	case protocol.AssetTypeSlice:
		return "slice"
	case protocol.AssetTypeAppointment:
		return "appointment"
	default:
		return fmt.Sprintf("unknown(%d)", t)
	}
}

func parseParentTypeName(s string) (uint16, error) {
	switch s {
	case "none":
		return protocol.ParentTypeNone, nil
	case "task":
		return protocol.ParentTypeTask, nil
	case "asset":
		return protocol.ParentTypeAsset, nil
	default:
		return 0, fmt.Errorf("unknown parent type: %s (valid: none, task, asset)", s)
	}
}

func parentTypeName(t uint16) string {
	switch t {
	case protocol.ParentTypeNone:
		return "none"
	case protocol.ParentTypeTask:
		return "task"
	case protocol.ParentTypeAsset:
		return "asset"
	default:
		return fmt.Sprintf("unknown(%d)", t)
	}
}

type assetJSON struct {
	ID         uint64 `json:"id"`
	Type       string `json:"type"`
	ParentType string `json:"parent_type"`
	ParentID   uint64 `json:"parent_id"`
	Owner      string `json:"owner"`
	Preview    string `json:"preview"`
	Payload    string `json:"payload,omitempty"`
	CreatedAt  int64  `json:"created_at"`
	UpdatedAt  int64  `json:"updated_at"`
}

func assetToJSON(a protocol.Asset, full bool) assetJSON {
	aj := assetJSON{
		ID:         a.AssetID,
		Type:       assetTypeName(a.AssetType),
		ParentType: parentTypeName(a.ParentType),
		ParentID:   a.ParentID,
		Owner:      a.Owner,
		Preview:    a.Preview,
		CreatedAt:  a.CreatedAt,
		UpdatedAt:  a.UpdatedAt,
	}
	if full {
		aj.Payload = a.Payload
	}
	return aj
}

var assetCmd = &cobra.Command{
	Use:   "asset",
	Short: "Manage assets",
}

var assetListCmd = &cobra.Command{
	Use:   "list",
	Short: "List assets",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		typeFlag, _ := cmd.Flags().GetString("type")
		fullFlag, _ := cmd.Flags().GetBool("full")
		jsonFlag := useJSONOutput(cmd)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		filterByType := typeFlag != ""
		var assetType uint16
		if filterByType {
			assetType, err = parseAssetTypeName(typeFlag)
			if err != nil {
				conn.Fatal("Error: %v", err)
			}
		}

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_ListAssets,
			Data:   protocol.EncodeListAssets(s.RoomID, filterByType, assetType, fullFlag),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetList {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		assets, err := protocol.DecodeAssetList(resp.Data, fullFlag)
		if err != nil {
			conn.Fatal("Error parsing assets: %v", err)
		}

		if jsonFlag {
			items := make([]assetJSON, len(assets))
			for i, a := range assets {
				items[i] = assetToJSON(a, fullFlag)
			}
			output.OutputJSON(items)
		} else {
			outputAssetsTable(assets)
		}
	},
}

var assetCreateCmd = &cobra.Command{
	Use:   "create <preview> [payload]",
	Short: "Create new asset",
	Args:  cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		typeFlag, _ := cmd.Flags().GetString("type")
		parentTypeFlag, _ := cmd.Flags().GetString("parent-type")
		parentIDFlag, _ := cmd.Flags().GetString("parent-id")

		preview := args[0]
		payload := ""
		if len(args) > 1 {
			payload = args[1]
		}

		assetType, err := parseAssetTypeName(typeFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		parentType, err := parseParentTypeName(parentTypeFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		var parentID uint64
		if parentIDFlag != "" {
			parentID, err = strconv.ParseUint(parentIDFlag, 10, 64)
			if err != nil {
				conn.Fatal("Invalid parent ID: %v", err)
			}
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_CreateAsset,
			Data:   protocol.EncodeCreateAsset(s.RoomID, assetType, parentType, parentID, preview, payload),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetCreated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		created, err := protocol.DecodeAssetCreated(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing created asset: %v", err)
		}

		output.PrintCreatedID("Asset", created.Asset.AssetID)
	},
}

var assetGetCmd = &cobra.Command{
	Use:   "get <id>",
	Short: "Get asset details",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		assetID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid asset ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		jsonFlag := useJSONOutput(cmd)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_GetAsset,
			Data:   protocol.EncodeGetAsset(s.RoomID, assetID),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetFull {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		a, err := protocol.DecodeAssetFull(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing asset: %v", err)
		}

		if jsonFlag {
			output.OutputJSON(assetToJSON(a, true))
		} else {
			fmt.Printf("ID:      %d\n", a.AssetID)
			fmt.Printf("Type:    %s\n", assetTypeName(a.AssetType))
			fmt.Printf("Owner:   %s\n", a.Owner)
			fmt.Printf("Preview: %s\n", a.Preview)
			if a.Payload != "" {
				fmt.Printf("\n%s\n", a.Payload)
			}
		}
	},
}

var assetUpdateCmd = &cobra.Command{
	Use:   "update <id> <preview> [payload]",
	Short: "Update asset",
	Args:  cobra.RangeArgs(2, 3),
	Run: func(cmd *cobra.Command, args []string) {
		assetID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid asset ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")

		preview := args[1]
		payload := ""
		if len(args) > 2 {
			payload = args[2]
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_UpdateAsset,
			Data:   protocol.EncodeUpdateAsset(s.RoomID, assetID, preview, payload),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetUpdated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("updated", "asset", assetID, "Asset updated", nil, nil)
	},
}

var assetDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete asset",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		assetID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid asset ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_DeleteAsset,
			Data:   protocol.EncodeDeleteAsset(s.RoomID, assetID),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetDeleted {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("deleted", "asset", assetID, "Asset deleted", nil, nil)
	},
}

func outputAssetsTable(assets []protocol.Asset) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "TYPE", "OWNER", "PREVIEW"}))
	for _, a := range assets {
		preview := a.Preview
		if len(preview) > 40 {
			preview = preview[:37] + "..."
		}
		table.Append(
			fmt.Sprintf("%d", a.AssetID),
			assetTypeName(a.AssetType),
			a.Owner,
			preview,
		)
	}
	table.Render()
}

func init() {
	assetListCmd.Flags().String("type", "", "Filter by type (comment|document|file|agenda|note|reminder|room_mapping|company|contact|activity)")
	assetListCmd.Flags().Bool("full", false, "Include full payload")

	assetCreateCmd.Flags().String("type", "document", "Asset type (comment|document|file|agenda|note|reminder|room_mapping|company|contact|activity)")
	assetCreateCmd.Flags().String("parent-type", "none", "Parent type (none|task|asset)")
	assetCreateCmd.Flags().String("parent-id", "", "Parent ID")

	assetCmd.AddCommand(assetListCmd, assetCreateCmd, assetGetCmd, assetUpdateCmd, assetDeleteCmd)
	rootCmd.AddCommand(assetCmd)
}

// suppress unused import
var _ = json.Marshal
