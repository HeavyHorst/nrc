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

// A slice is an explicit work stream: an asset of type AssetTypeSlice whose
// members are the tasks, notes and files linked to it with a member-of edge.
// The server reads those edges, so this command family reads slices and never
// assembles them: deriving membership here from project labels would be a second
// definition that could disagree with the register.
//
// Nothing is derived, so a slice is created and then filled. `slice create` makes
// the record, `slice assign` and `slice unassign` add and remove members, and
// because membership is an edge a task can belong to more than one slice and a
// slice can span projects.

// sliceRecord is the slice asset preview. It mirrors the payload the client
// writes, so a record created here is readable there and the reverse.
type sliceRecord struct {
	Version  int    `json:"version"`
	Name     string `json:"name"`
	Owner    string `json:"owner"`
	Outcome  string `json:"outcome"`
	Closed   bool   `json:"closed"`
	ClosedAt int64  `json:"closed_at"`
	ClosedBy string `json:"closed_by"`
}

// parseSlicePreview decodes a slice record. A preview that does not decode,
// carries an unknown version, or carries no name is not a slice record: it is
// reported as absent rather than repaired, matching the server, which skips such
// a record instead of inventing an identity from it.
func parseSlicePreview(preview string) (sliceRecord, error) {
	var record sliceRecord
	if strings.TrimSpace(preview) == "" {
		return record, fmt.Errorf("empty slice preview")
	}
	if err := json.Unmarshal([]byte(preview), &record); err != nil {
		return record, fmt.Errorf("slice preview is not valid JSON: %w", err)
	}
	if record.Version != 1 {
		return record, fmt.Errorf("unsupported slice preview version %d", record.Version)
	}
	if record.Name == "" {
		return record, fmt.Errorf("slice preview carries no name")
	}
	return record, nil
}

func (r sliceRecord) encode() (string, error) {
	if r.Version == 0 {
		r.Version = 1
	}
	if len(r.Name) > protocol.MaxProjectLength {
		return "", fmt.Errorf("slice name exceeds %d bytes", protocol.MaxProjectLength)
	}
	if len(r.Outcome) > protocol.MaxSliceOutcomeLength {
		return "", fmt.Errorf("slice outcome exceeds %d bytes", protocol.MaxSliceOutcomeLength)
	}
	if len(r.Owner) > protocol.MaxAssigneeLength {
		return "", fmt.Errorf("slice owner exceeds %d bytes", protocol.MaxAssigneeLength)
	}
	data, err := json.Marshal(r)
	if err != nil {
		return "", err
	}
	if len(data) > protocol.MaxPreviewLength {
		return "", fmt.Errorf("slice record exceeds the %d byte preview limit", protocol.MaxPreviewLength)
	}
	return string(data), nil
}

// sliceEntry is the read model for one slice. Members are every kind the slice
// carries; tasks are the subset with a status, which is what the register's
// silhouette is drawn from.
type sliceEntry struct {
	Name           string `json:"name"`
	SliceID        uint64 `json:"slice_id"`
	Closed         bool   `json:"closed"`
	Owner          string `json:"owner,omitempty"`
	Outcome        string `json:"outcome,omitempty"`
	ClosedAt       int64  `json:"closed_at,omitempty"`
	ClosedBy       string `json:"closed_by,omitempty"`
	Members        uint32 `json:"members"`
	Tasks          uint16 `json:"tasks"`
	Notes          uint16 `json:"notes"`
	Files          uint16 `json:"files"`
	Open           uint16 `json:"open"`
	Backlog        uint16 `json:"backlog"`
	Todo           uint16 `json:"todo"`
	InProgress     uint16 `json:"in_progress"`
	Done           uint16 `json:"done"`
	Blocked        uint16 `json:"blocked"`
	OldestActiveAt int64  `json:"oldest_active_at,omitempty"`
	LastMovedAt    int64  `json:"last_moved_at,omitempty"`
}

type sliceListResult struct {
	Slices          []sliceEntry `json:"slices"`
	Count           int          `json:"count"`
	TotalCount      uint32       `json:"total_count"`
	AssignedTasks   uint32       `json:"assigned_tasks"`
	UnassignedTasks uint32       `json:"unassigned_tasks"`
	HasMore         bool         `json:"has_more"`
}

func toSliceEntry(slice protocol.TaskSlice, record *sliceRecord) sliceEntry {
	entry := sliceEntry{
		Name:           slice.Name,
		SliceID:        slice.SliceID,
		Closed:         slice.IsClosed(),
		Owner:          slice.Owner,
		Members:        slice.MemberCount(),
		Tasks:          slice.TaskCount(),
		Notes:          slice.Notes,
		Files:          slice.Files,
		Open:           slice.OpenCount(),
		Backlog:        slice.Backlog,
		Todo:           slice.Todo,
		InProgress:     slice.InProgress,
		Done:           slice.Done,
		Blocked:        slice.Blocked,
		OldestActiveAt: slice.OldestActiveAt,
		LastMovedAt:    slice.LastMovedAt,
	}
	if record != nil {
		entry.Closed = record.Closed
		entry.Owner = record.Owner
		entry.Outcome = record.Outcome
		entry.ClosedAt = record.ClosedAt
		entry.ClosedBy = record.ClosedBy
	}
	return entry
}

