package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"charm.land/fantasy"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const ticketGroupDisclosure = "SENSITIVE ACCESS CHANGE: direct fellow-members may mutually read and reply to all existing and future tickets, including all public attachments. No transitive sharing; internal notes remain staff-only. Removing members or deleting groups revokes this group grant."

type ticketGroupAction struct {
	Operation       string    `json:"operation"`
	CompanyID       string    `json:"company_id"`
	ExpectedVersion string    `json:"expected_updated_at"`
	GroupID         string    `json:"group_id"`
	Name            *string   `json:"name,omitempty"`
	ContactIDs      *[]string `json:"contact_ids,omitempty"`
}

func ticketGroupSummary(a *ticketGroupAction) string {
	if a == nil {
		return "Invalid ticket group action; do not approve"
	}
	summary := fmt.Sprintf("%s ticket group %q on company #%s", a.Operation, a.GroupID, a.CompanyID)
	if a.Name != nil {
		summary += fmt.Sprintf("; name %q", *a.Name)
	}
	if a.ContactIDs != nil {
		summary += "; replacement members [" + strings.Join(*a.ContactIDs, ", ") + "]"
	}
	if a.Operation == "delete" {
		summary += "; revoke this entire group grant"
	}
	return summary + ". " + ticketGroupDisclosure
}

func validateTicketGroupAction(a *ticketGroupAction) error {
	if a == nil {
		return fmt.Errorf("group action required")
	}
	id, err := dataUint(a.CompanyID)
	if err != nil || strconv.FormatUint(id, 10) != a.CompanyID {
		return fmt.Errorf("canonical company_id required")
	}
	at, err := strconv.ParseInt(a.ExpectedVersion, 10, 64)
	if err != nil || at <= 0 {
		return fmt.Errorf("expected_updated_at required")
	}
	switch a.Operation {
	case "create":
		if a.Name == nil || a.ContactIDs == nil {
			return fmt.Errorf("create requires name and contact_ids")
		}
	case "update":
		if a.Name == nil && a.ContactIDs == nil {
			return fmt.Errorf("update requires name or replacement contact_ids")
		}
	case "delete":
		if a.Name != nil || a.ContactIDs != nil {
			return fmt.Errorf("delete accepts only group identity and version")
		}
	default:
		return fmt.Errorf("unsupported group operation")
	}
	g := protocol.TicketGroup{ID: a.GroupID, Name: "validation", ContactIDs: []string{}}
	if a.Name != nil {
		g.Name = *a.Name
	}
	if a.ContactIDs != nil {
		g.ContactIDs = *a.ContactIDs
	}
	return protocol.ValidateTicketGroups([]protocol.TicketGroup{g})
}

// Validate only the changed group's resulting members. Removed/deleted contacts
// must never prevent revocation, nor should an unrelated broken group do so.
func (c *NRCClient) ticketGroupPreview(ctx context.Context, a ticketGroupAction) (protocol.Asset, []byte, error) {
	if err := validateTicketGroupAction(&a); err != nil {
		return protocol.Asset{}, nil, err
	}
	id, _ := dataUint(a.CompanyID)
	company, err := c.GetAsset(ctx, 0, id)
	if err != nil {
		return company, nil, err
	}
	if company.AssetID != id || company.ConvID != 0 || company.AssetType != protocol.AssetTypeCustomerCompany {
		return company, nil, fmt.Errorf("not a workspace customer company")
	}
	if strconv.FormatInt(company.UpdatedAt, 10) != a.ExpectedVersion {
		return company, nil, fmt.Errorf("stale company version; reload and propose again")
	}
	groups, err := protocol.DecodeTicketGroups(company.Preview)
	if err != nil {
		return company, nil, err
	}
	index := -1
	for i, g := range groups {
		if g.ID == a.GroupID {
			index = i
		}
	}
	if (a.Operation == "create") != (index == -1) {
		return company, nil, fmt.Errorf("group already exists or no longer exists")
	}
	if a.Operation == "delete" {
		groups = append(groups[:index], groups[index+1:]...)
	} else {
		g := protocol.TicketGroup{ID: a.GroupID, ContactIDs: []string{}}
		if index >= 0 {
			g = groups[index]
		}
		if a.Name != nil {
			g.Name = *a.Name
		}
		if a.ContactIDs != nil {
			g.ContactIDs = append([]string{}, (*a.ContactIDs)...)
		}
		if len(g.ContactIDs) > 0 {
			var edges []protocol.Edge
			for after := uint64(0); ; {
				page, e := c.ListEntityLinks(ctx, 0, protocol.TargetTypeAsset, id, 100, after)
				if e != nil {
					return company, nil, e
				}
				edges = append(edges, page.Edges...)
				if !page.HasMore {
					break
				}
				if len(page.Edges) == 0 || page.NextEdgeID <= after {
					return company, nil, fmt.Errorf("company edge cursor did not advance")
				}
				after = page.NextEdgeID
			}
			for _, s := range g.ContactIDs {
				cid, _ := dataUint(s)
				contact, e := c.GetAsset(ctx, 0, cid)
				if e != nil {
					return company, nil, e
				}
				if contact.AssetID != cid || contact.ConvID != 0 || contact.AssetType != protocol.AssetTypeCustomerContact {
					return company, nil, fmt.Errorf("member %s is not a contact", s)
				}
				member := false
				for _, edge := range edges {
					if edge.ConvID == 0 && edge.Relation == protocol.RelationMemberOf && edge.SourceType == protocol.TargetTypeAsset && edge.TargetType == protocol.TargetTypeAsset && ((edge.SourceID == cid && edge.TargetID == id) || (edge.SourceID == id && edge.TargetID == cid)) {
						member = true
					}
				}
				if !member {
					return company, nil, fmt.Errorf("contact %s is not a company member", s)
				}
			}
		}
		if index < 0 {
			groups = append(groups, g)
		} else {
			groups[index] = g
		}
	}
	// RawMessage preserves unknown metadata, including integer precision.
	var metadata map[string]json.RawMessage
	if err = json.Unmarshal([]byte(company.Preview), &metadata); err != nil {
		return company, nil, err
	}
	metadata["ticket_groups"], err = json.Marshal(groups)
	if err != nil {
		return company, nil, err
	}
	preview, err := json.Marshal(metadata)
	if len(preview) > protocol.MaxPreviewLength {
		return company, nil, fmt.Errorf("company preview too large")
	}
	return company, preview, err
}

