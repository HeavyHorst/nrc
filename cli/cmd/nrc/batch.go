package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

type batchDocument struct {
	Room       string           `json:"room,omitempty"`
	Operations []batchOperation `json:"operations"`
}
type batchOperation struct {
	Op           string          `json:"op"`
	Ref          string          `json:"ref,omitempty"`
	Room         string          `json:"room,omitempty"`
	ID           json.Number     `json:"id,omitempty"`
	SourceID     json.Number     `json:"source_id,omitempty"`
	TargetID     json.Number     `json:"target_id,omitempty"`
	SourceRef    string          `json:"source_ref,omitempty"`
	TargetRef    string          `json:"target_ref,omitempty"`
	ParentID     json.Number     `json:"parent_id,omitempty"`
	ParentRef    string          `json:"parent_ref,omitempty"`
	ParentType   string          `json:"parent_type,omitempty"`
	BlockedByID  json.Number     `json:"blocked_by_id,omitempty"`
	BlockedByRef string          `json:"blocked_by_ref,omitempty"`
	IfUpdatedAt  *int64          `json:"if_updated_at,omitempty"`
	Title        *string         `json:"title,omitempty"`
	Description  *string         `json:"description,omitempty"`
	Project      *string         `json:"project,omitempty"`
	Status       string          `json:"status,omitempty"`
	Priority     *int            `json:"priority,omitempty"`
	SourceType   string          `json:"source_type,omitempty"`
	TargetType   string          `json:"target_type,omitempty"`
	Relation     string          `json:"relation,omitempty"`
	AssetType    *int            `json:"asset_type,omitempty"`
	Preview      *string         `json:"preview,omitempty"`
	Content      *string         `json:"content,omitempty"`
	Tags         []string        `json:"tags,omitempty"`
	Format       *string         `json:"format,omitempty"`
	Attachments  json.RawMessage `json:"attachments,omitempty"`
}
type batchResult struct {
	Index    int         `json:"index"`
	Ref      string      `json:"ref,omitempty"`
	Op       string      `json:"op"`
	OK       bool        `json:"ok"`
	ID       uint64      `json:"id,omitempty"`
	Resource any         `json:"resource,omitempty"`
	Error    *batchError `json:"error,omitempty"`
	Skipped  bool        `json:"skipped,omitempty"`
}
type batchError struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}
type batchEnvelope struct {
	Atomic          bool              `json:"atomic"`
	Committed       *bool             `json:"committed,omitempty"`
	FailedOperation *uint16           `json:"failed_operation,omitempty"`
	UnknownOutcome  bool              `json:"unknown_outcome,omitempty"`
	Refs            map[string]uint64 `json:"refs,omitempty"`
	Results         []batchResult     `json:"results"`
}

// batchUpdateString implements the server's exact update sentinel contract.
func batchUpdateString(value *string) string {
	if value == nil {
		return ""
	}
	if *value == "" {
		return "\x00"
	}
	return *value
}

func validateBatch(d batchDocument) error {
	if d.Room != "" {
		return fmt.Errorf("room is only supported for chat; batches are workspace-wide")
	}
	if len(d.Operations) == 0 {
		return fmt.Errorf("operations must contain at least one operation")
	}
	refs := map[string]bool{}
	for i, o := range d.Operations {
		if o.Room != "" {
			return fmt.Errorf("operation %d: room is only supported for chat", i)
		}
		if o.Ref != "" {
			if refs[o.Ref] {
				return fmt.Errorf("operation %d: duplicate ref %q", i, o.Ref)
			}
			refs[o.Ref] = true
		}
	}
	return nil
}

