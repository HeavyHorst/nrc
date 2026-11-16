package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
	"unicode/utf8"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

type monitorPolicy struct {
	Version    int      `json:"version"`
	Name       string   `json:"name"`
	Evaluator  string   `json:"evaluator"`
	Enabled    bool     `json:"enabled"`
	Interval   int64    `json:"interval_ns"`
	Timeout    int64    `json:"timeout_ns"`
	Failures   uint32   `json:"failures"`
	Recoveries uint32   `json:"recoveries"`
	Missing    uint32   `json:"missing"`
	Webhooks   []string `json:"webhooks"`
}

type monitorRecord struct {
	ID       uint64          `json:"id"`
	Revision string          `json:"revision"`
	Name     string          `json:"name"`
	Type     string          `json:"type"`
	Config   json.RawMessage `json:"config"`
	Check    json.RawMessage `json:"check,omitempty"`
}

func monitorRecordFrom(a p.Asset) (monitorRecord, error) {
	var name struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(a.Preview), &name); err != nil {
		return monitorRecord{}, err
	}
	r := monitorRecord{ID: a.AssetID, Revision: strconv.FormatInt(a.UpdatedAt, 10), Name: name.Name, Type: assetTypeName(a.AssetType), Config: json.RawMessage(a.Preview)}
	if a.Payload != "" {
		body, err := p.DecodeAssetPayload(a)
		if err != nil {
			return r, err
		}
		if !json.Valid([]byte(body)) {
			return r, fmt.Errorf("monitor %d has invalid check JSON", a.AssetID)
		}
		r.Check = json.RawMessage(body)
	}
	return r, nil
}

func newMonitorCommand() *cobra.Command {
	c := &cobra.Command{Use: "monitor", Short: "Manage HTTP, TCP and Victoria monitoring rules"}
	c.Example = "  nrc monitor source create metrics --kind victoriametrics --url http://metrics:8428\n  nrc monitor create Disk --source 123 --query-file disk.metricsql --identity instance,mountpoint --trigger '<10' --recovery '>15'\n  nrc monitor update 456 --interval 30s\n  nrc monitor update 456 --refresh-source --dry-run"
	s := &cobra.Command{Use: "source", Short: "Manage Victoria endpoints and immutable webhook routes; authentication is optional"}
	for _, pair := range []struct {
		cmd  *cobra.Command
		kind uint16
	}{{c, p.AssetTypeMonitor}, {s, p.AssetTypeMonitorSource}} {
		pair.cmd.AddCommand(monitorListCommand(pair.kind), monitorGetCommand(pair.kind), monitorWriteCommand(pair.kind, false), monitorWriteCommand(pair.kind, true))
	}
	c.AddCommand(s, monitorWebhookCommand(), monitorInstancesCommand())
	for _, action := range []p.MonitorInstanceAction{p.PauseMonitorInstance, p.ResumeMonitorInstance, p.RetireMonitorInstance} {
		c.AddCommand(monitorControlCommand(action))
	}
	return c
}

