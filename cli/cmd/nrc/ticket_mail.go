package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/spf13/cobra"
)

// Administrative transport operations use the private mail listener, not the
// public customer API. Credentials are read from a protected file, never flags.
func ticketMailCommand() *cobra.Command {
	root := &cobra.Command{Use: "mail", Short: "Private ticket mail journal: list, inspect, retry definite failures"}
	for _, action := range []string{"list", "raw", "retry"} {
		c := &cobra.Command{Use: action + " <job-id>", Args: cobra.ExactArgs(1)}
		if action == "list" {
			c.Use = "list"
			c.Args = cobra.NoArgs
		}
		if action == "retry" {
			c.Annotations = map[string]string{"mutation": "true"}
		}
		c.RunE = func(cmd *cobra.Command, args []string) error {
			base, err := url.Parse(os.Getenv("NRC_TICKET_MAIL_URL"))
			if err != nil || base == nil || base.Host == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" || base.Path != "" && base.Path != "/" {
				return fmt.Errorf("NRC_TICKET_MAIL_URL must be the private mail listener origin")
			}
			if base.Scheme != "https" && !(base.Scheme == "http" && (base.Hostname() == "127.0.0.1" || base.Hostname() == "localhost" || base.Hostname() == "::1")) {
				return fmt.Errorf("mail administration requires HTTPS or loopback HTTP")
			}
			f, err := os.Open(os.Getenv("NRC_TICKET_MAIL_SECRET_FILE"))
			if err != nil {
				return fmt.Errorf("private NRC_TICKET_MAIL_SECRET_FILE required")
			}
			defer f.Close()
			st, err := f.Stat()
			if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 {
				return fmt.Errorf("mail secret file must be private")
			}
			secret, err := io.ReadAll(io.LimitReader(f, 4097))
			if err != nil || len(secret) > 4096 || len(strings.TrimSpace(string(secret))) < 32 {
				return fmt.Errorf("invalid mail secret file")
			}
			path, method := "/jobs", "GET"
			if action != "list" {
				if strings.ContainsAny(args[0], "/.?#\\") {
					return fmt.Errorf("invalid job ID")
				}
				path += "/" + url.PathEscape(args[0]) + "/" + action
			}
			if action == "retry" {
				method = "POST"
			}
			req, err := http.NewRequestWithContext(cmd.Context(), method, strings.TrimRight(base.String(), "/")+path, nil)
			if err != nil {
				return err
			}
			req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(secret)))
			req.Header.Set("Content-Type", "application/json")
			client := &http.Client{Timeout: 2 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
			resp, err := client.Do(req)
			if err != nil {
				return fmt.Errorf("mail request failed; inspect saved state before retrying a mutation")
			}
			defer resp.Body.Close()
			if resp.StatusCode < 200 || resp.StatusCode >= 300 {
				return fmt.Errorf("mail request refused (HTTP %d); inspect journal state", resp.StatusCode)
			}
			if action == "raw" {
				_, err = io.Copy(cmd.OutOrStdout(), io.LimitReader(resp.Body, 32<<20))
				return err
			}
			if action == "list" {
				var value any
				if err = json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&value); err != nil {
					return err
				}
				output.OutputJSON(value)
			} else {
				output.OutputJSON(map[string]string{"state": "accepted"})
			}
			return nil
		}
		root.AddCommand(c)
	}
	return root
}
