package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/heavyhorst/nrc/cli/pkg/upload"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

// Ticket metadata is patched independently of the immutable original payload.
type ticketResource struct {
	ID          uint64                     `json:"id"`
	Metadata    map[string]json.RawMessage `json:"metadata"`
	Body        string                     `json:"body"`
	Attachments []p.Attachment             `json:"attachments"`
	CreatedAt   int64                      `json:"created_at"`
	UpdatedAt   int64                      `json:"updated_at"`
	Owner       string                     `json:"owner"`
}

func ticketView(a p.Asset) (ticketResource, error) {
	var m map[string]json.RawMessage
	e := json.Unmarshal([]byte(a.Preview), &m)
	if e != nil {
		return ticketResource{}, e
	}
	if m == nil {
		return ticketResource{}, fmt.Errorf("invalid ticket metadata object")
	}
	if a.AssetType == p.AssetTypeTicket {
		if e := p.ValidateTicketScheduling(m); e != nil {
			return ticketResource{}, e
		}
		if _, ok := m["priority"]; !ok {
			m["priority"] = json.RawMessage(`"normal"`)
		}
		if _, ok := m["follow_up_at"]; !ok {
			m["follow_up_at"] = json.RawMessage(`""`)
		}
	}
	body, e := p.DecodeAssetPayload(a)
	return ticketResource{a.AssetID, m, body, a.Attachments, a.CreatedAt, a.UpdatedAt, a.Owner}, e
}
func ticketString(m map[string]json.RawMessage, k string) string {
	var v string
	_ = json.Unmarshal(m[k], &v)
	return v
}
func ticketEmit(v any) {
	if output.Human() {
		b, _ := json.Marshal(v)
		var record struct {
			ticketResource
			Entries []ticketResource `json:"entries"`
			Members []sliceMember    `json:"members"`
		}
		if json.Unmarshal(b, &record) == nil {
			if record.ID != 0 {
				printTicketRecord(record.ticketResource)
				for _, entry := range record.Entries {
					printTicketRecord(entry)
				}
				return
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			if record.Members != nil {
				fmt.Fprintln(w, "KIND\tID\tTITLE\tSTATE")
				for _, m := range record.Members {
					fmt.Fprintf(w, "%s\t%d\t%s\t%s\n", m.Kind, m.ID, m.Title, memberState(m))
				}
			} else {
				fmt.Fprintln(w, "ID\tTITLE\tSTATUS\tPRIORITY\tFOLLOW_UP_AT\tASSIGNEE\tREQUESTER")
				for _, r := range record.Entries {
					fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", r.ID, ticketString(r.Metadata, "title"), ticketString(r.Metadata, "status"), ticketString(r.Metadata, "priority"), ticketString(r.Metadata, "follow_up_at"), ticketString(r.Metadata, "assignee"), ticketString(r.Metadata, "requester"))
				}
			}
			_ = w.Flush()
			return
		}
		var attachments []p.Attachment
		_ = json.Unmarshal(b, &attachments)
		printNoteAttachments(attachments, "")
		return
	}
	output.OutputJSON(v)
}
func printTicketRecord(r ticketResource) {
	title := ticketString(r.Metadata, "title")
	if title == "" {
		title = ticketString(r.Metadata, "kind")
	}
	fmt.Printf("#%d · %s · %s\n", r.ID, title, r.Owner)
	keys := make([]string, 0, len(r.Metadata))
	for key := range r.Metadata {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		fmt.Printf("%s: %s\n", key, r.Metadata[key])
	}
	fmt.Printf("updated_at: %d\n\n%s\n\n", r.UpdatedAt, r.Body)
	printNoteAttachments(r.Attachments, "")
}
func ticketAssets(s *conn.Session, kind uint16) ([]p.Asset, error) {
	out := make([]p.Asset, 0)
	var at int64
	var id uint64
	for {
		r, e := s.SendAndRecv(&p.Message{Opcode: p.C_ListAssetsPaged, Data: p.EncodeListAssetsPaged(0, kind, true, 250, id != 0, at, id)})
		if e != nil {
			return nil, e
		}
		if r.Opcode != p.S_AssetListPage {
			return nil, fmt.Errorf("unexpected asset list response %d", r.Opcode)
		}
		page, e := p.DecodeAssetListPage(r.Data)
		if e != nil {
			return nil, e
		}
		out = append(out, page.Assets...)
		if !page.HasMore {
			return out, nil
		}
		if page.NextCursorAssetID == id {
			return nil, fmt.Errorf("asset cursor did not advance")
		}
		at, id = page.NextCursorUpdatedAt, page.NextCursorAssetID
	}
}
func ticketCompany(s *conn.Session, m map[string]json.RawMessage) error {
	company, contact := ticketString(m, "company_id"), ticketString(m, "contact_id")
	if company != "" {
		id, e := customerID(company)
		if e != nil {
			return e
		}
		if _, e = customerAsset(s, id, p.AssetTypeCustomerCompany); e != nil {
			return e
		}
	}
	if contact == "" {
		return nil
	}
	id, e := customerID(contact)
	if e != nil {
		return e
	}
	if _, e = customerAsset(s, id, p.AssetTypeCustomerContact); e != nil {
		return e
	}
	edges, e := fetchIncidentEdges(s, p.TargetTypeAsset, id, 250)
	if e != nil {
		return e
	}
	companies := map[uint64]bool{}
	for _, edge := range edges {
		if edge.Relation != p.RelationMemberOf {
			continue
		}
		typ, other, ok := sliceEdgeMember(edge, id)
		if !ok || typ != p.TargetTypeAsset {
			continue
		}
		a, e := fetchAsset(s, other)
		if e != nil {
			return e
		}
		if a.AssetType == p.AssetTypeCustomerCompany {
			companies[other] = true
		}
	}
	if company != "" {
		cid, _ := customerID(company)
		if !companies[cid] {
			return fmt.Errorf("contact is not a MemberOf company %s", company)
		}
		return nil
	}
	if len(companies) != 1 {
		return fmt.Errorf("contact needs an explicit company (found %d company memberships)", len(companies))
	}
	for cid := range companies {
		m["company_id"], _ = json.Marshal(fmt.Sprint(cid))
	}
	return nil
}
func ticketValidate(m map[string]json.RawMessage) error {
	if err := p.ValidateTicketScheduling(m); err != nil {
		return err
	}
	for key, limit := range map[string]int{"title": 256, "company_id": 20, "contact_id": 20, "requester": 320, "requester_name": 256, "status": 32, "assignee": 64} {
		var value string
		if json.Unmarshal(m[key], &value) != nil || len(value) > limit {
			return fmt.Errorf("invalid %s (maximum %d bytes)", key, limit)
		}
	}
	var version int
	_ = json.Unmarshal(m["version"], &version)
	if version != 1 {
		return fmt.Errorf("unsupported ticket metadata version")
	}
	if strings.TrimSpace(ticketString(m, "title")) == "" || strings.TrimSpace(ticketString(m, "requester")) == "" {
		return fmt.Errorf("title and requester are required")
	}
	switch ticketString(m, "status") {
	case "open", "in_progress", "waiting_customer", "resolved", "closed":
	default:
		return fmt.Errorf("invalid ticket status")
	}
	return nil
}
func ticketCommand(action string) *cobra.Command {
	c := &cobra.Command{Use: action + " <id>", Short: action + " a workspace ticket", Args: cobra.ExactArgs(1)}
	if action == "list" || action == "create" {
		c.Use = action
		c.Args = cobra.NoArgs
	}
	mutation := action == "create" || action == "update" || action == "reply" || action == "internal-note" || action == "delete"
	if mutation {
		c.Annotations = map[string]string{"mutation": "true"}
	}
	if action == "create" || action == "update" || action == "list" {
		for _, f := range []string{"title", "requester", "requester-name", "company", "contact", "assignee", "status", "priority"} {
			c.Flags().String(f, "", "Ticket "+f)
		}
	}
	if action == "create" || action == "update" {
		c.Flags().String("follow-up", "", "RFC3339 timestamp with timezone; empty clears follow-up")
	}
	if action == "list" {
		c.Flags().Bool("follow-up-due", false, "Only tickets with follow-up at or before now")
		c.Flags().String("search", "", "Case-insensitive title/requester/body search")
	}
	if action == "create" || action == "reply" || action == "internal-note" {
		c.Flags().String("body", "", "Message body")
		c.Flags().String("body-file", "", "Read message from file")
		c.Flags().String("attach", "", "Comma-separated attachment paths")
	}
	if action == "reply" {
		c.Flags().Bool("public", false, "Explicitly send a public_reply (default internal_note)")
	}
	if action == "update" {
		c.Flags().Int64("expect-updated-at", 0, "Require this version in addition to the conditional server patch")
	}
	if action == "attachments" {
		c.Flags().String("entry", "", "Entry ID; omit for original")
	}
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		var a p.Asset
		var id uint64
		var e error
		if len(args) > 0 {
			id, e = customerID(args[0])
			if e != nil {
				return e
			}
			a, e = customerAsset(s, id, p.AssetTypeTicket)
			if e != nil {
				return e
			}
		}
		if action == "get" {
			v, e := ticketView(a)
			if e != nil {
				return e
			}
			assets, e := ticketAssets(s, p.AssetTypeTicketEntry)
			if e != nil {
				return e
			}
			entries := make([]ticketResource, 0)
			for _, entry := range assets {
				if entry.ParentType == p.ParentTypeAsset && entry.ParentID == id {
					v, e := ticketView(entry)
					if e != nil {
						return e
					}
					entries = append(entries, v)
				}
			}
			sort.Slice(entries, func(i, j int) bool {
				if entries[i].CreatedAt == entries[j].CreatedAt {
					return entries[i].ID < entries[j].ID
				}
				return entries[i].CreatedAt < entries[j].CreatedAt
			})
			ticketEmit(struct {
				ticketResource
				Entries []ticketResource `json:"entries"`
			}{v, entries})
			return nil
		}
		if action == "list" {
			priority, _ := cmd.Flags().GetString("priority")
			if cmd.Flags().Changed("priority") && !p.ValidTicketPriority(priority) {
				return fmt.Errorf("invalid ticket priority")
			}
			due, _ := cmd.Flags().GetBool("follow-up-due")
			for _, flag := range []string{"company", "contact"} {
				v, _ := cmd.Flags().GetString(flag)
				if v != "" {
					if _, e := customerID(v); e != nil {
						return e
					}
				}
			}
			assets, e := ticketAssets(s, p.AssetTypeTicket)
			if e != nil {
				return e
			}
			var dueIDs map[uint64]bool
			if due {
				dueIDs, e = p.TicketDueMembership(assets, func(q json.RawMessage) (*p.TicketPage, error) {
					data, err := p.EncodeTicketQuery(1, q)
					if err != nil {
						return nil, err
					}
					resp, err := s.SendAndRecv(&p.Message{Opcode: p.C_QueryTickets, Data: data})
					if err != nil {
						return nil, err
					}
					if resp.Opcode != p.S_TicketPage {
						return nil, fmt.Errorf("unexpected ticket response %d", resp.Opcode)
					}
					page, err := p.DecodeTicketPage(resp.Data)
					if err == nil && page.CorrelationID != 1 {
						return nil, fmt.Errorf("ticket correlation mismatch")
					}
					return page, err
				})
				if e != nil {
					return e
				}
			}
			entries := make([]ticketResource, 0)
			for _, a := range assets {
				v, e := ticketView(a)
				if e != nil {
					return e
				}
				match := true
				if priority != "" && ticketString(v.Metadata, "priority") != priority {
					match = false
				}
				if due && !dueIDs[a.AssetID] {
					match = false
				}
				for flag, key := range map[string]string{"status": "status", "assignee": "assignee", "company": "company_id", "contact": "contact_id", "requester": "requester", "title": "title", "requester-name": "requester_name"} {
					f, _ := cmd.Flags().GetString(flag)
					if f != "" && ticketString(v.Metadata, key) != f {
						match = false
					}
				}
				q, _ := cmd.Flags().GetString("search")
				if q != "" && !strings.Contains(strings.ToLower(ticketString(v.Metadata, "title")+" "+ticketString(v.Metadata, "requester")+" "+v.Body), strings.ToLower(q)) {
					match = false
				}
				if match {
					entries = append(entries, v)
				}
			}
			ticketEmit(struct {
				Entries []ticketResource `json:"entries"`
				Count   int              `json:"count"`
			}{entries, len(entries)})
			return nil
		}
		if action == "attachments" {
			entry, _ := cmd.Flags().GetString("entry")
			a, e = ticketAttachmentAsset(s, id, entry)
			if e != nil {
				return e
			}
			ticketEmit(a.Attachments)
			return nil
		}
		if action == "delete" {
			body, e := p.EncodeTransactionDelete(p.TransactionDelete{ConvID: 0, Entity: p.Existing(p.TransactionEntityAsset, id), IfUpdatedAt: a.UpdatedAt}, p.TransactionEntityAsset)
			if e != nil {
				return e
			}
			_, e = customerTransaction(s, []p.TransactionOperation{{Type: p.TransactionOpAssetDelete, Body: body}})
			if e != nil {
				return e
			}
			output.Mutation("deleted", "ticket", id, "Ticket deleted", nil, nil)
			return nil
		}
		if action == "create" || action == "update" {
			m := map[string]json.RawMessage{"version": json.RawMessage("1"), "status": json.RawMessage(`"open"`)}
			for _, key := range []string{"title", "requester", "requester_name", "company_id", "contact_id", "assignee"} {
				m[key] = json.RawMessage(`""`)
			}
			if action == "update" {
				m, e = customerMetadata(a.Preview)
				if e != nil {
					return e
				}
				expected, _ := cmd.Flags().GetInt64("expect-updated-at")
				if expected != 0 && expected != a.UpdatedAt {
					return fmt.Errorf("ticket changed: updated_at=%d", a.UpdatedAt)
				}
			}
			changed := false
			for flag, key := range map[string]string{"title": "title", "requester": "requester", "requester-name": "requester_name", "company": "company_id", "contact": "contact_id", "assignee": "assignee", "status": "status", "priority": "priority"} {
				if cmd.Flags().Changed(flag) {
					v, _ := cmd.Flags().GetString(flag)
					m[key], _ = json.Marshal(v)
					changed = true
				}
			}
			if cmd.Flags().Changed("follow-up") {
				v, _ := cmd.Flags().GetString("follow-up")
				if v != "" {
					at, err := time.Parse(time.RFC3339Nano, v)
					if err != nil || at.UnixMilli() <= 0 {
						return fmt.Errorf("follow-up must be a positive RFC3339 timestamp with timezone")
					}
					v = strconv.FormatInt(at.UnixMilli(), 10)
				}
				m["follow_up_at"], _ = json.Marshal(v)
				changed = true
			}
			if action == "update" && !changed {
				return fmt.Errorf("pass at least one metadata flag")
			}
			if e = ticketValidate(m); e != nil {
				return e
			}
			if e = ticketCompany(s, m); e != nil {
				return e
			}
			preview, e := json.Marshal(m)
			if e != nil {
				return e
			}
			if len(preview) > p.MaxPreviewLength {
				return fmt.Errorf("ticket metadata exceeds preview limit")
			}
			if action == "update" {
				body, e := p.EncodeTransactionAssetPatch(p.TransactionAssetPatch{ConvID: 0, Asset: p.Existing(p.TransactionEntityAsset, id), IfUpdatedAt: a.UpdatedAt, Present: p.TransactionAssetPatchPreview, Preview: preview})
				if e != nil {
					return e
				}
				_, e = customerTransaction(s, []p.TransactionOperation{{Type: p.TransactionOpAssetPatch, Body: body}})
				if e != nil {
					return e
				}
				output.Mutation("updated", "ticket", id, "Ticket metadata updated; original preserved", nil, nil)
				return nil
			}
			return ticketCreate(cmd, s, p.AssetTypeTicket, 0, string(preview))
		}
		kind := "internal_note"
		public, _ := cmd.Flags().GetBool("public")
		if public {
			kind = "public_reply"
		}
		metadata := map[string]any{"version": 1, "kind": kind, "author": ""}
		var guard []int64
		if public {
			v, err := ticketView(a)
			if err != nil {
				return err
			}
			metadata["recipient"] = ticketString(v.Metadata, "requester")
			guard = []int64{a.UpdatedAt}
		}
		preview, _ := json.Marshal(metadata)
		return ticketCreate(cmd, s, p.AssetTypeTicketEntry, id, string(preview), guard...)
	})
	return c
}
func ticketCreate(cmd *cobra.Command, s *conn.Session, kind uint16, parent uint64, preview string, guard ...int64) error {
	body, _ := cmd.Flags().GetString("body")
	file, _ := cmd.Flags().GetString("body-file")
	if cmd.Flags().Changed("body") && cmd.Flags().Changed("body-file") {
		return fmt.Errorf("use body or body-file, not both")
	}
	if file != "" {
		b, e := os.ReadFile(file)
		if e != nil {
			return e
		}
		body = string(b)
	}
	if strings.TrimSpace(body) == "" {
		return fmt.Errorf("body is required")
	}
	if len(body) > 32000 {
		return fmt.Errorf("body exceeds 32000 bytes")
	}
	attach, _ := cmd.Flags().GetString("attach")
	var atts []p.Attachment
	var e error
	if attach != "" {
		atts, e = upload.UploadFiles(parseFilePaths(attach), s.Config.GetProxyURL(), s.Config.WorkspaceID)
		if e != nil {
			return e
		}
	}
	parentType := uint16(p.ParentTypeNone)
	if parent != 0 {
		parentType = p.ParentTypeAsset
	}
	data, e := p.EncodeCreateAssetWithAttachments(0, kind, parentType, parent, preview, body, atts)
	if len(guard) > 0 {
		data, e = p.EncodeCreateAssetWithParentVersionAndCorrelation(0, kind, parentType, parent, preview, body, atts, guard[0], 0)
	}
	if e != nil {
		return e
	}
	r, e := s.SendAndRecv(&p.Message{Opcode: p.C_CreateAsset, Data: data})
	if e != nil {
		var serverError *conn.ServerError
		if errors.As(e, &serverError) {
			return e
		}
		return fmt.Errorf("creation outcome unconfirmed; inspect before retrying: %v", e)
	}
	if r.Opcode != p.S_AssetCreated {
		return fmt.Errorf("unexpected creation response %d", r.Opcode)
	}
	created, e := p.DecodeAssetCreated(r.Data)
	if e != nil {
		return e
	}
	output.Mutation("created", assetTypeName(kind), created.Asset.AssetID, "Ticket record created", nil, map[string]any{"parent_id": parent})
	return nil
}
func ticketSearchCommand() *cobra.Command {
	c := &cobra.Command{
		Use: "search <query>", Short: "Search ticket conversations through nrc-search",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			query := strings.TrimSpace(args[0])
			top, _ := cmd.Flags().GetInt("top")
			if query == "" || top < 1 || top > 100 {
				return &conn.InvalidArgumentError{Err: fmt.Errorf("ticket search requires a nonblank query and --top between 1 and 100")}
			}
			status, _ := cmd.Flags().GetString("status")
			priority, _ := cmd.Flags().GetString("priority")
			if cmd.Flags().Changed("priority") && !p.ValidTicketPriority(priority) {
				return fmt.Errorf("invalid ticket priority")
			}
			assignee, _ := cmd.Flags().GetString("assignee")
			company, _ := cmd.Flags().GetString("company")
			payload, _ := cmd.Flags().GetBool("payload")
			room, _ := cmd.Flags().GetString("room")
			resp, err := runSearch(p.SearchRequest{
				Query: query, TopN: top, IncludePayload: payload,
				Filters: &p.SearchFilters{
					EntityTypes: []p.SearchEntityType{p.SearchEntityAsset},
					AssetTypes:  []uint16{p.AssetTypeTicket},
					Ticket:      &p.SearchTicketFilters{Status: status, Assignee: assignee, CompanyID: company, Priority: priority},
				},
			}, room)
			if err != nil {
				return err
			}
			outputSearchResults(resp, useJSONOutput(cmd), payload, false)
			return nil
		},
	}
	for _, flag := range []string{"status", "assignee", "company", "priority"} {
		c.Flags().String(flag, "", "Exact ticket "+flag+" filter")
	}
	c.Flags().Int("top", 100, "Maximum number of results (1-100)")
	c.Flags().Bool("payload", false, "Include original ticket body (not replies or internal notes)")
	return c
}

