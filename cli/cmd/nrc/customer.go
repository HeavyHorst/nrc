package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

// Customer previews use the same versioned metadata as the browser. Raw values
// preserve extension fields (including large JSON numbers) during partial edits.
type customerRecord struct {
	ID        uint64                     `json:"id"`
	Type      string                     `json:"type"`
	Metadata  map[string]json.RawMessage `json:"metadata"`
	Body      string                     `json:"body,omitempty"`
	Owner     string                     `json:"owner"`
	CreatedAt int64                      `json:"created_at"`
	UpdatedAt int64                      `json:"updated_at"`
}

func customerMetadata(preview string) (map[string]json.RawMessage, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(preview), &m); err != nil {
		return nil, fmt.Errorf("invalid customer metadata: %w", err)
	}
	var version int
	var title *string
	if json.Unmarshal(m["version"], &version) != nil || version != 1 || json.Unmarshal(m["title"], &title) != nil || title == nil {
		return nil, fmt.Errorf("unsupported customer metadata (requires version 1 and title)")
	}
	return m, nil
}

func customerResource(a protocol.Asset, full bool) (customerRecord, error) {
	m, err := customerMetadata(a.Preview)
	r := customerRecord{ID: a.AssetID, Type: assetTypeName(a.AssetType), Metadata: m, Owner: a.Owner, CreatedAt: a.CreatedAt, UpdatedAt: a.UpdatedAt}
	if full && err == nil {
		r.Body, err = protocol.DecodeAssetPayload(a)
	}
	return r, err
}

func customerID(raw string) (uint64, error) {
	id, err := strconv.ParseUint(raw, 10, 64)
	if err != nil || id == 0 {
		return 0, &conn.InvalidArgumentError{Err: fmt.Errorf("invalid nonzero ID %q", raw)}
	}
	return id, nil
}

func customerAsset(s *conn.Session, id uint64, kind uint16) (protocol.Asset, error) {
	a, err := fetchAsset(s, id)
	if err == nil && a.AssetType != kind {
		err = fmt.Errorf("asset %d is %s, not %s", id, assetTypeName(a.AssetType), assetTypeName(kind))
	}
	return a, err
}

func customerRun(run func(*cobra.Command, []string, *conn.Session) error) func(*cobra.Command, []string) {
	return func(cmd *cobra.Command, args []string) {
		room, _ := cmd.Flags().GetString("room")
		s, err := conn.Dial(room)
		if err != nil {
			conn.Fail(err)
		}
		defer s.Close()
		if err := run(cmd, args, s); err != nil {
			conn.Fail(err)
		}
	}
}

func customerTransaction(s *conn.Session, ops []protocol.TransactionOperation) (*protocol.TransactionResult, error) {
	payload, err := protocol.EncodeApplyTransaction(1, ops)
	if err != nil {
		return nil, err
	}
	resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_ApplyTransaction, Data: payload})
	if err != nil {
		var serverError *conn.ServerError
		if errors.As(err, &serverError) {
			return nil, err
		}
		// A lost acknowledgement is not a safe reason to retry a create.
		return nil, fmt.Errorf("transaction outcome unconfirmed; inspect records before retrying: %v", err)
	}
	if resp.Opcode != protocol.S_TransactionResult {
		return nil, fmt.Errorf("unexpected transaction response: %d", resp.Opcode)
	}
	result, err := protocol.DecodeTransactionResult(resp.Data)
	if err != nil {
		return nil, err
	}
	if result.CorrelationID != 1 {
		return nil, fmt.Errorf("transaction correlation mismatch")
	}
	if result.Status != protocol.TransactionStatusCommitted {
		return nil, &conn.ServerError{Message: fmt.Sprintf("transaction rejected at operation %d; no changes committed (record may have changed)", result.FailedOperation)}
	}
	if len(result.Results) != len(ops) {
		return nil, fmt.Errorf("transaction result count mismatch")
	}
	return result, nil
}

