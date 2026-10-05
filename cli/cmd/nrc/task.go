package main

import (
	"fmt"
	"strconv"
	"strings"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/heavyhorst/nrc/cli/pkg/upload"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

var taskCmd = &cobra.Command{
	Use:   "task",
	Short: "Manage tasks",
}

var taskListCmd = &cobra.Command{
	Use:   "list",
	Short: "List all tasks",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)
		readyOnly, _ := cmd.Flags().GetBool("ready")
		blockedOnly, _ := cmd.Flags().GetBool("blocked")
		project, _ := cmd.Flags().GetString("project")
		statuses, _ := cmd.Flags().GetStringSlice("status")
		priority, _ := cmd.Flags().GetInt("priority")
		createdBy, _ := cmd.Flags().GetString("created-by")
		titleContains, _ := cmd.Flags().GetString("title-contains")

		if readyOnly && blockedOnly {
			output.Error("invalid_argument", "Use either --ready or --blocked, not both", false)
		}
		filters, err := parseTaskFilters(project, statuses, priority, cmd.Flags().Changed("priority"), createdBy, titleContains)
		if err != nil {
			output.Error("invalid_argument", err.Error(), false)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		statusMask := uint8(0x1f)
		if len(filters.Statuses) > 0 {
			statusMask = taskStatusMask(filters.Statuses)
		}
		tasks, err := fetchTasks(s, statusMask)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if readyOnly || blockedOnly {
			edges, err := fetchAllEdges(s)
			if err != nil {
				conn.Fatal("Error: %v", err)
			}
			if readyOnly {
				tasks = filterReadyTasks(tasks, edges)
			} else {
				tasks = filterBlockedTasks(tasks, edges)
			}
		}
		tasks = filterTasks(tasks, filters)

		taskList := &output.TaskList{Tasks: toOutputTasks(tasks, s.Config.GetProxyURL())}

		if jsonOutput {
			output.OutputJSON(taskList)
		} else {
			output.OutputTasksTable(taskList.Tasks)
		}
	},
}

var taskGetCmd = &cobra.Command{Use: "get <id>", Short: "Get a task by ID", Args: cobra.ExactArgs(1), Run: func(cmd *cobra.Command, args []string) {
	id, err := strconv.ParseUint(args[0], 10, 64)
	if err != nil {
		conn.Fatal("Invalid task ID: %v", err)
	}
	room, _ := cmd.Flags().GetString("room")
	s, err := conn.Dial(room)
	if err != nil {
		conn.Fatal("Error: %v", err)
	}
	defer s.Close()
	task, err := fetchTask(s, id)
	if err != nil {
		conn.Fatal("Error: %v", err)
	}
	if task == nil {
		output.Error("not_found", fmt.Sprintf("Task %d not found", id), false)
	}
	item := toOutputTasks([]*protocol.Task{task}, s.Config.GetProxyURL())[0]
	if useJSONOutput(cmd) {
		output.OutputJSON(item)
	} else {
		output.OutputTasksTable([]output.Task{item})
		printNoteAttachments(task.Attachments, s.Config.GetProxyURL())
	}
}}

type taskFilters struct {
	Project                  string
	Statuses                 []string
	Priority                 int
	HasPriority              bool
	CreatedBy, TitleContains string
}

func parseTaskFilters(project string, statuses []string, priority int, hasPriority bool, createdBy, titleContains string) (taskFilters, error) {
	normalized := make([]string, 0, len(statuses))
	for _, group := range statuses {
		for _, status := range strings.Split(group, ",") {
			code, err := parseTaskStatusFlag(status)
			if err != nil {
				return taskFilters{}, err
			}
			normalized = append(normalized, output.StatusName(code))
		}
	}
	if hasPriority && (priority < 0 || priority > 254) {
		return taskFilters{}, fmt.Errorf("priority must be between 0 and 254")
	}
	return taskFilters{Project: project, Statuses: normalized, Priority: priority, HasPriority: hasPriority, CreatedBy: createdBy, TitleContains: titleContains}, nil
}