type sliceListing struct {
	Slices          []protocol.TaskSlice
	Total           uint32
	AssignedTasks   uint32
	UnassignedTasks uint32
}

// fetchTaskSlices drains the slice listing a page at a time. The register's order
// is the server's, so the pages are read in the order they arrive and the cursor a
// page ends on asks for the next one. The CLI has no reader to keep waiting, so it
// follows every page: a listing that spans pages is still one listing, and the
// workspace counters belong to the first page, which is the one that folds them.
func fetchTaskSlices(s *conn.Session, query protocol.SliceQuery) (sliceListing, error) {
	var listing sliceListing
	for {
		if err := s.Client.Send(&protocol.Message{
			Opcode: protocol.C_ListTaskSlices,
			Data:   protocol.EncodeListTaskSlices(protocol.WorkspaceDataConvID, query, 0),
		}); err != nil {
			return listing, &conn.ConnectionError{Err: fmt.Errorf("sending: %w", err)}
		}
		resp, ok := s.Client.RecvSkipServerReady(0)
		if !ok {
			return listing, &conn.ConnectionError{Err: fmt.Errorf("connection closed")}
		}
		if resp.Opcode == protocol.S_ErrorResponse {
			return listing, conn.DecodeServerError(resp.Data)
		}
		if resp.Opcode != protocol.S_TaskSliceList {
			return listing, fmt.Errorf("unexpected response: %d", resp.Opcode)
		}
		list, err := protocol.DecodeTaskSliceList(resp.Data)
		if err != nil {
			return listing, fmt.Errorf("parsing slices: %w", err)
		}
		if !list.Success {
			if list.Error == "" {
				return listing, fmt.Errorf("slice listing failed")
			}
			return listing, fmt.Errorf("%s", list.Error)
		}
		listing.Slices = append(listing.Slices, list.Slices...)
		listing.Total = list.TotalCount
		if query.Cursor == nil {
			listing.AssignedTasks = list.AssignedTasks
			listing.UnassignedTasks = list.UnassignedTasks
		}
		if !list.HasMore {
			return listing, nil
		}
		if len(list.Slices) == 0 {
			return listing, fmt.Errorf("slice listing did not advance")
		}
		cursor := list.NextCursor
		query.Cursor = &cursor
	}
}

// fetchSliceRecord reads the slice record. Every slice has one, so a record that
// cannot be read is an error rather than a missing identity.
func fetchSliceRecord(s *conn.Session, sliceID uint64) (*sliceRecord, error) {
	resp, err := s.SendAndRecv(&protocol.Message{
		Opcode: protocol.C_GetAsset,
		Data:   protocol.EncodeGetAsset(protocol.WorkspaceDataConvID, sliceID),
	})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != protocol.S_AssetFull {
		return nil, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}
	full, err := protocol.DecodeAssetFullResponse(resp.Data)
	if err != nil {
		return nil, fmt.Errorf("parsing slice record: %w", err)
	}
	if full.Asset.AssetType != protocol.AssetTypeSlice {
		return nil, fmt.Errorf("asset %d is %s, not a slice record", sliceID, assetTypeName(full.Asset.AssetType))
	}
	record, err := parseSlicePreview(full.Asset.Preview)
	if err != nil {
		return nil, fmt.Errorf("asset %d is not a usable slice record: %w", sliceID, err)
	}
	return &record, nil
}

func findSlice(s *conn.Session, name string) (protocol.TaskSlice, error) {
	// Finding one slice reads the whole register: a slice is addressed by its name,
	// and the name is matched over every page.
	listing, err := fetchTaskSlices(s, protocol.SliceQuery{IncludeClosed: true, Limit: protocol.MaxTaskSliceCount})
	if err != nil {
		return protocol.TaskSlice{}, err
	}
	for _, slice := range listing.Slices {
		if slice.Name == name {
			return slice, nil
		}
	}
	return protocol.TaskSlice{}, nil
}

// requireSlice resolves a slice by name and fails with a not-found error when
// there is none, so every command reports the same way.
func requireSlice(s *conn.Session, name string) (protocol.TaskSlice, error) {
	slice, err := findSlice(s, name)
	if err != nil {
		return protocol.TaskSlice{}, err
	}
	if slice.SliceID == 0 {
		return protocol.TaskSlice{}, fmt.Errorf("slice %q was not found; run `nrc slice list` to see the slices in this workspace", name)
	}
	return slice, nil
}

