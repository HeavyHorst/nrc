package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

type searchRequest = protocol.SearchRequest
type searchResult = protocol.SearchResult
type searchResponse = protocol.SearchResponse

// legacySearchResult is the stable asset-only JSON shape emitted before typed
// entity search was added. Keep it separate so old scripts do not gain fields.
type legacySearchResult struct {
	AssetID    uint64  `json:"asset_id,string"`
	Score      float64 `json:"score"`
	Similarity float32 `json:"similarity,omitempty"`
	Preview    string  `json:"preview"`
	AssetType  uint16  `json:"asset_type"`
	Payload    string  `json:"payload,omitempty"`
}

type legacySearchResponse struct {
	Results []legacySearchResult `json:"results"`
	Stale   bool                 `json:"stale,omitempty"`
}

type legacySearchProjectionResult struct {
	AssetID    uint64   `json:"asset_id,string"`
	ID         *uint64  `json:"id,omitempty"`
	Score      float64  `json:"score"`
	Similarity float32  `json:"similarity,omitempty"`
	Preview    string   `json:"preview"`
	AssetType  uint16   `json:"asset_type"`
	Payload    string   `json:"payload,omitempty"`
	Title      string   `json:"title,omitempty"`
	Teaser     string   `json:"teaser,omitempty"`
	Project    string   `json:"project,omitempty"`
	Tags       []string `json:"tags,omitempty"`
	Format     string   `json:"format,omitempty"`
}

type legacySearchProjectionResponse struct {
	Results []legacySearchProjectionResult `json:"results"`
	Stale   bool                           `json:"stale,omitempty"`
}

var searchCmd = &cobra.Command{
	Use:   "search",
	Short: "Search workspace data indexed by nrc-search",
}

var searchQueryCmd = &cobra.Command{
	Use:   "query [text]",
	Short: "Search workspace assets or typed task entities",
	Long:  "Search workspace entities indexed by nrc-search. With no entity/task flags, this retains the legacy asset-only request and output. Use --entity task for tasks or --entity asset,task for unified results; task search includes active and Done tasks unless --status filters them.",
	Args:  cobra.MaximumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		assetTypeFlags, _ := cmd.Flags().GetStringSlice("type")
		entityFlags, _ := cmd.Flags().GetStringSlice("entity")
		topN, _ := cmd.Flags().GetInt("top")
		includePayload, _ := cmd.Flags().GetBool("payload")
		jsonOutput := useJSONOutput(cmd)

		assetTypes, err := parseSearchAssetTypes(assetTypeFlags)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		filters, taskFiltersUsed, err := parseSearchFilters(cmd, entityFlags, assetTypes)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}
		legacy := len(entityFlags) == 0 && !taskFiltersUsed
		query := ""
		if len(args) == 1 {
			query = args[0]
		}
		if strings.TrimSpace(query) == "" && legacy {
			conn.FatalInvalid("query text is required unless task/entity filters are explicit")
		}

		resp, err := runSearch(searchRequest{
			Query:          query,
			TopN:           topN,
			IncludePayload: includePayload,
			AssetTypes:     assetTypes,
			Filters:        filters,
		}, roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		outputSearchResults(resp, jsonOutput, includePayload, legacy)
	},
}

var searchSimilarCmd = &cobra.Command{
	Use:   "similar <asset-id>",
	Short: "Find assets similar to an existing asset",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		assetTypeFlags, _ := cmd.Flags().GetStringSlice("type")
		topN, _ := cmd.Flags().GetInt("top")
		includePayload, _ := cmd.Flags().GetBool("payload")
		jsonOutput := useJSONOutput(cmd)

		assetID, err := parseUint64Arg(args[0], "asset ID")
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		assetTypes, err := parseSearchAssetTypes(assetTypeFlags)
		if err != nil {
			conn.FatalInvalid("%v", err)
		}

		resp, err := runSearch(searchRequest{
			SimilarAssetID: &assetID,
			TopN:           topN,
			IncludePayload: includePayload,
			AssetTypes:     assetTypes,
		}, roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		outputSearchResults(resp, jsonOutput, includePayload, true)
	},
}

