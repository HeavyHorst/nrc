package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

const appointmentPageSize = 100

var appointmentTimePattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)

type appointmentPreview struct {
	Version     int    `json:"version"`
	Title       string `json:"title"`
	StartAt     string `json:"start_at"`
	EndAt       string `json:"end_at,omitempty"`
	Description string `json:"description,omitempty"`
	Assignee    string `json:"assignee,omitempty"`
	Project     string `json:"project,omitempty"`
	URL         string `json:"url,omitempty"`
}

type appointmentRecord struct {
	ID          uint64 `json:"id"`
	Title       string `json:"title"`
	StartAt     string `json:"start_at"`
	EndAt       string `json:"end_at,omitempty"`
	Description string `json:"description,omitempty"`
	Assignee    string `json:"assignee,omitempty"`
	Project     string `json:"project,omitempty"`
	URL         string `json:"url,omitempty"`
	Owner       string `json:"owner,omitempty"`
	CreatedAt   int64  `json:"created_at,omitempty"`
	UpdatedAt   int64  `json:"updated_at,omitempty"`
}

func parseAppointmentTime(raw string) (int64, error) {
	raw = strings.TrimSpace(raw)
	if n, err := strconv.ParseInt(raw, 10, 64); err == nil && n > 0 {
		return n, nil
	}
	if !appointmentTimePattern.MatchString(raw) {
		return 0, fmt.Errorf("use RFC3339 with explicit timezone and at most nine fractional digits, or positive unix nanoseconds")
	}
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return 0, fmt.Errorf("use RFC3339 with an explicit Z or numeric timezone, or positive unix nanoseconds")
	}
	if t.UnixNano() <= 0 || !time.Unix(0, t.UnixNano()).Equal(t) {
		return 0, fmt.Errorf("timestamp must be positive and fit signed 64-bit nanoseconds")
	}
	return t.UnixNano(), nil
}

func validateAppointment(p appointmentPreview) error {
	if p.Version != 1 {
		return fmt.Errorf("appointment version must be 1")
	}
	if strings.TrimSpace(p.Title) == "" || len(p.Title) > protocol.MaxTaskTitleLength {
		return fmt.Errorf("title is required and must be at most %d bytes", protocol.MaxTaskTitleLength)
	}
	start, err := parseAppointmentTime(p.StartAt)
	if err != nil {
		return fmt.Errorf("invalid start: %w", err)
	}
	if p.EndAt != "" {
		end, e := parseAppointmentTime(p.EndAt)
		if e != nil || end <= start {
			return fmt.Errorf("end must be later than start")
		}
	}
	if len(p.Description) > 2048 || len(p.URL) > 2048 || len(p.Assignee) > protocol.MaxAssigneeLength || len(p.Project) > protocol.MaxProjectLength {
		return fmt.Errorf("appointment field exceeds protocol limit")
	}
	return nil
}

func appointmentPreviewJSON(p appointmentPreview) (string, error) {
	p.Version = 1
	p.Title = strings.TrimSpace(p.Title)
	start, err := parseAppointmentTime(p.StartAt)
	if err != nil {
		return "", fmt.Errorf("invalid start: %w", err)
	}
	p.StartAt = strconv.FormatInt(start, 10)
	if p.EndAt != "" {
		end, e := parseAppointmentTime(p.EndAt)
		if e != nil {
			return "", fmt.Errorf("invalid end: %w", e)
		}
		p.EndAt = strconv.FormatInt(end, 10)
	}
	if err := validateAppointment(p); err != nil {
		return "", err
	}
	b, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	if len(b) > protocol.MaxPreviewLength {
		return "", fmt.Errorf("appointment record exceeds %d bytes", protocol.MaxPreviewLength)
	}
	return string(b), nil
}

func decodeAppointment(a protocol.Asset) (appointmentRecord, appointmentPreview, error) {
	if a.AssetType != protocol.AssetTypeAppointment || a.Payload != "" || a.PayloadEncoding != protocol.AssetPayloadEncodingPlain {
		return appointmentRecord{}, appointmentPreview{}, fmt.Errorf("asset %d is not an appointment", a.AssetID)
	}
	var p appointmentPreview
	if err := json.Unmarshal([]byte(a.Preview), &p); err != nil {
		return appointmentRecord{}, p, err
	}
	if err := validateAppointment(p); err != nil {
		return appointmentRecord{}, p, err
	}
	return appointmentRecord{ID: a.AssetID, Title: p.Title, StartAt: p.StartAt, EndAt: p.EndAt, Description: p.Description, Assignee: p.Assignee, Project: p.Project, URL: p.URL, Owner: a.Owner, CreatedAt: a.CreatedAt, UpdatedAt: a.UpdatedAt}, p, nil
}

func appointmentAsset(s *conn.Session, id uint64) (protocol.Asset, error) {
	resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_GetAsset, Data: protocol.EncodeGetAsset(protocol.WorkspaceDataConvID, id)})
	if err != nil {
		return protocol.Asset{}, err
	}
	if resp.Opcode != protocol.S_AssetFull {
		return protocol.Asset{}, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}
	return protocol.DecodeAssetFull(resp.Data)
}