func validateBatchOperation(o batchOperation) error {
	if o.IfUpdatedAt != nil {
		switch o.Op {
		case "task.update", "note.update", "asset.update", "task.delete", "note.delete", "asset.delete":
		default:
			return fmt.Errorf("if_updated_at is only valid for task and note/asset updates and deletes")
		}
	}
	validPriority := func() error {
		if o.Priority != nil && (*o.Priority < 0 || *o.Priority > 254) {
			return fmt.Errorf("priority must be between 0 and 254")
		}
		return nil
	}
	switch o.Op {
	case "task.create":
		if o.Title == nil || strings.TrimSpace(*o.Title) == "" {
			return fmt.Errorf("title is required")
		}
		return validPriority()
	case "task.update", "task.delete", "edge.delete":
		if o.ID == "" {
			return fmt.Errorf("id is required")
		}
		if _, err := numberID(o.ID); err != nil {
			return fmt.Errorf("invalid id: %w", err)
		}
		if o.Op == "task.update" {
			if err := validPriority(); err != nil {
				return err
			}
			if o.Status != "" {
				if _, err := parseTaskStatusFlag(o.Status); err != nil {
					return err
				}
			}
			if o.Title == nil && o.Description == nil && o.Project == nil && o.Status == "" && o.Priority == nil {
				return fmt.Errorf("task.update must specify at least one mutable field")
			}
		}
	case "edge.create":
		if _, err := numberID(o.SourceID); err != nil {
			return fmt.Errorf("invalid source_id: %w", err)
		}
		if _, err := numberID(o.TargetID); err != nil {
			return fmt.Errorf("invalid target_id: %w", err)
		}
		if targetTypeCodes[o.SourceType] == 0 || targetTypeCodes[o.TargetType] == 0 {
			return fmt.Errorf("invalid source_type or target_type")
		}
		if relationCodes[o.Relation] == 0 {
			return fmt.Errorf("invalid relation")
		}
	default:
		return fmt.Errorf("unsupported op %q", o.Op)
	}
	return nil
}
func numberID(n json.Number) (uint64, error) { return strconv.ParseUint(string(n), 10, 64) }

type atomicRefDefinition struct {
	index  int
	entity uint8
}

func hydrateAtomicNoteMetadata(s *conn.Session, d *batchDocument, room func(string) (int64, error)) error {
	for i := range d.Operations {
		o := &d.Operations[i]
		if o.Op != "note.update" || (o.Title == nil && o.Project == nil && o.Tags == nil && o.Format == nil) {
			continue
		}
		id, err := numberID(o.ID)
		if err != nil {
			return fmt.Errorf("operation %d: id is required", i)
		}
		roomName := o.Room
		if roomName == "" {
			roomName = d.Room
		}
		convID, err := room(roomName)
		if err != nil {
			return fmt.Errorf("operation %d: %w", i, err)
		}
		resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_GetAsset, Data: protocol.EncodeGetAsset(convID, id)})
		if err != nil {
			return fmt.Errorf("operation %d: fetch note: %w", i, err)
		}
		if resp.Opcode != protocol.S_AssetFull {
			return fmt.Errorf("operation %d: unexpected note response %d", i, resp.Opcode)
		}
		existing, err := protocol.DecodeAssetFull(resp.Data)
		if err != nil || existing.AssetType != protocol.AssetTypeNote {
			return fmt.Errorf("operation %d: asset %d is not a readable note", i, id)
		}
		meta := parseNotePreviewJSON(existing.Preview)
		title, project, tags, format := meta.Title, meta.Project, normalizeNoteTags(meta.Tags), meta.Format
		if o.Title != nil {
			title = *o.Title
		}
		if o.Project != nil {
			project = *o.Project
		}
		if o.Tags != nil {
			tags = normalizeNoteTags(o.Tags)
		}
		if o.Format != nil {
			format, err = normalizeNoteFormat(*o.Format)
			if err != nil {
				return fmt.Errorf("operation %d: %w", i, err)
			}
		}
		content := existing.Payload
		if o.Content != nil {
			content = *o.Content
		}
		preview := makeNotePreview(title, content, project, tags, format)
		o.Preview = &preview
		if o.IfUpdatedAt == nil {
			updatedAt := existing.UpdatedAt
			o.IfUpdatedAt = &updatedAt
		}
		o.Title, o.Project, o.Tags, o.Format = nil, nil, nil, nil
	}
	return nil
}

