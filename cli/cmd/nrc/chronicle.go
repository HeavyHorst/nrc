package main

import (
	"errors"
	"fmt"
	"strconv"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

const historyCorrelation uint32 = 1

func historyDecimal(value string, nonzero bool) (uint64, error) {
	n, err := strconv.ParseUint(value, 10, 64)
	if err != nil || strconv.FormatUint(n, 10) != value || (nonzero && n == 0) {
		return 0, &conn.InvalidArgumentError{Err: fmt.Errorf("expected canonical %sdecimal uint64, got %q", map[bool]string{true: "nonzero ", false: ""}[nonzero], value)}
	}
	return n, nil
}

type chronicleError struct {
	code, message string
}

func (e *chronicleError) Error() string { return e.message }

func failChronicle(err error) {
	var failure *chronicleError
	if errors.As(err, &failure) {
		_, retryable := protocol.DatabaseRetryDelay(failure.code, 0)
		output.Error(failure.code, failure.message, retryable)
	}
	conn.Fail(err)
}

func exchangeChronicle(s *conn.Session, request protocol.ChronicleRequest) (*protocol.ChronicleResponse, error) {
	frame, err := protocol.EncodeChronicleRequest(request, historyCorrelation)
	if err != nil {
		return nil, &conn.InvalidArgumentError{Err: err}
	}
	message, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_Chronicle, Data: frame[2:]})
	if err != nil {
		return nil, err
	}
	if message.Opcode != protocol.S_Chronicle {
		return nil, fmt.Errorf("expected Chronicle response, got opcode %d", message.Opcode)
	}
	r, err := protocol.DecodeChronicleResponse(message.Data)
	if err != nil {
		return nil, fmt.Errorf("decode Chronicle: %w", err)
	}
	if r.CorrelationID != historyCorrelation {
		return nil, fmt.Errorf("Chronicle response correlation mismatch")
	}
	want := "ok"
	if request.Op == "delete" {
		want = "deleted"
	}
	if r.Error != "" || r.Status != want {
		code := r.Error
		if code == "" {
			code = r.Status
		}
		if code == "" {
			code = "unexpected_response"
		}
		return nil, &chronicleError{code, fmt.Sprintf("Chronicle %s: status=%q error=%q", request.Op, r.Status, r.Error)}
	}
	return r, nil
}

func validateChroniclePage(q protocol.ChronicleRequest, r *protocol.ChronicleResponse) error {
	count := len(r.Entries)
	if q.Op == "gaps" {
		count = len(r.Gaps)
	}
	if count > int(q.Limit) {
		return fmt.Errorf("Chronicle page exceeds requested limit")
	}
	// The backend leaves cursor empty on an empty terminal page. Keep the
	// caller's exclusive cursor so scripts never restart accidentally.
	if count == 0 && !r.More && r.Cursor == "" {
		r.Cursor = q.Cursor
	}
	end, err := historyDecimal(r.Cursor, false)
	if err != nil {
		return fmt.Errorf("invalid Chronicle response cursor")
	}
	previous, _ := historyDecimal(q.Cursor, false)
	for i := 0; i < count; i++ {
		id, note := "", ""
		if q.Op == "gaps" {
			id, note = r.Gaps[i].FirstSource, r.Gaps[i].NoteID
		} else {
			id, note = r.Entries[i].Generation, r.Entries[i].NoteID
		}
		n, err := historyDecimal(id, true)
		if err != nil {
			return fmt.Errorf("Chronicle page has invalid ID")
		}
		if q.NewestFirst {
			if (i > 0 || previous != 0) && n >= previous {
				return fmt.Errorf("Chronicle page is not descending exclusive IDs")
			}
		} else if n <= previous {
			return fmt.Errorf("Chronicle page is not ascending exclusive IDs")
		}
		if _, err := historyDecimal(note, true); err != nil || (q.NoteID != "" && note != q.NoteID) {
			return fmt.Errorf("Chronicle page has invalid note scope")
		}
		previous = n
	}
	if (count > 0 && end != previous) || (r.More && count == 0) {
		return fmt.Errorf("Chronicle cursor does not match page")
	}
	return nil
}

