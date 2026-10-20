package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"charm.land/fantasy"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type ticketOutcomeUnknown struct{ cause error }

func (e *ticketOutcomeUnknown) Error() string {
	return "outcome_unknown: ticket write may have committed; do not replay: " + e.cause.Error()
}
func (e *ticketOutcomeUnknown) Unwrap() error { return e.cause }

type ticketWriteRejection struct{ message string }

func (e *ticketWriteRejection) Error() string { return e.message }

func ticketWriteError(err error) error {
	if err == nil {
		return nil
	}
	var rejected *ticketWriteRejection
	if errors.As(err, &rejected) {
		return err
	}
	return &ticketOutcomeUnknown{err}
}

func ticketPreview(a ticketAction, current protocol.Asset) ([]byte, error) {
	m := map[string]any{"version": 1, "title": "", "company_id": "", "contact_id": "", "requester": "", "requester_name": "", "status": "open", "assignee": ""}
	if a.Operation == "entry" {
		m = map[string]any{"version": 1, "kind": a.Kind, "author": "Sullivan"}
		if a.Kind == "public_reply" {
			m["recipient"] = a.Recipient
		}
	} else if a.Operation == "update_metadata" {
		var err error
		m, err = ticketMetadata(current)
		if err != nil {
			return nil, err
		}
	}
	for k, v := range a.Metadata {
		m[k] = v
	}
	b, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	if len(b) > protocol.MaxPreviewLength {
		return nil, fmt.Errorf("ticket metadata exceeds protocol preview limit")
	}
	if a.Operation == "create" || a.Operation == "update_metadata" {
		raw := map[string]json.RawMessage{}
		for k, v := range m {
			raw[k], _ = json.Marshal(v)
		}
		if err := protocol.ValidateTicketScheduling(raw); err != nil {
			return nil, err
		}
		for key, limit := range map[string]int{"title": 256, "company_id": 20, "contact_id": 20, "requester": 320, "requester_name": 256, "status": 32, "assignee": 64} {
			v, ok := m[key].(string)
			if !ok || !utf8.ValidString(v) || len(v) > limit {
				return nil, fmt.Errorf("invalid ticket metadata field %s (max %d bytes)", key, limit)
			}
		}
	}
	return b, nil
}

// Only workspace-owned sources are accepted, never caller supplied blob URLs.
type ticketAttachmentSource struct {
	EntityType string `json:"entity_type"`
	EntityID   string `json:"entity_id"`
	FileID     string `json:"file_id"`
}
type ticketAction struct {
	Group           *ticketGroupAction       `json:"group,omitempty"`
	GeneratedFiles  []ticketGeneratedFile    `json:"generated_files,omitempty"`
	Operation       string                   `json:"operation"`
	TicketID        string                   `json:"ticket_id,omitempty"`
	ExpectedVersion string                   `json:"expected_updated_at,omitempty"`
	Metadata        map[string]string        `json:"metadata,omitempty" jsonschema:"Ticket patch: title, company_id, contact_id, requester, requester_name, status, assignee; priority is low|normal|high|urgent (absent defaults normal); follow_up_at is a canonical positive Unix milliseconds string or empty to clear. Staff scheduling is private."`
	Content         string                   `json:"content,omitempty"`
	Kind            string                   `json:"kind,omitempty"`
	Recipient       string                   `json:"recipient,omitempty"`
	Attachments     []ticketAttachmentSource `json:"attachments,omitempty"`
	Filenames       []string                 `json:"filenames,omitempty"`
}
type ticketGeneratedFile struct {
	Filename string `json:"filename"`
	Content  string `json:"content"`
}