var appointmentCmd = &cobra.Command{Use: "appointment", Short: "Manage calendar appointments"}

var appointmentListCmd = &cobra.Command{Use: "list", Short: "List appointments overlapping a bounded range", Args: cobra.NoArgs, Run: func(cmd *cobra.Command, args []string) {
	fromRaw, _ := cmd.Flags().GetString("from")
	toRaw, _ := cmd.Flags().GetString("to")
	assignee, _ := cmd.Flags().GetString("assignee")
	project, _ := cmd.Flags().GetString("project")
	start, err := parseAppointmentTime(fromRaw)
	if err != nil {
		conn.FatalInvalid("Invalid --from: %v", err)
	}
	end, err := parseAppointmentTime(toRaw)
	if err != nil {
		conn.FatalInvalid("Invalid --to: %v", err)
	}
	if _, err := protocol.EncodeCalendarQuery(protocol.CalendarQuery{Start: start, End: end, Limit: appointmentPageSize, Assignee: assignee, Project: project}); err != nil {
		conn.FatalInvalid("%v", err)
	}
	s, err := conn.Dial("")
	if err != nil {
		conn.Fatal("Error: %v", err)
	}
	defer s.Close()
	rows := []appointmentRecord{}
	var cursor *protocol.CalendarCursor
	for {
		data, e := protocol.EncodeCalendarQuery(protocol.CalendarQuery{Start: start, End: end, Limit: appointmentPageSize, Cursor: cursor, Assignee: assignee, Project: project})
		if e != nil {
			conn.FatalInvalid("%v", e)
		}
		resp, e := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_QueryCalendar, Data: data})
		if e != nil {
			conn.Fatal("Error: %v", e)
		}
		if resp.Opcode != protocol.S_CalendarPage {
			conn.Fatal("Unexpected response: %d", resp.Opcode)
		}
		page, e := protocol.DecodeCalendarPage(resp.Data)
		if e != nil {
			conn.Fatal("Error parsing calendar: %v", e)
		}
		for _, r := range page.Rows {
			if r.Kind == protocol.CalendarKindAppointment {
				rows = append(rows, appointmentRecord{ID: r.ID, Title: r.Title, StartAt: strconv.FormatInt(r.ActualStartAt, 10), EndAt: func() string {
					if r.EndAt == 0 {
						return ""
					}
					return strconv.FormatInt(r.EndAt, 10)
				}(), Assignee: r.Assignee, Project: r.Project})
			}
		}
		if !page.HasMore {
			break
		}
		c := page.Cursor
		if len(page.Rows) == 0 || cursor != nil && (c.At < cursor.At || c.At == cursor.At && (c.Kind < cursor.Kind || c.Kind == cursor.Kind && c.ID <= cursor.ID)) {
			conn.Fatal("Calendar pagination did not advance")
		}
		cursor = &c
	}
	if useJSONOutput(cmd) {
		output.OutputJSON(struct {
			Appointments []appointmentRecord `json:"appointments"`
		}{rows})
	} else {
		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tSTART\tEND\tASSIGNEE\tPROJECT\tTITLE")
		for _, r := range rows {
			fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%s\n", r.ID, appointmentTimeLabel(r.StartAt), appointmentTimeLabel(r.EndAt), r.Assignee, r.Project, r.Title)
		}
		_ = w.Flush()
	}
}}

func appointmentTimeLabel(raw string) string {
	if raw == "" {
		return "—"
	}
	n, _ := strconv.ParseInt(raw, 10, 64)
	return time.Unix(0, n).Format(time.RFC3339Nano)
}

var appointmentShowCmd = &cobra.Command{Use: "show <id>", Short: "Show an appointment", Args: cobra.ExactArgs(1), Run: func(cmd *cobra.Command, args []string) {
	id, e := strconv.ParseUint(args[0], 10, 64)
	if e != nil {
		conn.FatalInvalid("Invalid appointment ID")
	}
	s, e := conn.Dial("")
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	defer s.Close()
	a, e := appointmentAsset(s, id)
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	r, _, e := decodeAppointment(a)
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	if useJSONOutput(cmd) {
		output.OutputJSON(r)
	} else {
		fmt.Printf("#%d %s\nSTART: %s\nEND: %s\nASSIGNEE: %s\nPROJECT: %s\nURL: %s\n%s\n", r.ID, r.Title, appointmentTimeLabel(r.StartAt), appointmentTimeLabel(r.EndAt), r.Assignee, r.Project, r.URL, r.Description)
	}
}}

func appointmentFromFlags(cmd *cobra.Command, title string) (appointmentPreview, error) {
	p := appointmentPreview{Title: title}
	p.StartAt, _ = cmd.Flags().GetString("start")
	p.EndAt, _ = cmd.Flags().GetString("end")
	p.Description, _ = cmd.Flags().GetString("description")
	p.Assignee, _ = cmd.Flags().GetString("assignee")
	p.Project, _ = cmd.Flags().GetString("project")
	p.URL, _ = cmd.Flags().GetString("url")
	_, e := appointmentPreviewJSON(p)
	return p, e
}

