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
	"strings"
	"time"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/spf13/cobra"
)

// Explicit read DTOs keep --fields independent of collection contents/order.
type newsletterCampaign struct {
	Kind           string          `json:"kind"`
	Audience       string          `json:"audience"`
	CustomerIDs    []string        `json:"customer_ids"`
	ServiceReason  string          `json:"service_reason"`
	ID             string          `json:"id"`
	Title          string          `json:"title"`
	TemplateID     string          `json:"template_id"`
	Subject        string          `json:"subject"`
	Variables      json.RawMessage `json:"variables"`
	Status         string          `json:"status"`
	Archived       bool            `json:"archived"`
	Revision       int             `json:"revision"`
	TestedRevision int             `json:"tested_revision"`
	CreatedAt      string          `json:"created_at"`
	UpdatedAt      string          `json:"updated_at"`
	Recipients     json.RawMessage `json:"recipients"`
	Error          string          `json:"error,omitempty"`
}
type newsletterSubscriber struct {
	ContactID   string          `json:"contact_id"`
	Name        string          `json:"name"`
	Email       string          `json:"email"`
	Status      string          `json:"status"`
	Companies   json.RawMessage `json:"companies"`
	Source      *string         `json:"source,omitempty"`
	ConfirmedAt *string         `json:"confirmed_at,omitempty"`
	ImportProof json.RawMessage `json:"import_proof,omitempty"`
}
type newsletterTemplate struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Variables []string `json:"variables"`
}
type newsletterCustomer struct {
	CustomerID string          `json:"customer_id"`
	Name       string          `json:"name"`
	Contacts   json.RawMessage `json:"contacts"`
}
type newsletterState struct {
	Configured  bool                   `json:"configured"`
	FromEmail   string                 `json:"from_email"`
	FromName    string                 `json:"from_name"`
	ReplyTo     string                 `json:"reply_to"`
	Templates   []newsletterTemplate   `json:"templates"`
	Customers   []newsletterCustomer   `json:"customers"`
	Campaigns   []newsletterCampaign   `json:"campaigns"`
	Subscribers []newsletterSubscriber `json:"subscribers"`
	Audience    map[string]int         `json:"audience"`
}