func (a *ticketAction) UnmarshalJSON(data []byte) error {
	type plain ticketAction
	var raw struct {
		Metadata map[string]json.RawMessage `json:"metadata"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if err := protocol.ValidateTicketScheduling(raw.Metadata); err != nil {
		return err
	}
	return json.Unmarshal(data, (*plain)(a))
}

type ticketReadInput struct {
	Priority        string `json:"priority,omitempty" jsonschema:"Exact priority: low, normal (including legacy tickets), high, urgent"`
	FollowUpDue     bool   `json:"follow_up_due,omitempty" jsonschema:"Only tickets with follow_up_at at or before now"`
	TicketID        string `json:"ticket_id,omitempty"`
	CursorUpdatedAt string `json:"cursor_updated_at,omitempty"`
	CursorID        string `json:"cursor_id,omitempty"`
	Limit           int    `json:"limit,omitempty"`
	IncludePayload  bool   `json:"include_payload,omitempty"`
	Status          string `json:"status,omitempty"`
	Assignee        string `json:"assignee,omitempty"`
	Requester       string `json:"requester,omitempty"`
	CompanyID       string `json:"company_id,omitempty"`
	ContactID       string `json:"contact_id,omitempty"`
	Search          string `json:"search,omitempty"`
}

func ticketMetadata(a protocol.Asset) (map[string]any, error) {
	var m map[string]any
	decoder := json.NewDecoder(strings.NewReader(a.Preview))
	decoder.UseNumber()
	if err := decoder.Decode(&m); err != nil || m == nil {
		return nil, fmt.Errorf("invalid ticket metadata")
	}
	if a.AssetType == protocol.AssetTypeTicket {
		raw := map[string]json.RawMessage{}
		for k, v := range m {
			raw[k], _ = json.Marshal(v)
		}
		if err := protocol.ValidateTicketScheduling(raw); err != nil {
			return nil, err
		}
	}
	return m, nil
}
func ticketRecord(a protocol.Asset, payload bool) map[string]any {
	m, _ := ticketMetadata(a)
	if a.AssetType == protocol.AssetTypeTicket && m != nil {
		if _, ok := m["priority"]; !ok {
			m["priority"] = "normal"
		}
		if _, ok := m["follow_up_at"]; !ok {
			m["follow_up_at"] = ""
		}
	}
	files := make([]map[string]any, 0, len(a.Attachments))
	for _, f := range a.Attachments {
		files = append(files, map[string]any{"file_id": f.FileId, "filename": f.Filename, "mime_type": f.MimeType, "size": strconv.FormatInt(f.Size, 10)})
	}
	r := map[string]any{"asset_id": strconv.FormatUint(a.AssetID, 10), "asset_type": assetTypeName(a.AssetType), "parent_id": strconv.FormatUint(a.ParentID, 10), "metadata": m, "updated_at": strconv.FormatInt(a.UpdatedAt, 10), "created_at": strconv.FormatInt(a.CreatedAt, 10), "attachments": files}
	if payload {
		r["payload"] = a.Payload
	}
	return r
}
func validateTicketAction(a *ticketAction) error {
	if a.Operation == "group" {
		return validateTicketGroupAction(a.Group)
	}
	if a.Group != nil {
		return fmt.Errorf("group input requires group operation")
	}
	switch a.Operation {
	case "create", "update_metadata", "entry", "delete":
	default:
		return fmt.Errorf("unsupported ticket operation")
	}
	if a.Operation != "create" {
		if _, err := dataUint(a.TicketID); err != nil {
			return err
		}
		n, err := strconv.ParseInt(a.ExpectedVersion, 10, 64)
		if err != nil || n <= 0 {
			return fmt.Errorf("expected_updated_at required")
		}
	}
	if len(a.Content) > 32000 {
		return fmt.Errorf("content exceeds 32000 bytes")
	}
	if a.Operation != "entry" && (a.Kind != "" || a.Recipient != "") {
		return fmt.Errorf("visibility and recipient only apply to entries")
	}
	if a.Operation == "entry" && len(a.Metadata) != 0 {
		return fmt.Errorf("entry cannot change ticket metadata")
	}
	if a.Operation == "entry" {
		if a.Kind == "" {
			a.Kind = "internal_note"
		}
		if a.Kind != "internal_note" && a.Kind != "public_reply" {
			return fmt.Errorf("kind must be internal_note or public_reply; customer_reply is forbidden")
		}
		if strings.TrimSpace(a.Content) == "" {
			return fmt.Errorf("entry content required")
		}
		if a.Kind == "public_reply" && strings.TrimSpace(a.Recipient) == "" {
			return fmt.Errorf("explicit public recipient required")
		}
	}
	if (a.Operation == "update_metadata" || a.Operation == "delete") && (a.Content != "" || len(a.Attachments) > 0 || len(a.GeneratedFiles) > 0) {
		return fmt.Errorf("original body and attachments are read only")
	}
	if len(a.Attachments)+len(a.GeneratedFiles) > 10 {
		return fmt.Errorf("at most ten attachments")
	}
	for _, f := range a.GeneratedFiles {
		if f.Filename == "" || len(f.Filename) > 255 || strings.ContainsAny(f.Filename, "\r\n/\\\x00") || !utf8.ValidString(f.Filename) || !utf8.ValidString(f.Content) || len(f.Content) > 1024*1024 {
			return fmt.Errorf("invalid generated text file (max 1 MiB)")
		}
	}
	for k, v := range a.Metadata {
		switch k {
		case "priority":
			if !protocol.ValidTicketPriority(v) {
				return fmt.Errorf("invalid ticket priority")
			}
		case "follow_up_at":
			if !protocol.ValidTicketFollowUp(v) {
				return fmt.Errorf("follow_up_at must be empty or canonical positive Unix milliseconds string")
			}
		case "title", "requester", "requester_name", "assignee":
			if k == "title" && strings.TrimSpace(v) == "" {
				return fmt.Errorf("title cannot be empty")
			}
		case "company_id", "contact_id":
			if v != "" {
				if _, err := dataUint(v); err != nil {
					return err
				}
			}
		case "status":
			if v != "open" && v != "in_progress" && v != "waiting_customer" && v != "resolved" && v != "closed" {
				return fmt.Errorf("invalid status")
			}
		default:
			return fmt.Errorf("unsupported metadata field %q", k)
		}
	}
	if a.Operation == "create" && strings.TrimSpace(a.Metadata["title"]) == "" {
		return fmt.Errorf("ticket title required")
	}
	preview, _ := json.Marshal(a.Metadata)
	if len(preview) > protocol.MaxPreviewLength-64 {
		return fmt.Errorf("ticket metadata exceeds protocol preview limit")
	}
	return nil
}
func resolveTicketAttachments(ctx context.Context, c *NRCClient, sources []ticketAttachmentSource) ([]protocol.Attachment, error) {
	if len(sources) > 10 {
		return nil, fmt.Errorf("at most ten attachments")
	}
	out := make([]protocol.Attachment, 0, len(sources))
	for _, s := range sources {
		id, err := dataUint(s.EntityID)
		if err != nil {
			return nil, err
		}
		kind := s.EntityType
		if kind == "file" {
			a, err := c.GetAsset(ctx, 0, id)
			if err != nil {
				return nil, err
			}
			if a.AssetID != id || a.ConvID != 0 || a.AssetType != protocol.AssetTypeFile {
				return nil, fmt.Errorf("not a workspace File asset")
			}
			if len(a.Attachments) != 1 {
				return nil, fmt.Errorf("File asset must have one attachment")
			}
			if s.FileID != "" && s.FileID != a.Attachments[0].FileId {
				return nil, fmt.Errorf("File attachment changed")
			}
			if !aiAttachmentID.MatchString(a.Attachments[0].FileId) {
				return nil, fmt.Errorf("invalid File attachment")
			}
			out = append(out, a.Attachments[0])
			continue
		}
		files, err := ownerAttachments(ctx, c, kind, id)
		if err != nil {
			return nil, err
		}
		found := false
		for _, f := range files {
			if f.FileId == s.FileID && aiAttachmentID.MatchString(f.FileId) {
				out = append(out, f)
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("attachment not found on workspace source")
		}
	}
	return out, nil
}
func (c *NRCClient) ticketPrecheck(ctx context.Context, a ticketAction) (protocol.Asset, error) {
	id, err := dataUint(a.TicketID)
	if err != nil {
		return protocol.Asset{}, err
	}
	current, err := c.GetAsset(ctx, 0, id)
	if err != nil {
		return current, err
	}
	if current.ConvID != 0 || current.AssetID != id || current.AssetType != 13 {
		return current, fmt.Errorf("not a workspace ticket")
	}
	if strconv.FormatInt(current.UpdatedAt, 10) != a.ExpectedVersion {
		return current, fmt.Errorf("stale ticket version; reload and propose again")
	}
	if a.Kind == "public_reply" {
		m, err := ticketMetadata(current)
		if err != nil {
			return current, err
		}
		if m["requester"] != a.Recipient {
			return current, fmt.Errorf("public recipient changed; reload and propose again")
		}
	}
	return current, nil
}
func (s *AgentSessionStore) addTicketAction(sessionID, planID string, a ticketAction) (ProposedAction, error) {
	if err := validateTicketAction(&a); err != nil {
		return ProposedAction{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneExpiredLocked(time.Now())
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ProposedAction{}, fmt.Errorf("pending action plan not found")
	}
	// Own the staged snapshot. Neither tool inputs nor API response maps may alter approval.
	b, _ := json.Marshal(a)
	for i, existing := range plan.Actions {
		if existing.Ticket != nil {
			prior, _ := json.Marshal(existing.Ticket)
			if string(prior) == string(b) {
				return cloneActionPlan(*plan).Actions[i], nil
			}
			if a.Group != nil && existing.Ticket.Group != nil && existing.Ticket.Group.CompanyID == a.Group.CompanyID && existing.Status != actionStatusApplied {
				return ProposedAction{}, fmt.Errorf("a ticket group change for company #%s is already staged; apply it and read the company again before proposing another", a.Group.CompanyID)
			}
		}
	}
	var owned ticketAction
	json.Unmarshal(b, &owned)
	title := fmt.Sprintf("%s ticket %s: %s", a.Operation, a.TicketID, a.Metadata["title"])
	if a.Group != nil {
		title = ticketGroupSummary(a.Group)
	}
	if a.Kind == "public_reply" {
		title = fmt.Sprintf("PUBLIC REPLY · visible in customer portal · recipient %s · files: %s", a.Recipient, strings.Join(a.Filenames, ", "))
	} else if a.Operation == "entry" {
		title = "INTERNAL NOTE · staff only"
	}
	detail, _ := json.Marshal(a)
	action := ProposedAction{ID: strconv.Itoa(len(plan.Actions) + 1), Type: "ticket_" + a.Operation, Status: actionStatusPending, Title: title, Description: string(detail), Content: a.Content, Ticket: &owned}
	plan.Actions = append(plan.Actions, action)
	plan.Status = actionPlanStatusPending
	plan.UpdatedAt = time.Now()
	plan.ExpiresAt = plan.UpdatedAt.Add(s.ttl)
	session.UpdatedAt = plan.UpdatedAt
	session.ExpiresAt = plan.ExpiresAt
	return cloneActionPlan(*plan).Actions[len(plan.Actions)-1], nil
}
func newTicketTools(wm *WorkspaceManager, store *AgentSessionStore) []fantasy.AgentTool {
	read := fantasy.NewAgentTool("read_tickets", "Native paginated ticket list/filter or full conversation. ticket_id selects original Ticket plus a page of TicketEntry records (including internal notes); otherwise lists tickets. Filtered results may be empty while has_more=true: continue the returned cursor. include_payload returns full bodies and attachment metadata. IDs and timestamps are decimal strings. Never expose internal notes to customers.", func(ctx context.Context, in ticketReadInput, call fantasy.ToolCall) (fantasy.ToolResponse, error) {
		tc := newFantasyADKToolContext(ctx, call.ID)
		ws, conv, err := adkSessionScope(tc)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		c, err := dataReadClient(wm, ws, conv)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		typ := uint16(13)
		var original any
		var ticketID uint64
		if in.TicketID != "" {
			ticketID, err = dataUint(in.TicketID)
			if err != nil {
				return fantasy.ToolResponse{}, err
			}
			a, e := c.GetAsset(ctx, 0, ticketID)
			if e != nil {
				return fantasy.ToolResponse{}, e
			}
			if a.AssetType != 13 {
				return fantasy.ToolResponse{}, fmt.Errorf("not a ticket")
			}
			original = ticketRecord(a, true)
			typ = 14
		}
		var cursor *assetPageCursor
		if in.CursorID != "" {
			id, e := dataUint(in.CursorID)
			if e != nil {
				return fantasy.ToolResponse{}, e
			}
			at, e := strconv.ParseInt(in.CursorUpdatedAt, 10, 64)
			if e != nil {
				return fantasy.ToolResponse{}, e
			}
			cursor = &assetPageCursor{UpdatedAt: at, AssetID: id}
		}
		limit := in.Limit
		if in.Priority != "" && !protocol.ValidTicketPriority(in.Priority) {
			return fantasy.ToolResponse{}, fmt.Errorf("invalid ticket priority")
		}
		if limit == 0 {
			limit = 20
		}
		if limit < 1 || limit > 100 {
			return fantasy.ToolResponse{}, fmt.Errorf("limit must be 1-100")
		}
		page, err := c.ListAssetsPage(ctx, 0, typ, noteListFilter{}, uint16(limit), in.IncludePayload, cursor)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		var dueIDs map[uint64]bool
		if in.FollowUpDue {
			dueIDs, err = protocol.TicketDueMembership(page.Assets, func(q json.RawMessage) (*protocol.TicketPage, error) { return c.QueryTickets(ctx, q) })
			if err != nil {
				return fantasy.ToolResponse{}, err
			}
		}
		rows := []map[string]any{}
		for _, a := range page.Assets {
			if ticketID != 0 && (a.ParentType != 2 || a.ParentID != ticketID) {
				continue
			}
			m, _ := ticketMetadata(a)
			priority, _ := m["priority"].(string)
			if in.Priority != "" && protocol.EffectiveTicketPriority(priority) != in.Priority {
				continue
			}
			if in.FollowUpDue && !dueIDs[a.AssetID] {
				continue
			}
			if (in.Status != "" && m["status"] != in.Status) || (in.Assignee != "" && m["assignee"] != in.Assignee) || (in.Requester != "" && m["requester"] != in.Requester) || (in.CompanyID != "" && m["company_id"] != in.CompanyID) {
				continue
			}
			if in.ContactID != "" && m["contact_id"] != in.ContactID {
				continue
			}
			if in.Search != "" && !strings.Contains(strings.ToLower(fmt.Sprint(m["title"], " ", m["requester"], " ", a.AssetID)), strings.ToLower(in.Search)) {
				continue
			}
			// List metadata omits attachments; load the authoritative full record even
			// when bodies are omitted from the tool response.
			{
				full, e := c.GetAsset(ctx, 0, a.AssetID)
				if e != nil {
					return fantasy.ToolResponse{}, e
				}
				a = full
			}
			rows = append(rows, ticketRecord(a, in.IncludePayload))
		}
		b, err := json.Marshal(map[string]any{"ticket": original, "records": rows, "has_more": page.HasMore, "cursor_id": strconv.FormatUint(page.NextCursorAssetID, 10), "cursor_updated_at": strconv.FormatInt(page.NextCursorUpdatedAt, 10)})
		return fantasy.NewTextResponse(string(b)), err
	})
	propose := fantasy.NewAgentTool("propose_ticket", "Stage create/update_metadata/entry/delete for explicit approval; NEVER writes/uploads. Requires plan mode. entry defaults INTERNAL NOTE; public_reply requires explicit recipient and version from read_tickets and discloses customer-portal visibility plus filenames. Never customer_reply. Metadata patch preserves original body/attachments. attachments: entity_type=file with decimal File asset entity_id (optional file_id), or asset/task entity_id plus exact attached file_id from list_attachments. No arbitrary URLs/blob IDs. generated_files: filename and UTF-8 content (max 1 MiB each); uploaded through private file service ONLY on approved apply. Ten total files maximum. Link/unlink via propose_create_edge/propose_delete_edge: related-to for Task to Ticket; member-of for Ticket Asset to Slice Asset membership. Create linked work using propose_create_task then propose_create_edge with source_action_id; no status synchronization.", func(ctx context.Context, in ticketAction, call fantasy.ToolCall) (fantasy.ToolResponse, error) {
		tc := newFantasyADKToolContext(ctx, call.ID)
		ws, conv, err := adkSessionScope(tc)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		if normalizeAgentMode(toolContextString(tc, agentModeContextKey{}, "mode")) != agentModePlan {
			return fantasy.ToolResponse{}, fmt.Errorf("propose_ticket requires plan mode")
		}
		if in.Operation == "group" || in.Group != nil {
			return fantasy.ToolResponse{}, fmt.Errorf("use propose_ticket_group")
		}
		if err = validateTicketAction(&in); err != nil {
			return fantasy.ToolResponse{}, err
		}
		c, err := dataReadClient(wm, ws, conv)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		if in.Operation != "create" {
			if _, err = c.ticketPrecheck(ctx, in); err != nil {
				return fantasy.ToolResponse{}, err
			}
		}
		files, err := resolveTicketAttachments(ctx, c, in.Attachments)
		if err != nil {
			return fantasy.ToolResponse{}, err
		}
		in.Filenames = nil
		for i, f := range files {
			in.Attachments[i].FileID = f.FileId
			in.Filenames = append(in.Filenames, f.Filename)
		}
		if len(in.GeneratedFiles) > 0 && (c.filesURL == "" || c.botSecret == "") {
			return fantasy.ToolResponse{}, fmt.Errorf("private file service unavailable")
		}
		for _, f := range in.GeneratedFiles {
			in.Filenames = append(in.Filenames, f.Filename)
		}
		a, err := store.addTicketAction(toolContextString(tc, agentSessionContextKey{}, "agent_session_id"), toolContextString(tc, actionPlanContextKey{}, "action_plan_id"), in)
		b, _ := json.Marshal(a)
		return fantasy.NewTextResponse(string(b)), err
	})
	return []fantasy.AgentTool{read, propose}
}

func (c *NRCClient) applyTicket(ctx context.Context, a ticketAction) (uint64, error) {
	if err := validateTicketAction(&a); err != nil {
		return 0, err
	}
	if a.Operation == "group" {
		return c.applyTicketGroup(ctx, *a.Group)
	}
	var current protocol.Asset
	var err error
	if a.Operation != "create" {
		current, err = c.ticketPrecheck(ctx, a)
		if err != nil {
			return 0, err
		}
	}
	preview, err := ticketPreview(a, current)
	if err != nil {
		return 0, err
	}
	files, err := resolveTicketAttachments(ctx, c, a.Attachments)
	if err != nil {
		return 0, err
	}
	for i, f := range files {
		if i >= len(a.Filenames) || f.Filename != a.Filenames[i] {
			return 0, fmt.Errorf("attachment filename changed; propose again")
		}
	}
	// Blob uploads are external writes: this code is reached only from approved
	// apply, never from a model read or proposal. No arbitrary source URLs.
	for _, f := range a.GeneratedFiles {
		attachment, e := c.uploadTicketText(ctx, f)
		if e != nil {
			return 0, e
		}
		files = append(files, attachment)
	}
	if a.Kind == "public_reply" {
		// Attachment resolution can take time; re-check delivery identity immediately
		// before sending, not merely before reading the attachment sources.
		current, err = c.ticketPrecheck(ctx, a)
		if err != nil {
			return 0, err
		}
	}
	if a.Operation == "create" || a.Operation == "entry" {
		typ, parent, id := uint16(13), uint16(0), uint64(0)
		if a.Operation == "entry" {
			typ = 14
			parent = 2
			id = current.AssetID
		}
		var guard []int64
		if a.Kind == "public_reply" {
			guard = []int64{current.UpdatedAt}
		}
		asset, e := c.createAssetAttachments(ctx, 0, typ, parent, id, string(preview), a.Content, files, guard...)
		if e != nil {
			return 0, e
		}
		return asset.AssetID, nil
	}
	var body []byte
	var opcode uint8
	if a.Operation == "delete" {
		opcode = protocol.TransactionOpAssetDelete
		body, err = protocol.EncodeTransactionDelete(protocol.TransactionDelete{ConvID: 0, Entity: protocol.Existing(protocol.TransactionEntityAsset, current.AssetID), IfUpdatedAt: current.UpdatedAt}, protocol.TransactionEntityAsset)
	} else {
		opcode = protocol.TransactionOpAssetPatch
		// Preview-only patch is essential: the server preserves payload and attachments atomically.
		body, err = protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{ConvID: 0, Asset: protocol.Existing(protocol.TransactionEntityAsset, current.AssetID), IfUpdatedAt: current.UpdatedAt, Present: protocol.TransactionAssetPatchPreview, Preview: preview})
	}
	if err != nil {
		return 0, err
	}
	v, err := c.correlatedDataRead(ctx, 0, protocol.C_ApplyTransaction, func(id uint32) ([]byte, error) {
		return protocol.EncodeApplyTransaction(id, []protocol.TransactionOperation{{Type: opcode, Body: body}})
	}, true)
	if err != nil {
		return 0, err
	}
	r := v.(*protocol.TransactionResult)
	if r.Status != protocol.TransactionStatusCommitted {
		return 0, fmt.Errorf("ticket transaction rejected (conflict or validation), operation %d; reload and propose again", r.FailedOperation)
	}
	return current.AssetID, nil
}
func applyTicketAction(ctx context.Context, c *NRCClient, store *AgentSessionStore, p actionToApply, result *askApplyResponse) {
	if p.Action.Ticket == nil {
		return
	}
	id, err := c.applyTicket(ctx, *p.Action.Ticket)
	done, _ := store.completeAction(p.SessionID, p.PlanID, p.Action.ID, err, func(a *ProposedAction) { a.TicketResultID = strconv.FormatUint(id, 10) })
	if err != nil {
		result.Failed = append(result.Failed, applyActionFailure{ActionID: done.ID, Type: done.Type, Error: err.Error()})
		return
	}
	result.Applied = append(result.Applied, applyActionResult{ActionID: done.ID, Type: done.Type, Status: done.Status, TicketAssetID: strconv.FormatUint(id, 10)})
}

func (c *NRCClient) uploadTicketText(ctx context.Context, f ticketGeneratedFile) (protocol.Attachment, error) {
	if c.filesURL == "" || c.botSecret == "" {
		return protocol.Attachment{}, fmt.Errorf("private file service unavailable")
	}
	u, err := url.Parse(strings.TrimRight(c.filesURL, "/") + "/upload")
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return protocol.Attachment{}, fmt.Errorf("invalid private file service")
	}
	q := u.Query()
	q.Set("workspace", c.workspace)
	u.RawQuery = q.Encode()
	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	part, err := form.CreateFormFile("file", f.Filename)
	if err != nil {
		return protocol.Attachment{}, err
	}
	if _, err = io.WriteString(part, f.Content); err != nil {
		return protocol.Attachment{}, err
	}
	if err = form.Close(); err != nil {
		return protocol.Attachment{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), &body)
	if err != nil {
		return protocol.Attachment{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.botSecret)
	req.Header.Set("Content-Type", form.FormDataContentType())
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return protocol.Attachment{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return protocol.Attachment{}, fmt.Errorf("private blob upload failed (HTTP %d)", resp.StatusCode)
	}
	var ack struct {
		FileID, Filename, MimeType string
		Size, UploadedAt           int64
	}
	if err = json.NewDecoder(io.LimitReader(resp.Body, 8192)).Decode(&ack); err != nil {
		return protocol.Attachment{}, err
	}
	if !aiAttachmentID.MatchString(ack.FileID) || ack.Filename != f.Filename || ack.Size != int64(len(f.Content)) || len(ack.MimeType) > 100 {
		return protocol.Attachment{}, fmt.Errorf("invalid blob upload acknowledgement")
	}
	return protocol.Attachment{FileId: ack.FileID, Filename: ack.Filename, Size: ack.Size, MimeType: ack.MimeType, UploadedAt: ack.UploadedAt}, nil
}