func filterTasks(tasks []*protocol.Task, f taskFilters) []*protocol.Task {
	allowed := map[string]bool{}
	for _, group := range f.Statuses {
		for _, s := range strings.Split(group, ",") {
			allowed[strings.ToLower(strings.TrimSpace(s))] = true
		}
	}
	out := make([]*protocol.Task, 0, len(tasks))
	for _, t := range tasks {
		if f.Project != "" && t.Project != f.Project {
			continue
		}
		if len(allowed) > 0 && !allowed[output.StatusName(int32(t.Status))] {
			continue
		}
		if f.HasPriority && int(t.Priority) != f.Priority {
			continue
		}
		if f.CreatedBy != "" && t.CreatedBy != f.CreatedBy {
			continue
		}
		if f.TitleContains != "" && !strings.Contains(strings.ToLower(t.Title), strings.ToLower(f.TitleContains)) {
			continue
		}
		out = append(out, t)
	}
	return out
}

func taskStatusMask(statuses []string) uint8 {
	var mask uint8
	for _, status := range statuses {
		code, err := parseTaskStatusFlag(status)
		if err == nil {
			mask |= 1 << uint8(code)
		}
	}
	return mask
}

var taskCreateCmd = &cobra.Command{
	Use:   "create <title>",
	Short: "Create new task",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		title := args[0]
		roomFlag, _ := cmd.Flags().GetString("room")
		desc, _ := cmd.Flags().GetString("description")
		priority, _ := cmd.Flags().GetInt("priority")
		project, _ := cmd.Flags().GetString("project")
		attach, _ := cmd.Flags().GetString("attach")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		// Upload attachments if provided
		var attachments []protocol.Attachment
		if attach != "" {
			if output.Human() {
				fmt.Fprintln(cmd.ErrOrStderr(), "Uploading attachments...")
			}
			filePaths := parseFilePaths(attach)
			atts, err := upload.UploadFiles(filePaths, s.Config.GetProxyURL(), s.Config.WorkspaceID)
			if err != nil {
				conn.Fatal("Error uploading files: %v", err)
			}
			attachments = atts
			if output.Human() {
				output.PrintSuccess("Uploaded %d file(s)", len(attachments))
			}
		}

		taskData := protocol.EncodeTaskCreateFullWithCorrelation(s.RoomID, title, desc, int32(priority), strings.TrimSpace(project), attachments, 0)

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_CreateTask,
			Data:   taskData,
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_TaskCreated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		created, err := protocol.DecodeTaskCreated(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing created task: %v", err)
		}

		output.Mutation("created", "task", created.Task.ID, fmt.Sprintf("Task created: %d", created.Task.ID), taskResource(created.Task, s.Config.GetProxyURL()), nil)
	},
}