func parseSearchAssetTypes(values []string) ([]uint16, error) {
	if len(values) == 0 {
		return nil, nil
	}

	assetTypes := make([]uint16, 0, len(values))
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			part = strings.TrimSpace(strings.ToLower(part))
			if part == "" {
				continue
			}
			assetType, err := parseAssetTypeName(part)
			if err != nil {
				return nil, err
			}
			assetTypes = append(assetTypes, assetType)
		}
	}

	return assetTypes, nil
}

func splitSearchValues(values []string) []string {
	var result []string
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			if part = strings.TrimSpace(part); part != "" {
				result = append(result, part)
			}
		}
	}
	return result
}

func parseSearchFilters(cmd *cobra.Command, entityValues []string, assetTypes []uint16) (*protocol.SearchFilters, bool, error) {
	statuses, _ := cmd.Flags().GetStringSlice("status")
	assignees, _ := cmd.Flags().GetStringSlice("assignee")
	projects, _ := cmd.Flags().GetStringSlice("project")
	priorities, _ := cmd.Flags().GetStringSlice("priority")
	colors, _ := cmd.Flags().GetStringSlice("color")
	creators, _ := cmd.Flags().GetStringSlice("creator")
	completers, _ := cmd.Flags().GetStringSlice("completer")
	taskIDs, _ := cmd.Flags().GetStringSlice("task-id")
	externalRefs, _ := cmd.Flags().GetStringSlice("external-ref")
	blocked, _ := cmd.Flags().GetString("blocked")
	blockedBy, _ := cmd.Flags().GetStringSlice("blocked-by")
	overdueBefore, _ := cmd.Flags().GetInt64("overdue-before")

	taskFiltersUsed := len(statuses)+len(assignees)+len(projects)+len(priorities)+len(colors)+len(creators)+len(completers)+len(taskIDs)+len(externalRefs)+len(blockedBy) > 0 || blocked != "" || cmd.Flags().Changed("overdue-before")
	entities := make([]protocol.SearchEntityType, 0, len(entityValues))
	for _, value := range splitSearchValues(entityValues) {
		switch strings.ToLower(value) {
		case "asset", "assets":
			entities = append(entities, protocol.SearchEntityAsset)
		case "task", "tasks":
			entities = append(entities, protocol.SearchEntityTask)
		default:
			return nil, false, fmt.Errorf("unknown entity type %q (expected asset or task)", value)
		}
	}
	if len(entities) == 0 && taskFiltersUsed {
		entities = append(entities, protocol.SearchEntityTask)
	}
	if len(entities) == 0 {
		return nil, false, nil
	}

	taskFilters := &protocol.SearchTaskFilters{
		Assignees: splitSearchValues(assignees), ExternalRefs: splitSearchValues(externalRefs),
		Projects: splitSearchValues(projects), CreatedBy: splitSearchValues(creators), CompletedBy: splitSearchValues(completers),
	}
	for _, value := range splitSearchValues(statuses) {
		status, err := parseTaskStatusFlag(value)
		if err != nil {
			return nil, false, err
		}
		taskFilters.Statuses = append(taskFilters.Statuses, uint8(status))
	}
	for _, value := range splitSearchValues(priorities) {
		priority, err := strconv.ParseUint(value, 10, 8)
		if err != nil || priority > 254 {
			return nil, false, fmt.Errorf("priority must be between 0 and 254, got %q", value)
		}
		taskFilters.Priorities = append(taskFilters.Priorities, uint8(priority))
	}
	for _, value := range splitSearchValues(colors) {
		color, err := strconv.ParseUint(value, 10, 8)
		if err != nil {
			return nil, false, fmt.Errorf("color must be between 0 and 255, got %q", value)
		}
		taskFilters.Colors = append(taskFilters.Colors, uint8(color))
	}
	for _, value := range splitSearchValues(taskIDs) {
		id, err := parseUint64Arg(value, "task ID")
		if err != nil {
			return nil, false, err
		}
		taskFilters.TaskIDs = append(taskFilters.TaskIDs, id)
	}
	for _, value := range splitSearchValues(blockedBy) {
		id, err := parseUint64Arg(value, "blocking task ID")
		if err != nil {
			return nil, false, err
		}
		taskFilters.BlockedBy = append(taskFilters.BlockedBy, id)
	}
	if blocked != "" {
		value, err := strconv.ParseBool(blocked)
		if err != nil {
			return nil, false, fmt.Errorf("blocked must be true or false, got %q", blocked)
		}
		taskFilters.Blocked = &value
	}
	if cmd.Flags().Changed("overdue-before") {
		if overdueBefore <= 0 {
			return nil, false, fmt.Errorf("overdue-before must be a positive Unix-nanosecond timestamp")
		}
		taskFilters.OverdueBefore = &overdueBefore
	}
	if taskFilters.Empty() {
		taskFilters = nil
	}
	return &protocol.SearchFilters{EntityTypes: entities, AssetTypes: assetTypes, Task: taskFilters}, taskFiltersUsed, nil
}

