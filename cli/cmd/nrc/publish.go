package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/spf13/cobra"
)

func runPublish(ctx context.Context, method, path string, input any) (map[string]any, error) {
	base := strings.TrimRight(os.Getenv("NRC_PUBLISH_URL"), "/")
	if base == "" {
		cfg, err := config.Load()
		if err != nil {
			return nil, err
		}
		base = strings.TrimRight(cfg.GetProxyURL(), "/")
	}
	u, err := url.Parse(base)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, fmt.Errorf("configure the Tailscale proxy URL or set NRC_PUBLISH_URL to that proxy's base URL")
	}
	var body []byte
	if input != nil {
		body, err = json.Marshal(input)
		if err != nil {
			return nil, err
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, base+"/publish"+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("publish request failed; for draft creation the outcome may be unknown, inspect `nrc publish list` before retrying: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, (16<<20)+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 16<<20 {
		return nil, fmt.Errorf("publish response exceeds 16 MiB")
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		var apiError struct {
			Error string `json:"error"`
		}
		json.Unmarshal(data, &apiError)
		return nil, fmt.Errorf("publish API returned HTTP %d: %s", resp.StatusCode, apiError.Error)
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		return nil, fmt.Errorf("decode publish response: %w", err)
	}
	return result, nil
}

var publishCmd = &cobra.Command{Use: "publish", Short: "Prepare public knowledge-base drafts (human approval required)"}

func publishOutput(cmd *cobra.Command, result map[string]any) {
	if useJSONOutput(cmd) {
		output.OutputJSON(result)
		return
	}
	data, _ := json.MarshalIndent(result, "", "  ")
	fmt.Println(string(data))
}

func init() {
	list := &cobra.Command{Use: "list", Short: "List published articles and pending drafts", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		result, err := runPublish(cmd.Context(), http.MethodGet, "/api/publications", nil)
		if err != nil {
			return err
		}
		publishOutput(cmd, result)
		return nil
	}}
	inspect := &cobra.Command{Use: "inspect <draft-id>", Short: "Read the stored draft, published version and human review link", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		if len(args[0]) != 32 || strings.Trim(args[0], "0123456789abcdef") != "" {
			return fmt.Errorf("invalid draft ID")
		}
		result, err := runPublish(cmd.Context(), http.MethodGet, "/api/drafts/"+args[0], nil)
		if err != nil {
			return err
		}
		publishOutput(cmd, result)
		return nil
	}}
	draft := &cobra.Command{Use: "draft", Short: "Copy a current NRC note into a private review draft; never publishes", Args: cobra.NoArgs, Annotations: map[string]string{"mutation": "true"}, RunE: func(cmd *cobra.Command, args []string) error {
		note, _ := cmd.Flags().GetString("note")
		id, err := strconv.ParseUint(note, 10, 64)
		if err != nil || id == 0 {
			return fmt.Errorf("--note must be a positive NRC note ID")
		}
		input := map[string]string{"note_id": strconv.FormatUint(id, 10)}
		for _, name := range []string{"slug", "title", "summary", "category", "kind"} {
			input[name], _ = cmd.Flags().GetString(name)
		}
		result, err := runPublish(cmd.Context(), http.MethodPost, "/api/drafts", input)
		if err != nil {
			return err
		}
		publishOutput(cmd, result)
		return nil
	}}
	for _, name := range []string{"note", "slug", "title", "category"} {
		draft.Flags().String(name, "", "Public draft "+name)
		draft.MarkFlagRequired(name)
	}
	draft.Flags().String("summary", "", "Public article summary")
	draft.Flags().String("kind", "Anleitung", "Article kind: Anleitung, Referenz, Fehlerbehebung")
	publishCmd.AddCommand(list, draft, inspect)
	rootCmd.AddCommand(publishCmd)
}