var taskUpdateCmd = &cobra.Command{
	Use:   "update <id>",
	Short: "Update task",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		taskID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid task ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		title, _ := cmd.Flags().GetString("title")
		desc, _ := cmd.Flags().GetString("description")
		status, _ := cmd.Flags().GetString("status")
		priority, _ := cmd.Flags().GetInt("priority")
		project, _ := cmd.Flags().GetString("project")
		assignee, _ := cmd.Flags().GetString("assignee")
		blk, _ := cmd.Flags().GetString("blk")
		attach, _ := cmd.Flags().GetString("attach")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		// Upload attachments if provided
		var attachments []protocol.Attachment
		if attach != "" {
			if output.Human() {
				fmt.Fprintln(cmd.ErrOrStderr(), "Uploading attachments...")
			}
			filePaths := parseFilePaths(attach)
			atts, err := upload.UploadFiles(filePaths, s.Config.GetProxyURL(), s.Config.WorkspaceID)
			if err != nil {
				conn.Fatal("Error uploading files: %v", err)
			}
			attachments = atts
			if output.Human() {
				output.PrintSuccess("Uploaded %d file(s)", len(attachments))
			}
		}

		statusCode := int32(255) // no change
		if cmd.Flags().Changed("status") {
			statusCode, err = parseTaskStatusFlag(status)
			if err != nil {
				conn.Fatal("Invalid status: %v", err)
			}
		}

		priorityCode := int32(255) // no change
		if cmd.Flags().Changed("priority") {
			if priority < 0 || priority > 254 {
				conn.Fatal("Invalid priority: %d (must be 0-254)", priority)
			}
			priorityCode = int32(priority)
		}

		blockedBy := uint64(0) // no change
		if cmd.Flags().Changed("blk") {
			blockedBy, err = parseBlockedByFlag(blk)
			if err != nil {
				conn.Fatal("Invalid blk value: %v", err)
			}
		}

		projectValue := ""
		if cmd.Flags().Changed("project") {
			projectValue = strings.TrimSpace(project)
			if projectValue == "" {
				projectValue = "\x00"
			}
		}

		assigneeValue := ""
		if cmd.Flags().Changed("assignee") {
			assigneeValue = strings.TrimSpace(assignee)
			if len(assigneeValue) > protocol.MaxAssigneeLength {
				conn.Fatal("Assignee exceeds %d bytes", protocol.MaxAssigneeLength)
			}
			if assigneeValue == "" {
				assigneeValue = "\x00"
			}
		}

		taskData := protocol.EncodeTaskUpdateFullWithProjectAndCorrelation(s.RoomID, int64(taskID), title, desc, uint8(statusCode), assigneeValue, uint8(priorityCode), protocol.TaskColorNone, "", 0, blockedBy, attachments, projectValue, 0)

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_UpdateTask,
			Data:   taskData,
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_TaskUpdated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("updated", "task", taskID, "Task updated", nil, nil)
	},
}

var taskDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete task",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		taskID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid task ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_DeleteTask,
			Data:   protocol.EncodeTaskDelete(s.RoomID, int64(taskID)),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_TaskDeleted {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("deleted", "task", taskID, "Task deleted", nil, nil)
	},
}

var taskAttachCmd = &cobra.Command{
	Use:   "attach <id> <file1> [file2...]",
	Short: "Attach file(s) to task",
	Args:  cobra.MinimumNArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		taskID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid task ID: %v", err)
		}

		filePaths := args[1:]
		roomFlag, _ := cmd.Flags().GetString("room")

		// Upload files
		if output.Human() {
			fmt.Fprintf(cmd.ErrOrStderr(), "Uploading %d file(s)...\n", len(filePaths))
		}
		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		attachments, err := upload.UploadFiles(filePaths, s.Config.GetProxyURL(), s.Config.WorkspaceID)
		if err != nil {
			conn.Fatal("Error uploading files: %v", err)
		}
		if output.Human() {
			output.PrintSuccess("Uploaded %d file(s)", len(attachments))
		}

		// Update task with attachments (keep existing fields empty)
		taskData := protocol.EncodeTaskUpdateWithAttachments(s.RoomID, int64(taskID), "", "", 255, 255, 0, attachments)
		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_UpdateTask,
			Data:   taskData,
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_TaskUpdated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("attached", "task", taskID, fmt.Sprintf("Attached %d file(s) to task #%d", len(attachments), taskID), nil, map[string]any{"attachment_count": len(attachments)})
	},
}

