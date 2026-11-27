package main

import (
	"fmt"
	"os"
	"sort"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

func sliceGroupFlag(value string) uint64 {
	if value == "none" {
		return 0
	}
	id, err := parseSliceID(value)
	if err != nil {
		conn.FatalInvalid("Group must be a positive numeric ID or none")
	}
	return id
}

func init() {
	group := &cobra.Command{Use: "group", Short: "Organize slices into groups"}
	group.AddCommand(&cobra.Command{Use: "list", Short: "List slice groups", Args: cobra.NoArgs, Run: func(cmd *cobra.Command, _ []string) {
		s, err := conn.Dial("")
		if err != nil {
			conn.Fatal("%v", err)
		}
		defer s.Close()
		assets, err := fetchAssetsOfType(s, p.AssetTypeSliceGroup)
		if err != nil {
			conn.Fatal("%v", err)
		}
		type row struct {
			ID   uint64 `json:"group_id"`
			Name string `json:"name"`
		}
		rows := make([]row, 0, len(assets))
		for _, a := range assets {
			rows = append(rows, row{a.AssetID, a.Preview})
		}
		sort.Slice(rows, func(i, j int) bool {
			if rows[i].Name == rows[j].Name {
				return rows[i].ID < rows[j].ID
			}
			return rows[i].Name < rows[j].Name
		})
		if useJSONOutput(cmd) {
			output.OutputJSON(map[string]any{"groups": rows})
			return
		}
		for _, r := range rows {
			fmt.Fprintf(os.Stdout, "%d\t%s\n", r.ID, r.Name)
		}
	}})
	for _, spec := range []struct{ use, short string }{
		{"create <name>", "Create a slice group"},
		{"update <id>", "Rename a slice group"},
		{"dissolve <id>", "Delete a group and keep its slices"},
	} {
		cmd := &cobra.Command{Use: spec.use, Short: spec.short, Args: cobra.ExactArgs(1), Annotations: map[string]string{"mutation": "true"}, Run: mutateSliceGroup}
		if cmd.Name() == "update" {
			cmd.Flags().String("name", "", "New group name")
			_ = cmd.MarkFlagRequired("name")
		}
		group.AddCommand(cmd)
	}
	sliceCmd.AddCommand(group)
}

func mutateSliceGroup(cmd *cobra.Command, args []string) {
	var name string
	var id uint64
	var err error
	if cmd.Name() != "create" {
		id, err = parseSliceID(args[0])
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
	}
	if cmd.Name() != "dissolve" {
		name, _ = cmd.Flags().GetString("name")
		if cmd.Name() == "create" {
			name = args[0]
		}
		name, err = requireSliceName(name)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
	}
	s, err := conn.Dial("")
	if err != nil {
		conn.Fatal("%v", err)
	}
	defer s.Close()
	if id != 0 {
		if _, err := customerAsset(s, id, p.AssetTypeSliceGroup); err != nil {
			conn.FatalNotFound("%v", err)
		}
	}
	var msg p.Message
	var response uint16
	verb := ""
	switch cmd.Name() {
	case "create":
		msg = p.Message{Opcode: p.C_CreateAsset, Data: p.EncodeCreateAsset(0, p.AssetTypeSliceGroup, p.ParentTypeNone, 0, name, "")}
		response, verb = p.S_AssetCreated, "created"
	case "update":
		msg = p.Message{Opcode: p.C_UpdateAsset, Data: p.EncodeUpdateAsset(0, id, name, "")}
		response, verb = p.S_AssetUpdated, "updated"
	case "dissolve":
		msg = p.Message{Opcode: p.C_DeleteAsset, Data: p.EncodeDeleteAsset(0, id)}
		response, verb = p.S_AssetDeleted, "dissolved"
	}
	reply, err := s.SendAndRecv(&msg)
	if err != nil {
		conn.Fatal("%v", err)
	}
	if reply.Opcode != response {
		conn.Fatal("Unexpected response: %d", reply.Opcode)
	}
	if response == p.S_AssetCreated {
		created, err := p.DecodeAssetCreated(reply.Data)
		if err != nil {
			conn.Fatal("%v", err)
		}
		id = created.Asset.AssetID
	}
	output.Mutation(verb, "slice_group", id, fmt.Sprintf("Slice group %d %s", id, verb), nil, nil)
}