var customerFields = map[uint16][]string{
	protocol.AssetTypeCustomerCompany:  {"title", "number", "sector", "account_type", "city", "address", "website", "assignee", "phone"},
	protocol.AssetTypeCustomerContact:  {"title", "role", "email", "phone"},
	protocol.AssetTypeCustomerActivity: {"title", "kind"},
}

func customerPreview(m map[string]json.RawMessage, changes map[string]string, kind uint16, body *string) ([]byte, error) {
	for key, value := range changes {
		m[key], _ = json.Marshal(strings.TrimSpace(value))
	}
	m["version"] = json.RawMessage("1")
	delete(m, "companyId") // Membership is represented exclusively by edges.
	var title string
	_ = json.Unmarshal(m["title"], &title)
	if strings.TrimSpace(title) == "" {
		return nil, fmt.Errorf("title must not be blank")
	}
	if kind == protocol.AssetTypeCustomerActivity {
		var activityKind string
		_ = json.Unmarshal(m["kind"], &activityKind)
		switch activityKind {
		case "Call", "Meeting", "Email", "Decision":
		default:
			return nil, fmt.Errorf("kind must be Call, Meeting, Email or Decision")
		}
		if body != nil {
			if strings.TrimSpace(*body) == "" {
				return nil, fmt.Errorf("activity body must not be blank")
			}
			runes := []rune(*body)
			if len(runes) > 160 {
				runes = runes[:160]
			}
			m["excerpt"], _ = json.Marshal(string(runes))
		}
	}
	preview, err := json.Marshal(m)
	if err == nil && len(preview) > protocol.MaxPreviewLength {
		err = fmt.Errorf("metadata exceeds %d protocol bytes", protocol.MaxPreviewLength)
	}
	return preview, err
}