func compileAtomicBatch(d batchDocument, room func(string) (int64, error)) ([]protocol.TransactionOperation, map[string]atomicRefDefinition, error) {
	if len(d.Operations) > protocol.MaxTransactionOperations {
		return nil, nil, fmt.Errorf("operations exceeds maximum %d", protocol.MaxTransactionOperations)
	}
	defs := map[string]atomicRefDefinition{}
	for i, o := range d.Operations {
		if o.IfUpdatedAt != nil {
			switch o.Op {
			case "task.update", "note.update", "asset.update", "task.delete", "note.delete", "asset.delete":
			default:
				return nil, nil, fmt.Errorf("operation %d: if_updated_at is only valid for task and note/asset updates and deletes", i)
			}
		}
		if o.Ref == "" {
			continue
		}
		var e uint8
		switch o.Op {
		case "task.create":
			e = protocol.TransactionEntityTask
		case "note.create", "asset.create":
			e = protocol.TransactionEntityAsset
		case "edge.create":
			e = protocol.TransactionEntityEdge
		default:
			return nil, nil, fmt.Errorf("operation %d: ref is only valid on create operations", i)
		}
		if _, ok := defs[o.Ref]; ok {
			return nil, nil, fmt.Errorf("operation %d: duplicate ref %q", i, o.Ref)
		}
		defs[o.Ref] = atomicRefDefinition{i, e}
	}
	resolve := func(name string, id json.Number, entity uint8) (protocol.TransactionReference, error) {
		if name != "" && id != "" {
			return protocol.TransactionReference{}, fmt.Errorf("specify either symbolic ref or numeric ID, not both")
		}
		if name != "" {
			d, ok := defs[name]
			if !ok {
				return protocol.TransactionReference{}, fmt.Errorf("missing ref %q", name)
			}
			if d.entity != entity {
				return protocol.TransactionReference{}, fmt.Errorf("ref %q has incompatible entity type", name)
			}
			return protocol.CreatedBy(entity, uint64(d.index)), nil
		}
		if id == "" {
			return protocol.Existing(entity, 0), nil
		}
		v, e := numberID(id)
		if e != nil || v == 0 {
			return protocol.TransactionReference{}, fmt.Errorf("invalid existing ID")
		}
		return protocol.Existing(entity, v), nil
	}
	ops := make([]protocol.TransactionOperation, 0, len(d.Operations))
	for i, o := range d.Operations {
		rn := o.Room
		if rn == "" {
			rn = d.Room
		}
		cid, e := room(rn)
		if e != nil {
			return nil, nil, fmt.Errorf("operation %d: %w", i, e)
		}
		conv := uint64(cid)
		var typ uint8
		var body []byte
		switch o.Op {
		case "task.create":
			if o.Title == nil || strings.TrimSpace(*o.Title) == "" {
				e = fmt.Errorf("title is required")
				break
			}
			status := uint8(protocol.TaskStatusBacklog)
			if o.Status != "" {
				var s int32
				s, e = parseTaskStatusFlag(o.Status)
				status = uint8(s)
			}
			p := 0
			if o.Priority != nil {
				p = *o.Priority
				if p < 0 || p > 254 {
					e = fmt.Errorf("priority must be between 0 and 254")
					break
				}
			}
			blocked := protocol.Existing(protocol.TransactionEntityTask, 0)
			if e == nil && (o.BlockedByRef != "" || o.BlockedByID != "") {
				blocked, e = resolve(o.BlockedByRef, o.BlockedByID, protocol.TransactionEntityTask)
			}
			desc, project := "", ""
			if o.Description != nil {
				desc = *o.Description
			}
			if o.Project != nil {
				project = *o.Project
			}
			if e == nil {
				body, e = protocol.EncodeTransactionTaskCreate(protocol.TransactionTaskCreate{ConvID: conv, Status: status, Priority: uint8(p), BlockedBy: blocked, Title: *o.Title, Description: desc, Project: project})
			}
			typ = protocol.TransactionOpTaskCreate
		case "task.update":
			id, er := numberID(o.ID)
			if er != nil {
				e = fmt.Errorf("id is required")
				break
			}
			v := protocol.TransactionTaskPatch{ConvID: conv, Task: protocol.Existing(protocol.TransactionEntityTask, id)}
			if o.IfUpdatedAt != nil {
				v.IfUpdatedAt = *o.IfUpdatedAt
			}
			if o.Title != nil {
				v.Present |= protocol.TransactionTaskPatchTitle
				v.Title = *o.Title
			}
			if o.Description != nil {
				v.Present |= protocol.TransactionTaskPatchDescription
				v.Description = *o.Description
			}
			if o.Project != nil {
				v.Present |= protocol.TransactionTaskPatchProject
				v.Project = *o.Project
			}
			if o.Status != "" {
				s, er := parseTaskStatusFlag(o.Status)
				if er != nil {
					e = er
					break
				}
				v.Present |= protocol.TransactionTaskPatchStatus
				v.Status = uint8(s)
			}
			if o.Priority != nil {
				if *o.Priority < 0 || *o.Priority > 254 {
					e = fmt.Errorf("priority must be between 0 and 254")
					break
				}
				v.Present |= protocol.TransactionTaskPatchPriority
				v.Priority = uint8(*o.Priority)
			}
			if o.BlockedByRef != "" || o.BlockedByID != "" {
				v.Present |= protocol.TransactionTaskPatchBlockedBy
				if o.BlockedByRef == "" && string(o.BlockedByID) == "0" {
					v.BlockedBy = protocol.Existing(protocol.TransactionEntityTask, 0)
				} else {
					v.BlockedBy, e = resolve(o.BlockedByRef, o.BlockedByID, protocol.TransactionEntityTask)
					if e != nil {
						break
					}
				}
			}
			body, e = protocol.EncodeTransactionTaskPatch(v)
			typ = protocol.TransactionOpTaskPatch
		case "task.delete", "note.delete", "asset.delete", "edge.delete":
			id, er := numberID(o.ID)
			if er != nil {
				e = fmt.Errorf("id is required")
				break
			}
			entity := protocol.TransactionEntityTask
			typ = protocol.TransactionOpTaskDelete
			if o.Op == "note.delete" || o.Op == "asset.delete" {
				entity = protocol.TransactionEntityAsset
				typ = protocol.TransactionOpAssetDelete
			}
			if o.Op == "edge.delete" {
				entity = protocol.TransactionEntityEdge
				typ = protocol.TransactionOpEdgeDelete
			}
			ifUpdatedAt := int64(0)
			if o.IfUpdatedAt != nil {
				ifUpdatedAt = *o.IfUpdatedAt
			}
			body, e = protocol.EncodeTransactionDelete(protocol.TransactionDelete{ConvID: conv, Entity: protocol.Existing(entity, id), IfUpdatedAt: ifUpdatedAt}, entity)
		case "note.create", "asset.create":
			if len(o.Attachments) > 0 {
				e = fmt.Errorf("attachments are not supported by the atomic transaction asset schema")
				break
			}
			at := protocol.AssetTypeNote
			if o.Op == "asset.create" {
				if o.AssetType == nil {
					e = fmt.Errorf("asset_type is required")
					break
				}
				at = uint16(*o.AssetType)
			}
			payload := ""
			if o.Content != nil {
				payload = *o.Content
			}
			if o.Op == "asset.create" && o.Content == nil && o.Description != nil {
				payload = *o.Description
			}
			preview := ""
			if o.Preview != nil {
				preview = *o.Preview
			}
			if o.Op == "note.create" {
				if o.Title == nil {
					e = fmt.Errorf("title is required")
					break
				}
				project := ""
				if o.Project != nil {
					project = *o.Project
				}
				format := ""
				if o.Format != nil {
					format = *o.Format
				}
				preview = makeNotePreview(*o.Title, payload, project, normalizeNoteTags(o.Tags), format)
			}
			pt := uint16(protocol.ParentTypeNone)
			parent := protocol.Existing(protocol.TransactionEntityTask, 0)
			if o.ParentType != "" {
				switch o.ParentType {
				case "task":
					pt = protocol.ParentTypeTask
					parent, e = resolve(o.ParentRef, o.ParentID, protocol.TransactionEntityTask)
				case "asset", "note":
					pt = protocol.ParentTypeAsset
					parent, e = resolve(o.ParentRef, o.ParentID, protocol.TransactionEntityAsset)
				default:
					e = fmt.Errorf("invalid parent_type")
				}
			}
			if e == nil {
				body, e = protocol.EncodeTransactionAssetCreate(protocol.TransactionAssetCreate{ConvID: conv, AssetType: at, ParentType: pt, Parent: parent, PayloadRawLen: uint32(len(payload)), Preview: []byte(preview), Payload: []byte(payload)})
			}
			typ = protocol.TransactionOpAssetCreate
		case "note.update", "asset.update":
			if len(o.Attachments) > 0 {
				e = fmt.Errorf("attachments are not supported by the atomic transaction asset schema")
				break
			}
			if o.Title != nil || o.Project != nil || o.Tags != nil || o.Format != nil {
				e = fmt.Errorf("atomic note update cannot change title, project, tags, or format; provide preview and/or content directly")
				break
			}
			id, er := numberID(o.ID)
			if er != nil {
				e = fmt.Errorf("id is required")
				break
			}
			v := protocol.TransactionAssetPatch{ConvID: conv, Asset: protocol.Existing(protocol.TransactionEntityAsset, id)}
			if o.IfUpdatedAt != nil {
				v.IfUpdatedAt = *o.IfUpdatedAt
			}
			if o.Preview != nil {
				v.Present |= protocol.TransactionAssetPatchPreview
				v.Preview = []byte(*o.Preview)
			}
			if o.Content != nil {
				v.Present |= protocol.TransactionAssetPatchPayload
				v.Payload = []byte(*o.Content)
				v.PayloadRawLen = uint32(len(v.Payload))
			}
			body, e = protocol.EncodeTransactionAssetPatch(v)
			typ = protocol.TransactionOpAssetPatch
		case "edge.create":
			se := protocol.TransactionEntityTask
			if o.SourceType == "asset" || o.SourceType == "note" {
				se = protocol.TransactionEntityAsset
			}
			te := protocol.TransactionEntityTask
			if o.TargetType == "asset" || o.TargetType == "note" {
				te = protocol.TransactionEntityAsset
			}
			if targetTypeCodes[o.SourceType] == 0 && o.SourceType != "note" {
				e = fmt.Errorf("invalid source_type")
				break
			}
			if targetTypeCodes[o.TargetType] == 0 && o.TargetType != "note" {
				e = fmt.Errorf("invalid target_type")
				break
			}
			sr, er := resolve(o.SourceRef, o.SourceID, se)
			if er != nil {
				e = er
				break
			}
			tr, er := resolve(o.TargetRef, o.TargetID, te)
			if er != nil {
				e = er
				break
			}
			body, e = protocol.EncodeTransactionEdgeCreate(protocol.TransactionEdgeCreate{ConvID: conv, Source: sr, Target: tr, Relation: relationCodes[o.Relation]})
			typ = protocol.TransactionOpEdgeCreate
		default:
			e = fmt.Errorf("unsupported op %q", o.Op)
		}
		if e != nil {
			return nil, nil, fmt.Errorf("operation %d: %w", i, e)
		}
		ops = append(ops, protocol.TransactionOperation{Type: typ, Body: body})
	}
	return ops, defs, nil
}

