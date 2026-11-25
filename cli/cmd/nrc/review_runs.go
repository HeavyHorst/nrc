package main

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

func reviewPositiveDecimal(value, name string, max uint64) error {
	n, err := strconv.ParseUint(value, 10, 64)
	if err != nil || n == 0 || n > max || strconv.FormatUint(n, 10) != value {
		return reviewInvalid(name + " must be a positive canonical decimal string")
	}
	return nil
}

func executeReviewRun(cmd *cobra.Command, q p.ReviewRequest, preview bool) error {
	mutation := q.Op != "run_get" && q.Op != "run_list" && q.Op != "participant_accounts"
	payload, err := encodeReview(q)
	if err != nil {
		return err
	}
	s, err := conn.Dial("")
	if err != nil {
		return err
	}
	defer s.Close()
	if q.PreviousRun != "" {
		// This read supplies only the closed team's immutable label and kind.
		// The new form's release token always comes from the caller.
		read := p.ReviewRequest{Op: "run_get", RunID: q.PreviousRun}
		readPayload, err := encodeReview(read)
		if err != nil {
			return err
		}
		previous, err := exchangeReview(s, read, readPayload, false)
		if err != nil {
			return err
		}
		if previous.Run.Decision == "" {
			return reviewInvalid("retest requires a closed predecessor run")
		}
		q.Label, q.Kind = previous.Run.Label, previous.Run.Kind
		payload, err = encodeReview(q)
		if err != nil {
			return err
		}
	}
	r, err := exchangeReview(s, q, payload, mutation)
	if err != nil {
		return err
	}
	if preview {
		printReviewClosePreview(cmd, r)
		return nil
	}
	printReviewRunResult(cmd, q, r)
	return nil
}

type reviewClosePreview struct {
	RunID       string   `json:"run_id"`
	Revision    string   `json:"revision"`
	Kind        string   `json:"kind"`
	Decision    string   `json:"decision"`
	CanClose    bool     `json:"can_close"`
	Decisions   []string `json:"allowed_decisions"`
	Total       int      `json:"total_points"`
	Answered    int      `json:"answered_points"`
	Open        int      `json:"open_points"`
	Conflicting int      `json:"conflicting_points"`
	NotAllYes   int      `json:"not_all_yes_points"`
}

func reviewCloseSnapshot(r *p.ReviewResponse) reviewClosePreview {
	v := reviewClosePreview{RunID: r.Run.ID, Revision: r.Run.Revision, Kind: r.Run.Kind, Decision: r.Run.Decision, Total: len(r.Form.Points), Decisions: []string{}}
	if v.Decision == "" {
		for _, person := range r.Run.Participants {
			if person.ID == r.ParticipantID && person.Source == "staff" {
				v.CanClose = person.CanClose
				break
			}
		}
		switch v.Kind {
		case "qa":
			v.Decisions = []string{"completed"}
		case "customer":
			v.Decisions = []string{"accepted", "conditional", "rejected"}
		}
	}
	const yes, no, unable = 1, 2, 4
	results := make(map[string]int)
	for _, answer := range r.Run.Answers {
		switch answer.Result {
		case "yes":
			results[answer.PointID] |= yes
		case "no":
			results[answer.PointID] |= no
		case "unable":
			results[answer.PointID] |= unable
		}
	}
	for _, point := range r.Form.Points {
		result := results[point.ID]
		if result == 0 {
			v.Open++
			continue
		}
		v.Answered++
		if result&(result-1) != 0 {
			v.Conflicting++
		}
		if result&(no|unable) != 0 {
			v.NotAllYes++
		}
	}
	return v
}