func requireSliceName(name string) (string, error) {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return "", fmt.Errorf("a slice name is required")
	}
	if len(trimmed) > protocol.MaxProjectLength {
		return "", fmt.Errorf("slice name exceeds %d bytes", protocol.MaxProjectLength)
	}
	return trimmed, nil
}

// sliceMemberKind is one of the kinds a slice can carry. Membership is an edge
// whose source is the member and whose target is the slice.
type sliceMemberKind struct {
	name       string
	targetType uint16
	ids        []uint64
}

// resolveMemberKinds reads the flags that name the members to add or remove. Any
// mix is allowed in one call, because assigning two tasks and the note that
// documents them is one act.
func resolveMemberKinds(cmd *cobra.Command) ([]sliceMemberKind, error) {
	flags := []struct {
		flag       string
		name       string
		targetType uint16
	}{
		{"task", "task", protocol.TargetTypeTask},
		{"note", "note", protocol.TargetTypeAsset},
		{"file", "file", protocol.TargetTypeAsset},
	}
	var kinds []sliceMemberKind
	for _, kind := range flags {
		values, _ := cmd.Flags().GetStringSlice(kind.flag)
		if len(values) == 0 {
			continue
		}
		ids := make([]uint64, 0, len(values))
		for _, value := range values {
			id, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64)
			if err != nil || id == 0 {
				return nil, fmt.Errorf("--%s takes positive IDs, got %q", kind.flag, value)
			}
			ids = append(ids, id)
		}
		kinds = append(kinds, sliceMemberKind{name: kind.name, targetType: kind.targetType, ids: ids})
	}
	if len(kinds) == 0 {
		return nil, fmt.Errorf("name the members with --task, --note or --file")
	}
	return kinds, nil
}

// sliceMemberEdges returns the member-of edges of a slice, so a caller can match
// one against the member it wants to remove.
func sliceMemberEdges(s *conn.Session, sliceID uint64) ([]protocol.Edge, error) {
	resp, err := s.SendAndRecv(&protocol.Message{
		Opcode: protocol.C_ListEdges,
		Data:   protocol.EncodeListEdges(protocol.WorkspaceDataConvID, protocol.TargetTypeAsset, sliceID),
	})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != protocol.S_EdgeList {
		return nil, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}
	edges, err := protocol.DecodeEdgeList(resp.Data)
	if err != nil {
		return nil, fmt.Errorf("parsing slice members: %w", err)
	}
	members := make([]protocol.Edge, 0, len(edges))
	for _, edge := range edges {
		if edge.Relation == protocol.RelationMemberOf {
			members = append(members, edge)
		}
	}
	return members, nil
}

// edgeMemberMatches reports whether an edge joins this slice to the given member.
func edgeMemberMatches(edge protocol.Edge, sliceID uint64, targetType uint16, memberID uint64) bool {
	sliceIsTarget := edge.TargetType == protocol.TargetTypeAsset && edge.TargetID == sliceID
	if sliceIsTarget && edge.SourceType == targetType && edge.SourceID == memberID {
		return true
	}
	sliceIsSource := edge.SourceType == protocol.TargetTypeAsset && edge.SourceID == sliceID
	return sliceIsSource && edge.TargetType == targetType && edge.TargetID == memberID
}

var sliceCmd = &cobra.Command{
	Use:   "slice",
	Short: "Manage work slices",
}

var sliceListCmd = &cobra.Command{
	Use:   "list",
	Short: "List work slices with their member counts and ages",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		includeClosed, _ := cmd.Flags().GetBool("include-closed")
		jsonOutput := useJSONOutput(cmd)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		listing, err := fetchTaskSlices(s, protocol.SliceQuery{IncludeClosed: includeClosed, Limit: protocol.MaxTaskSliceCount})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		// The listing carries the record's name, owner and closure, so the
		// register reads one response. `slice get` fetches the outcome.
		entries := make([]sliceEntry, 0, len(listing.Slices))
		for _, slice := range listing.Slices {
			entries = append(entries, toSliceEntry(slice, nil))
		}

		if jsonOutput {
			output.OutputJSON(sliceListResult{
				Slices:          entries,
				Count:           len(entries),
				TotalCount:      listing.Total,
				AssignedTasks:   listing.AssignedTasks,
				UnassignedTasks: listing.UnassignedTasks,
				HasMore:         uint32(len(entries)) < listing.Total,
			})
			return
		}

		if len(entries) == 0 {
			output.PrintSuccess("No slices in this workspace.")
			return
		}
		rows := make([][]string, 0, len(entries))
		for _, entry := range entries {
			rows = append(rows, []string{
				entry.Name,
				strconv.FormatUint(uint64(entry.Members), 10),
				strconv.FormatUint(uint64(entry.Open), 10),
				strconv.FormatUint(uint64(entry.Blocked), 10),
				strconv.FormatUint(uint64(entry.Done), 10),
				sliceAge(entry.LastMovedAt),
				sliceState(entry),
			})
		}
		table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"SLICE", "MEM", "OPEN", "BLK", "DONE", "MOVED", "STATE"}))
		for _, row := range rows {
			table.Append(row)
		}
		table.Render()
		output.PrintSuccess("%d tasks in slices, %d without one.", listing.AssignedTasks, listing.UnassignedTasks)
	},
}