func deleteChronicle(s *conn.Session, note string, yes bool) (*protocol.ChronicleResponse, error) {
	if _, err := historyDecimal(note, true); err != nil {
		return nil, err
	}
	if !yes {
		return nil, &conn.InvalidArgumentError{Err: fmt.Errorf("Chronicle deletion requires --yes; removes AI results and suppresses pending inputs through the watermark, not the note or technical history; future changes may generate entries")}
	}
	status, err := exchangeChronicle(s, protocol.ChronicleRequest{Op: "status", NoteID: note})
	if err != nil {
		return nil, err
	}
	if !status.CanDelete {
		return nil, &chronicleError{"forbidden", "server did not grant can_delete; no deletion was sent"}
	}
	r, err := exchangeChronicle(s, protocol.ChronicleRequest{Op: "delete", NoteID: note})
	if err == nil {
		if _, decimalErr := historyDecimal(r.DeletedThrough, false); decimalErr != nil {
			err = fmt.Errorf("invalid deletion watermark")
		}
	}
	if err != nil {
		// Once sent, even a transport/decode failure can hide a completed delete.
		// Do not advertise this mutation as safe for a generic retry loop.
		return nil, &chronicleError{"delete_not_confirmed", fmt.Sprintf("Chronicle deletion not confirmed: %v; inspect status/history before deciding whether to retry; no automatic retry was made", err)}
	}
	return r, nil
}

var chronicleCmd = &cobra.Command{Use: "chronicle", Short: "Read AI note summaries, processing status and gaps (not technical history)"}

func newChronicleRead(op string) *cobra.Command {
	c := &cobra.Command{
		Use: op, Args: cobra.NoArgs,
		Short: map[string]string{"history": "Read result-only AI summaries, newest generation first", "gaps": "Read input gaps, newest first_source first", "status": "Read processing counts, workspace budgets and server deletion permission"}[op],
		Run: func(cmd *cobra.Command, args []string) {
			note, _ := cmd.Flags().GetString("note")
			if note != "" {
				if _, err := historyDecimal(note, true); err != nil {
					conn.Fail(err)
					return
				}
			}
			q := protocol.ChronicleRequest{Op: op, NoteID: note}
			if op != "status" {
				if cmd.Flags().Changed("before") && cmd.Flags().Changed("cursor") {
					conn.FatalInvalid("--before and --cursor are mutually exclusive")
					return
				}
				q.NewestFirst = !cmd.Flags().Changed("cursor")
				cursorFlag := "cursor"
				if q.NewestFirst {
					cursorFlag = "before"
				}
				cursor, _ := cmd.Flags().GetString(cursorFlag)
				limit, _ := cmd.Flags().GetInt("limit")
				if _, err := historyDecimal(cursor, false); err != nil {
					conn.Fail(err)
					return
				}
				if limit < 1 || limit > 16 {
					conn.FatalInvalid("--limit must be 1..16")
					return
				}
				q.Cursor, q.Limit = cursor, uint16(limit)
			}
			s, err := conn.Dial("")
			if err != nil {
				conn.Fail(err)
				return
			}
			defer s.Close()
			r, err := exchangeChronicle(s, q)
			if err != nil {
				failChronicle(err)
				return
			}
			if op == "history" || op == "gaps" {
				if err := validateChroniclePage(q, r); err != nil {
					conn.FatalUnexpected("%v", err)
					return
				}
			}
			if useJSONOutput(cmd) {
				switch op {
				case "history":
					if r.Entries == nil {
						r.Entries = []protocol.ChronicleEntry{}
					}
					output.OutputJSON(struct {
						Entries []protocol.ChronicleEntry `json:"entries"`
						Cursor  string                    `json:"cursor"`
						More    bool                      `json:"more"`
					}{r.Entries, r.Cursor, r.More})
				case "gaps":
					if r.Gaps == nil {
						r.Gaps = []protocol.ChronicleGap{}
					}
					output.OutputJSON(struct {
						Gaps   []protocol.ChronicleGap `json:"gaps"`
						Cursor string                  `json:"cursor"`
						More   bool                    `json:"more"`
					}{r.Gaps, r.Cursor, r.More})
				default:
					output.OutputJSON(r)
				}
				return
			}
			printChronicleHuman(op, r)
		},
	}
	c.Flags().String("note", "", "Optional note ID; status counts are note-scoped but raw bytes/day budgets remain workspace totals")
	if op != "status" {
		c.Flags().String("before", "0", "Exclusive descending ID cursor (generation for history; first_source for gaps); 0 starts at newest")
		c.Flags().String("cursor", "0", "Select ascending order with an exclusive ID cursor; 0 starts at oldest; cannot combine with --before")
		c.Flags().Int("limit", 16, "Maximum entries in one page (1..16); pass returned cursor to --before (descending) or --cursor (ascending) when more=true")
	}
	return c
}