var appointmentCreateCmd = &cobra.Command{Use: "create <title>", Short: "Create an appointment", Args: cobra.ExactArgs(1), Run: func(cmd *cobra.Command, args []string) {
	p, e := appointmentFromFlags(cmd, args[0])
	if e != nil {
		conn.FatalInvalid("%v", e)
	}
	preview, _ := appointmentPreviewJSON(p)
	s, e := conn.Dial("")
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	defer s.Close()
	resp, e := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_CreateAsset, Data: protocol.EncodeCreateAsset(protocol.WorkspaceDataConvID, protocol.AssetTypeAppointment, protocol.ParentTypeNone, 0, preview, "")})
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	if resp.Opcode != protocol.S_AssetCreated {
		conn.Fatal("Unexpected response: %d", resp.Opcode)
	}
	created, e := protocol.DecodeAssetCreated(resp.Data)
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	output.Mutation("created", "appointment", created.Asset.AssetID, "Appointment created", nil, nil)
}}

var appointmentUpdateCmd = &cobra.Command{Use: "update <id>", Short: "Update an appointment", Args: cobra.ExactArgs(1), Run: func(cmd *cobra.Command, args []string) {
	id, e := strconv.ParseUint(args[0], 10, 64)
	if e != nil {
		conn.FatalInvalid("Invalid appointment ID")
	}
	s, e := conn.Dial("")
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	defer s.Close()
	a, e := appointmentAsset(s, id)
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	_, p, e := decodeAppointment(a)
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	for _, name := range []string{"title", "start", "end", "description", "assignee", "project", "url"} {
		if cmd.Flags().Changed(name) {
			v, _ := cmd.Flags().GetString(name)
			switch name {
			case "title":
				p.Title = v
			case "start":
				p.StartAt = v
			case "end":
				p.EndAt = v
			case "description":
				p.Description = v
			case "assignee":
				p.Assignee = v
			case "project":
				p.Project = v
			case "url":
				p.URL = v
			}
		}
	}
	preview, e := appointmentPreviewJSON(p)
	if e != nil {
		conn.FatalInvalid("%v", e)
	}
	resp, e := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_UpdateAsset, Data: protocol.EncodeUpdateAsset(protocol.WorkspaceDataConvID, id, preview, "")})
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	if resp.Opcode != protocol.S_AssetUpdated {
		conn.Fatal("Unexpected response: %d", resp.Opcode)
	}
	output.Mutation("updated", "appointment", id, "Appointment updated", nil, nil)
}}

var appointmentDeleteCmd = &cobra.Command{Use: "delete <id>", Short: "Delete an appointment", Args: cobra.ExactArgs(1), Run: func(cmd *cobra.Command, args []string) {
	id, e := strconv.ParseUint(args[0], 10, 64)
	if e != nil {
		conn.FatalInvalid("Invalid appointment ID")
	}
	s, e := conn.Dial("")
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	defer s.Close()
	a, e := appointmentAsset(s, id)
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	if a.AssetType != protocol.AssetTypeAppointment {
		conn.FatalInvalid("Asset %d is not an appointment", id)
	}
	resp, e := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_DeleteAsset, Data: protocol.EncodeDeleteAsset(protocol.WorkspaceDataConvID, id)})
	if e != nil {
		conn.Fatal("Error: %v", e)
	}
	if resp.Opcode != protocol.S_AssetDeleted {
		conn.Fatal("Unexpected response: %d", resp.Opcode)
	}
	output.Mutation("deleted", "appointment", id, "Appointment deleted", nil, nil)
}}

func init() {
	appointmentListCmd.Flags().String("from", "", "Range start (RFC3339 with timezone or unix nanoseconds)")
	appointmentListCmd.Flags().String("to", "", "Exclusive range end (RFC3339 with timezone or unix nanoseconds)")
	appointmentListCmd.Flags().String("assignee", "", "Exact assignee filter")
	appointmentListCmd.Flags().String("project", "", "Exact project filter")
	_ = appointmentListCmd.MarkFlagRequired("from")
	_ = appointmentListCmd.MarkFlagRequired("to")
	for _, c := range []*cobra.Command{appointmentCreateCmd, appointmentUpdateCmd} {
		c.Flags().String("title", "", "Title (update only)")
		c.Flags().String("start", "", "Start (RFC3339 with timezone or unix nanoseconds)")
		c.Flags().String("end", "", "End; empty clears to a point appointment")
		c.Flags().String("description", "", "Description")
		c.Flags().String("assignee", "", "Assignee")
		c.Flags().String("project", "", "Project")
		c.Flags().String("url", "", "URL")
	}
	_ = appointmentCreateCmd.MarkFlagRequired("start")
	_ = appointmentCreateCmd.Flags().MarkHidden("title")
	appointmentCmd.AddCommand(appointmentListCmd, appointmentShowCmd, appointmentCreateCmd, appointmentUpdateCmd, appointmentDeleteCmd)
	rootCmd.AddCommand(appointmentCmd)
}