func monitorInstancesCommand() *cobra.Command {
	c := &cobra.Command{Use: "instances <monitor-id>", Short: "List instance IDs and current state, problems first", Args: cobra.ExactArgs(1)}
	c.Flags().Int("limit", 16, "Page size, 1–16")
	c.Flags().String("cursor", "", "Resume from next_cursor with the same monitor and include-retired setting")
	c.Flags().Bool("include-retired", false, "Include retired instances")
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		id, err := customerID(args[0])
		if err != nil {
			return err
		}
		limit, _ := cmd.Flags().GetInt("limit")
		if limit < 1 || limit > 16 {
			return &conn.InvalidArgumentError{Err: fmt.Errorf("--limit must be 1–16")}
		}
		retired, _ := cmd.Flags().GetBool("include-retired")
		q := p.MonitorStatusQuery{MonitorID: id, IncludeRetired: retired}
		cursor, _ := cmd.Flags().GetString("cursor")
		if cursor != "" {
			b, err := base64.RawURLEncoding.DecodeString(cursor)
			if err != nil || json.Unmarshal(b, &q) != nil || q.MonitorID != id || q.IncludeRetired != retired || q.CursorID == 0 || q.At <= 0 || q.CorrelationID != 0 {
				return &conn.InvalidArgumentError{Err: fmt.Errorf("invalid cursor or different monitor/include-retired setting")}
			}
		}
		q.Limit = uint8(limit)
		wire, err := p.EncodeQueryMonitorStatus(q)
		if err != nil {
			return &conn.InvalidArgumentError{Err: err}
		}
		response, err := s.SendAndRecv(&p.Message{Opcode: p.C_QueryMonitorStatus, Data: wire[2:]})
		if err != nil {
			return err
		}
		if response.Opcode != p.S_MonitorStatusPage {
			return fmt.Errorf("unexpected instance response %d", response.Opcode)
		}
		page, err := p.DecodeMonitorStatusPage(response.Data)
		if err != nil {
			return err
		}
		if page.CorrelationID != 0 || page.MonitorID != strconv.FormatUint(id, 10) {
			return fmt.Errorf("instance page does not match request")
		}
		next := ""
		if page.HasMore {
			q.CursorID, err = strconv.ParseUint(page.CursorID, 10, 64)
			if err != nil || q.CursorID == 0 {
				return fmt.Errorf("invalid instance page cursor")
			}
			q.At, err = strconv.ParseInt(page.At, 10, 64)
			if err != nil || q.At <= 0 {
				return fmt.Errorf("invalid instance page time")
			}
			q.CursorRank = page.CursorRank
			b, err := json.Marshal(q)
			if err != nil {
				return err
			}
			next = base64.RawURLEncoding.EncodeToString(b)
		}
		if useJSONOutput(cmd) {
			output.OutputJSON(struct {
				MonitorID  string               `json:"monitor_id"`
				At         string               `json:"at"`
				Entries    []p.MonitorStatusRow `json:"entries"`
				HasMore    bool                 `json:"has_more"`
				NextCursor string               `json:"next_cursor"`
			}{page.MonitorID, page.At, page.Rows, page.HasMore, next})
		} else {
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			fmt.Fprintln(w, "INSTANCE ID\tSTATE\tIDENTITY\tVALUE\tINCIDENT")
			for _, row := range page.Rows {
				value, incident := "—", row.IncidentID
				if row.Value != nil {
					value = strconv.FormatFloat(*row.Value, 'g', -1, 64)
				}
				if incident == "" || incident == "0" {
					incident = "—"
				}
				fmt.Fprintf(w, "%s\t%s\t%q\t%s\t%s\n", row.ID, row.Status, row.Identity, value, incident)
			}
			w.Flush()
			fmt.Printf("%d instances · as of %s (Unix nanoseconds)\n", len(page.Rows), page.At)
			if page.HasMore {
				fmt.Println("Next cursor:", next)
			}
		}
		return nil
	})
	return c
}