var sliceGetCmd = &cobra.Command{
	Use:   "get <name>",
	Short: "Show one slice, including its outcome and closure",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		slice, err := requireSlice(s, args[0])
		if err != nil {
			conn.FatalNotFound("%v", err)
		}
		record, err := fetchSliceRecord(s, slice.SliceID)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		entry := toSliceEntry(slice, record)

		if jsonOutput {
			output.OutputJSON(entry)
			return
		}
		output.PrintSuccess("%s", entry.Name)
		table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"FIELD", "VALUE"}))
		for _, row := range [][]string{
			{"STATE", sliceState(entry)},
			{"OWNER", sliceOrDash(entry.Owner)},
			{"MEMBERS", strconv.FormatUint(uint64(entry.Members), 10)},
			{"TASKS", strconv.FormatUint(uint64(entry.Tasks), 10)},
			{"OPEN", strconv.FormatUint(uint64(entry.Open), 10)},
			{"BLOCKED", strconv.FormatUint(uint64(entry.Blocked), 10)},
			{"DONE", strconv.FormatUint(uint64(entry.Done), 10)},
			{"NOTES", strconv.FormatUint(uint64(entry.Notes), 10)},
			{"FILES", strconv.FormatUint(uint64(entry.Files), 10)},
			{"OLDEST OPEN", sliceAge(entry.OldestActiveAt)},
			{"LAST MOVED", sliceAge(entry.LastMovedAt)},
			{"OUTCOME", sliceOrDash(entry.Outcome)},
		} {
			table.Append(row)
		}
		table.Render()
	},
}

// sliceMember is one member of a slice, resolved to what a reader needs: what it
// is, which ID it carries, its title, and the state that kind has.
type sliceMember struct {
	Kind      string `json:"kind"` // task, note, file, or asset when the kind is unknown
	ID        uint64 `json:"id"`
	Title     string `json:"title"`
	Status    string `json:"status,omitempty"`
	Assignee  string `json:"assignee,omitempty"`
	Priority  uint8  `json:"priority,omitempty"`
	BlockedBy uint64 `json:"blocked_by,omitempty"`
	Project   string `json:"project,omitempty"`
	Category  string `json:"category,omitempty"`
}

type sliceMembersResult struct {
	Name    string        `json:"name"`
	SliceID uint64        `json:"slice_id"`
	Closed  bool          `json:"closed"`
	Count   int           `json:"count"`
	Members []sliceMember `json:"members"`
}

// memberPreview is the part of an asset preview that names the asset in a member
// list. A note carries a title and a project, a file a title and a category.
type memberPreview struct {
	Title    string `json:"title"`
	Project  string `json:"project"`
	Category string `json:"category"`
}

// sliceEdgeMember returns the endpoint of a membership edge that is not the slice
// itself, so the member is read from the edge that joins it and not from a stored
// member list. A slice is never its own member: the server refuses self-edges, and
// the read path does not assume that it always did.
func sliceEdgeMember(edge protocol.Edge, sliceID uint64) (targetType uint16, memberID uint64, found bool) {
	if edge.TargetType == protocol.TargetTypeAsset && edge.TargetID == sliceID {
		if edge.SourceType == protocol.TargetTypeAsset && edge.SourceID == sliceID {
			return 0, 0, false
		}
		return edge.SourceType, edge.SourceID, true
	}
	if edge.SourceType == protocol.TargetTypeAsset && edge.SourceID == sliceID {
		if edge.TargetType == protocol.TargetTypeAsset && edge.TargetID == sliceID {
			return 0, 0, false
		}
		return edge.TargetType, edge.TargetID, true
	}
	return 0, 0, false
}

// taskMember reads the task behind a membership edge. A task that cannot be read
// keeps its identity and loses only its title, so the member count stays true.
func taskMember(s *conn.Session, taskID uint64) sliceMember {
	task, err := fetchTask(s, taskID)
	if err != nil {
		return sliceMember{Kind: "task", ID: taskID}
	}
	return taskMemberFrom(task, taskID)
}

// taskMemberFrom renders a task that was already read, from the bulk listing.
func taskMemberFrom(task *protocol.Task, taskID uint64) sliceMember {
	member := sliceMember{Kind: "task", ID: taskID}
	if task == nil {
		return member
	}
	member.Title = task.Title
	member.Status = output.StatusName(int32(task.Status))
	member.Assignee = task.Assignee
	member.Priority = task.Priority
	member.BlockedBy = task.BlockedBy
	return member
}