func printReviewClosePreview(cmd *cobra.Command, r *p.ReviewResponse) {
	v := reviewCloseSnapshot(r)
	if useJSONOutput(cmd) {
		output.OutputJSON(v)
	} else {
		fmt.Printf("Run %s  %s  revision=%s  decision=%q  can_close=%t\n", v.RunID, v.Kind, v.Revision, v.Decision, v.CanClose)
		fmt.Printf("%d/%d answered  %d open  %d conflicting  %d not all yes\n", v.Answered, v.Total, v.Open, v.Conflicting, v.NotAllYes)
		if len(v.Decisions) != 0 {
			fmt.Printf("Decisions: %s. Closing freezes all answers.\n", strings.Join(v.Decisions, ", "))
		}
	}
}

type reviewRunReceipt struct {
	Run           p.ReviewRun  `json:"run"`
	Form          p.ReviewForm `json:"form"`
	ParticipantID string       `json:"participant_id"`
}

func printReviewRunResult(cmd *cobra.Command, q p.ReviewRequest, r *p.ReviewResponse) {
	jsonMode := useJSONOutput(cmd)
	switch q.Op {
	case "run_list", "participant_accounts":
		if q.Op == "run_list" {
			if jsonMode {
				output.OutputJSON(struct {
					Entries []p.ReviewRun `json:"entries"`
					Cursor  string        `json:"cursor"`
					HasMore bool          `json:"has_more"`
				}{r.Runs, r.Cursor, r.HasMore})
				return
			}
			for _, run := range r.Runs {
				printReviewRunSummary(run)
			}
		} else {
			if r.Accounts == nil {
				r.Accounts = []p.ReviewAccountChoice{}
			}
			if jsonMode {
				output.OutputJSON(struct {
					Accounts []p.ReviewAccountChoice `json:"accounts"`
					Cursor   string                  `json:"cursor"`
					HasMore  bool                    `json:"has_more"`
				}{r.Accounts, r.Cursor, r.HasMore})
				return
			}
			for _, account := range r.Accounts {
				fmt.Printf("%q  login=%q  requester=%q\n", account.Name, account.Login, account.Requester)
			}
		}
		fmt.Printf("Entries: %d  has_more=%t  cursor=%s\n", len(r.Runs)+len(r.Accounts), r.HasMore, r.Cursor)
	case "invite":
		if jsonMode {
			output.OutputJSON(map[string]string{"run_id": q.RunID, "invite_id": r.InviteID, "expires_at": q.ExpiresAt, "token": r.Token})
		} else {
			fmt.Printf("Run %s  invite %s  expires_at=%s\nGuest token (keep private): %s\n", q.RunID, r.InviteID, q.ExpiresAt, r.Token)
		}
	case "revoke":
		if jsonMode {
			output.OutputJSON(map[string]string{"run_id": q.RunID, "invite_id": q.InviteID, "status": "ok"})
		} else {
			fmt.Printf("Revocation acknowledged for run %s, invite %s\n", q.RunID, q.InviteID)
		}
	default:
		if jsonMode {
			output.OutputJSON(reviewRunReceipt{r.Run, r.Form, r.ParticipantID})
			return
		}
		printReviewRunSummary(r.Run)
		fmt.Printf("Form: %q  Build: %q  Environment: %q\n", r.Form.Title, r.Form.Build, r.Form.Environment)
		if r.Run.PreviousRun != "" {
			fmt.Printf("Retest of run %s\n", r.Run.PreviousRun)
		}
		if r.Run.Decision != "" {
			fmt.Printf("Closed by %q (%s) at %s: %q\n", r.Run.ClosedName, r.Run.ClosedSource, r.Run.ClosedAt, r.Run.Comment)
		}
		fmt.Printf("Participant ID: %s\n", r.ParticipantID)
		for _, person := range r.Run.Participants {
			fmt.Printf("  Participant %s  %s  %q  close=%t\n", person.ID, person.Source, person.Name, person.CanClose)
		}
		for _, a := range r.Run.Answers {
			fmt.Printf("  Answer %s  point=%s  participant=%s  %s  %q\n", a.ID, a.PointID, a.ParticipantID, a.Result, a.Comment)
		}
	}
}