func runSearch(req searchRequest, roomFlag string) (*searchResponse, error) {
	cfg, roomID, err := loadSearchContext(roomFlag)
	if err != nil {
		return nil, err
	}

	proxyURL := strings.TrimRight(cfg.GetProxyURL(), "/")
	if proxyURL == "" {
		return nil, fmt.Errorf("proxy URL is not configured; set it with `nrc config set proxy http://host` or use a ws:// server URL that can be derived")
	}

	req.Workspace = cfg.WorkspaceID
	req.ConvID = uint64(roomID)
	if req.TopN <= 0 {
		req.TopN = 10
	}

	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal search request: %w", err)
	}

	httpReq, err := http.NewRequest(http.MethodPost, proxyURL+"/search", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create search request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	httpClient := &http.Client{Timeout: 45 * time.Second}
	httpResp, err := httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("search request failed: %w", err)
	}
	defer httpResp.Body.Close()

	respBody, err := io.ReadAll(httpResp.Body)
	if err != nil {
		return nil, fmt.Errorf("read search response: %w", err)
	}

	if httpResp.StatusCode != http.StatusOK {
		message := strings.TrimSpace(string(respBody))
		if message == "" {
			message = httpResp.Status
		}
		return nil, fmt.Errorf("search API error: %s", message)
	}
	if req.Filters != nil && httpResp.Header.Get(protocol.SearchAPIVersionHeader) != protocol.SearchAPIVersion {
		return nil, fmt.Errorf("nrc-search does not support typed entity search %q", protocol.SearchAPIVersion)
	}

	var resp searchResponse
	if err := json.Unmarshal(respBody, &resp); err != nil {
		return nil, fmt.Errorf("decode search response: %w", err)
	}

	return &resp, nil
}

func loadSearchContext(roomFlag string) (*config.Config, int64, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, 0, &conn.CommandError{Err: fmt.Errorf("loading config: %w", err)}
	}

	if roomFlag != "" {
		return nil, 0, &conn.InvalidArgumentError{Err: fmt.Errorf("--room is only supported for chat")}
	}

	return cfg, protocol.WorkspaceDataConvID, nil
}

func outputSearchResults(resp *searchResponse, jsonOutput bool, includePayload bool, legacy bool) {
	if jsonOutput {
		if legacy {
			if output.HasFieldProjection() {
				output.OutputJSON(asLegacySearchProjectionResponse(resp))
			} else {
				output.OutputJSON(asLegacySearchResponse(resp))
			}
		} else {
			output.OutputJSON(resp)
		}
		return
	}

	if resp.Stale {
		fmt.Fprintln(os.Stderr, "Warning: search index reconciliation failed; results may be stale")
	}

	if includePayload {
		for _, result := range resp.Results {
			if result.Entity.EntityType == protocol.SearchEntityTask {
				fmt.Printf("[%d] task score=%.4f\n", result.Entity.EntityID, result.Score)
			} else {
				fmt.Printf("[%d] %s score=%.4f\n", result.AssetID, assetTypeName(result.AssetType), result.Score)
			}
			fmt.Printf("Preview: %s\n", formatSearchPreview(result))
			if payload := strings.TrimSpace(result.Payload); payload != "" {
				fmt.Printf("\n%s\n", payload)
			}
			fmt.Println()
		}
		return
	}
	if !legacy {
		outputTypedSearchTable(resp.Results)
		return
	}

	if searchResultsContainNotes(resp.Results) {
		outputNoteSearchTable(resp.Results)
		return
	}

	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "TYPE", "SCORE", "PREVIEW"}))
	for _, result := range resp.Results {
		table.Append(
			fmt.Sprintf("%d", result.AssetID),
			assetTypeName(result.AssetType),
			fmt.Sprintf("%.4f", result.Score),
			truncateSearch(formatSearchPreview(result), 72),
		)
	}
	table.Render()
}