func customerWrite(kind uint16, action string) *cobra.Command {
	use := action + " <id>"
	args := cobra.ExactArgs(1)
	if action == "create" {
		use, args = "create", cobra.NoArgs
	}
	c := &cobra.Command{Use: use, Short: action + " " + assetTypeName(kind), Args: args, Annotations: map[string]string{"mutation": "true"}}
	if action == "create" || action == "update" {
		for _, field := range customerFields[kind] {
			flag := strings.ReplaceAll(field, "_", "-")
			c.Flags().String(flag, "", "Set "+flag+" (empty clears optional fields)")
		}
		if kind == protocol.AssetTypeCustomerActivity {
			c.Flags().String("body", "", "Activity record text")
			c.Flags().String("body-file", "", "Read UTF-8 activity record from file")
			c.MarkFlagsMutuallyExclusive("body", "body-file")
		}
		if action == "create" {
			_ = c.MarkFlagRequired("title")
			if kind != protocol.AssetTypeCustomerCompany {
				c.Flags().Uint64("company", 0, "Company ID to link atomically")
				_ = c.MarkFlagRequired("company")
			}
		}
	}
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		var id uint64
		var existing protocol.Asset
		m := map[string]json.RawMessage{}
		if action != "create" {
			var err error
			id, err = customerID(args[0])
			if err != nil {
				return err
			}
			existing, err = customerAsset(s, id, kind)
			if err != nil {
				return err
			}
			if action != "delete" {
				m, err = customerMetadata(existing.Preview)
				if err != nil {
					return err
				}
			}
		}
		var ops []protocol.TransactionOperation
		if action == "delete" {
			body, err := protocol.EncodeTransactionDelete(protocol.TransactionDelete{ConvID: uint64(s.RoomID), Entity: protocol.Existing(protocol.TransactionEntityAsset, id), IfUpdatedAt: existing.UpdatedAt}, protocol.TransactionEntityAsset)
			if err != nil {
				return err
			}
			ops = append(ops, protocol.TransactionOperation{Type: protocol.TransactionOpAssetDelete, Body: body})
		} else {
			changes := map[string]string{}
			for _, field := range customerFields[kind] {
				flag := strings.ReplaceAll(field, "_", "-")
				if cmd.Flags().Changed(flag) {
					changes[field], _ = cmd.Flags().GetString(flag)
				}
			}
			var recordBody *string
			if action == "create" && kind == protocol.AssetTypeCustomerActivity {
				m["kind"] = json.RawMessage(`"Call"`)
				empty := ""
				recordBody = &empty
			}
			if cmd.Flags().Changed("body") {
				value, _ := cmd.Flags().GetString("body")
				recordBody = &value
			}
			if cmd.Flags().Changed("body-file") {
				file, _ := cmd.Flags().GetString("body-file")
				data, err := os.ReadFile(file)
				if err != nil {
					return err
				}
				value := string(data)
				recordBody = &value
			}
			if recordBody != nil && (!utf8.ValidString(*recordBody) || len(*recordBody) > protocol.MaxPayloadLength) {
				return &conn.InvalidArgumentError{Err: fmt.Errorf("body must be UTF-8 and at most %d bytes", protocol.MaxPayloadLength)}
			}
			if action == "archive" || action == "restore" {
				m["archived"], _ = json.Marshal(action == "archive")
			}
			if action == "update" && len(changes) == 0 && recordBody == nil {
				return &conn.InvalidArgumentError{Err: fmt.Errorf("no changes specified")}
			}
			preview, err := customerPreview(m, changes, kind, recordBody)
			if err != nil {
				return &conn.InvalidArgumentError{Err: err}
			}
			if action == "create" {
				payload := ""
				if recordBody != nil {
					payload = *recordBody
				}
				body, err := protocol.EncodeTransactionAssetCreate(protocol.TransactionAssetCreate{ConvID: uint64(s.RoomID), AssetType: kind, Preview: preview, Payload: []byte(payload), PayloadRawLen: uint32(len(payload))})
				if err != nil {
					return err
				}
				ops = append(ops, protocol.TransactionOperation{Type: protocol.TransactionOpAssetCreate, Body: body})
				if kind != protocol.AssetTypeCustomerCompany {
					company, _ := cmd.Flags().GetUint64("company")
					if company == 0 {
						return &conn.InvalidArgumentError{Err: fmt.Errorf("company must be nonzero")}
					}
					if _, err := customerAsset(s, company, protocol.AssetTypeCustomerCompany); err != nil {
						return err
					}
					body, err := protocol.EncodeTransactionEdgeCreate(protocol.TransactionEdgeCreate{ConvID: uint64(s.RoomID), Source: protocol.CreatedBy(protocol.TransactionEntityAsset, 0), Target: protocol.Existing(protocol.TransactionEntityAsset, company), Relation: protocol.RelationMemberOf})
					if err != nil {
						return err
					}
					ops = append(ops, protocol.TransactionOperation{Type: protocol.TransactionOpEdgeCreate, Body: body})
				}
			} else {
				patch := protocol.TransactionAssetPatch{ConvID: uint64(s.RoomID), Asset: protocol.Existing(protocol.TransactionEntityAsset, id), IfUpdatedAt: existing.UpdatedAt, Present: protocol.TransactionAssetPatchPreview, Preview: preview}
				if recordBody != nil {
					patch.Present |= protocol.TransactionAssetPatchPayload
					patch.Payload = []byte(*recordBody)
					patch.PayloadRawLen = uint32(len(patch.Payload))
				}
				body, err := protocol.EncodeTransactionAssetPatch(patch)
				if err != nil {
					return err
				}
				ops = append(ops, protocol.TransactionOperation{Type: protocol.TransactionOpAssetPatch, Body: body})
			}
		}
		result, err := customerTransaction(s, ops)
		if err != nil {
			return err
		}
		id = result.Results[0].EntityID
		operation := map[string]string{"create": "created", "update": "updated", "delete": "deleted", "archive": "archived", "restore": "restored"}[action]
		output.Mutation(operation, assetTypeName(kind), id, fmt.Sprintf("%s %s: %d", assetTypeName(kind), operation, id), nil, map[string]any{"transaction": result})
		return nil
	})
	return c
}