func printReviewRunSummary(run p.ReviewRun) {
	state := run.Decision
	if state == "" {
		state = "open"
	}
	fmt.Printf("Run %s  form=%s  %s  %s  revision=%s  %q  answered=%d\n", run.ID, run.FormID, run.Kind, state, run.Revision, run.Label, run.AnsweredPoints)
}

func newReviewRunStart(retest bool) *cobra.Command {
	use, short, count := "create <form-id>", "Start a QA or customer run on a released form", 1
	if retest {
		use, short, count = "retest <previous-run-id> <form-id>", "Start a fresh run for a closed team's label and kind on a released form", 2
	}
	c := reviewCommand(use, short, count, true, func(cmd *cobra.Command, args []string) error {
		q := p.ReviewRequest{Op: "run_create", FormID: args[len(args)-1], IfReleasedAt: reviewFlag(cmd, "if-released-at")}
		if err := reviewPositiveDecimal(q.IfReleasedAt, "--if-released-at", math.MaxInt64); err != nil {
			return err
		}
		if retest {
			q.PreviousRun = args[0]
			if err := reviewPositiveDecimal(q.PreviousRun, "previous run ID", math.MaxUint64); err != nil {
				return err
			}
		} else {
			q.Label, q.Kind = reviewFlag(cmd, "label"), reviewFlag(cmd, "kind")
			if strings.TrimSpace(q.Label) == "" || len(q.Label) > 256 {
				return reviewInvalid("--label must be nonblank and no longer than 256 bytes")
			}
			if q.Kind != "qa" && q.Kind != "customer" {
				return reviewInvalid("--kind must be qa or customer")
			}
		}
		return executeReviewRun(cmd, q, false)
	})
	reviewRequiredFlag(c, "if-released-at", "Observed form.released_at from review get")
	if !retest {
		reviewRequiredFlag(c, "label", "Team label")
		reviewRequiredFlag(c, "kind", "Run kind: qa or customer")
	}
	return c
}

func newReviewAssignment(source string) *cobra.Command {
	c := reviewCommand(source+" <run-id>", "Assign a "+source+" participant", 1, true, func(cmd *cobra.Command, args []string) error {
		q := p.ReviewRequest{Op: "participant_add", RunID: args[0], Source: source, Name: reviewFlag(cmd, "name")}
		if strings.TrimSpace(q.Name) == "" || len(q.Name) > 256 {
			return reviewInvalid("--name must be nonblank and no longer than 256 bytes")
		}
		if source == "portal" {
			q.Identity = reviewFlag(cmd, "requester")
			if strings.TrimSpace(q.Identity) == "" {
				return reviewInvalid("--requester must be the portal account's canonical requester identity")
			}
		} else {
			q.Identity = reviewFlag(cmd, "identity")
		}
		q.CanClose, _ = cmd.Flags().GetBool("can-close")
		return executeReviewRun(cmd, q, false)
	})
	reviewRequiredFlag(c, "name", "Participant display name")
	c.Flags().Bool("can-close", false, "Grant permission to close the run; otherwise contribute-only")
	if source == "portal" {
		reviewRequiredFlag(c, "requester", "Canonical requester from review run portal-accounts (not login or display name)")
	} else {
		c.Flags().String("identity", "", "Stable NRC staff subject; omit to assign the current authenticated member")
	}
	return c
}