func init() {
	c := &cobra.Command{Use: "ticket", Short: "Staff tickets: original bodies are read-only; replies default internal"}
	c.AddCommand(metadataListCommand("assignees", "ASSIGNEE", p.C_ListTicketAssignees, p.S_TicketAssignees))
	for _, action := range []string{"list", "get", "create", "update", "reply", "internal-note", "attachments", "delete"} {
		c.AddCommand(ticketCommand(action))
	}
	c.AddCommand(ticketMailCommand(), ticketSearchCommand(), ticketDownload(), ticketLinks("links"), ticketLinks("link"), ticketLinks("unlink"), ticketLinks("create-task"))
	rootCmd.AddCommand(c)
}

func ticketAttachmentAsset(s *conn.Session, ticket uint64, entry string) (p.Asset, error) {
	a, e := customerAsset(s, ticket, p.AssetTypeTicket)
	if e != nil || entry == "" {
		return a, e
	}
	id, e := customerID(entry)
	if e != nil {
		return a, e
	}
	a, e = customerAsset(s, id, p.AssetTypeTicketEntry)
	if e == nil && (a.ParentType != p.ParentTypeAsset || a.ParentID != ticket) {
		e = fmt.Errorf("entry does not belong to ticket")
	}
	return a, e
}
func ticketDownload() *cobra.Command {
	c := &cobra.Command{Use: "download-attachment <ticket-id> <index-or-file-id> [output-path]", Short: "Download original or entry attachment", Args: cobra.RangeArgs(2, 3), Annotations: map[string]string{"mutation": "true"}}
	c.Flags().String("entry", "", "Entry ID; omit for original")
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		id, e := customerID(args[0])
		if e != nil {
			return e
		}
		entry, _ := cmd.Flags().GetString("entry")
		a, e := ticketAttachmentAsset(s, id, entry)
		if e != nil {
			return e
		}
		index, e := noteAttachmentIndex(a.Attachments, args[1])
		if e != nil {
			return e
		}
		destination := ""
		if len(args) == 3 {
			destination = args[2]
		}
		if destination == "" {
			destination = filepath.Base(attachmentDisplayName(a.Attachments[index]))
		}
		written, e := upload.DownloadFile(a.Attachments[index], s.Config.GetProxyURL(), destination)
		if e != nil {
			return e
		}
		output.Mutation("downloaded_attachment", "ticket", id, "Attachment downloaded", nil, map[string]any{"path": destination, "bytes": written})
		return nil
	})
	return c
}
func ticketLinks(action string) *cobra.Command {
	c := &cobra.Command{Use: action + " <ticket-id>", Short: action + " related tasks and slices", Args: cobra.ExactArgs(1)}
	if action != "links" {
		c.Annotations = map[string]string{"mutation": "true"}
	}
	if action == "link" || action == "unlink" {
		c.Flags().String("task", "", "Existing task ID")
		c.Flags().String("slice", "", "Existing slice ID")
	}
	if action == "create-task" {
		c.Flags().String("title", "", "Task title")
		c.Flags().String("description", "", "Task description")
	}
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		id, e := customerID(args[0])
		if e != nil {
			return e
		}
		if _, e = customerAsset(s, id, p.AssetTypeTicket); e != nil {
			return e
		}
		if action == "create-task" {
			title, _ := cmd.Flags().GetString("title")
			description, _ := cmd.Flags().GetString("description")
			if strings.TrimSpace(title) == "" {
				return fmt.Errorf("title required")
			}
			body, e := p.EncodeTransactionTaskCreate(p.TransactionTaskCreate{ConvID: 0, Title: title, Description: description, BlockedBy: p.Existing(p.TransactionEntityTask, 0)})
			if e != nil {
				return e
			}
			edge, e := p.EncodeTransactionEdgeCreate(p.TransactionEdgeCreate{ConvID: 0, Source: p.Existing(p.TransactionEntityAsset, id), Target: p.CreatedBy(p.TransactionEntityTask, 0), Relation: p.RelationRelatedTo})
			if e != nil {
				return e
			}
			r, e := customerTransaction(s, []p.TransactionOperation{{Type: p.TransactionOpTaskCreate, Body: body}, {Type: p.TransactionOpEdgeCreate, Body: edge}})
			if e != nil {
				return e
			}
			output.Mutation("created_task", "ticket", id, "Task created and linked atomically", nil, map[string]any{"task_id": r.Results[0].EntityID, "edge_id": r.Results[1].EntityID})
			return nil
		}
		edges, e := fetchIncidentEdges(s, p.TargetTypeAsset, id, 250)
		if e != nil {
			return e
		}
		if action == "links" {
			members := make([]sliceMember, 0)
			for _, edge := range edges {
				if edge.Relation != p.RelationRelatedTo && edge.Relation != p.RelationMemberOf {
					continue
				}
				typ, other, ok := sliceEdgeMember(edge, id)
				if !ok {
					continue
				}
				if typ == p.TargetTypeTask && edge.Relation == p.RelationRelatedTo {
					members = append(members, taskMember(s, other))
				} else if typ == p.TargetTypeAsset {
					a, e := fetchAsset(s, other)
					if e != nil {
						return e
					}
					if a.AssetType == p.AssetTypeSlice {
						record, e := parseSlicePreview(a.Preview)
						if e != nil {
							return e
						}
						members = append(members, sliceMember{Kind: "slice", ID: other, Title: record.Name, Assignee: record.Owner})
					}
				}
			}
			ticketEmit(struct {
				Members []sliceMember `json:"members"`
			}{members})
			return nil
		}
		task, _ := cmd.Flags().GetString("task")
		slice, _ := cmd.Flags().GetString("slice")
		if (task == "") == (slice == "") {
			return fmt.Errorf("pass exactly one of --task or --slice")
		}
		value := task
		entity := uint8(p.TransactionEntityTask)
		typ := uint16(p.TargetTypeTask)
		relation := uint16(p.RelationRelatedTo)
		if slice != "" {
			relation = p.RelationMemberOf
			value = slice
			entity = p.TransactionEntityAsset
			typ = p.TargetTypeAsset
		}
		other, e := customerID(value)
		if e != nil {
			return e
		}
		if slice != "" {
			_, e = customerAsset(s, other, p.AssetTypeSlice)
		} else {
			_, e = fetchTask(s, other)
		}
		if e != nil {
			return e
		}
		var found uint64
		for _, edge := range edges {
			t, n, ok := sliceEdgeMember(edge, id)
			if ok && t == typ && n == other && edge.Relation == relation {
				found = edge.EdgeID
				break
			}
		}
		var body []byte
		var op uint8
		if action == "link" {
			if found != 0 {
				return fmt.Errorf("already linked (edge %d)", found)
			}
			body, e = p.EncodeTransactionEdgeCreate(p.TransactionEdgeCreate{ConvID: 0, Source: p.Existing(p.TransactionEntityAsset, id), Target: p.Existing(entity, other), Relation: relation})
			op = p.TransactionOpEdgeCreate
		} else {
			if found == 0 {
				return fmt.Errorf("not linked")
			}
			body, e = p.EncodeTransactionDelete(p.TransactionDelete{ConvID: 0, Entity: p.Existing(p.TransactionEntityEdge, found)}, p.TransactionEntityEdge)
			op = p.TransactionOpEdgeDelete
		}
		if e != nil {
			return e
		}
		r, e := customerTransaction(s, []p.TransactionOperation{{Type: op, Body: body}})
		if e != nil {
			return e
		}
		output.Mutation(action+"ed", "ticket", id, "Ticket work link changed", nil, map[string]any{"transaction": r})
		return nil
	})
	return c
}