func customerList(kind uint16) *cobra.Command {
	c := &cobra.Command{Use: "list", Short: "List one page; --all follows live cursors (not a snapshot)", Args: cobra.NoArgs}
	c.Flags().Int("page-size", 50, "Page size, 1–250 (server may return fewer due to byte limit)")
	c.Flags().Bool("all", false, "Follow all pages")
	c.Flags().String("cursor", "", "Resume from next_cursor with identical filters")
	if kind == protocol.AssetTypeCustomerCompany {
		c.Flags().String("search", "", "Search company or linked contact fields")
		c.Flags().Bool("archived", false, "Include archived companies")
	}
	c.Run = customerRun(func(cmd *cobra.Command, _ []string, s *conn.Session) error {
		size, _ := cmd.Flags().GetInt("page-size")
		if size < 1 || size > 250 {
			return &conn.InvalidArgumentError{Err: fmt.Errorf("page-size must be 1–250")}
		}
		all, _ := cmd.Flags().GetBool("all")
		cursor, _ := cmd.Flags().GetString("cursor")
		query, _ := cmd.Flags().GetString("search")
		archived, _ := cmd.Flags().GetBool("archived")
		entries := []customerRecord{}
		var total uint32
		var more bool
		for {
			var assets []protocol.Asset
			var next string
			if kind == protocol.AssetTypeCustomerCompany {
				var after uint64
				if cursor != "" {
					var err error
					after, err = customerID(cursor)
					if err != nil {
						return err
					}
				}
				data, err := protocol.EncodeSearchCustomers(s.RoomID, uint16(size), after, archived, query, 1)
				if err != nil {
					return &conn.InvalidArgumentError{Err: err}
				}
				resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_SearchCustomers, Data: data})
				if err != nil {
					return err
				}
				if resp.Opcode != protocol.S_CustomerSearchPage {
					return fmt.Errorf("unexpected customer page response: %d", resp.Opcode)
				}
				page, err := protocol.DecodeCustomerSearchPage(resp.Data)
				if err != nil {
					return err
				}
				assets, total, more, next = page.Assets, page.TotalCount, page.HasMore, strconv.FormatUint(page.NextCompanyID, 10)
			} else {
				var position noteCursor
				if cursor != "" {
					var err error
					position, err = decodeNoteCursor(cursor)
					if err != nil {
						return &conn.InvalidArgumentError{Err: err}
					}
				}
				resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_ListAssetsPaged, Data: protocol.EncodeListAssetsPaged(s.RoomID, kind, false, uint16(size), cursor != "", position.UpdatedAt, position.AssetID)})
				if err != nil {
					return err
				}
				if resp.Opcode != protocol.S_AssetListPage {
					return fmt.Errorf("unexpected asset page response: %d", resp.Opcode)
				}
				page, err := protocol.DecodeAssetListPage(resp.Data)
				if err != nil {
					return err
				}
				assets, total, more, next = page.Assets, page.TotalCount, page.HasMore, encodeNoteCursor(page.NextCursorUpdatedAt, page.NextCursorAssetID)
			}
			for _, asset := range assets {
				entry, err := customerResource(asset, false)
				if err != nil {
					return err
				}
				entries = append(entries, entry)
			}
			if more && (len(assets) == 0 || next == cursor) {
				return fmt.Errorf("customer page cursor did not advance")
			}
			cursor = next
			if !more {
				cursor = ""
			}
			if !all || !more {
				break
			}
		}
		result := struct {
			Entries    []customerRecord `json:"entries"`
			TotalCount uint32           `json:"total_count"`
			HasMore    bool             `json:"has_more"`
			NextCursor string           `json:"next_cursor"`
		}{entries, total, more, cursor}
		if output.Human() {
			for _, r := range entries {
				fmt.Printf("%d\t%s\t%s\n", r.ID, r.Type, r.Metadata["title"])
			}
			fmt.Printf("Loaded %d / %d; next cursor: %s\n", len(entries), total, cursor)
		} else {
			output.OutputJSON(result)
		}
		return nil
	})
	return c
}