func monitorControlCommand(action p.MonitorInstanceAction) *cobra.Command {
	name := map[p.MonitorInstanceAction]string{p.PauseMonitorInstance: "pause", p.ResumeMonitorInstance: "resume", p.RetireMonitorInstance: "retire"}[action]
	c := &cobra.Command{Use: name + " <monitor-id> <instance-id>", Short: name + " one monitor instance using the current monitor revision", Args: cobra.ExactArgs(2), Annotations: map[string]string{"mutation": "true"}}
	if action == p.RetireMonitorInstance {
		c.Flags().Bool("confirm", false, "Close any open incident as removed; retain history and allow automatic reactivation")
	}
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		id, err := customerID(args[0])
		if err != nil {
			return err
		}
		instance, err := customerID(args[1])
		if err != nil {
			return err
		}
		if action == p.RetireMonitorInstance {
			confirmed, _ := cmd.Flags().GetBool("confirm")
			if !confirmed {
				return &conn.InvalidArgumentError{Err: fmt.Errorf("retirement closes the open incident as removed; pass --confirm")}
			}
		}
		a, err := customerAsset(s, id, p.AssetTypeMonitor)
		if err != nil {
			return err
		}
		wire, err := p.EncodeControlMonitorInstance(p.ControlMonitorInstance{MonitorID: id, Revision: a.UpdatedAt, InstanceID: instance, Action: action})
		if err != nil {
			return &conn.InvalidArgumentError{Err: err}
		}
		unconfirmed := func(err error) error {
			return &conn.CommandError{Err: fmt.Errorf("monitor instance action outcome unconfirmed; inspect the instance before retrying: %w", err)}
		}
		response, err := s.SendAndRecv(&p.Message{Opcode: p.C_ControlMonitorInstance, Data: wire[2:]})
		if err != nil {
			var serverError *conn.ServerError
			if errors.As(err, &serverError) {
				return err
			}
			return unconfirmed(err)
		}
		if response.Opcode != p.S_MonitorInstanceControlled {
			return unconfirmed(fmt.Errorf("unexpected control response %d", response.Opcode))
		}
		r, err := p.DecodeMonitorInstanceControlled(response.Data)
		if err != nil {
			return unconfirmed(err)
		}
		if r.CorrelationID != 0 || r.MonitorID != id || r.InstanceID != instance || r.Revision <= a.UpdatedAt {
			return unconfirmed(fmt.Errorf("control receipt does not match request"))
		}
		output.Mutation(name, "monitor_instance", instance, fmt.Sprintf("Monitor %d instance %d: %s accepted", id, instance, name), nil, map[string]any{"monitor_id": id, "revision": strconv.FormatInt(r.Revision, 10), "replayed": r.Replayed})
		return nil
	})
	return c
}

func monitorGetCommand(kind uint16) *cobra.Command {
	c := &cobra.Command{Use: "get <id>", Short: "Show decoded configuration and its revision", Args: cobra.ExactArgs(1)}
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		id, err := customerID(args[0])
		if err != nil {
			return err
		}
		a, err := customerAsset(s, id, kind)
		if err != nil {
			return err
		}
		r, err := monitorRecordFrom(a)
		if err != nil {
			return err
		}
		if useJSONOutput(cmd) {
			output.OutputJSON(r)
		} else {
			b, err := json.MarshalIndent(r, "", "  ")
			if err != nil {
				return err
			}
			fmt.Println(string(b))
		}
		return nil
	})
	return c
}

func monitoringAssetPage(cmd *cobra.Command, s *conn.Session, kind uint16) (*p.AssetListPageResponse, error) {
	limit, _ := cmd.Flags().GetInt("limit")
	if limit < 1 || limit > 250 {
		return nil, &conn.InvalidArgumentError{Err: fmt.Errorf("--limit must be 1–250")}
	}
	raw, _ := cmd.Flags().GetString("cursor")
	cursor := noteCursor{}
	if raw != "" {
		var err error
		cursor, err = decodeNoteCursor(raw)
		if err != nil {
			return nil, &conn.InvalidArgumentError{Err: err}
		}
	}
	resp, err := s.SendAndRecv(&p.Message{Opcode: p.C_ListAssetsPaged, Data: p.EncodeListAssetsPaged(0, kind, false, uint16(limit), raw != "", cursor.UpdatedAt, cursor.AssetID)})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != p.S_AssetListPage {
		return nil, fmt.Errorf("unexpected list response: %d", resp.Opcode)
	}
	return p.DecodeAssetListPage(resp.Data)
}

