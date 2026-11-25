package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"unicode/utf8"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

const reviewCorrelation uint32 = 1

type reviewError struct{ code, message string }

func (e *reviewError) Error() string { return e.message }

func reviewInvalid(message string) error {
	return &conn.InvalidArgumentError{Err: errors.New(message)}
}

func reviewCommand(use, short string, count int, mutation bool, run func(*cobra.Command, []string) error) *cobra.Command {
	c := &cobra.Command{Use: use, Short: short, Args: cobra.ExactArgs(count)}
	if mutation {
		c.Annotations = map[string]string{"mutation": "true"}
	}
	c.Run = func(cmd *cobra.Command, args []string) {
		if err := run(cmd, args); err != nil {
			var failure *reviewError
			if errors.As(err, &failure) {
				output.Error(failure.code, failure.message, false)
			}
			conn.Fail(err)
		}
	}
	return c
}

func reviewFlag(cmd *cobra.Command, name string) string {
	value, _ := cmd.Flags().GetString(name)
	return value
}

func reviewRequiredFlag(c *cobra.Command, name, help string) {
	c.Flags().String(name, "", help)
	_ = c.MarkFlagRequired(name)
}

func encodeReview(q p.ReviewRequest) ([]byte, error) {
	frame, err := p.EncodeReviewRequest(q, reviewCorrelation)
	if err != nil {
		return nil, &conn.InvalidArgumentError{Err: err}
	}
	return frame[2:], nil
}

func exchangeReview(s *conn.Session, q p.ReviewRequest, payload []byte, mutation bool) (*p.ReviewResponse, error) {
	// C_Review is not on Session.SendAndRecv's retry allowlist. Each
	// invocation sends the mutation once, with the caller's original token.
	unknown := func(err error) error {
		if mutation {
			return &reviewError{"review_outcome_unconfirmed", fmt.Sprintf("Review %s outcome unconfirmed; inspect the current form or run before trying again: %v", q.Op, err)}
		}
		return err
	}
	m, err := s.SendAndRecv(&p.Message{Opcode: p.C_Review, Data: payload})
	if err != nil {
		if !mutation {
			return nil, err
		}
		var server *conn.ServerError
		if errors.As(err, &server) && server.OriginOpcode == p.C_Review && server.CorrelationID == reviewCorrelation {
			// The overload codes explicitly confirm that the request was not
			// admitted. Other transport errors cannot confirm a write outcome.
			if _, overloaded := p.DatabaseRetryDelay(server.Message, 0); overloaded {
				return nil, err
			}
			return nil, unknown(fmt.Errorf("server could not confirm the review request"))
		}
		return nil, unknown(err)
	}
	if m.Opcode != p.S_Review {
		return nil, unknown(fmt.Errorf("unexpected review response opcode %d", m.Opcode))
	}
	r, err := p.DecodeReviewResponse(m.Data)
	if err != nil || r.CorrelationID != reviewCorrelation {
		// Don't include raw decoder errors: an invite receipt carries a secret.
		return nil, unknown(fmt.Errorf("invalid or uncorrelated review response"))
	}
	switch r.Status {
	case "ok":
	case "conflict":
		return nil, &reviewError{"conflict", "Review state changed; read the current record and inspect it before submitting a new request"}
	case "invalid", "forbidden", "not_found", "released", "has_runs", "archived", "closed":
		return nil, &reviewError{r.Status, fmt.Sprintf("Review %s: %s", q.Op, r.Status)}
	default:
		return nil, unknown(fmt.Errorf("unexpected review response status"))
	}
	if err := validateReviewReceipt(q, r); err != nil {
		return nil, unknown(err)
	}
	return r, nil
}

func validateReviewReceipt(q p.ReviewRequest, r *p.ReviewResponse) error {
	valid := false
	switch q.Op {
	case "create", "copy":
		valid = r.FormID != "" && r.FormID != q.FormID && r.Revision != ""
	case "get", "update", "release", "unrelease", "archive", "restore":
		valid = r.FormID == q.FormID && r.Revision != ""
	case "delete_draft":
		valid = r.FormID == q.FormID && r.Revision == ""
	case "run_create":
		valid = r.Run.ID != "" && r.Run.FormID == q.FormID && r.Form.ReleasedAt == q.IfReleasedAt &&
			r.Run.PreviousRun == q.PreviousRun && r.Run.Kind == q.Kind && r.Run.Label == q.Label
	case "run_get", "participant_add", "answer", "close", "invite", "revoke":
		valid = r.Run.ID == q.RunID && r.Form.Version == 1
		if q.Op == "invite" {
			valid = valid && r.InviteID != "" && r.Token != ""
		}
		if q.Op == "close" {
			valid = valid && r.Run.Decision == q.Decision
		}
	case "run_list", "participant_accounts":
		start, _ := strconv.ParseUint(q.Cursor, 10, 64)
		end, _ := strconv.ParseUint(r.Cursor, 10, 64)
		count := len(r.Accounts)
		valid = true
		if q.Op == "run_list" {
			count = len(r.Runs)
			last := start
			for _, run := range r.Runs {
				id, _ := strconv.ParseUint(run.ID, 10, 64)
				if id <= last || (q.FormID != "" && run.FormID != q.FormID) {
					valid = false
				}
				last = id
			}
			valid = valid && (count == 0 || last == end)
		}
		valid = valid && ((count == 0 && end == 0 && !r.HasMore) || (count > 0 && end > start))
	}
	if !valid {
		return fmt.Errorf("review receipt does not match the request")
	}
	return nil
}