func customerEdgePage(s *conn.Session, company uint64, size int, after uint64) (*protocol.EdgeListPageResponse, error) {
	resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_ListEdgesPaged, Data: protocol.EncodeListEdgesPaged(s.RoomID, protocol.TargetTypeAsset, company, uint16(size), after, 1)})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != protocol.S_EdgeListPage {
		return nil, fmt.Errorf("unexpected incident edge response: %d", resp.Opcode)
	}
	page, err := protocol.DecodeEdgeListPage(resp.Data)
	if err != nil {
		return nil, err
	}
	if page.HasMore && (len(page.Edges) == 0 || page.NextEdgeID <= after) {
		return nil, fmt.Errorf("edge cursor did not advance")
	}
	return page, nil
}

func customerLinks() *cobra.Command {
	c := &cobra.Command{Use: "links <company-id>", Short: "List incoming and outgoing company edges only; use asset/task get for endpoint details", Args: cobra.ExactArgs(1)}
	c.Flags().Int("page-size", 50, "Incident edges per page, 1–250")
	c.Flags().Uint64("after", 0, "Resume after next_edge_id with the same company")
	c.Flags().Bool("all", false, "Follow all incident edge pages (not a snapshot)")
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		company, err := customerID(args[0])
		if err != nil {
			return err
		}
		size, _ := cmd.Flags().GetInt("page-size")
		if size < 1 || size > 250 {
			return &conn.InvalidArgumentError{Err: fmt.Errorf("page-size must be 1–250")}
		}
		if _, err := customerAsset(s, company, protocol.AssetTypeCustomerCompany); err != nil {
			return err
		}
		after, _ := cmd.Flags().GetUint64("after")
		all, _ := cmd.Flags().GetBool("all")
		result := struct {
			Edges      []edgeEntry `json:"edges"`
			TotalCount uint32      `json:"total_count"`
			HasMore    bool        `json:"has_more"`
			NextEdgeID uint64      `json:"next_edge_id"`
		}{Edges: []edgeEntry{}}
		for {
			page, err := customerEdgePage(s, company, size, after)
			if err != nil {
				return err
			}
			for _, edge := range page.Edges {
				result.Edges = append(result.Edges, edgeResource(edge))
			}
			result.TotalCount, result.HasMore, result.NextEdgeID = page.TotalCount, page.HasMore, page.NextEdgeID
			if !page.HasMore {
				result.NextEdgeID = 0
			}
			if !all || !page.HasMore {
				break
			}
			after = page.NextEdgeID
		}
		if output.Human() {
			for _, edge := range result.Edges {
				fmt.Printf("%d\t%s:%d -> %s:%d\t%s\n", edge.ID, edge.SourceType, edge.SourceID, edge.TargetType, edge.TargetID, edge.Relation)
			}
			fmt.Printf("Loaded %d / %d edges; next edge ID: %d\n", len(result.Edges), result.TotalCount, result.NextEdgeID)
		} else {
			output.OutputJSON(result)
		}
		return nil
	})
	return c
}

func customerLink() *cobra.Command {
	c := &cobra.Command{Use: "link <company-id> <asset|task> <id>", Short: "Link an existing contact, activity, note, task or other asset", Args: cobra.ExactArgs(3), Annotations: map[string]string{"mutation": "true"}}
	c.Flags().String("relation", "related-to", "Relation; defaults to member-of for contacts and activities, related-to otherwise")
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		company, err := customerID(args[0])
		if err != nil {
			return err
		}
		id, err := customerID(args[2])
		if err != nil {
			return err
		}
		entity := uint8(protocol.TransactionEntityAsset)
		switch args[1] {
		case "asset":
		case "task":
			entity = protocol.TransactionEntityTask
		default:
			return &conn.InvalidArgumentError{Err: fmt.Errorf("endpoint must be asset or task")}
		}
		if _, err := customerAsset(s, company, protocol.AssetTypeCustomerCompany); err != nil {
			return err
		}
		name, _ := cmd.Flags().GetString("relation")
		if !cmd.Flags().Changed("relation") && args[1] == "asset" {
			linked, err := fetchAsset(s, id)
			if err != nil {
				return err
			}
			if linked.AssetType == protocol.AssetTypeCustomerContact || linked.AssetType == protocol.AssetTypeCustomerActivity {
				name = "member-of"
			}
		}
		relation, ok := relationCodes[name]
		if !ok {
			return &conn.InvalidArgumentError{Err: fmt.Errorf("unknown relation %q", name)}
		}
		source, target := protocol.Existing(protocol.TransactionEntityAsset, company), protocol.Existing(entity, id)
		if relation == protocol.RelationMemberOf {
			// Membership direction is member -> container, matching slices.
			source, target = target, source
		}
		body, err := protocol.EncodeTransactionEdgeCreate(protocol.TransactionEdgeCreate{ConvID: uint64(s.RoomID), Source: source, Target: target, Relation: relation})
		if err != nil {
			return err
		}
		result, err := customerTransaction(s, []protocol.TransactionOperation{{Type: protocol.TransactionOpEdgeCreate, Body: body}})
		if err != nil {
			return err
		}
		output.Mutation("created", "edge", result.Results[0].EntityID, "Customer link created", nil, nil)
		return nil
	})
	return c
}