func monitorListCommand(kind uint16) *cobra.Command {
	c := &cobra.Command{Use: "list", Short: "List a configuration page (newest edits first, not alert priority)", Args: cobra.NoArgs}
	c.Flags().Int("limit", 50, "Page size, 1–250")
	c.Flags().String("cursor", "", "Resume from next_cursor with the same resource type")
	c.Run = customerRun(func(cmd *cobra.Command, _ []string, s *conn.Session) error {
		page, err := monitoringAssetPage(cmd, s, kind)
		if err != nil {
			return err
		}
		entries := make([]monitorRecord, 0, len(page.Assets))
		for _, a := range page.Assets {
			r, err := monitorRecordFrom(a)
			if err != nil {
				return err
			}
			entries = append(entries, r)
		}
		next := ""
		if page.HasMore {
			next = encodeNoteCursor(page.NextCursorUpdatedAt, page.NextCursorAssetID)
		}
		if useJSONOutput(cmd) {
			output.OutputJSON(map[string]any{"entries": entries, "has_more": page.HasMore, "next_cursor": next, "total_count": page.TotalCount})
		} else {
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			fmt.Fprintln(w, "ID\tNAME\tREVISION")
			for _, r := range entries {
				fmt.Fprintf(w, "%d\t%s\t%s\n", r.ID, r.Name, r.Revision)
			}
			w.Flush()
			if page.HasMore {
				fmt.Println("Next cursor:", next)
			}
		}
		return nil
	})
	return c
}

