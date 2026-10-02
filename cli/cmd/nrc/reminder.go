package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

const reminderDefaultUrgencyDays = 3

const (
	reminderStateLate   = "LATE"
	reminderStateUrgent = "URGENT"
	reminderStateOpen   = "OPEN"
	reminderStateLocked = "LOCKED"
)

type reminderAssetPayload struct {
	Title             string `json:"title"`
	Name              string `json:"name"`
	WindowStart       string `json:"window_start_at"`
	WindowStartLegacy string `json:"windowStartAt"`
	Deadline          string `json:"deadline_at"`
	DeadlineLegacy    string `json:"deadlineAt"`
	UrgencyDays       int    `json:"urgency_days"`
	UrgencyDaysLegacy int    `json:"urgencyDays"`
	NoteAssetID       string `json:"note_asset_id"`
	NoteAssetIDLegacy string `json:"noteAssetId"`
}

type reminderEntry struct {
	ID           uint64 `json:"id"`
	Title        string `json:"title"`
	State        string `json:"state"`
	WindowStart  int64  `json:"window_start_at"`
	Deadline     int64  `json:"deadline_at"`
	UrgencyDays  int    `json:"urgency_days"`
	NoteAssetID  uint64 `json:"note_asset_id,omitempty"`
	Owner        string `json:"owner"`
	UpdatedAt    int64  `json:"updated_at"`
	UpdatedAtISO string `json:"updated_at_iso"`
}

var reminderCmd = &cobra.Command{
	Use:   "reminder",
	Short: "Manage reminders (assets)",
	Long:  "Manage reminders stored as assets (AssetType=6). Reminder state is derived from deadline/window/urgency fields.",
}

var reminderListCmd = &cobra.Command{
	Use:   "list",
	Short: "List reminders ordered by urgency state",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)
		hideLocked, _ := cmd.Flags().GetBool("hide-locked")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_ListAssets,
			Data:   protocol.EncodeListAssets(s.RoomID, true, protocol.AssetTypeReminder, true),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetList {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		assets, err := protocol.DecodeAssetList(resp.Data, true)
		if err != nil {
			conn.Fatal("Error parsing reminders: %v", err)
		}

		now := time.Now().UnixNano()
		entries := make([]reminderEntry, 0, len(assets))
		for _, asset := range assets {
			entry, ok := reminderAssetToEntry(asset, now)
			if !ok {
				continue
			}
			if hideLocked && entry.State == reminderStateLocked {
				continue
			}
			entries = append(entries, entry)
		}

		sort.Slice(entries, func(i, j int) bool {
			left := entries[i]
			right := entries[j]
			if stateRank(left.State) != stateRank(right.State) {
				return stateRank(left.State) < stateRank(right.State)
			}
			if left.Deadline != right.Deadline {
				if left.Deadline == 0 {
					return false
				}
				if right.Deadline == 0 {
					return true
				}
				return left.Deadline < right.Deadline
			}
			if left.WindowStart != right.WindowStart {
				if left.WindowStart == 0 {
					return false
				}
				if right.WindowStart == 0 {
					return true
				}
				return left.WindowStart < right.WindowStart
			}
			return strings.ToLower(left.Title) < strings.ToLower(right.Title)
		})

		if jsonOutput {
			output.OutputJSON(entries)
			return
		}

		outputReminderTable(entries)
	},
}

var reminderCreateCmd = &cobra.Command{
	Use:   "create <title>",
	Short: "Create a reminder",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		title := strings.TrimSpace(args[0])
		if title == "" {
			conn.FatalInvalid("Title is required")
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		deadlineRaw, _ := cmd.Flags().GetString("deadline")
		windowStartRaw, _ := cmd.Flags().GetString("window-start")
		urgencyDays, _ := cmd.Flags().GetInt("urgency-days")
		noteIDRaw, _ := cmd.Flags().GetString("note-id")

		deadline, err := parseDateOrNanos(deadlineRaw)
		if err != nil || deadline == 0 {
			conn.Fatal("Invalid deadline: use RFC3339 datetime or unix nanoseconds")
		}

		windowStart := int64(0)
		if windowStartRaw != "" && !strings.EqualFold(strings.TrimSpace(windowStartRaw), "none") {
			windowStart, err = parseDateOrNanos(windowStartRaw)
			if err != nil {
				conn.Fatal("Invalid window-start: use RFC3339 datetime or unix nanoseconds")
			}
		}

		noteID := uint64(0)
		if noteIDRaw != "" && !strings.EqualFold(strings.TrimSpace(noteIDRaw), "none") {
			noteID, err = strconv.ParseUint(strings.TrimSpace(noteIDRaw), 10, 64)
			if err != nil {
				conn.Fatal("Invalid note-id: %v", err)
			}
		}

		if err := validateReminderFields(title, deadline, windowStart, urgencyDays); err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		payload := buildReminderPayload(title, deadline, windowStart, urgencyDays, noteID)
		preview := buildReminderPreview(title, deadline)

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_CreateAsset,
			Data:   protocol.EncodeCreateAsset(s.RoomID, protocol.AssetTypeReminder, protocol.ParentTypeNone, 0, preview, payload),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetCreated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		created, err := protocol.DecodeAssetCreated(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing created reminder: %v", err)
		}

		output.PrintCreatedID("Reminder", created.Asset.AssetID)
	},
}