func outputTypedSearchTable(results []searchResult) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "ENTITY", "TYPE/STATUS", "SCORE", "ASSIGNEE", "PROJECT", "PREVIEW"}))
	for _, result := range results {
		id := result.Entity.EntityID
		entityType := string(result.Entity.EntityType)
		typeOrStatus := assetTypeName(result.AssetType)
		assignee, project := "", ""
		if result.Metadata.Task != nil {
			typeOrStatus = searchTaskStatusName(result.Metadata.Task.Status)
			assignee, project = result.Metadata.Task.Assignee, result.Metadata.Task.Project
		}
		table.Append(fmt.Sprintf("%d", id), entityType, typeOrStatus, fmt.Sprintf("%.4f", result.Score),
			truncateSearch(assignee, 20), truncateSearch(project, 24), truncateSearch(formatSearchPreview(result), 72))
	}
	table.Render()
}

func searchTaskStatusName(status uint8) string {
	switch status {
	case protocol.TaskStatusBacklog:
		return "backlog"
	case protocol.TaskStatusTodo:
		return "todo"
	case protocol.TaskStatusInProgress:
		return "in-progress"
	case protocol.TaskStatusDone:
		return "done"
	case protocol.TaskStatusNote:
		return "note"
	default:
		return fmt.Sprintf("status-%d", status)
	}
}

func asLegacySearchResponse(resp *searchResponse) legacySearchResponse {
	var results []legacySearchResult
	if resp.Results != nil {
		results = make([]legacySearchResult, len(resp.Results))
	}
	for i, result := range resp.Results {
		results[i] = legacySearchResult{AssetID: result.AssetID, Score: result.Score, Similarity: result.Similarity,
			Preview: result.Preview, AssetType: result.AssetType, Payload: result.Payload}
	}
	return legacySearchResponse{Results: results, Stale: resp.Stale}
}

func asLegacySearchProjectionResponse(resp *searchResponse) legacySearchProjectionResponse {
	results := make([]legacySearchProjectionResult, len(resp.Results))
	for i, result := range resp.Results {
		projected := legacySearchProjectionResult{
			AssetID: result.AssetID, Score: result.Score, Similarity: result.Similarity,
			Preview: result.Preview, AssetType: result.AssetType, Payload: result.Payload,
		}
		if result.AssetType == protocol.AssetTypeNote {
			preview := parseNotePreviewJSON(result.Preview)
			projected.ID = &projected.AssetID
			projected.Title = strings.TrimSpace(preview.Title)
			projected.Teaser = strings.TrimSpace(preview.Teaser)
			projected.Project = strings.TrimSpace(preview.Project)
			projected.Tags = normalizeNoteTags(preview.Tags)
			projected.Format = preview.Format
		}
		results[i] = projected
	}
	return legacySearchProjectionResponse{Results: results, Stale: resp.Stale}
}

func searchResultsContainNotes(results []searchResult) bool {
	for _, result := range results {
		if result.AssetType == protocol.AssetTypeNote {
			return true
		}
	}
	return false
}

func outputNoteSearchTable(results []searchResult) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "TYPE", "SCORE", "PROJECT", "TAGS", "TITLE", "TEASER"}))
	for _, result := range results {
		fields := searchDisplayFields(result)
		table.Append(
			fmt.Sprintf("%d", result.AssetID),
			assetTypeName(result.AssetType),
			fmt.Sprintf("%.4f", result.Score),
			truncateSearch(fields.Project, 24),
			truncateSearch(fields.Tags, 32),
			truncateSearch(fields.Title, 36),
			truncateSearch(fields.Teaser, 72),
		)
	}
	table.Render()
}