// assetMember reads the asset behind a membership edge: a note or a file, named
// by its type and its preview.
func assetMember(s *conn.Session, assetID uint64) sliceMember {
	member := sliceMember{Kind: "asset", ID: assetID}
	asset, err := fetchAsset(s, assetID)
	if err != nil {
		return member
	}
	member.Kind = assetTypeName(asset.AssetType)
	var preview memberPreview
	if json.Unmarshal([]byte(asset.Preview), &preview) != nil {
		return member
	}
	member.Title = preview.Title
	switch asset.AssetType {
	case protocol.AssetTypeNote:
		member.Project = preview.Project
	case protocol.AssetTypeFile:
		member.Category = preview.Category
	}
	return member
}

// sliceMemberBulkThreshold is where reading tasks one by one stops being cheaper
// than listing them: a slice can carry a thousand edges, and one round trip per
// member would make reading a slice as slow as its size.
const sliceMemberBulkThreshold = 16

// allTaskStatuses is every status the task listing can report, including the
// retired note status, so a member is never missing from the bulk read.
const allTaskStatuses = uint8(0x1f)

// sliceMembers resolves a slice's membership edges into the entities behind them,
// in the order they were assigned. Membership is read from the edges, so this
// never assembles a slice itself: it only names what the edges already point at.
func sliceMembers(s *conn.Session, slice protocol.TaskSlice) ([]sliceMember, error) {
	edges, err := sliceMemberEdges(s, slice.SliceID)
	if err != nil {
		return nil, err
	}
	sort.Slice(edges, func(i, j int) bool { return edges[i].EdgeID < edges[j].EdgeID })

	type endpoint struct {
		targetType uint16
		id         uint64
	}
	endpoints := make([]endpoint, 0, len(edges))
	taskIDs := make(map[uint64]bool)
	for _, edge := range edges {
		targetType, memberID, found := sliceEdgeMember(edge, slice.SliceID)
		if !found {
			continue
		}
		if targetType == protocol.TargetTypeTask {
			taskIDs[memberID] = true
		}
		endpoints = append(endpoints, endpoint{targetType: targetType, id: memberID})
	}

	// Notes and files are read one by one, because a slice carries few of them and
	// no listing returns them by ID.
	var listedTasks map[uint64]*protocol.Task
	if len(taskIDs) > sliceMemberBulkThreshold {
		tasks, err := fetchTasks(s, allTaskStatuses)
		if err != nil {
			return nil, err
		}
		listedTasks = make(map[uint64]*protocol.Task, len(taskIDs))
		for _, task := range tasks {
			if taskIDs[task.ID] {
				listedTasks[task.ID] = task
			}
		}
	}

	members := make([]sliceMember, 0, len(endpoints))
	for _, entry := range endpoints {
		if entry.targetType != protocol.TargetTypeTask {
			members = append(members, assetMember(s, entry.id))
			continue
		}
		if listedTasks != nil {
			members = append(members, taskMemberFrom(listedTasks[entry.id], entry.id))
			continue
		}
		members = append(members, taskMember(s, entry.id))
	}
	return members, nil
}

// memberState renders the one line a human reads per member: the state its kind
// carries, and nothing invented for a kind that has none.
func memberState(member sliceMember) string {
	switch member.Kind {
	case "task":
		state := member.Status
		if member.Assignee != "" {
			state += " · " + member.Assignee
		}
		if member.BlockedBy != 0 {
			state += fmt.Sprintf(" · blocked by #%d", member.BlockedBy)
		}
		return state
	case "note":
		return sliceOrDash(member.Project)
	case "file":
		return sliceOrDash(member.Category)
	default:
		return "—"
	}
}

var sliceMembersCmd = &cobra.Command{
	Use:   "members <name>",
	Short: "List what a slice carries, with each member's kind and title",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)

		name, err := requireSliceName(args[0])
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		slice, err := requireSlice(s, name)
		if err != nil {
			conn.FatalNotFound("%v", err)
		}
		members, err := sliceMembers(s, slice)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if jsonOutput {
			output.OutputJSON(sliceMembersResult{
				Name:    slice.Name,
				SliceID: slice.SliceID,
				Closed:  slice.IsClosed(),
				Count:   len(members),
				Members: members,
			})
			return
		}

		if len(members) == 0 {
			output.PrintSuccess("Slice %s carries no members.", name)
			return
		}
		rows := make([][]string, 0, len(members))
		for _, member := range members {
			rows = append(rows, []string{
				member.Kind,
				strconv.FormatUint(member.ID, 10),
				sliceOrDash(member.Title),
				memberState(member),
			})
		}
		table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"KIND", "ID", "TITLE", "STATE"}))
		for _, row := range rows {
			table.Append(row)
		}
		table.Render()
	},
}