func readReviewDraft(cmd *cobra.Command) (p.ReviewForm, error) {
	var form p.ReviewForm
	name := reviewFlag(cmd, "file")
	if name == "" {
		return form, reviewInvalid("--file must name a JSON file or be - for stdin")
	}
	var src io.Reader = cmd.InOrStdin()
	if name != "-" {
		f, err := os.Open(name)
		if err != nil {
			return form, reviewInvalid(err.Error())
		}
		defer f.Close()
		src = f
	}
	data, err := io.ReadAll(io.LimitReader(src, p.MaxReviewFormBytes+1))
	if err != nil {
		return form, reviewInvalid(err.Error())
	}
	if len(data) > p.MaxReviewFormBytes || !utf8.Valid(data) {
		return form, reviewInvalid("draft input must be UTF-8 and no larger than 48 KiB")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&form); err != nil {
		return form, reviewInvalid(fmt.Sprintf("invalid draft JSON: %v", err))
	}
	if err := dec.Decode(new(json.RawMessage)); err != io.EOF {
		return form, reviewInvalid("draft input must contain exactly one JSON object")
	}
	if form.Points == nil {
		form.Points = []p.ReviewPoint{}
	}
	return form, nil
}

type reviewFormReceipt struct {
	FormID   string       `json:"form_id"`
	Revision string       `json:"revision"`
	Form     p.ReviewForm `json:"form"`
}

func reviewFormState(form p.ReviewForm) string {
	if form.Archived {
		return "archived"
	}
	if form.ReleasedAt != "" {
		return "released"
	}
	return "draft"
}

func newReviewFormCommand(use, short, op string, count int, revision bool) *cobra.Command {
	c := reviewCommand(use, short, count, op != "get", func(cmd *cobra.Command, args []string) error {
		q := p.ReviewRequest{Op: op, IfRevision: reviewFlag(cmd, "if-revision")}
		if len(args) != 0 {
			q.FormID = args[0]
		}
		if op == "delete_draft" {
			yes, _ := cmd.Flags().GetBool("yes")
			if !yes {
				return reviewInvalid("delete-draft requires --yes; the draft and its links will be removed")
			}
		}
		if op == "create" || op == "update" {
			var err error
			q.Form, err = readReviewDraft(cmd)
			if err != nil {
				return err
			}
		}
		payload, err := encodeReview(q)
		if err != nil {
			return err
		}
		s, err := conn.Dial("")
		if err != nil {
			return err
		}
		defer s.Close()
		r, err := exchangeReview(s, q, payload, op != "get")
		if err != nil {
			return err
		}
		switch {
		case op == "delete_draft":
			if useJSONOutput(cmd) {
				output.OutputJSON(map[string]string{"form_id": r.FormID, "status": "deleted"})
			} else {
				fmt.Printf("Deleted review draft %s and its links\n", r.FormID)
			}
		case useJSONOutput(cmd):
			output.OutputJSON(reviewFormReceipt{r.FormID, r.Revision, r.Form})
		default:
			fmt.Printf("Review %s  %s  revision=%s  %q\nBuild: %q  Environment: %q  Released at: %s\n", r.FormID, reviewFormState(r.Form), r.Revision, r.Form.Title, r.Form.Build, r.Form.Environment, r.Form.ReleasedAt)
			for _, point := range r.Form.Points {
				fmt.Printf("  %s  %q  %q\n    Instruction: %q\n    Expected: %q\n", point.ID, point.Section, point.Question, point.Instruction, point.Expected)
			}
		}
		return nil
	})
	if op == "create" || op == "update" {
		reviewRequiredFlag(c, "file", "Complete draft form JSON file (- reads stdin)")
	}
	if revision {
		reviewRequiredFlag(c, "if-revision", "Observed form revision from review get")
	}
	if op == "delete_draft" {
		c.Flags().Bool("yes", false, "Confirm permanent deletion of the draft and its links")
		_ = c.MarkFlagRequired("yes")
	}
	return c
}

