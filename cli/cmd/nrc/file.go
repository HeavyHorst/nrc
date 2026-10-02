package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/heavyhorst/nrc/cli/pkg/upload"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

// File metadata lives in the payload; the preview is only a short register entry.
// RawMessage keeps extension fields and large integers lossless during edits.
func fileMetadata(a protocol.Asset) (map[string]json.RawMessage, map[string]json.RawMessage, error) {
	p, err := customerMetadata(a.Preview)
	if err != nil {
		return nil, nil, err
	}
	body, err := protocol.DecodeAssetPayload(a)
	if err != nil {
		return nil, nil, err
	}
	m, err := customerMetadata(body)
	if err != nil {
		return nil, nil, err
	}
	if string(m["type"]) != `"file"` {
		return nil, nil, fmt.Errorf("unsupported File metadata type")
	}
	return p, m, nil
}

func fileContent(cmd *cobra.Command, preview, metadata map[string]json.RawMessage) (string, string, error) {
	for _, name := range []string{"title", "description", "category"} {
		if cmd.Flags().Changed(name) {
			value, _ := cmd.Flags().GetString(name)
			if name == "title" {
				value = strings.TrimSpace(value)
			}
			metadata[name], _ = json.Marshal(value)
		}
	}
	if cmd.Flags().Changed("tag") {
		tags, _ := cmd.Flags().GetStringSlice("tag")
		clean := []string{}
		for _, tag := range tags {
			if tag = strings.TrimSpace(tag); tag != "" {
				clean = append(clean, tag)
			}
		}
		metadata["tags"], _ = json.Marshal(clean)
	}
	var title string
	_ = json.Unmarshal(metadata["title"], &title)
	if strings.TrimSpace(title) == "" {
		return "", "", fmt.Errorf("title must not be blank")
	}
	preview["title"], preview["category"] = metadata["title"], metadata["category"]
	p, err := json.Marshal(preview)
	if err != nil {
		return "", "", err
	}
	m, err := json.Marshal(metadata)
	if err != nil {
		return "", "", err
	}
	if len(p) > protocol.MaxPreviewLength || len(m) > 65535 {
		return "", "", fmt.Errorf("File metadata exceeds protocol limits")
	}
	return string(p), string(m), nil
}

func fileOutput(a protocol.Asset, proxy, operation string) error {
	_, metadata, err := fileMetadata(a)
	if err != nil {
		return err
	}
	r := struct {
		ID          uint64                     `json:"id"`
		Type        string                     `json:"type"`
		Metadata    map[string]json.RawMessage `json:"metadata"`
		Attachments []output.Attachment        `json:"attachments"`
		UpdatedAt   int64                      `json:"updated_at"`
	}{a.AssetID, "file", metadata, toOutputAttachments(a.Attachments, proxy), a.UpdatedAt}
	if operation != "" {
		output.Mutation(operation, "file", a.AssetID, fmt.Sprintf("file %s: %d", operation, a.AssetID), r, nil)
	} else if output.Human() {
		fmt.Printf("FILE %d\n%s\n", r.ID, r.Metadata["title"])
		printNoteAttachments(a.Attachments, proxy)
	} else {
		output.OutputJSON(r)
	}
	return nil
}

func newFileCommand() *cobra.Command {
	group := &cobra.Command{Use: "file", Short: "Manage reusable File assets; use attachments for inline supporting material"}
	get := &cobra.Command{Use: "get <id>", Short: "Read full File metadata and attachment download URLs", Args: cobra.ExactArgs(1)}
	get.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		id, err := customerID(args[0])
		if err != nil {
			return err
		}
		a, err := customerAsset(s, id, protocol.AssetTypeFile)
		if err != nil {
			return err
		}
		return fileOutput(a, s.Config.GetProxyURL(), "")
	})
	group.AddCommand(get, fileListCommand())
	for _, action := range []string{"upload", "update"} {
		action := action
		use := "update <id>"
		if action == "upload" {
			use = "upload <path>"
		}
		cmd := &cobra.Command{Use: use, Short: action + " File metadata (link separately using customer/edge commands)", Args: cobra.ExactArgs(1), Annotations: map[string]string{"mutation": "true"}}
		for _, name := range []string{"title", "description", "category"} {
			cmd.Flags().String(name, "", "Set "+name+" (empty clears optional fields)")
		}
		cmd.Flags().StringSlice("tag", nil, "Replace tags; repeat or comma-separate; empty clears")
		cmd.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
			var a protocol.Asset
			var p, m map[string]json.RawMessage
			if action == "update" {
				id, err := customerID(args[0])
				if err != nil {
					return err
				}
				a, err = customerAsset(s, id, protocol.AssetTypeFile)
				if err != nil {
					return err
				}
				p, m, err = fileMetadata(a)
				if err != nil {
					return err
				}
			} else {
				p = map[string]json.RawMessage{"type": json.RawMessage(`"file"`), "version": json.RawMessage("1")}
				p["filename"], _ = json.Marshal(filepath.Base(args[0]))
				m = map[string]json.RawMessage{"type": json.RawMessage(`"file"`), "version": json.RawMessage("1"), "description": json.RawMessage(`""`), "category": json.RawMessage(`""`), "tags": json.RawMessage("[]")}
				m["title"], _ = json.Marshal(filepath.Base(args[0]))
			}
			preview, payload, err := fileContent(cmd, p, m)
			if err != nil {
				return &conn.InvalidArgumentError{Err: err}
			}
			if action == "upload" {
				att, err := upload.UploadFile(args[0], s.Config.GetProxyURL(), s.Config.WorkspaceID)
				if err != nil {
					return err
				}
				data, err := protocol.EncodeCreateAssetWithAttachmentsAndCorrelation(s.RoomID, protocol.AssetTypeFile, protocol.ParentTypeNone, 0, preview, payload, []protocol.Attachment{*att}, 1)
				if err != nil {
					return fmt.Errorf("binary uploaded as %s but asset not created: %w", att.FileId, err)
				}
				a, err = createUploadedFile(s, data, att.FileId)
				if err != nil {
					return err
				}
			} else {
				data, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{ConvID: uint64(s.RoomID), Asset: protocol.Existing(protocol.TransactionEntityAsset, a.AssetID), IfUpdatedAt: a.UpdatedAt, Present: protocol.TransactionAssetPatchPreview | protocol.TransactionAssetPatchPayload, Preview: []byte(preview), Payload: []byte(payload), PayloadRawLen: uint32(len(payload))})
				if err != nil {
					return err
				}
				_, err = customerTransaction(s, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetPatch, Body: data}})
				if err != nil {
					return err
				}
				a, err = readCommittedFile(s, a.AssetID)
				if err != nil {
					return err
				}
			}
			operation := "updated"
			if action == "upload" {
				operation = "created"
			}
			return fileOutput(a, s.Config.GetProxyURL(), operation)
		})
		group.AddCommand(cmd)
	}
	return group
}