var sliceCreateCmd = &cobra.Command{
	Use:         "create <name>",
	Short:       "Create a slice, so tasks, notes and files can be assigned to it",
	Args:        cobra.ExactArgs(1),
	Annotations: map[string]string{"mutation": "true"},
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		owner, _ := cmd.Flags().GetString("owner")
		outcome, _ := cmd.Flags().GetString("outcome")

		name, err := requireSliceName(args[0])
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		record := sliceRecord{Version: 1, Name: name, Owner: strings.TrimSpace(owner), Outcome: outcome}
		preview, err := record.encode()
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		existing, err := findSlice(s, name)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if existing.SliceID != 0 {
			conn.FatalInvalid("Slice %q already exists as asset %d; use `nrc slice update` or `nrc slice close`.", name, existing.SliceID)
		}

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_CreateAsset,
			Data:   protocol.EncodeCreateAssetWithCorrelation(protocol.WorkspaceDataConvID, protocol.AssetTypeSlice, protocol.ParentTypeNone, 0, preview, outcome, 0),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_AssetCreated {
			conn.Fatal("Unexpected response: %d", resp.Opcode)
		}
		created, err := protocol.DecodeAssetCreated(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing created slice: %v", err)
		}
		output.Mutation("created", "slice", created.Asset.AssetID, fmt.Sprintf("Slice created: %s (%d)", name, created.Asset.AssetID), nil, map[string]any{"name": name})
	},
}

var sliceAssignCmd = &cobra.Command{
	Use:         "assign <name> --task <id> | --note <id> | --file <id>",
	Short:       "Assign tasks, notes or files to a slice",
	Args:        cobra.ExactArgs(1),
	Annotations: map[string]string{"mutation": "true"},
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		name, err := requireSliceName(args[0])
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		members, err := resolveMemberKinds(cmd)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		slice, err := requireSlice(s, name)
		if err != nil {
			conn.FatalNotFound("%v", err)
		}

		assigned := make([]string, 0)
		for _, kind := range members {
			for _, memberID := range kind.ids {
				resp, err := s.SendAndRecv(&protocol.Message{
					Opcode: protocol.C_CreateEdge,
					Data: protocol.EncodeCreateEdgeWithCorrelation(
						protocol.WorkspaceDataConvID,
						kind.targetType, memberID,
						protocol.TargetTypeAsset, slice.SliceID,
						protocol.RelationMemberOf, 0,
					),
				})
				if err != nil {
					conn.Fatal("Error: %v", err)
				}
				if resp.Opcode == protocol.S_ErrorResponse {
					conn.Fatal("%v", conn.DecodeServerError(resp.Data))
				}
				if resp.Opcode != protocol.S_EdgeCreated {
					conn.Fatal("Unexpected response: %d", resp.Opcode)
				}
				assigned = append(assigned, fmt.Sprintf("%s %d", kind.name, memberID))
			}
		}
		output.Mutation("assigned", "slice", slice.SliceID,
			fmt.Sprintf("Assigned %s to %s", strings.Join(assigned, ", "), name), nil,
			map[string]any{"name": name, "members": assigned})
	},
}

var sliceUnassignCmd = &cobra.Command{
	Use:         "unassign <name> --task <id> | --note <id> | --file <id>",
	Short:       "Remove tasks, notes or files from a slice",
	Args:        cobra.ExactArgs(1),
	Annotations: map[string]string{"mutation": "true"},
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		name, err := requireSliceName(args[0])
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		members, err := resolveMemberKinds(cmd)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		slice, err := requireSlice(s, name)
		if err != nil {
			conn.FatalNotFound("%v", err)
		}
		edges, err := sliceMemberEdges(s, slice.SliceID)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		removed := make([]string, 0)
		for _, kind := range members {
			for _, memberID := range kind.ids {
				edgeID := uint64(0)
				for _, edge := range edges {
					if edgeMemberMatches(edge, slice.SliceID, kind.targetType, memberID) {
						edgeID = edge.EdgeID
						break
					}
				}
				if edgeID == 0 {
					conn.FatalNotFound("%s %d is not assigned to slice %q.", kind.name, memberID, name)
				}
				resp, err := s.SendAndRecv(&protocol.Message{
					Opcode: protocol.C_DeleteEdge,
					Data:   protocol.EncodeDeleteEdgeWithCorrelation(protocol.WorkspaceDataConvID, edgeID, 0),
				})
				if err != nil {
					conn.Fatal("Error: %v", err)
				}
				if resp.Opcode == protocol.S_ErrorResponse {
					conn.Fatal("%v", conn.DecodeServerError(resp.Data))
				}
				if resp.Opcode != protocol.S_EdgeDeleted {
					conn.Fatal("Unexpected response: %d", resp.Opcode)
				}
				removed = append(removed, fmt.Sprintf("%s %d", kind.name, memberID))
			}
		}
		output.Mutation("unassigned", "slice", slice.SliceID,
			fmt.Sprintf("Unassigned %s from %s", strings.Join(removed, ", "), name), nil,
			map[string]any{"name": name, "members": removed})
	},
}