func init() {
	taskListCmd.Flags().Bool("ready", false, "Only show tasks with no unfinished blockers")
	taskListCmd.Flags().Bool("blocked", false, "Only show tasks with unfinished blockers")
	taskListCmd.Flags().String("project", "", "Filter by exact project")
	taskListCmd.Flags().StringSlice("status", nil, "Filter by status (repeatable or comma-separated)")
	taskListCmd.Flags().Int("priority", 0, "Filter by exact numeric priority")
	taskListCmd.Flags().String("created-by", "", "Filter by exact creator")
	taskListCmd.Flags().String("title-contains", "", "Filter title case-insensitively")

	taskCreateCmd.Flags().String("description", "", "Task description")
	taskCreateCmd.Flags().Int("priority", 0, "Task priority (numeric, 0=default)")
	taskCreateCmd.Flags().String("project", "", "Task project")
	taskCreateCmd.Flags().String("attach", "", "Comma-separated file paths to attach")

	taskUpdateCmd.Flags().String("title", "", "New title")
	taskUpdateCmd.Flags().String("description", "", "New description")
	taskUpdateCmd.Flags().String("status", "", "New status (backlog|todo|progress|done|note)")
	taskUpdateCmd.Flags().Int("priority", 0, "New priority (numeric, 0-254)")
	taskUpdateCmd.Flags().String("project", "", "New project; pass empty value to clear, omit to keep existing")
	taskUpdateCmd.Flags().String("assignee", "", "New assignee; pass empty value to clear, omit to keep existing")
	taskUpdateCmd.Flags().String("blk", "", "Blocking task ID, or 'clear' to remove blocker")
	taskUpdateCmd.Flags().String("attach", "", "Comma-separated file paths to attach")

	taskCmd.AddCommand(taskListCmd, taskGetCmd, taskCreateCmd, taskUpdateCmd, taskDeleteCmd, taskAttachCmd)
	rootCmd.AddCommand(taskCmd)
}

func fetchTasks(s *conn.Session, statusMask uint8) ([]*protocol.Task, error) {
	tasks := make([]*protocol.Task, 0)
	var cursor *protocol.TaskPageCursor
	for {
		data, err := protocol.EncodeListTasksPaged(uint64(s.RoomID), statusMask, protocol.MaxTaskPageSize, cursor, 0)
		if err != nil {
			return nil, err
		}
		resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_ListTasksPaged, Data: data})
		if err != nil {
			return nil, err
		}
		if resp.Opcode != protocol.S_TaskListPage {
			return nil, fmt.Errorf("unexpected response: %d", resp.Opcode)
		}
		page, err := protocol.DecodeTaskListPage(resp.Data)
		if err != nil {
			return nil, fmt.Errorf("parsing tasks: %w", err)
		}
		tasks = append(tasks, page.Tasks...)
		if !page.HasMore {
			return tasks, nil
		}
		next := page.NextCursor
		// The server walks strictly descending (SortAt, TaskID) keys.
		if cursor != nil && (next.SortAt > cursor.SortAt ||
			next.SortAt == cursor.SortAt && next.TaskID >= cursor.TaskID) {
			return nil, fmt.Errorf("task pagination cursor did not advance")
		}
		cursor = &next
	}
}

func fetchTask(s *conn.Session, taskID uint64) (*protocol.Task, error) {
	resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_GetTask, Data: protocol.EncodeGetTask(uint64(s.RoomID), taskID, 0)})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != protocol.S_TaskFull {
		return nil, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}
	full, err := protocol.DecodeTaskFull(resp.Data)
	if err != nil {
		if full != nil && full.Task == nil {
			return nil, nil
		}
		return nil, fmt.Errorf("parsing task: %w", err)
	}
	return full.Task, nil
}

func fetchAllEdges(s *conn.Session) ([]protocol.Edge, error) {
	return fetchAllEdgesPaged(s, 250)
}

func filterReadyTasks(tasks []*protocol.Task, edges []protocol.Edge) []*protocol.Task {
	blockedTaskIDs := blockedTaskIDs(tasks, edges)
	ready := make([]*protocol.Task, 0, len(tasks))
	for _, task := range tasks {
		if task == nil {
			continue
		}
		if _, blocked := blockedTaskIDs[task.ID]; blocked {
			continue
		}
		ready = append(ready, task)
	}

	return ready
}

func filterBlockedTasks(tasks []*protocol.Task, edges []protocol.Edge) []*protocol.Task {
	blockedTaskIDs := blockedTaskIDs(tasks, edges)
	blocked := make([]*protocol.Task, 0, len(blockedTaskIDs))
	for _, task := range tasks {
		if task == nil {
			continue
		}
		if _, isBlocked := blockedTaskIDs[task.ID]; !isBlocked {
			continue
		}
		blocked = append(blocked, task)
	}

	return blocked
}