func (c *NRCClient) applyTicketGroup(ctx context.Context, a ticketGroupAction) (uint64, error) {
	company, preview, err := c.ticketGroupPreview(ctx, a)
	if err != nil {
		return 0, err
	}
	body, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{ConvID: 0, Asset: protocol.Existing(protocol.TransactionEntityAsset, company.AssetID), IfUpdatedAt: company.UpdatedAt, Present: protocol.TransactionAssetPatchPreview, Preview: preview})
	if err != nil {
		return 0, err
	}
	v, err := c.correlatedDataRead(ctx, 0, protocol.C_ApplyTransaction, func(id uint32) ([]byte, error) {
		return protocol.EncodeApplyTransaction(id, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetPatch, Body: body}})
	}, true)
	if err != nil {
		return 0, err
	}
	if v.(*protocol.TransactionResult).Status != protocol.TransactionStatusCommitted {
		return 0, fmt.Errorf("group transaction rejected; reload and propose again")
	}
	return company.AssetID, nil
}

func newTicketGroupTools(wm *WorkspaceManager, store *AgentSessionStore) []fantasy.AgentTool {
	read := fantasy.NewAgentTool("read_ticket_groups", "List a company's explicit non-transitive ticket-sharing groups and expected_updated_at. "+ticketGroupDisclosure, func(ctx context.Context, in struct {
		CompanyID string `json:"company_id"`
	}, call fantasy.ToolCall) (fantasy.ToolResponse, error) {
		tc := newFantasyADKToolContext(ctx, call.ID)
		ws, conv, err := adkSessionScope(tc)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		c, err := dataReadClient(wm, ws, conv)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		id, err := dataUint(in.CompanyID)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		a, err := c.GetAsset(ctx, 0, id)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		if a.AssetID != id || a.ConvID != 0 || a.AssetType != protocol.AssetTypeCustomerCompany {
			return fantasy.ToolResponse{}, fmt.Errorf("not a workspace customer company")
		}
		groups, err := protocol.DecodeTicketGroups(a.Preview)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		b, err := json.Marshal(map[string]any{"company_id": in.CompanyID, "expected_updated_at": strconv.FormatInt(a.UpdatedAt, 10), "ticket_groups": groups, "disclosure": ticketGroupDisclosure})
		return fantasy.NewTextResponse(string(b)), err
	})
	propose := fantasy.NewAgentTool("propose_ticket_group", "Stage create/update/delete of one company ticket-sharing group for explicit approval ONLY, no writes. Read first; company_id, stable group_id and expected_updated_at required. Only one unapplied group change per company per plan; apply and re-read before proposing another. create requires name and contact_ids; update optionally renames and/or REPLACES all members (empty array revokes all); delete removes group. "+ticketGroupDisclosure, func(ctx context.Context, in ticketGroupAction, call fantasy.ToolCall) (fantasy.ToolResponse, error) {
		tc := newFantasyADKToolContext(ctx, call.ID)
		ws, conv, err := adkSessionScope(tc)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		if normalizeAgentMode(toolContextString(tc, agentModeContextKey{}, "mode")) != agentModePlan {
			return fantasy.ToolResponse{}, fmt.Errorf("propose_ticket_group requires plan mode")
		}
		c, err := dataReadClient(wm, ws, conv)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		if _, _, err = c.ticketGroupPreview(ctx, in); err != nil {
			return fantasy.ToolResponse{}, err
		}
		a, err := store.addTicketAction(toolContextString(tc, agentSessionContextKey{}, "agent_session_id"), toolContextString(tc, actionPlanContextKey{}, "action_plan_id"), ticketAction{Operation: "group", Group: &in})
		b, _ := json.Marshal(a)
		return fantasy.NewTextResponse(string(b)), err
	})
	return []fantasy.AgentTool{read, propose}
}