func monitorWriteCommand(kind uint16, update bool) *cobra.Command {
	c := &cobra.Command{Use: "create <name>", Short: "Create an HTTP, TCP or Victoria query monitor", Args: cobra.ExactArgs(1), Annotations: map[string]string{"mutation": "true"}}
	if kind == p.AssetTypeMonitorSource {
		c.Short = "Create a Victoria source without storing secret values"
	}
	if update {
		c.Use = "update <id>"
		c.Short = "Change only supplied fields; reject concurrent edits"
	}
	f := c.Flags()
	if update {
		f.String("name", "", "New display name")
	}
	f.Bool("dry-run", false, "Read dependencies and print proposed configuration without writing")
	if kind == p.AssetTypeMonitorSource {
		f.String("kind", "", "victoriametrics, victorialogs, or webhook (immutable route)")
		f.String("url", "", "Service base URL, including any cluster/proxy prefix")
		f.String("retention", "", "Descriptive retention, e.g. 7d; empty clears it")
		f.String("secret-ref", "", "Optional environment-secret name; empty removes authentication")
		f.Bool("insecure-tls", false, "Explicitly disable TLS certificate verification")
		if !update {
			_ = c.MarkFlagRequired("kind")
			_ = c.MarkFlagRequired("url")
		}
	} else {
		f.String("kind", "", "http or tcp; omit for a Victoria source")
		f.String("url", "", "HTTP check URL")
		f.String("address", "", "TCP host:port")
		f.Int("status", 200, "Required HTTP status (default 200 on create)")
		f.Duration("max-latency", 0, "Maximum HTTP response latency; zero removes condition")
		f.Duration("certificate-valid-for", 0, "Minimum remaining TLS certificate validity; zero removes condition")
		f.String("conditions-file", "", "Replace HTTP conditions with a JSON array from file or - for stdin (max 32 KiB)")
		f.Bool("insecure-tls", false, "Explicitly disable HTTP TLS certificate verification")
		f.Bool("follow-redirects", false, "Follow HTTP redirects")
		for _, name := range []string{"status", "max-latency", "certificate-valid-for"} {
			c.MarkFlagsMutuallyExclusive("conditions-file", name)
		}
		f.Uint64("source", 0, "Source asset ID; pins its current revision and infers the query kind")
		if update {
			f.Bool("refresh-source", false, "Explicitly pin the existing source's current revision")
		}
		f.String("query", "", "Complete MetricsQL/LogsQL query, including healthy result rows")
		f.String("query-file", "", "Read query from a UTF-8 file, or - for stdin (max 32 KiB)")
		c.MarkFlagsMutuallyExclusive("query", "query-file")
		f.StringSlice("identity", nil, "Identity labels, e.g. instance,mountpoint; replaces the entire list")
		f.String("trigger", "", "Alarm comparison, e.g. '<10' or '>=5' (quote it)")
		f.String("recovery", "", "Opposite recovery comparison, e.g. '>15'; empty clears hysteresis")
		f.Duration("interval", time.Minute, "Evaluation interval")
		f.Duration("timeout", 10*time.Second, "Query timeout, at most the interval")
		f.Uint32("failures", 5, "Consecutive failures before opening an incident")
		f.Uint32("recoveries", 5, "Consecutive successes before recovery")
		f.Uint32("missing", 3, "Consecutive missing results before no-data qualification")
		f.String("evaluator", "nrc-incidents", "Sidecar's authenticated evaluator nickname")
		f.Bool("enabled", true, "Schedule evaluations; this does not resolve open incidents")
		f.StringSlice("webhooks", nil, "Immutable webhook source asset IDs; empty clears the list")
	}
	var editFlags []string
	f.VisitAll(func(flag *pflag.Flag) {
		if flag.Name != "dry-run" {
			editFlags = append(editFlags, flag.Name)
		}
	})
	c.Run = customerRun(func(cmd *cobra.Command, args []string, s *conn.Session) error {
		a := p.Asset{AssetType: kind}
		if update {
			id, err := customerID(args[0])
			if err != nil {
				return err
			}
			a, err = customerAsset(s, id, kind)
			if err != nil {
				return err
			}
			changed := false
			for _, name := range editFlags {
				if cmd.Flags().Changed(name) {
					changed = true
				}
			}
			if !changed {
				return &conn.InvalidArgumentError{Err: fmt.Errorf("no changes specified")}
			}
		}
		var err error
		if kind == p.AssetTypeMonitorSource {
			a, err = buildMonitorSource(cmd, args[0], a, update)
		} else {
			a, err = buildMonitorRule(cmd, args[0], a, update, func(id uint64) (p.Asset, error) { return customerAsset(s, id, p.AssetTypeMonitorSource) })
		}
		if err != nil {
			return &conn.InvalidArgumentError{Err: err}
		}
		var body []byte
		op := uint8(p.TransactionOpAssetCreate)
		if update {
			op = p.TransactionOpAssetPatch
			body, err = p.EncodeTransactionAssetPatch(p.TransactionAssetPatch{Asset: p.Existing(p.TransactionEntityAsset, a.AssetID), IfUpdatedAt: a.UpdatedAt, Present: p.TransactionAssetPatchPreview | p.TransactionAssetPatchPayload, Preview: []byte(a.Preview), Payload: []byte(a.Payload), PayloadRawLen: uint32(len(a.Payload))})
		} else {
			body, err = p.EncodeTransactionAssetCreate(p.TransactionAssetCreate{AssetType: kind, Preview: []byte(a.Preview), Payload: []byte(a.Payload), PayloadRawLen: uint32(len(a.Payload))})
		}
		if err != nil {
			return &conn.InvalidArgumentError{Err: err}
		}
		if dry, _ := cmd.Flags().GetBool("dry-run"); dry {
			r, err := monitorRecordFrom(a)
			if err != nil {
				return err
			}
			output.OutputJSON(map[string]any{"dry_run": true, "record": r})
			return nil
		}
		result, err := customerTransaction(s, []p.TransactionOperation{{Type: op, Body: body}})
		if err != nil {
			return err
		}
		action := "created"
		if update {
			action = "updated"
		}
		extra := map[string]any{}
		message := fmt.Sprintf("%s %s: %d", assetTypeName(kind), action, result.Results[0].EntityID)
		if update && kind == p.AssetTypeMonitorSource {
			extra["dependent_monitors_need_refresh"] = true
			message += "; refresh referencing monitors explicitly with monitor update <id> --refresh-source"
		}
		output.Mutation(action, assetTypeName(kind), result.Results[0].EntityID, message, nil, extra)
		return nil
	})
	return c
}