var batchCmd = &cobra.Command{Use: "batch", Short: "Execute sequential or atomic task, asset, and edge operations"}
var batchApplyCmd = &cobra.Command{Use: "apply", Short: "Apply operations from a JSON document; use --atomic for one server transaction and symbolic references", Args: cobra.NoArgs, Run: func(cmd *cobra.Command, args []string) {
	path, _ := cmd.Flags().GetString("input")
	var r io.Reader = os.Stdin
	if path != "" {
		f, e := os.Open(path)
		if e != nil {
			conn.FatalInvalid("Invalid input: %v", e)
		}
		defer f.Close()
		r = f
	}
	dec := json.NewDecoder(r)
	dec.UseNumber()
	dec.DisallowUnknownFields()
	var doc batchDocument
	if err := dec.Decode(&doc); err != nil {
		conn.FatalInvalid("Invalid batch input: %v", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		if err == nil {
			err = fmt.Errorf("multiple JSON documents")
		}
		conn.FatalInvalid("Invalid batch input: trailing data: %v", err)
	}
	if err := validateBatch(doc); err != nil {
		conn.FatalInvalid("Invalid batch input: %v", err)
	}
	s, err := conn.Dial(doc.Room)
	if err != nil {
		conn.Fail(err)
	}
	defer s.Close()
	atomic, _ := cmd.Flags().GetBool("atomic")
	if atomic {
		resolveRoom := func(name string) (int64, error) {
			if name != "" {
				return 0, fmt.Errorf("room is only supported for chat")
			}
			return protocol.WorkspaceDataConvID, nil
		}
		if hydrateErr := hydrateAtomicNoteMetadata(s, &doc, resolveRoom); hydrateErr != nil {
			conn.FatalInvalid("Invalid atomic batch input: %v", hydrateErr)
		}
		ops, defs, compileErr := compileAtomicBatch(doc, resolveRoom)
		if compileErr != nil {
			conn.FatalInvalid("Invalid atomic batch input: %v", compileErr)
		}
		const correlationID = uint32(1)
		payload, encodeErr := protocol.EncodeApplyTransaction(correlationID, ops)
		if encodeErr != nil {
			conn.FatalInvalid("Invalid atomic batch input: %v", encodeErr)
		}
		resp, sendErr := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_ApplyTransaction, Data: payload})
		if sendErr != nil {
			var transportErr *conn.ConnectionError
			if errors.As(sendErr, &transportErr) {
				env := batchEnvelope{Atomic: true, UnknownOutcome: true, Results: []batchResult{}}
				if output.Human() {
					fmt.Printf("UNKNOWN OUTCOME: transaction request transport failed: %v\n", sendErr)
				} else {
					output.OutputJSON(env)
				}
				os.Exit(1)
			}
			conn.Fail(sendErr)
		}
		if resp.Opcode != protocol.S_TransactionResult {
			conn.Fail(fmt.Errorf("unexpected response: %d", resp.Opcode))
		}
		tr, decodeErr := protocol.DecodeTransactionResult(resp.Data)
		if decodeErr != nil || tr.CorrelationID != correlationID {
			if decodeErr == nil {
				decodeErr = fmt.Errorf("transaction correlation mismatch")
			}
			conn.Fail(decodeErr)
		}
		if tr.Status == protocol.TransactionStatusCommitted && len(tr.Results) != len(ops) {
			conn.Fail(fmt.Errorf("transaction result count mismatch"))
		}
		committed := tr.Status == protocol.TransactionStatusCommitted
		env := batchEnvelope{Atomic: true, Committed: &committed, Results: make([]batchResult, len(doc.Operations))}
		if !committed {
			env.FailedOperation = &tr.FailedOperation
		}
		if committed {
			env.Refs = map[string]uint64{}
			for i, r := range tr.Results {
				env.Results[i] = batchResult{Index: i, Ref: doc.Operations[i].Ref, Op: doc.Operations[i].Op, OK: true, ID: r.EntityID}
				if doc.Operations[i].Ref != "" {
					env.Refs[doc.Operations[i].Ref] = r.EntityID
				}
			}
			_ = defs
		} else {
			for i, o := range doc.Operations {
				env.Results[i] = batchResult{Index: i, Ref: o.Ref, Op: o.Op, Skipped: true}
				if i == int(tr.FailedOperation) {
					env.Results[i].Skipped = false
					env.Results[i].Error = &batchError{Code: "transaction_rejected", Message: "server rejected atomic transaction"}
				}
			}
		}
		if output.Human() {
			if committed {
				fmt.Println("COMMITTED")
				for n, id := range env.Refs {
					fmt.Printf("%s=%d\n", n, id)
				}
			} else {
				fmt.Printf("REJECTED failed_operation=%d\n", tr.FailedOperation)
			}
		} else {
			output.OutputJSON(env)
		}
		if !committed {
			os.Exit(1)
		}
		return
	}
	results := make([]batchResult, 0, len(doc.Operations))
	failed := false
	connectionBroken := false
	for i, o := range doc.Operations {
		res := batchResult{Index: i, Ref: o.Ref, Op: o.Op}
		if connectionBroken {
			res.Skipped = true
			res.Error = &batchError{Code: "skipped", Message: "not executed because the batch connection is no longer safe"}
			results = append(results, res)
			continue
		}
		if validationErr := validateBatchOperation(o); validationErr != nil {
			failed = true
			res.Error = &batchError{Code: "invalid_argument", Message: validationErr.Error()}
			results = append(results, res)
			continue
		}
		roomID := s.RoomID
		if o.Room != "" {
			roomID, err = conn.ResolveRoomFlag(s.Config.WorkspaceID, o.Room)
		}
		if err != nil {
			failed = true
			res.Error = &batchError{Code: "invalid_argument", Message: err.Error()}
			results = append(results, res)
			err = nil
			continue
		}
		if err == nil {
			var msg *protocol.Message
			var expected uint16
			var expectedSourceID, expectedTargetID uint64
			switch o.Op {
			case "task.create":
				p := 0
				if o.Priority != nil {
					p = *o.Priority
				}
				description, project := "", ""
				if o.Description != nil {
					description = *o.Description
				}
				if o.Project != nil {
					project = *o.Project
				}
				msg = &protocol.Message{Opcode: protocol.C_CreateTask, Data: protocol.EncodeTaskCreateFullWithCorrelation(roomID, *o.Title, description, int32(p), project, nil, uint32(i+1))}
				expected = protocol.S_TaskCreated
			case "task.update":
				var id uint64
				id, err = numberID(o.ID)
				if err == nil {
					res.ID = id
					status := int32(255)
					if o.Status != "" {
						status, err = parseTaskStatusFlag(o.Status)
					}
					p := int32(255)
					if o.Priority != nil {
						p = int32(*o.Priority)
					}
					title, description, project := batchUpdateString(o.Title), batchUpdateString(o.Description), batchUpdateString(o.Project)
					msg = &protocol.Message{Opcode: protocol.C_UpdateTask, Data: protocol.EncodeTaskUpdateFullWithProjectAndCorrelation(roomID, int64(id), title, description, uint8(status), "", uint8(p), protocol.TaskColorNone, "", 0, 0, nil, project, uint32(i+1))}
					expected = protocol.S_TaskUpdated
				}
			case "task.delete":
				var id uint64
				id, err = numberID(o.ID)
				if err == nil {
					msg = &protocol.Message{Opcode: protocol.C_DeleteTask, Data: protocol.EncodeTaskDeleteWithCorrelation(roomID, int64(id), uint32(i+1))}
					expected = protocol.S_TaskDeleted
					res.ID = id
				}
			case "edge.create":
				var sid, tid uint64
				sid, err = numberID(o.SourceID)
				if err == nil {
					tid, err = numberID(o.TargetID)
				}
				if err == nil {
					expectedSourceID, expectedTargetID = sid, tid
					msg = &protocol.Message{Opcode: protocol.C_CreateEdge, Data: protocol.EncodeCreateEdgeWithCorrelation(roomID, targetTypeCodes[o.SourceType], sid, targetTypeCodes[o.TargetType], tid, relationCodes[o.Relation], uint32(i+1))}
					expected = protocol.S_EdgeCreated
				}
			case "edge.delete":
				var id uint64
				id, err = numberID(o.ID)
				if err == nil {
					msg = &protocol.Message{Opcode: protocol.C_DeleteEdge, Data: protocol.EncodeDeleteEdgeWithCorrelation(roomID, id, uint32(i+1))}
					expected = protocol.S_EdgeDeleted
					res.ID = id
				}
			}
			if err == nil {
				var resp *protocol.Message
				resp, err = s.SendAndRecv(msg)
				if err == nil && resp.Opcode != expected {
					err = fmt.Errorf("unexpected response: %d", resp.Opcode)
				}
				if err == nil && o.Op == "task.create" {
					var c *protocol.TaskCreatedResponse
					c, err = protocol.DecodeTaskCreated(resp.Data)
					if err == nil {
						if c.CorrelationID != uint32(i+1) || c.Task.ConvID != roomID {
							err = fmt.Errorf("task create response mismatch")
						}
						res.ID = c.Task.ID
						res.Resource = taskResource(c.Task, s.Config.GetProxyURL())
					}
				}
				if err == nil && o.Op == "task.update" {
					var updated *protocol.TaskUpdatedResponse
					updated, err = protocol.DecodeTaskUpdated(resp.Data)
					if err == nil {
						if updated.CorrelationID != uint32(i+1) || updated.Task.ID != res.ID || updated.Task.ConvID != roomID {
							err = fmt.Errorf("task update response mismatch")
						}
						res.Resource = taskResource(updated.Task, s.Config.GetProxyURL())
					}
				}
				if err == nil && o.Op == "edge.create" {
					var c *protocol.EdgeCreatedResponse
					c, err = protocol.DecodeEdgeCreated(resp.Data)
					if err == nil {
						if c.CorrelationID != uint32(i+1) || c.Edge.ConvID != uint64(roomID) || c.Edge.SourceID != expectedSourceID || c.Edge.TargetID != expectedTargetID || c.Edge.SourceType != targetTypeCodes[o.SourceType] || c.Edge.TargetType != targetTypeCodes[o.TargetType] || c.Edge.Relation != relationCodes[o.Relation] {
							err = fmt.Errorf("edge create correlation mismatch")
						}
						res.ID = c.Edge.EdgeID
						res.Resource = edgeResource(c.Edge)
					}
				}
				if err == nil && o.Op == "task.delete" {
					d, decodeErr := protocol.DecodeTaskDeleted(resp.Data)
					err = decodeErr
					if err == nil && (d.TaskID != res.ID || d.ConvID != uint64(roomID) || d.CorrelationID != uint32(i+1)) {
						err = fmt.Errorf("task delete response mismatch")
					}
				}
				if err == nil && o.Op == "edge.delete" {
					d, decodeErr := protocol.DecodeEdgeDeleted(resp.Data)
					err = decodeErr
					if err == nil && (d.EdgeID != res.ID || d.ConvID != uint64(roomID) || d.CorrelationID != uint32(i+1)) {
						err = fmt.Errorf("edge delete response mismatch")
					}
				}
			}
		}
		if err != nil {
			failed = true
			classification := conn.Classify(err)
			code := classification.Code
			var connectionErr *conn.ConnectionError
			if errors.As(err, &connectionErr) {
				connectionBroken = true
			}
			if code == "unexpected_response" {
				connectionBroken = true
			}
			res.Error = &batchError{Code: code, Message: err.Error(), Retryable: classification.Retryable}
		} else {
			res.OK = true
		}
		results = append(results, res)
		err = nil
	}
	if output.Human() {
		for _, result := range results {
			state := "OK"
			if result.Skipped {
				state = "SKIPPED"
			} else if !result.OK {
				state = "FAILED"
			}
			fmt.Printf("[%d] %-12s %-7s", result.Index, result.Op, state)
			if result.ID != 0 {
				fmt.Printf(" id=%d", result.ID)
			}
			if result.Error != nil {
				fmt.Printf(" %s", result.Error.Message)
			}
			fmt.Println()
		}
	} else {
		output.OutputJSON(batchEnvelope{Atomic: false, Results: results})
	}
	if failed {
		os.Exit(1)
	}
}}

func taskResource(t *protocol.Task, proxyURL string) output.Task {
	return output.Task{ID: t.ID, Title: t.Title, Description: t.Description, Status: output.StatusName(int32(t.Status)), Priority: strconv.Itoa(int(t.Priority)), Project: t.Project, BlockedBy: t.BlockedBy, CreatedBy: t.CreatedBy, Timestamp: t.CreatedAt, Attachments: toOutputAttachments(t.Attachments, proxyURL)}
}

func init() {
	batchApplyCmd.Annotations = map[string]string{"mutation": "true"}
	batchApplyCmd.Flags().String("input", "", "Read JSON input from file (default: stdin)")
	batchApplyCmd.Flags().Bool("atomic", false, "Apply all operations in one atomic transaction")
	batchCmd.AddCommand(batchApplyCmd)
	rootCmd.AddCommand(batchCmd)
}