func blockedTaskIDs(tasks []*protocol.Task, edges []protocol.Edge) map[uint64]struct{} {
	tasksByID := make(map[uint64]*protocol.Task, len(tasks))
	for _, task := range tasks {
		if task == nil {
			continue
		}
		tasksByID[task.ID] = task
	}

	blocked := make(map[uint64]struct{})
	for _, edge := range edges {
		blockerID, blockedID, ok := blockingEdgeTaskIDs(edge)
		if !ok {
			continue
		}

		blocker, exists := tasksByID[blockerID]
		if !exists || blocker.Status != protocol.TaskStatusDone {
			blocked[blockedID] = struct{}{}
		}
	}

	for _, task := range tasks {
		if task == nil || task.BlockedBy == 0 {
			continue
		}
		blocker, exists := tasksByID[task.BlockedBy]
		if !exists || blocker.Status != protocol.TaskStatusDone {
			blocked[task.ID] = struct{}{}
		}
	}

	return blocked
}

func blockingEdgeTaskIDs(edge protocol.Edge) (uint64, uint64, bool) {
	if edge.SourceType != protocol.TargetTypeTask || edge.TargetType != protocol.TargetTypeTask {
		return 0, 0, false
	}

	switch edge.Relation {
	case protocol.RelationDependsOn:
		return edge.TargetID, edge.SourceID, true
	case protocol.RelationBlocks:
		return edge.SourceID, edge.TargetID, true
	default:
		return 0, 0, false
	}
}

func toOutputTasks(tasks []*protocol.Task, proxyURL string) []output.Task {
	result := make([]output.Task, 0, len(tasks))
	for _, task := range tasks {
		if task == nil {
			continue
		}
		result = append(result, output.Task{
			ID:          task.ID,
			Title:       task.Title,
			Description: task.Description,
			Status:      output.StatusName(int32(task.Status)),
			Assignee:    task.Assignee,
			Priority:    fmt.Sprintf("%d", task.Priority),
			Project:     task.Project,
			BlockedBy:   task.BlockedBy,
			CreatedBy:   task.CreatedBy,
			Timestamp:   task.CreatedAt,
			Attachments: toOutputAttachments(task.Attachments, proxyURL),
		})
	}
	return result
}

func toOutputAttachments(attachments []protocol.Attachment, proxyURL string) []output.Attachment {
	result := make([]output.Attachment, 0, len(attachments))
	for _, attachment := range attachments {
		result = append(result, output.Attachment{
			FileID:     attachment.FileId,
			Filename:   attachment.Filename,
			Size:       attachment.Size,
			MimeType:   attachment.MimeType,
			UploadedAt: attachment.UploadedAt,
			URL:        upload.FileURL(attachment, proxyURL),
		})
	}
	return result
}

// parseFilePaths splits comma-separated file paths
func parseFilePaths(input string) []string {
	if input == "" {
		return []string{}
	}

	paths := []string{}
	for _, path := range strings.Split(input, ",") {
		trimmed := strings.TrimSpace(path)
		if trimmed != "" {
			paths = append(paths, trimmed)
		}
	}
	return paths
}

func parseBlockedByFlag(value string) (uint64, error) {
	v := strings.ToLower(strings.TrimSpace(value))
	if v == "" {
		return 0, nil
	}

	if v == "clear" || v == "none" {
		return ^uint64(0), nil
	}

	blockedBy, err := strconv.ParseUint(v, 10, 64)
	if err != nil {
		return 0, err
	}
	if blockedBy == 0 {
		return 0, fmt.Errorf("use a task ID > 0, or 'clear' to remove blocker")
	}

	return blockedBy, nil
}

func parseTaskStatusFlag(value string) (int32, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "backlog":
		return 0, nil
	case "todo":
		return 1, nil
	case "in-progress", "progress":
		return 2, nil
	case "done":
		return 3, nil
	case "note":
		return 4, nil
	default:
		return 0, fmt.Errorf("expected backlog|todo|progress|done|note, got %q", value)
	}
}