func printChronicleHuman(op string, r *protocol.ChronicleResponse) {
	switch op {
	case "history":
		for _, e := range r.Entries {
			fmt.Printf("Generation %s  note %s  title=%q  source_available=%t\n%s\n", e.Generation, e.NoteID, e.NoteTitle, e.SourceAvailable, e.Summary)
		}
		fmt.Printf("AI results: %d  cursor=%s  more=%t\n", len(r.Entries), r.Cursor, r.More)
	case "gaps":
		for _, g := range r.Gaps {
			fmt.Printf("%s..%s  note %s  title=%q  %s  inputs=%d  source_available=%t  at=%s..%s\n", g.FirstSource, g.LastSource, g.NoteID, g.NoteTitle, g.Reason, g.InputCount, g.SourceAvailable, g.FirstAt, g.LastAt)
		}
		fmt.Printf("Gaps: %d  cursor=%s  more=%t\n", len(r.Gaps), r.Cursor, r.More)
	default:
		fmt.Printf("AI Chronicle: enabled=%t  note=%s  can_delete=%t\nPending=%d  processing=%d  failed=%d  acknowledged=%d  gaps=%d  expired=%d\nWorkspace totals: raw_bytes=%d  day calls=%d  input_tokens=%d  output_tokens=%d\n", r.Enabled, r.NoteID, r.CanDelete, r.Pending, r.Processing, r.Failed, r.Acknowledged, r.GapCount, r.Expired, r.RawBytes, r.Calls, r.InputTokens, r.OutputTokens)
	}
}

func init() {
	for _, op := range []string{"history", "status", "gaps"} {
		chronicleCmd.AddCommand(newChronicleRead(op))
	}
	del := &cobra.Command{
		Use: "delete <note-id>", Args: cobra.ExactArgs(1), Short: "Delete AI results and suppress pending inputs through a watermark (requires server permission and --yes)",
		Long:        "Delete AI results for one note and remove/suppress pending inputs through the server watermark. The canonical note and technical history are unchanged. Future note changes can generate new AI entries. Requires server-authenticated human can_delete permission and --yes. Never automatically retries deletion.",
		Annotations: map[string]string{"mutation": "true"},
		Run: func(cmd *cobra.Command, args []string) {
			yes, _ := cmd.Flags().GetBool("yes")
			if _, err := historyDecimal(args[0], true); err != nil {
				conn.Fail(err)
				return
			}
			if !yes {
				conn.FatalInvalid("Deletion requires explicit --yes; see nrc chronicle delete --help")
				return
			}
			s, err := conn.Dial("")
			if err != nil {
				conn.Fail(err)
				return
			}
			defer s.Close()
			r, err := deleteChronicle(s, args[0], yes)
			if err != nil {
				failChronicle(err)
				return
			}
			if useJSONOutput(cmd) {
				output.OutputJSON(r)
				return
			}
			fmt.Printf("AI Chronicle deleted for note %s through source %s. Note and technical history unchanged; future changes may generate entries.\n", args[0], r.DeletedThrough)
		},
	}
	del.Flags().Bool("yes", false, "Affirm deletion of AI results and pending inputs only; the note and technical history remain")
	chronicleCmd.AddCommand(del)
	rootCmd.AddCommand(chronicleCmd)
}