var sliceUpdateCmd = &cobra.Command{
	Use:         "update <name>",
	Short:       "Change a slice's owner or outcome",
	Args:        cobra.ExactArgs(1),
	Annotations: map[string]string{"mutation": "true"},
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		owner, _ := cmd.Flags().GetString("owner")
		outcome, _ := cmd.Flags().GetString("outcome")

		name, err := requireSliceName(args[0])
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		if !cmd.Flags().Changed("owner") && !cmd.Flags().Changed("outcome") {
			conn.FatalInvalid("Pass --owner, --outcome, or both. Only the flags you pass are changed.")
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		slice, err := requireSlice(s, name)
		if err != nil {
			conn.FatalNotFound("%v", err)
		}
		record, err := fetchSliceRecord(s, slice.SliceID)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if cmd.Flags().Changed("owner") {
			record.Owner = strings.TrimSpace(owner)
		}
		if cmd.Flags().Changed("outcome") {
			record.Outcome = outcome
		}
		preview, err := record.encode()
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_UpdateAsset,
			Data:   protocol.EncodeUpdateAssetWithCorrelation(protocol.WorkspaceDataConvID, slice.SliceID, preview, record.Outcome, 0),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_AssetUpdated {
			conn.Fatal("Unexpected response: %d", resp.Opcode)
		}
		output.Mutation("updated", "slice", slice.SliceID, fmt.Sprintf("Slice updated: %s", name), nil, map[string]any{"name": name})
	},
}

var sliceCloseCmd = &cobra.Command{
	Use:         "close <name>",
	Short:       "Close a slice",
	Args:        cobra.ExactArgs(1),
	Annotations: map[string]string{"mutation": "true"},
	Run: func(cmd *cobra.Command, args []string) {
		setSliceClosed(cmd, args, true)
	},
}

var sliceReopenCmd = &cobra.Command{
	Use:         "reopen <name>",
	Short:       "Reopen a closed slice",
	Args:        cobra.ExactArgs(1),
	Annotations: map[string]string{"mutation": "true"},
	Run: func(cmd *cobra.Command, args []string) {
		setSliceClosed(cmd, args, false)
	},
}

// membershipNoun names the memberships a delete releases, so a slice with one
// member does not read as a plural.
func membershipNoun(count uint32) string {
	if count == 1 {
		return "membership"
	}
	return "memberships"
}

// sliceDeleteRefusal says what a delete would take with it, or an empty string
// when the slice carries nothing. A slice that was created by accident is
// deleted without ceremony; one that carries members, an owner or an outcome is
// refused until the caller says --force, because the record cannot be recovered
// and the memberships can only be rebuilt by hand.
func sliceDeleteRefusal(name string, members uint32, record *sliceRecord) string {
	carries := make([]string, 0, 3)
	if members > 0 {
		noun := "members"
		if members == 1 {
			noun = "member"
		}
		carries = append(carries, fmt.Sprintf("%d %s", members, noun))
	}
	if record != nil && strings.TrimSpace(record.Owner) != "" {
		carries = append(carries, "an owner")
	}
	if record != nil && strings.TrimSpace(record.Outcome) != "" {
		carries = append(carries, "an outcome")
	}
	if len(carries) == 0 {
		return ""
	}
	carried := carries[0]
	if len(carries) > 1 {
		carried = strings.Join(carries[:len(carries)-1], ", ") + " and " + carries[len(carries)-1]
	}
	if members > 0 {
		return fmt.Sprintf(
			"Refusing to delete slice %q: it carries %s. Pass --force to delete the slice and release its %d %s; the tasks, notes and files themselves stay.",
			name, carried, members, membershipNoun(members),
		)
	}
	return fmt.Sprintf("Refusing to delete slice %q: it carries %s. Pass --force to delete the slice and its record.", name, carried)
}

var sliceDeleteCmd = &cobra.Command{
	Use:         "delete <name>",
	Short:       "Delete a slice and release its memberships",
	Args:        cobra.ExactArgs(1),
	Annotations: map[string]string{"mutation": "true"},
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		force, _ := cmd.Flags().GetBool("force")

		name, err := requireSliceName(args[0])
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		slice, err := requireSlice(s, name)
		if err != nil {
			conn.FatalNotFound("%v", err)
		}
		record, err := fetchSliceRecord(s, slice.SliceID)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		members := slice.MemberCount()
		if !force {
			if refusal := sliceDeleteRefusal(name, members, record); refusal != "" {
				conn.Fatal("%s", refusal)
			}
		}

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_DeleteAsset,
			Data:   protocol.EncodeDeleteAsset(protocol.WorkspaceDataConvID, slice.SliceID),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode == protocol.S_ErrorResponse {
			conn.Fatal("%v", conn.DecodeServerError(resp.Data))
		}
		if resp.Opcode != protocol.S_AssetDeleted {
			conn.Fatal("Unexpected response: %d", resp.Opcode)
		}

		message := fmt.Sprintf("Deleted slice %s (%d)", name, slice.SliceID)
		if members > 0 {
			message = fmt.Sprintf("Deleted slice %s (%d), released %d %s", name, slice.SliceID, members, membershipNoun(members))
		}
		output.Mutation("deleted", "slice", slice.SliceID, message, nil,
			map[string]any{"name": name, "released_members": members})
	},
}