type reviewListEntry struct {
	FormID     string `json:"form_id"`
	Revision   string `json:"revision"`
	Title      string `json:"title"`
	Build      string `json:"build"`
	ReleasedAt string `json:"released_at"`
	Archived   bool   `json:"archived"`
}

type reviewFormPage struct {
	Entries    []reviewListEntry `json:"entries"`
	HasMore    bool              `json:"has_more"`
	NextCursor string            `json:"next_cursor"`
	TotalCount uint32            `json:"total_count"`
}

func newReviewListCommand() *cobra.Command {
	c := reviewCommand("list", "List a page of review forms, including archived forms", 0, false, func(cmd *cobra.Command, _ []string) error {
		limit, _ := cmd.Flags().GetInt("limit")
		if limit < 1 || limit > 250 {
			return reviewInvalid("--limit must be 1–250")
		}
		raw := reviewFlag(cmd, "cursor")
		cursor := noteCursor{}
		if raw != "" {
			var err error
			cursor, err = decodeNoteCursor(raw)
			if err != nil {
				return reviewInvalid(err.Error())
			}
		}
		s, err := conn.Dial("")
		if err != nil {
			return err
		}
		defer s.Close()
		resp, err := s.SendAndRecv(&p.Message{Opcode: p.C_ListAssetsPaged, Data: p.EncodeListAssetsPagedWithCorrelation(0, p.AssetTypeReviewForm, false, uint16(limit), raw != "", cursor.UpdatedAt, cursor.AssetID, reviewCorrelation)})
		if err != nil {
			return err
		}
		if resp.Opcode != p.S_AssetListPage {
			return fmt.Errorf("unexpected review form list response opcode %d", resp.Opcode)
		}
		page, err := p.DecodeAssetListPage(resp.Data)
		if err != nil {
			return err
		}
		if page.ConvID != 0 || page.FullContent || page.CorrelationID != reviewCorrelation || len(page.Assets) > limit {
			return fmt.Errorf("review form list page does not match the request")
		}
		entries := make([]reviewListEntry, 0, len(page.Assets))
		for _, a := range page.Assets {
			var e reviewListEntry
			if a.AssetType != p.AssetTypeReviewForm || a.AssetID == 0 || a.UpdatedAt <= 0 || json.Unmarshal([]byte(a.Preview), &e) != nil || e.Title == "" {
				return fmt.Errorf("invalid review form preview")
			}
			e.FormID = strconv.FormatUint(a.AssetID, 10)
			e.Revision = strconv.FormatInt(a.UpdatedAt, 10)
			entries = append(entries, e)
		}
		next := ""
		if page.HasMore {
			next = encodeNoteCursor(page.NextCursorUpdatedAt, page.NextCursorAssetID)
			if len(entries) == 0 || page.NextCursorUpdatedAt <= 0 || page.NextCursorAssetID == 0 || next == raw {
				return fmt.Errorf("review form list cursor did not advance")
			}
		}
		if useJSONOutput(cmd) {
			output.OutputJSON(reviewFormPage{entries, page.HasMore, next, page.TotalCount})
		} else {
			for _, e := range entries {
				fmt.Printf("%s  %s  revision=%s  %q  build=%q\n", e.FormID, reviewFormState(p.ReviewForm{Archived: e.Archived, ReleasedAt: e.ReleasedAt}), e.Revision, e.Title, e.Build)
			}
			fmt.Printf("Review forms: %d of %d  has_more=%t  next_cursor=%s\n", len(entries), page.TotalCount, page.HasMore, next)
		}
		return nil
	})
	c.Flags().Int("limit", 50, "Form page size (1–250)")
	c.Flags().String("cursor", "", "Resume from next_cursor in the preceding form page")
	return c
}

func init() {
	c := &cobra.Command{Use: "review", Short: "Manage review forms and runs as staff"}
	c.AddCommand(
		newReviewListCommand(),
		newReviewFormCommand("get <form-id>", "Read a review form and its revision", "get", 1, false),
		newReviewFormCommand("create", "Create a draft from a complete JSON form", "create", 0, false),
		newReviewFormCommand("update <form-id>", "Replace a draft with a complete JSON form", "update", 1, true),
		newReviewFormCommand("copy <form-id>", "Copy a form into an independent draft", "copy", 1, false),
		newReviewFormCommand("release <form-id>", "Freeze a draft for testing", "release", 1, true),
		newReviewFormCommand("withdraw-release <form-id>", "Return a released form to draft before its first run", "unrelease", 1, true),
		newReviewFormCommand("archive <form-id>", "Prevent new runs without changing existing runs", "archive", 1, true),
		newReviewFormCommand("restore <form-id>", "Restore an archived form for new runs", "restore", 1, true),
		newReviewFormCommand("delete-draft <form-id>", "Permanently delete a draft and its links", "delete_draft", 1, true),
		newReviewRunsCommand(),
	)
	rootCmd.AddCommand(c)
}