func newReviewRunsCommand() *cobra.Command {
	runs := &cobra.Command{Use: "run", Short: "Manage review runs, contributions and access"}
	list := reviewCommand("list", "List a page of runs, optionally for one form", 0, false, func(cmd *cobra.Command, _ []string) error {
		q := p.ReviewRequest{Op: "run_list", FormID: reviewFlag(cmd, "form"), Cursor: reviewFlag(cmd, "cursor")}
		if cmd.Flags().Changed("form") {
			if err := reviewPositiveDecimal(q.FormID, "--form", math.MaxUint64); err != nil {
				return err
			}
		}
		return executeReviewRun(cmd, q, false)
	})
	list.Flags().String("form", "", "Filter to this form ID")
	list.Flags().String("cursor", "", "Continue after the returned run cursor")
	get := reviewCommand("get <run-id>", "Read a run, its form, participants and answers", 1, false, func(cmd *cobra.Command, args []string) error {
		return executeReviewRun(cmd, p.ReviewRequest{Op: "run_get", RunID: args[0]}, false)
	})
	assign := &cobra.Command{Use: "assign", Short: "Assign a staff or portal participant"}
	assign.AddCommand(newReviewAssignment("staff"), newReviewAssignment("portal"))
	accounts := reviewCommand("portal-accounts <run-id>", "List assignable portal accounts for an open run", 1, false, func(cmd *cobra.Command, args []string) error {
		return executeReviewRun(cmd, p.ReviewRequest{Op: "participant_accounts", RunID: args[0], Cursor: reviewFlag(cmd, "cursor")}, false)
	})
	accounts.Flags().String("cursor", "", "Continue after the returned account cursor")
	answer := reviewCommand("answer <run-id> <point-id>", "Save the authenticated staff member's answer", 2, true, func(cmd *cobra.Command, args []string) error {
		return executeReviewRun(cmd, p.ReviewRequest{Op: "answer", RunID: args[0], PointID: args[1], Result: reviewFlag(cmd, "result"), Comment: reviewFlag(cmd, "comment")}, false)
	})
	reviewRequiredFlag(answer, "result", "Answer result: yes, no, or unable")
	answer.Flags().String("comment", "", "Answer comment")
	preview := reviewCommand("close-preview <run-id>", "Read progress, close permission and the revision to confirm", 1, false, func(cmd *cobra.Command, args []string) error {
		return executeReviewRun(cmd, p.ReviewRequest{Op: "run_get", RunID: args[0]}, true)
	})
	closeRun := reviewCommand("close <run-id>", "Freeze answers and record a decision using the preview revision", 1, true, func(cmd *cobra.Command, args []string) error {
		return executeReviewRun(cmd, p.ReviewRequest{Op: "close", RunID: args[0], IfRevision: reviewFlag(cmd, "if-revision"), Decision: reviewFlag(cmd, "decision"), Comment: reviewFlag(cmd, "comment")}, false)
	})
	reviewRequiredFlag(closeRun, "if-revision", "Observed run revision from review run close-preview")
	reviewRequiredFlag(closeRun, "decision", "completed for QA; accepted, conditional or rejected for customer runs")
	closeRun.Flags().String("comment", "", "Closing comment")
	invite := reviewCommand("invite <run-id>", "Create a guest invitation; stdout contains a private token", 1, true, func(cmd *cobra.Command, args []string) error {
		q := p.ReviewRequest{Op: "invite", RunID: args[0], ExpiresAt: reviewFlag(cmd, "expires-at")}
		if err := reviewPositiveDecimal(q.ExpiresAt, "--expires-at", math.MaxInt64); err != nil {
			return err
		}
		q.CanClose, _ = cmd.Flags().GetBool("can-close")
		return executeReviewRun(cmd, q, false)
	})
	reviewRequiredFlag(invite, "expires-at", "Expiry as a future Unix timestamp in nanoseconds")
	invite.Flags().Bool("can-close", false, "Allow anyone holding the guest link to close the run")
	revoke := reviewCommand("revoke <run-id> <invite-id>", "Revoke a guest invitation, even on a closed run", 2, true, func(cmd *cobra.Command, args []string) error {
		if err := reviewPositiveDecimal(args[1], "invitation ID", math.MaxUint64); err != nil {
			return err
		}
		return executeReviewRun(cmd, p.ReviewRequest{Op: "revoke", RunID: args[0], InviteID: args[1]}, false)
	})
	runs.AddCommand(list, get, newReviewRunStart(false), newReviewRunStart(true), assign, accounts, answer, preview, closeRun, invite, revoke)
	return runs
}