type searchPreviewFields struct {
	Project string
	Tags    string
	Title   string
	Teaser  string
}

func searchDisplayFields(result searchResult) searchPreviewFields {
	preview := strings.TrimSpace(result.Preview)
	if result.AssetType != protocol.AssetTypeNote {
		return searchPreviewFields{Teaser: preview}
	}

	p := parseNotePreviewJSON(preview)
	return searchPreviewFields{
		Project: strings.TrimSpace(p.Project),
		Tags:    strings.Join(normalizeNoteTags(p.Tags), ", "),
		Title:   strings.TrimSpace(p.Title),
		Teaser:  strings.TrimSpace(p.Teaser),
	}
}

func formatSearchPreview(result searchResult) string {
	preview := strings.TrimSpace(result.Preview)
	if result.AssetType != protocol.AssetTypeNote {
		return preview
	}

	p := parseNotePreviewJSON(preview)
	parts := make([]string, 0, 3)
	title := strings.TrimSpace(p.Title)
	if title != "" {
		parts = append(parts, title)
	}

	meta := formatNoteSearchMetadata(p)
	if meta != "" {
		parts = append(parts, meta)
	}

	teaser := strings.TrimSpace(p.Teaser)
	if teaser != "" {
		parts = append(parts, teaser)
	}

	if len(parts) == 0 {
		return preview
	}
	return strings.Join(parts, " — ")
}

func formatNoteSearchMetadata(p notePreview) string {
	parts := make([]string, 0, 2)
	if project := strings.TrimSpace(p.Project); project != "" {
		parts = append(parts, "project: "+project)
	}

	tags := normalizeNoteTags(p.Tags)
	if len(tags) > 0 {
		parts = append(parts, "tags: "+strings.Join(tags, ", "))
	}

	if len(parts) == 0 {
		return ""
	}
	return "(" + strings.Join(parts, "; ") + ")"
}

func truncateSearch(s string, maxLen int) string {
	s = strings.TrimSpace(s)
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-3] + "..."
}

func init() {
	searchQueryCmd.Flags().StringSlice("type", nil, "Asset type filter (repeat or use comma-separated values)")
	searchQueryCmd.Flags().StringSlice("entity", nil, "Entity type filter: asset or task (repeat/comma-separate; omit for legacy asset-only search)")
	searchQueryCmd.Flags().StringSlice("status", nil, "Exact task status filter: backlog, todo, progress, done, or note")
	searchQueryCmd.Flags().StringSlice("assignee", nil, "Exact task assignee filter")
	searchQueryCmd.Flags().StringSlice("project", nil, "Exact task project filter")
	searchQueryCmd.Flags().StringSlice("priority", nil, "Exact numeric task priority filter (0-254)")
	searchQueryCmd.Flags().StringSlice("color", nil, "Exact numeric task color filter (0-255)")
	searchQueryCmd.Flags().StringSlice("creator", nil, "Exact task creator filter")
	searchQueryCmd.Flags().StringSlice("completer", nil, "Exact task completer filter")
	searchQueryCmd.Flags().StringSlice("task-id", nil, "Exact task ID filter")
	searchQueryCmd.Flags().StringSlice("external-ref", nil, "Exact task external-reference filter")
	searchQueryCmd.Flags().String("blocked", "", "Task blocked-state filter: true or false")
	searchQueryCmd.Flags().StringSlice("blocked-by", nil, "Exact blocking task ID filter")
	searchQueryCmd.Flags().Int64("overdue-before", 0, "Overdue cutoff Unix-nanosecond timestamp (due > 0, not Done, due before cutoff)")
	searchQueryCmd.Flags().Int("top", 10, "Maximum number of results")
	searchQueryCmd.Flags().Bool("payload", false, "Include full payload text in results")

	searchSimilarCmd.Flags().StringSlice("type", nil, "Asset type filter (repeat or use comma-separated values)")
	searchSimilarCmd.Flags().Int("top", 10, "Maximum number of results")
	searchSimilarCmd.Flags().Bool("payload", false, "Include full payload text in results")

	searchCmd.AddCommand(searchQueryCmd, searchSimilarCmd)
	rootCmd.AddCommand(searchCmd)
}