func buildMonitorSource(cmd *cobra.Command, name string, a p.Asset, update bool) (p.Asset, error) {
	s := p.MonitorSource{Version: 1, Name: name}
	if update {
		var err error
		s, err = p.DecodeMonitorSource(a)
		if err != nil {
			return a, err
		}
		if s.Kind == "webhook" {
			return a, fmt.Errorf("webhook routes are immutable; create a new source with --kind webhook")
		}
	}
	f := cmd.Flags()
	for flag, dst := range map[string]*string{"name": &s.Name, "kind": &s.Kind, "url": &s.BaseURL, "retention": &s.Retention, "secret-ref": &s.SecretRef} {
		if f.Changed(flag) {
			*dst, _ = f.GetString(flag)
		}
	}
	if f.Changed("insecure-tls") {
		s.InsecureTLS, _ = f.GetBool("insecure-tls")
	}
	if update && s.Kind == "webhook" {
		return a, fmt.Errorf("create a new webhook route instead of changing a source's kind")
	}
	b, err := json.Marshal(s)
	if err != nil {
		return a, err
	}
	a.Preview = string(b)
	_, err = p.DecodeMonitorSource(a)
	if err != nil {
		return a, fmt.Errorf("invalid source: check --kind, --url and --secret-ref (a name, never a token)")
	}
	return a, nil
}

func monitorComparison(raw string) (json.RawMessage, *big.Rat, string, error) {
	op := ""
	for _, candidate := range []string{"<=", ">=", "<", ">"} {
		if strings.HasPrefix(raw, candidate) {
			op = candidate
			break
		}
	}
	n := strings.TrimSpace(strings.TrimPrefix(raw, op))
	if op == "" || len(n) == 0 || len(n) > 128 || !json.Valid([]byte(n)) || n[0] != '-' && (n[0] < '0' || n[0] > '9') {
		return nil, nil, "", fmt.Errorf("comparison must be '<10', '<=10', '>15' or '>=15'")
	}
	if i := strings.IndexAny(n, "eE"); i >= 0 {
		e, err := strconv.Atoi(n[i+1:])
		if err != nil || e < -308 || e > 308 {
			return nil, nil, "", fmt.Errorf("comparison exponent must be -308..308")
		}
	}
	value, ok := new(big.Rat).SetString(n)
	if !ok {
		return nil, nil, "", fmt.Errorf("invalid comparison number")
	}
	b, err := json.Marshal(struct {
		Op    string      `json:"op"`
		Value json.Number `json:"value"`
	}{op, json.Number(n)})
	return b, value, op, err
}

