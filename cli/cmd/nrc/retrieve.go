package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

var retrieveCmd = &cobra.Command{
	Use:   "retrieve <question>",
	Short: "Retrieve a fused search and graph evidence bundle",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		topN, _ := cmd.Flags().GetInt("top")
		depth, _ := cmd.Flags().GetUint8("depth")
		relations, _ := cmd.Flags().GetStringSlice("relation")
		direction, _ := cmd.Flags().GetString("direction")
		noGraph, _ := cmd.Flags().GetBool("no-graph")
		payloadMode, _ := cmd.Flags().GetString("payload")
		payloadTop, _ := cmd.Flags().GetInt("payload-top")
		maxPayloadBytes, _ := cmd.Flags().GetInt("max-payload-bytes")
		pathMode, _ := cmd.Flags().GetString("paths")

		response, err := runRetrieve(protocol.RetrieveRequest{
			Query:           args[0],
			TopN:            topN,
			Depth:           depth,
			Relations:       relations,
			Direction:       direction,
			NoGraph:         noGraph,
			PayloadMode:     payloadMode,
			PayloadTop:      payloadTop,
			MaxPayloadBytes: maxPayloadBytes,
			PathMode:        pathMode,
		}, roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if useJSONOutput(cmd) {
			output.OutputJSON(response)
			return
		}
		printRetrieveHuman(response)
	},
}

func runRetrieve(request protocol.RetrieveRequest, roomFlag string) (*protocol.RetrieveResponse, error) {
	cfg, roomID, err := loadSearchContext(roomFlag)
	if err != nil {
		return nil, err
	}
	proxyURL := strings.TrimRight(cfg.GetProxyURL(), "/")
	if proxyURL == "" {
		return nil, fmt.Errorf("proxy URL is not configured; set it with `nrc config set proxy http://host` or use a ws:// server URL that can be derived")
	}

	request.Workspace = cfg.WorkspaceID
	request.ConvID = uint64(roomID)
	body, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("marshal retrieve request: %w", err)
	}
	httpRequest, err := http.NewRequest(http.MethodPost, proxyURL+"/ai/retrieve", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create retrieve request: %w", err)
	}
	httpRequest.Header.Set("Content-Type", "application/json")

	httpResponse, err := (&http.Client{Timeout: 60 * time.Second}).Do(httpRequest)
	if err != nil {
		return nil, fmt.Errorf("retrieve request failed: %w", err)
	}
	defer httpResponse.Body.Close()
	responseBody, err := io.ReadAll(httpResponse.Body)
	if err != nil {
		return nil, fmt.Errorf("read retrieve response: %w", err)
	}
	if httpResponse.StatusCode != http.StatusOK {
		var apiError struct {
			Error string `json:"error"`
		}
		message := strings.TrimSpace(string(responseBody))
		if json.Unmarshal(responseBody, &apiError) == nil && apiError.Error != "" {
			message = apiError.Error
		}
		return nil, fmt.Errorf("retrieve API error: %s", message)
	}

	var response protocol.RetrieveResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		return nil, fmt.Errorf("decode retrieve response: %w", err)
	}
	return &response, nil
}

func printRetrieveHuman(response *protocol.RetrieveResponse) {
	fmt.Printf("Room: %d\n", response.ConvID)
	fmt.Printf("Graph: enabled=%t contributed=%t\n", response.GraphEnabled, response.GraphContributed)
	fmt.Printf("Truncated: results=%t graph=%t payloads=%t\n\n",
		response.Truncation.Results, response.Truncation.Graph, response.Truncation.Payloads)
	for _, result := range response.Results {
		fmt.Printf("%2d  %-5s:%-8d score=%0.4f via=%s payload=%s\n",
			result.Rank, result.Type, result.ID, result.Score, strings.Join(result.Origins, ","), result.PayloadState)
		if result.Title != "" {
			fmt.Printf("    %s\n", result.Title)
		}
		if result.Teaser != "" {
			fmt.Printf("    %s\n", truncateSearch(result.Teaser, 180))
		}
		if result.Payload != "" {
			fmt.Printf("    %s\n", truncateSearch(result.Payload, 300))
		}
		for _, path := range result.Evidence {
			fmt.Printf("    evidence: %s:%d depth=%d edges=%v\n",
				path.Anchor.Type, path.Anchor.ID, path.Depth, []uint64(path.EdgeIDs))
		}
	}
	for _, warning := range response.Warnings {
		fmt.Fprintln(os.Stderr, "Warning:", warning)
	}
}

func init() {
	retrieveCmd.Flags().Int("top", 10, "Maximum number of fused results")
	retrieveCmd.Flags().Uint8("depth", 1, "Graph traversal depth (1-4)")
	retrieveCmd.Flags().StringSlice("relation", nil, "Graph relation filter (repeat or comma-separate)")
	retrieveCmd.Flags().String("direction", "both", "Graph direction: both, outgoing, or incoming")
	retrieveCmd.Flags().Bool("no-graph", false, "Disable graph expansion for diagnostics or ablation")
	retrieveCmd.Flags().String("payload", protocol.RetrievePayloadTop, "Payload policy: none, top, or all")
	retrieveCmd.Flags().Int("payload-top", 3, "Number of ranked results hydrated when --payload=top")
	retrieveCmd.Flags().Int("max-payload-bytes", 30_000, "Maximum combined payload bytes")
	retrieveCmd.Flags().String("paths", protocol.RetrievePathsBest, "Evidence paths per result: none, best, or all")
	rootCmd.AddCommand(retrieveCmd)
}
