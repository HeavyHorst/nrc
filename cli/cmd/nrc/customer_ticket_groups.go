package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

func customerTicketGroups() *cobra.Command {
	group := &cobra.Command{Use: "ticket-group", Short: "Manage company-scoped, direct (non-transitive) ticket sharing"}
	for _, action := range []string{"list", "create", "update", "delete"} {
		use, count := action+" <company-id>", 1
		if action == "update" || action == "delete" {
			use, count = use+" <group-id>", 2
		}
		c := &cobra.Command{Use: use, Short: action + " ticket sharing groups", Args: cobra.ExactArgs(count)}
		if action != "list" {
			c.Annotations = map[string]string{"mutation": "true"}
		}
		if action == "create" || action == "update" {
			c.Flags().String("name", "", "Group display name (trimmed)")
			c.Flags().StringSlice("contacts", nil, "Replace member contact IDs (comma-separated; empty clears all)")
		}
		if action == "create" {
			c.Flags().String("id", "", "Stable group ID (default: randomly generated)")
			_ = c.MarkFlagRequired("name")
		}
		c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
			invalid := func(err error) error { return &conn.InvalidArgumentError{Err: err} }
			company, err := customerID(args[0])
			if err != nil {
				return err
			}
			a, err := customerAsset(s, company, protocol.AssetTypeCustomerCompany)
			if err != nil {
				return err
			}
			if a.ConvID != 0 {
				return fmt.Errorf("company %d is not a workspace asset", company)
			}
			m, err := customerMetadata(a.Preview)
			if err != nil {
				return err
			}
			groups, err := protocol.DecodeTicketGroups(a.Preview)
			if err != nil {
				return err
			}
			if action == "list" {
				if output.Human() {
					for _, g := range groups {
						fmt.Printf("%s\t%s\t%s\n", g.ID, g.Name, strings.Join(g.ContactIDs, ","))
					}
				} else {
					output.OutputJSON(map[string]any{"company_id": company, "ticket_groups": groups})
				}
				return nil
			}
			index := -1
			if action != "create" {
				for i := range groups {
					if groups[i].ID == args[1] {
						index = i
						break
					}
				}
				if index < 0 {
					return invalid(fmt.Errorf("ticket group %q not found", args[1]))
				}
			}
			var changed protocol.TicketGroup
			if action == "delete" {
				changed = groups[index]
				groups = append(groups[:index], groups[index+1:]...)
			} else {
				if action == "create" {
					changed.ID, _ = cmd.Flags().GetString("id")
					if !cmd.Flags().Changed("id") {
						var random [16]byte
						if _, err := rand.Read(random[:]); err != nil {
							return err
						}
						changed.ID = hex.EncodeToString(random[:])
					}
					changed.ContactIDs = []string{}
				} else {
					changed = groups[index]
					if !cmd.Flags().Changed("name") && !cmd.Flags().Changed("contacts") {
						return invalid(fmt.Errorf("no changes specified"))
					}
				}
				if cmd.Flags().Changed("name") {
					name, _ := cmd.Flags().GetString("name")
					changed.Name = strings.TrimSpace(name)
				}
				if cmd.Flags().Changed("contacts") {
					changed.ContactIDs, _ = cmd.Flags().GetStringSlice("contacts")
					if changed.ContactIDs == nil {
						changed.ContactIDs = []string{}
					}
				}
				if action == "create" {
					groups = append(groups, changed)
				} else {
					groups[index] = changed
				}
				if err := protocol.ValidateTicketGroups(groups); err != nil {
					return invalid(err)
				}
				// Resolve desired members only: stale or deleted old members can be removed.
				if len(changed.ContactIDs) > 0 {
					members := map[uint64]bool{}
					for after := uint64(0); ; {
						page, err := customerEdgePage(s, company, 250, after)
						if err != nil {
							return err
						}
						for _, e := range page.Edges {
							if e.Relation != protocol.RelationMemberOf || e.SourceType != protocol.TargetTypeAsset || e.TargetType != protocol.TargetTypeAsset {
								continue
							}
							if e.SourceID == company {
								members[e.TargetID] = true
							}
							if e.TargetID == company {
								members[e.SourceID] = true
							}
						}
						if !page.HasMore {
							break
						}
						after = page.NextEdgeID
					}
					for _, raw := range changed.ContactIDs {
						id, _ := strconv.ParseUint(raw, 10, 64)
						if !members[id] {
							return invalid(fmt.Errorf("contact %d must be linked to company %d by MemberOf", id, company))
						}
						contact, err := customerAsset(s, id, protocol.AssetTypeCustomerContact)
						if err != nil {
							return err
						}
						if contact.ConvID != 0 {
							return invalid(fmt.Errorf("contact %d is not a workspace asset", id))
						}
					}
				}
			}
			m["ticket_groups"], _ = json.Marshal(groups)
			preview, err := json.Marshal(m)
			if err != nil {
				return err
			}
			if len(preview) > protocol.MaxPreviewLength {
				return invalid(fmt.Errorf("metadata exceeds %d protocol bytes", protocol.MaxPreviewLength))
			}
			body, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{ConvID: uint64(s.RoomID), Asset: protocol.Existing(protocol.TransactionEntityAsset, company), IfUpdatedAt: a.UpdatedAt, Present: protocol.TransactionAssetPatchPreview, Preview: preview})
			if err != nil {
				return err
			}
			result, err := customerTransaction(s, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetPatch, Body: body}})
			if err != nil {
				return err
			}
			operation := map[string]string{"create": "created", "update": "updated", "delete": "deleted"}[action]
			output.Mutation(operation, "ticket-group", company, "Ticket group "+changed.ID+" "+operation, nil, map[string]any{"group_id": changed.ID, "transaction": result})
			return nil
		})
		group.AddCommand(c)
	}
	return group
}