func buildMonitorRule(cmd *cobra.Command, name string, a p.Asset, update bool, load func(uint64) (p.Asset, error)) (p.Asset, error) {
	f := cmd.Flags()
	c := monitorPolicy{Version: 1, Name: name}
	d := map[string]json.RawMessage{}
	if update {
		if err := json.Unmarshal([]byte(a.Preview), &c); err != nil {
			return a, err
		}
		if a.PayloadEncoding != 0 {
			return a, fmt.Errorf("monitor check must use plain JSON")
		}
		if err := json.Unmarshal([]byte(a.Payload), &d); err != nil || d == nil {
			return a, fmt.Errorf("invalid monitor check")
		}
	}
	set := func(key string, v any) { d[key], _ = json.Marshal(v) }
	if f.Changed("name") {
		c.Name, _ = f.GetString("name")
	}
	if !update || f.Changed("interval") {
		v, _ := f.GetDuration("interval")
		c.Interval = int64(v)
	}
	if !update || f.Changed("timeout") {
		v, _ := f.GetDuration("timeout")
		c.Timeout = int64(v)
	}
	if !update || f.Changed("enabled") {
		c.Enabled, _ = f.GetBool("enabled")
	}
	if !update || f.Changed("evaluator") {
		c.Evaluator, _ = f.GetString("evaluator")
	}
	for flag, dst := range map[string]*uint32{"failures": &c.Failures, "recoveries": &c.Recoveries, "missing": &c.Missing} {
		if !update || f.Changed(flag) {
			*dst, _ = f.GetUint32(flag)
		}
	}
	if f.Changed("webhooks") {
		c.Webhooks, _ = f.GetStringSlice("webhooks")
	}
	if c.Version != 1 || strings.TrimSpace(c.Name) == "" || len(c.Name) > 256 || c.Evaluator == "" || len(c.Evaluator) > p.MaxOwnerLength || c.Interval <= 0 || c.Timeout <= 0 || c.Timeout > c.Interval || c.Interval > (math.MaxInt64-c.Timeout)/3 || c.Failures == 0 || c.Recoveries == 0 || c.Missing == 0 {
		return a, fmt.Errorf("invalid policy: name/evaluator required, positive thresholds and 0 < timeout <= interval")
	}
	if len(c.Webhooks) > 8 {
		return a, fmt.Errorf("at most eight webhook routes")
	}
	seen := map[string]bool{}
	for _, route := range c.Webhooks {
		_, err := p.EncodeMonitorDelivery(p.MonitorDelivery{MonitorID: 1, Stream: 1, Route: route})
		if err != nil || seen[route] {
			return a, fmt.Errorf("invalid or duplicate webhook route %q", route)
		}
		if f.Changed("webhooks") {
			id, err := strconv.ParseUint(route, 10, 64)
			if err != nil || id == 0 || strconv.FormatUint(id, 10) != route {
				return a, fmt.Errorf("webhook route must be a canonical source asset ID")
			}
			asset, err := load(id)
			if err != nil {
				return a, err
			}
			routeConfig, err := p.DecodeMonitorSource(asset)
			if err != nil || routeConfig.Kind != "webhook" {
				return a, fmt.Errorf("source %d is not a webhook route", id)
			}
		}
		seen[route] = true
	}
	var checkKind string
	_ = json.Unmarshal(d["kind"], &checkKind)
	if f.Changed("kind") {
		requested, _ := f.GetString("kind")
		if requested != "http" && requested != "tcp" || update && requested != checkKind {
			return a, fmt.Errorf("--kind must be http or tcp; changing check kind requires a new monitor")
		}
		checkKind = requested
		set("kind", checkKind)
	}
	if checkKind == "http" || checkKind == "tcp" {
		if err := buildNetworkMonitor(cmd, d, checkKind, update); err != nil {
			return a, err
		}
	} else {
		for _, name := range []string{"url", "address", "status", "max-latency", "certificate-valid-for", "conditions-file", "insecure-tls", "follow-redirects"} {
			if f.Changed(name) {
				return a, fmt.Errorf("--%s requires --kind http or tcp", name)
			}
		}
		refresh, _ := f.GetBool("refresh-source")
		if f.Changed("source") || refresh || !update {
			id, _ := f.GetUint64("source")
			if !f.Changed("source") && update {
				var old string
				_ = json.Unmarshal(d["source_id"], &old)
				id, _ = strconv.ParseUint(old, 10, 64)
			}
			if id == 0 {
				return a, fmt.Errorf("--source must be a nonzero source ID")
			}
			source, err := load(id)
			if err != nil {
				return a, err
			}
			config, err := p.DecodeMonitorSource(source)
			if err != nil {
				return a, err
			}
			if source.UpdatedAt <= 0 {
				return a, fmt.Errorf("source has no valid revision")
			}
			if config.Kind == "webhook" {
				return a, fmt.Errorf("webhook routes cannot be used as query sources")
			}
			set("kind", config.Kind)
			set("source_id", strconv.FormatUint(id, 10))
			set("source_revision", strconv.FormatInt(source.UpdatedAt, 10))
		}
		if f.Changed("query") && f.Changed("query-file") {
			return a, fmt.Errorf("use --query or --query-file, not both")
		}
		if f.Changed("query-file") {
			path, _ := f.GetString("query-file")
			var reader io.Reader = cmd.InOrStdin()
			if path != "-" {
				file, err := os.Open(path)
				if err != nil {
					return a, err
				}
				defer file.Close()
				reader = file
			}
			b, err := io.ReadAll(io.LimitReader(reader, 32769))
			if err != nil {
				return a, err
			}
			if len(b) > 32768 || !utf8.Valid(b) {
				return a, fmt.Errorf("query file must be UTF-8 and at most 32 KiB")
			}
			set("query", string(b))
		} else if f.Changed("query") {
			q, _ := f.GetString("query")
			if !utf8.ValidString(q) {
				return a, fmt.Errorf("query must be UTF-8")
			}
			set("query", q)
		}
		var query, kind string
		_ = json.Unmarshal(d["query"], &query)
		_ = json.Unmarshal(d["kind"], &kind)
		if strings.TrimSpace(query) == "" || len(query) > 32768 || !utf8.ValidString(query) {
			return a, fmt.Errorf("query must contain 1–32768 UTF-8 bytes")
		}
		if kind == "victorialogs" && strings.Contains(strings.ToLower(query), "allow_partial_response") {
			return a, fmt.Errorf("LogsQL allow_partial_response overrides are forbidden")
		}
		if f.Changed("identity") {
			labels, _ := f.GetStringSlice("identity")
			set("identity_labels", labels)
		}
		var labels []string
		if json.Unmarshal(d["identity_labels"], &labels) != nil || len(labels) == 0 || len(labels) > 32 {
			return a, fmt.Errorf("--identity requires 1–32 labels")
		}
		seen = map[string]bool{}
		for _, label := range labels {
			if label == "" || len(label) > 256 || !utf8.ValidString(label) || seen[label] {
				return a, fmt.Errorf("invalid or duplicate identity label %q", label)
			}
			seen[label] = true
		}
		for _, key := range []string{"trigger", "recovery"} {
			if f.Changed(key) {
				raw, _ := f.GetString(key)
				if key == "recovery" && raw == "" {
					delete(d, key)
					continue
				}
				b, _, _, err := monitorComparison(raw)
				if err != nil {
					return a, err
				}
				d[key] = b
			}
		}
		values := map[string]*big.Rat{}
		ops := map[string]string{}
		for _, key := range []string{"trigger", "recovery"} {
			if key == "recovery" && (len(d[key]) == 0 || string(d[key]) == "null") {
				continue
			}
			var v struct {
				Op    string
				Value json.Number
			}
			if json.Unmarshal(d[key], &v) != nil {
				return a, fmt.Errorf("valid --trigger required")
			}
			_, n, op, err := monitorComparison(v.Op + string(v.Value))
			if err != nil {
				return a, err
			}
			values[key], ops[key] = n, op
		}
		if recovery := values["recovery"]; recovery != nil {
			below := strings.HasPrefix(ops["trigger"], "<")
			order := values["trigger"].Cmp(recovery)
			if below == strings.HasPrefix(ops["recovery"], "<") || below && order > 0 || !below && order < 0 || order == 0 && strings.HasSuffix(ops["trigger"], "=") && strings.HasSuffix(ops["recovery"], "=") {
				return a, fmt.Errorf("recovery must oppose trigger without overlapping it")
			}
		}
	}
	preview, err := json.Marshal(c)
	if err != nil {
		return a, err
	}
	payload, err := json.Marshal(d)
	if err != nil {
		return a, err
	}
	a.Preview, a.Payload = string(preview), string(payload)
	a.PayloadRawLen = uint32(len(payload))
	return a, nil
}

func init() { rootCmd.AddCommand(newMonitorCommand()) }