func createUploadedFile(s *conn.Session, data []byte, binaryID string) (protocol.Asset, error) {
	unknown := func(err error) (protocol.Asset, error) {
		return protocol.Asset{}, &conn.CommandError{Err: fmt.Errorf("File creation unconfirmed (binary %s); inspect file list before retrying upload: %w", binaryID, err)}
	}
	resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_CreateAsset, Data: data})
	if err != nil {
		var rejected *conn.ServerError
		if errors.As(err, &rejected) {
			return protocol.Asset{}, fmt.Errorf("File creation rejected; binary %s was uploaded: %w", binaryID, err)
		}
		return unknown(err)
	}
	if resp.Opcode != protocol.S_AssetCreated {
		return unknown(fmt.Errorf("unexpected response %d", resp.Opcode))
	}
	created, err := protocol.DecodeAssetCreated(resp.Data)
	if err != nil {
		return unknown(err)
	}
	if created.CorrelationID != 1 {
		return unknown(fmt.Errorf("correlation mismatch"))
	}
	return created.Asset, nil
}

func readCommittedFile(s *conn.Session, id uint64) (protocol.Asset, error) {
	a, err := fetchAsset(s, id)
	if err != nil {
		return a, &conn.CommandError{Err: fmt.Errorf("File %d metadata committed; readback failed: %w", id, err)}
	}
	return a, nil
}

type fileHeader struct {
	ID        uint64 `json:"id"`
	Type      string `json:"type"`
	Preview   string `json:"preview"`
	UpdatedAt int64  `json:"updated_at"`
}

func fileListCommand() *cobra.Command {
	c := &cobra.Command{Use: "list", Short: "One page of room File headers; --all follows live cursors", Args: cobra.NoArgs}
	c.Flags().Int("page-size", 50, "Page size, 1–250")
	c.Flags().String("cursor", "", "Resume next_cursor in the same room")
	c.Flags().Bool("all", false, "Follow all pages (not a snapshot)")
	c.Run = customerRun(func(cmd *cobra.Command, _ []string, s *conn.Session) error {
		size, _ := cmd.Flags().GetInt("page-size")
		if size < 1 || size > 250 {
			return &conn.InvalidArgumentError{Err: fmt.Errorf("page-size must be 1–250")}
		}
		cursor, _ := cmd.Flags().GetString("cursor")
		all, _ := cmd.Flags().GetBool("all")
		entries := []fileHeader{}
		var total uint32
		var more bool
		for {
			var position noteCursor
			if cursor != "" {
				var err error
				position, err = decodeNoteCursor(cursor)
				if err != nil {
					return &conn.InvalidArgumentError{Err: err}
				}
			}
			resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_ListAssetsPaged, Data: protocol.EncodeListAssetsPaged(s.RoomID, protocol.AssetTypeFile, false, uint16(size), cursor != "", position.UpdatedAt, position.AssetID)})
			if err != nil {
				return err
			}
			if resp.Opcode != protocol.S_AssetListPage {
				return fmt.Errorf("unexpected File page response: %d", resp.Opcode)
			}
			page, err := protocol.DecodeAssetListPage(resp.Data)
			if err != nil {
				return err
			}
			if page.HasMore && (len(page.Assets) == 0 || (cursor != "" && (page.NextCursorUpdatedAt > position.UpdatedAt || (page.NextCursorUpdatedAt == position.UpdatedAt && page.NextCursorAssetID >= position.AssetID)))) {
				return fmt.Errorf("File cursor did not advance")
			}
			for _, a := range page.Assets {
				entries = append(entries, fileHeader{a.AssetID, "file", a.Preview, a.UpdatedAt})
			}
			total, more = page.TotalCount, page.HasMore
			cursor = ""
			if more {
				cursor = encodeNoteCursor(page.NextCursorUpdatedAt, page.NextCursorAssetID)
			}
			if !all || !more {
				break
			}
		}
		result := struct {
			Entries    []fileHeader `json:"entries"`
			TotalCount uint32       `json:"total_count"`
			HasMore    bool         `json:"has_more"`
			NextCursor string       `json:"next_cursor"`
		}{entries, total, more, cursor}
		if output.Human() {
			for _, a := range entries {
				fmt.Printf("%d\t%s\n", a.ID, a.Preview)
			}
			fmt.Printf("Loaded %d / %d; next cursor: %s\n", len(entries), total, cursor)
		} else {
			output.OutputJSON(result)
		}
		return nil
	})
	return c
}

func init() { rootCmd.AddCommand(newFileCommand()) }