var reminderGetCmd = &cobra.Command{
	Use:   "get <id>",
	Short: "Get reminder details",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		reminderID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid reminder ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_GetAsset,
			Data:   protocol.EncodeGetAsset(s.RoomID, reminderID),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetFull {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		asset, err := protocol.DecodeAssetFull(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing asset: %v", err)
		}
		entry, ok := reminderAssetToEntry(asset, time.Now().UnixNano())
		if !ok {
			conn.Fatal("Asset #%d is not a valid reminder", reminderID)
		}

		if jsonOutput {
			output.OutputJSON(entry)
			return
		}

		fmt.Printf("ID:          %d\n", entry.ID)
		fmt.Printf("Title:       %s\n", entry.Title)
		fmt.Printf("State:       %s\n", entry.State)
		fmt.Printf("Window:      %s\n", formatTimestamp(entry.WindowStart))
		fmt.Printf("Deadline:    %s\n", formatTimestamp(entry.Deadline))
		fmt.Printf("Urgency:     %d day(s)\n", entry.UrgencyDays)
		if entry.NoteAssetID > 0 {
			fmt.Printf("Linked Note: %d\n", entry.NoteAssetID)
		} else {
			fmt.Printf("Linked Note: -\n")
		}
		fmt.Printf("Owner:       %s\n", entry.Owner)
		fmt.Printf("Updated:     %s\n", entry.UpdatedAtISO)
	},
}

var reminderUpdateCmd = &cobra.Command{
	Use:   "update <id>",
	Short: "Update reminder",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		reminderID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid reminder ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_GetAsset,
			Data:   protocol.EncodeGetAsset(s.RoomID, reminderID),
		})
		if err != nil {
			conn.Fatal("Error fetching reminder: %v", err)
		}
		if resp.Opcode != protocol.S_AssetFull {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		asset, err := protocol.DecodeAssetFull(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing reminder asset: %v", err)
		}

		entry, ok := reminderAssetToEntry(asset, time.Now().UnixNano())
		if !ok {
			conn.Fatal("Asset #%d is not a valid reminder", reminderID)
		}

		title := entry.Title
		if cmd.Flags().Changed("title") {
			title, _ = cmd.Flags().GetString("title")
			title = strings.TrimSpace(title)
		}

		deadline := entry.Deadline
		if cmd.Flags().Changed("deadline") {
			deadlineRaw, _ := cmd.Flags().GetString("deadline")
			deadline, err = parseDateOrNanos(deadlineRaw)
			if err != nil || deadline == 0 {
				conn.Fatal("Invalid deadline: use RFC3339 datetime or unix nanoseconds")
			}
		}

		windowStart := entry.WindowStart
		if cmd.Flags().Changed("window-start") {
			windowStartRaw, _ := cmd.Flags().GetString("window-start")
			if strings.TrimSpace(windowStartRaw) == "" || strings.EqualFold(strings.TrimSpace(windowStartRaw), "none") {
				windowStart = 0
			} else {
				windowStart, err = parseDateOrNanos(windowStartRaw)
				if err != nil {
					conn.Fatal("Invalid window-start: use RFC3339 datetime or unix nanoseconds")
				}
			}
		}

		urgencyDays := entry.UrgencyDays
		if cmd.Flags().Changed("urgency-days") {
			urgencyDays, _ = cmd.Flags().GetInt("urgency-days")
		}

		noteID := entry.NoteAssetID
		if cmd.Flags().Changed("note-id") {
			noteIDRaw, _ := cmd.Flags().GetString("note-id")
			if strings.TrimSpace(noteIDRaw) == "" || strings.EqualFold(strings.TrimSpace(noteIDRaw), "none") {
				noteID = 0
			} else {
				noteID, err = strconv.ParseUint(strings.TrimSpace(noteIDRaw), 10, 64)
				if err != nil {
					conn.Fatal("Invalid note-id: %v", err)
				}
			}
		}

		if err := validateReminderFields(title, deadline, windowStart, urgencyDays); err != nil {
			conn.FatalInvalid("%v", err)
		}

		payload := buildReminderPayload(title, deadline, windowStart, urgencyDays, noteID)
		preview := buildReminderPreview(title, deadline)

		resp, err = s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_UpdateAsset,
			Data:   protocol.EncodeUpdateAsset(s.RoomID, reminderID, preview, payload),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetUpdated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("updated", "reminder", reminderID, "Reminder updated", nil, nil)
	},
}

var reminderDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete reminder",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		reminderID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid reminder ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_DeleteAsset,
			Data:   protocol.EncodeDeleteAsset(s.RoomID, reminderID),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetDeleted {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("deleted", "reminder", reminderID, "Reminder deleted", nil, nil)
	},
}

func parseDateOrNanos(raw string) (int64, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, nil
	}

	if nanos, err := strconv.ParseInt(raw, 10, 64); err == nil {
		return nanos, nil
	}

	if ts, err := time.Parse(time.RFC3339, raw); err == nil {
		return ts.UnixNano(), nil
	}

	if ts, err := time.Parse("2006-01-02T15:04", raw); err == nil {
		return ts.UnixNano(), nil
	}

	return 0, fmt.Errorf("unsupported datetime format")
}

func formatTimestamp(nanos int64) string {
	if nanos == 0 {
		return "-"
	}
	return time.Unix(0, nanos).Format(time.DateTime)
}

func normalizeUrgencyDays(value int) int {
	if value < 1 {
		return reminderDefaultUrgencyDays
	}
	return value
}

func validateReminderFields(title string, deadline, windowStart int64, urgencyDays int) error {
	if strings.TrimSpace(title) == "" {
		return fmt.Errorf("title is required")
	}
	if deadline == 0 {
		return fmt.Errorf("deadline is required")
	}
	if windowStart != 0 && windowStart > deadline {
		return fmt.Errorf("window-start must be before or equal to deadline")
	}
	if urgencyDays < 1 {
		return fmt.Errorf("urgency-days must be >= 1")
	}
	return nil
}

func buildReminderPayload(title string, deadline, windowStart int64, urgencyDays int, noteID uint64) string {
	p := reminderAssetPayload{
		Title:       title,
		WindowStart: fmt.Sprintf("%d", windowStart),
		Deadline:    fmt.Sprintf("%d", deadline),
		UrgencyDays: normalizeUrgencyDays(urgencyDays),
	}
	if noteID > 0 {
		p.NoteAssetID = fmt.Sprintf("%d", noteID)
	}
	body, _ := json.Marshal(p)
	return string(body)
}

func buildReminderPreview(title string, deadline int64) string {
	if deadline == 0 {
		return title
	}
	return fmt.Sprintf("%s | DUE %s", title, time.Unix(0, deadline).Format("2006-01-02 15:04"))
}

func reminderState(deadline, windowStart int64, urgencyDays int, now int64) string {
	if deadline != 0 && now > deadline {
		return reminderStateLate
	}
	if windowStart != 0 && now < windowStart {
		return reminderStateLocked
	}
	urgencyWindow := int64(normalizeUrgencyDays(urgencyDays)) * int64(24*time.Hour)
	if deadline != 0 && deadline-now <= urgencyWindow {
		return reminderStateUrgent
	}
	return reminderStateOpen
}

func stateRank(state string) int {
	switch state {
	case reminderStateLate:
		return 0
	case reminderStateUrgent:
		return 1
	case reminderStateOpen:
		return 2
	default:
		return 3
	}
}

func parseReminderPayload(asset protocol.Asset) (reminderAssetPayload, bool) {
	if asset.AssetType != protocol.AssetTypeReminder {
		return reminderAssetPayload{}, false
	}

	tryDecode := func(raw string) (reminderAssetPayload, bool) {
		raw = strings.TrimSpace(raw)
		if raw == "" || !strings.HasPrefix(raw, "{") {
			return reminderAssetPayload{}, false
		}
		var p reminderAssetPayload
		if err := json.Unmarshal([]byte(raw), &p); err != nil {
			return reminderAssetPayload{}, false
		}
		return p, true
	}

	if payload, ok := tryDecode(asset.Payload); ok {
		return payload, true
	}
	if payload, ok := tryDecode(asset.Preview); ok {
		return payload, true
	}
	return reminderAssetPayload{}, false
}