// setSliceClosed writes the closure act. Closure is not derived from member
// statuses, so it is always an explicit write by whoever asks for it.
func setSliceClosed(cmd *cobra.Command, args []string, closed bool) {
	roomFlag, _ := cmd.Flags().GetString("room")
	by, _ := cmd.Flags().GetString("by")

	name, err := requireSliceName(args[0])
	if err != nil {
		conn.FatalInvalid("%v", err)
	}

	s, err := conn.Dial(roomFlag)
	if err != nil {
		conn.Fatal("Error: %v", err)
	}
	defer s.Close()

	slice, err := requireSlice(s, name)
	if err != nil {
		conn.FatalNotFound("%v", err)
	}
	record, err := fetchSliceRecord(s, slice.SliceID)
	if err != nil {
		conn.Fatal("Error: %v", err)
	}

	verb := "closed"
	if closed {
		record.Closed = true
		record.ClosedAt = time.Now().UnixNano()
		record.ClosedBy = strings.TrimSpace(by)
	} else {
		verb = "reopened"
		record.Closed = false
		record.ClosedAt = 0
		record.ClosedBy = ""
	}
	preview, err := record.encode()
	if err != nil {
		conn.FatalInvalid("%v", err)
	}

	resp, err := s.SendAndRecv(&protocol.Message{
		Opcode: protocol.C_UpdateAsset,
		Data:   protocol.EncodeUpdateAssetWithCorrelation(protocol.WorkspaceDataConvID, slice.SliceID, preview, record.Outcome, 0),
	})
	if err != nil {
		conn.Fatal("Error: %v", err)
	}
	if resp.Opcode != protocol.S_AssetUpdated {
		conn.Fatal("Unexpected response: %d", resp.Opcode)
	}
	output.Mutation(verb, "slice", slice.SliceID, fmt.Sprintf("Slice %s: %s", verb, name), nil, map[string]any{"name": name})
}

func sliceState(entry sliceEntry) string {
	if entry.Closed {
		return "CLOSED"
	}
	return "OPEN"
}

func sliceOrDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "—"
	}
	return value
}

// sliceAge renders a nanosecond timestamp as a compact age. Zero means the
// slice has nothing to age: no open member, or no recorded movement.
func sliceAge(timestamp int64) string {
	if timestamp == 0 {
		return "—"
	}
	elapsed := time.Since(time.Unix(0, timestamp))
	if elapsed < 0 {
		elapsed = 0
	}
	switch {
	case elapsed < time.Hour:
		return fmt.Sprintf("%dm", int(elapsed.Minutes()))
	case elapsed < 24*time.Hour:
		return fmt.Sprintf("%dh", int(elapsed.Hours()))
	default:
		return fmt.Sprintf("%dd", int(elapsed.Hours()/24))
	}
}

func init() {
	sliceListCmd.Flags().Bool("include-closed", false, "Include closed slices")
	sliceCreateCmd.Flags().String("owner", "", "Owner of the slice")
	sliceCreateCmd.Flags().String("outcome", "", "What the slice ends in")
	sliceUpdateCmd.Flags().String("owner", "", "Owner of the slice")
	sliceUpdateCmd.Flags().String("outcome", "", "What the slice ends in")
	sliceCloseCmd.Flags().String("by", "", "Who is closing the slice")
	sliceDeleteCmd.Flags().Bool("force", false, "Delete a slice that still carries members, an owner or an outcome")
	sliceAssignCmd.Flags().StringSlice("task", nil, "Task IDs to assign")
	sliceAssignCmd.Flags().StringSlice("note", nil, "Note IDs to assign")
	sliceAssignCmd.Flags().StringSlice("file", nil, "File IDs to assign")
	sliceUnassignCmd.Flags().StringSlice("task", nil, "Task IDs to remove")
	sliceUnassignCmd.Flags().StringSlice("note", nil, "Note IDs to remove")
	sliceUnassignCmd.Flags().StringSlice("file", nil, "File IDs to remove")
	sliceCmd.AddCommand(
		sliceListCmd,
		sliceGetCmd,
		sliceMembersCmd,
		sliceCreateCmd,
		sliceAssignCmd,
		sliceUnassignCmd,
		sliceUpdateCmd,
		sliceCloseCmd,
		sliceReopenCmd,
		sliceDeleteCmd,
	)
	rootCmd.AddCommand(sliceCmd)
}