func runNewsletter(ctx context.Context, method, path string, input, result any) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	base := strings.TrimRight(cfg.GetProxyURL(), "/")
	u, err := url.Parse(base)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("configure the Tailscale proxy URL with `nrc config set proxy-url`")
	}
	var body []byte
	if input != nil {
		body, err = json.Marshal(input)
		if err != nil {
			return err
		}
		if len(body) > 64<<10 {
			return fmt.Errorf("newsletter request exceeds 64 KiB; split consent imports into smaller batches")
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, base+"/newsletter/api"+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-NRC-Workspace", cfg.WorkspaceID)
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("newsletter request failed; mutation outcome may be unknown, inspect `nrc newsletter state` before retrying: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, (16<<20)+1))
	if err != nil {
		return fmt.Errorf("newsletter response incomplete; inspect state before retrying mutations: %w", err)
	}
	if len(data) > 16<<20 {
		return fmt.Errorf("newsletter response exceeds 16 MiB; inspect state before retrying mutations")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var apiError struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(data, &apiError)
		if apiError.Error == "" {
			apiError.Error = http.StatusText(resp.StatusCode)
		}
		return fmt.Errorf("newsletter API returned HTTP %d: %s", resp.StatusCode, apiError.Error)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(result); err != nil {
		return fmt.Errorf("decode newsletter response; inspect state before retrying mutations: %w", err)
	}
	return nil
}

func newsletterInput(cmd *cobra.Command) (any, error) {
	path, _ := cmd.Flags().GetString("input")
	reader := cmd.InOrStdin()
	if path != "" && path != "-" {
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		defer file.Close()
		reader = file
	}
	data, err := io.ReadAll(io.LimitReader(reader, (64<<10)+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 64<<10 {
		return nil, fmt.Errorf("newsletter input exceeds 64 KiB")
	}
	var value any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return nil, fmt.Errorf("invalid JSON input: %w", err)
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, fmt.Errorf("expected one JSON document")
	}
	return value, nil
}

func newsletterOutput(cmd *cobra.Command, result any) {
	if useJSONOutput(cmd) {
		output.OutputJSON(result)
	} else {
		data, _ := json.MarshalIndent(result, "", "  ")
		fmt.Fprintln(cmd.OutOrStdout(), string(data))
	}
}

func newNewsletterCommand() *cobra.Command {
	group := &cobra.Command{Use: "newsletter", Short: "Manage Mailjet campaigns, service information and newsletter consent"}
	for _, field := range []string{"state", "templates", "customers"} {
		c := &cobra.Command{Use: field, Short: "Read newsletter " + field, Args: cobra.NoArgs}
		c.RunE = func(cmd *cobra.Command, _ []string) error {
			var result newsletterState
			if err := runNewsletter(cmd.Context(), http.MethodGet, "/state", nil, &result); err != nil {
				return err
			}
			switch field {
			case "state":
				newsletterOutput(cmd, result)
			case "templates":
				newsletterOutput(cmd, result.Templates)
			case "customers":
				newsletterOutput(cmd, result.Customers)
			}
			return nil
		}
		group.AddCommand(c)
	}
	campaign := &cobra.Command{Use: "campaign", Short: "Manage newsletter or non-promotional service campaigns"}
	subscriber := &cobra.Command{Use: "subscriber", Short: "Inspect subscriptions and handle individual requests"}
	for _, resource := range []struct {
		command *cobra.Command
		field   string
	}{{campaign, "campaigns"}, {subscriber, "subscribers"}} {
		list := &cobra.Command{Use: "list", Short: "List " + resource.field, Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
			var result newsletterState
			if err := runNewsletter(cmd.Context(), http.MethodGet, "/state", nil, &result); err != nil {
				return err
			}
			if resource.field == "campaigns" {
				includeArchived, _ := cmd.Flags().GetBool("include-archived")
				rows := []newsletterCampaign{}
				for _, row := range result.Campaigns {
					if includeArchived || !row.Archived {
						rows = append(rows, row)
					}
				}
				newsletterOutput(cmd, rows)
			} else {
				newsletterOutput(cmd, result.Subscribers)
			}
			return nil
		}}
		if resource.field == "campaigns" {
			list.Flags().Bool("include-archived", false, "Include archived campaigns and their delivery history")
		}
		resource.command.AddCommand(list)
	}
	searchContacts := &cobra.Command{Use: "search", Short: "Search a bounded contact page by name, email or company (no embeddings)", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		query, _ := cmd.Flags().GetString("query")
		offset, _ := cmd.Flags().GetInt("offset")
		limit, _ := cmd.Flags().GetInt("limit")
		if offset < 0 || limit < 1 || limit > 250 {
			return fmt.Errorf("offset must be nonnegative; limit must be 1–250")
		}
		var result map[string]any
		if err := runNewsletter(cmd.Context(), http.MethodPost, "/subscribers/search", map[string]any{"query": query, "offset": offset, "limit": limit}, &result); err != nil {
			return err
		}
		newsletterOutput(cmd, result)
		return nil
	}}
	searchContacts.Flags().String("query", "", "Case-insensitive substring (empty lists all contacts)")
	searchContacts.Flags().Int("offset", 0, "Offset from the preceding page's next_offset")
	searchContacts.Flags().Int("limit", 25, "Maximum contacts per page (1–250)")
	subscriber.AddCommand(searchContacts)
	for _, action := range []string{"create", "update", "audience", "preview", "test", "send", "delete", "archive", "restore"} {
		use, args := action+" <campaign-id>", cobra.ExactArgs(1)
		if action == "create" {
			use, args = action, cobra.NoArgs
		}
		c := &cobra.Command{Use: use, Short: action + " campaign", Args: args}
		if action != "audience" && action != "preview" {
			c.Annotations = map[string]string{"mutation": "true"}
		}
		if action == "create" || action == "update" {
			c.Flags().String("input", "", "Campaign JSON file (default stdin; update replaces the complete draft)")
		}
		if action != "create" {
			c.Flags().Int("revision", 0, "Exact campaign revision to operate on")
			_ = c.MarkFlagRequired("revision")
		}
		if action == "test" {
			c.Flags().String("email", "", "Test email recipient (sends real mail)")
			_ = c.MarkFlagRequired("email")
		}
		if action == "send" {
			c.Flags().String("confirm-subject", "", "Exact subject confirming real delivery to the reviewed audience")
			_ = c.MarkFlagRequired("confirm-subject")
			c.Flags().String("audience-token", "", "Token from audience review; required for service campaigns")
		}
		c.RunE = func(cmd *cobra.Command, args []string) error {
			method, path := http.MethodPost, "/campaigns"
			input := map[string]any{}
			if action != "create" {
				if len(args[0]) != 64 || strings.Trim(args[0], "0123456789abcdef") != "" {
					return fmt.Errorf("invalid campaign ID")
				}
				path += "/" + args[0]
				revision, _ := cmd.Flags().GetInt("revision")
				if revision <= 0 {
					return fmt.Errorf("--revision must be positive")
				}
				input["revision"] = revision
			}
			if action == "create" || action == "update" {
				value, err := newsletterInput(cmd)
				if err != nil {
					return err
				}
				draft, ok := value.(map[string]any)
				if !ok || draft == nil {
					return fmt.Errorf("campaign input must be a JSON object")
				}
				if action == "update" {
					method = http.MethodPut
					// encoding/json also accepts case-folded Unicode aliases (e.g. ſ).
					// Only the explicit flag may select the optimistic revision.
					for key := range draft {
						if strings.EqualFold(key, "revision") {
							delete(draft, key)
						}
					}
					draft["revision"] = input["revision"]
				}
				input = draft
			} else {
				path += "/" + action
				if action == "test" {
					input["email"], _ = cmd.Flags().GetString("email")
				}
				if action == "send" {
					input["confirmation"], _ = cmd.Flags().GetString("confirm-subject")
					input["audience_token"], _ = cmd.Flags().GetString("audience-token")
				}
			}
			var result map[string]any
			if err := runNewsletter(cmd.Context(), method, path, input, &result); err != nil {
				return err
			}
			newsletterOutput(cmd, result)
			return nil
		}
		campaign.AddCommand(c)
	}
	for _, action := range []string{"invite", "unsubscribe"} {
		c := &cobra.Command{Use: action + " <contact-id>", Short: action + " individual contact (invite sends a DOI email)", Args: cobra.ExactArgs(1), Annotations: map[string]string{"mutation": "true"}}
		if action == "invite" {
			c.Flags().String("source", "", "Evidence of this individual's signup request; never invite the whole CRM")
			_ = c.MarkFlagRequired("source")
		}
		c.RunE = func(cmd *cobra.Command, args []string) error {
			id, err := customerID(args[0])
			if err != nil {
				return err
			}
			input := map[string]string{}
			if action == "invite" {
				input["source"], _ = cmd.Flags().GetString("source")
			}
			var result map[string]any
			if err := runNewsletter(cmd.Context(), http.MethodPost, fmt.Sprintf("/subscribers/%d/%s", id, action), input, &result); err != nil {
				return err
			}
			newsletterOutput(cmd, result)
			return nil
		}
		subscriber.AddCommand(c)
	}
	consent := &cobra.Command{Use: "consent", Short: "Import existing, documented newsletter consent"}
	importCmd := &cobra.Command{Use: "import", Short: "Preview consent import; only --confirm writes (never sends mail)", Args: cobra.NoArgs, Annotations: map[string]string{"mutation": "true"}}
	importCmd.Flags().String("input", "", "JSON array or {records:[...]} file (default stdin)")
	importCmd.Flags().Bool("confirm", false, "Import eligible consents after reviewing the preview; preserves optouts and blocks")
	importCmd.RunE = func(cmd *cobra.Command, _ []string) error {
		value, err := newsletterInput(cmd)
		if err != nil {
			return err
		}
		if envelope, ok := value.(map[string]any); ok {
			for key := range envelope {
				if key != "records" {
					return fmt.Errorf("import input only accepts records; use --confirm explicitly to write")
				}
			}
			value = envelope["records"]
		}
		records, ok := value.([]any)
		if !ok || len(records) == 0 || len(records) > 200 {
			return fmt.Errorf("import requires an array of 1 to 200 consent records")
		}
		confirm, _ := cmd.Flags().GetBool("confirm")
		var result map[string]any
		if err := runNewsletter(cmd.Context(), http.MethodPost, "/consents/import", map[string]any{"records": records, "confirm": confirm}, &result); err != nil {
			return err
		}
		newsletterOutput(cmd, result)
		return nil
	}
	consent.AddCommand(importCmd)
	group.AddCommand(campaign, subscriber, consent)
	return group
}

func init() { rootCmd.AddCommand(newNewsletterCommand()) }