func customerUnlink() *cobra.Command {
	c := &cobra.Command{Use: "unlink <company-id> <edge-id>", Short: "Delete a company edge without deleting either record", Args: cobra.ExactArgs(2), Annotations: map[string]string{"mutation": "true"}}
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		company, err := customerID(args[0])
		if err != nil {
			return err
		}
		id, err := customerID(args[1])
		if err != nil {
			return err
		}
		if _, err := customerAsset(s, company, protocol.AssetTypeCustomerCompany); err != nil {
			return err
		}
		// Edge IDs are immutable and ordered: one bounded incident page confirms membership.
		page, err := customerEdgePage(s, company, 1, id-1)
		if err != nil {
			return err
		}
		if len(page.Edges) != 1 || page.Edges[0].EdgeID != id {
			return &conn.InvalidArgumentError{Err: fmt.Errorf("edge %d does not belong to company %d", id, company)}
		}
		body, err := protocol.EncodeTransactionDelete(protocol.TransactionDelete{ConvID: uint64(s.RoomID), Entity: protocol.Existing(protocol.TransactionEntityEdge, id)}, protocol.TransactionEntityEdge)
		if err != nil {
			return err
		}
		if _, err := customerTransaction(s, []protocol.TransactionOperation{{Type: protocol.TransactionOpEdgeDelete, Body: body}}); err != nil {
			return err
		}
		output.Mutation("deleted", "edge", id, "Customer link deleted; records retained", nil, nil)
		return nil
	})
	return c
}

func init() {
	customer := &cobra.Command{Use: "customer", Short: "Manage companies, contacts, activity history and linked work"}
	customer.AddCommand(customerLinks(), customerLink(), customerUnlink())
	for _, kind := range []uint16{protocol.AssetTypeCustomerCompany, protocol.AssetTypeCustomerContact, protocol.AssetTypeCustomerActivity} {
		group := &cobra.Command{Use: assetTypeName(kind), Short: "Manage customer " + assetTypeName(kind) + " assets"}
		get := &cobra.Command{Use: "get <id>", Short: "Get metadata and full record body", Args: cobra.ExactArgs(1)}
		get.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
			id, err := customerID(args[0])
			if err != nil {
				return err
			}
			a, err := customerAsset(s, id, kind)
			if err != nil {
				return err
			}
			r, err := customerResource(a, true)
			if err != nil {
				return err
			}
			if output.Human() {
				data, _ := json.MarshalIndent(r, "", "  ")
				fmt.Println(string(data))
			} else {
				output.OutputJSON(r)
			}
			return nil
		})
		group.AddCommand(customerList(kind), get, customerWrite(kind, "create"), customerWrite(kind, "update"), customerWrite(kind, "delete"))
		if kind == protocol.AssetTypeCustomerCompany {
			group.AddCommand(customerWrite(kind, "archive"), customerWrite(kind, "restore"))
		}
		customer.AddCommand(group)
	}
	rootCmd.AddCommand(customer)
}