func reminderAssetToEntry(asset protocol.Asset, now int64) (reminderEntry, bool) {
	payload, ok := parseReminderPayload(asset)
	if !ok {
		return reminderEntry{}, false
	}

	title := strings.TrimSpace(payload.Title)
	if title == "" {
		title = strings.TrimSpace(payload.Name)
	}
	if title == "" {
		title = strings.TrimSpace(asset.Preview)
	}

	deadlineRaw := payload.Deadline
	if strings.TrimSpace(deadlineRaw) == "" {
		deadlineRaw = payload.DeadlineLegacy
	}
	deadline, err := parseDateOrNanos(deadlineRaw)
	if err != nil || deadline == 0 {
		return reminderEntry{}, false
	}

	windowStart := int64(0)
	windowStartRaw := payload.WindowStart
	if strings.TrimSpace(windowStartRaw) == "" {
		windowStartRaw = payload.WindowStartLegacy
	}
	if strings.TrimSpace(windowStartRaw) != "" {
		windowStart, err = parseDateOrNanos(windowStartRaw)
		if err != nil {
			windowStart = 0
		}
	}

	noteAssetID := uint64(0)
	noteAssetIDRaw := payload.NoteAssetID
	if strings.TrimSpace(noteAssetIDRaw) == "" {
		noteAssetIDRaw = payload.NoteAssetIDLegacy
	}
	if strings.TrimSpace(noteAssetIDRaw) != "" {
		noteAssetID, _ = strconv.ParseUint(strings.TrimSpace(noteAssetIDRaw), 10, 64)
	}

	urgencyDays := payload.UrgencyDays
	if urgencyDays < 1 {
		urgencyDays = payload.UrgencyDaysLegacy
	}
	urgencyDays = normalizeUrgencyDays(urgencyDays)

	return reminderEntry{
		ID:           asset.AssetID,
		Title:        title,
		State:        reminderState(deadline, windowStart, urgencyDays, now),
		WindowStart:  windowStart,
		Deadline:     deadline,
		UrgencyDays:  urgencyDays,
		NoteAssetID:  noteAssetID,
		Owner:        asset.Owner,
		UpdatedAt:    asset.UpdatedAt,
		UpdatedAtISO: time.Unix(0, asset.UpdatedAt).Format(time.DateTime),
	}, true
}

func outputReminderTable(reminders []reminderEntry) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "STATE", "TITLE", "WINDOW", "DEADLINE", "URG", "NOTE", "OWNER"}))
	for _, r := range reminders {
		note := "-"
		if r.NoteAssetID > 0 {
			note = fmt.Sprintf("%d", r.NoteAssetID)
		}
		table.Append(
			fmt.Sprintf("%d", r.ID),
			r.State,
			truncateNote(r.Title, 32),
			formatTimestamp(r.WindowStart),
			formatTimestamp(r.Deadline),
			fmt.Sprintf("%d", r.UrgencyDays),
			note,
			r.Owner,
		)
	}
	table.Render()
}

func init() {
	reminderListCmd.Flags().Bool("hide-locked", false, "Hide reminders that are in LOCKED state")

	reminderCreateCmd.Flags().String("deadline", "", "Deadline (RFC3339, YYYY-MM-DDTHH:MM, or unix nanos)")
	reminderCreateCmd.Flags().String("window-start", "", "Window start (RFC3339, YYYY-MM-DDTHH:MM, or unix nanos)")
	reminderCreateCmd.Flags().Int("urgency-days", reminderDefaultUrgencyDays, "Urgency window in days")
	reminderCreateCmd.Flags().String("note-id", "", "Linked note asset ID")
	_ = reminderCreateCmd.MarkFlagRequired("deadline")

	reminderUpdateCmd.Flags().String("title", "", "New title")
	reminderUpdateCmd.Flags().String("deadline", "", "New deadline (RFC3339, YYYY-MM-DDTHH:MM, or unix nanos)")
	reminderUpdateCmd.Flags().String("window-start", "", "New window start; pass empty value to clear")
	reminderUpdateCmd.Flags().Int("urgency-days", reminderDefaultUrgencyDays, "New urgency window in days")
	reminderUpdateCmd.Flags().String("note-id", "", "Linked note asset ID; pass empty value to clear")

	reminderCmd.AddCommand(reminderListCmd, reminderCreateCmd, reminderGetCmd, reminderUpdateCmd, reminderDeleteCmd)
	rootCmd.AddCommand(reminderCmd)
}
