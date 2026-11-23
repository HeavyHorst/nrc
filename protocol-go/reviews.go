package protocol

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

const MaxReviewFormBytes = 48 * 1024
const MaxReviewPoints = 100

type ReviewPoint struct {
	ID          string `json:"id"`
	Section     string `json:"section,omitempty"`
	Question    string `json:"question"`
	Instruction string `json:"instruction"`
	Expected    string `json:"expected"`
}
type ReviewForm struct {
	Version     int           `json:"version"`
	Title       string        `json:"title"`
	Build       string        `json:"build"`
	Environment string        `json:"environment"`
	ReleasedAt  string        `json:"released_at"`
	Points      []ReviewPoint `json:"points"`
}
type ReviewRequest struct {
	Op          string     `json:"op"`
	FormID      string     `json:"form_id"`
	IfRevision  string     `json:"if_revision"`
	Form        ReviewForm `json:"form"`
	RunID       string     `json:"run_id,omitempty"`
	Label       string     `json:"label,omitempty"`
	Kind        string     `json:"kind,omitempty"`
	PreviousRun string     `json:"previous_run,omitempty"`
	Source      string     `json:"source,omitempty"`
	Identity    string     `json:"identity,omitempty"`
	Name        string     `json:"name,omitempty"`
	CanClose    bool       `json:"can_close,omitempty"`
	PointID     string     `json:"point_id,omitempty"`
	Result      string     `json:"result,omitempty"`
	Comment     string     `json:"comment,omitempty"`
	Decision    string     `json:"decision,omitempty"`
	Token       string     `json:"token,omitempty"`
	GuestID     string     `json:"guest_id,omitempty"`
	ExpiresAt   string     `json:"expires_at,omitempty"`
	InviteID    string     `json:"invite_id,omitempty"`
	Cursor      string     `json:"cursor,omitempty"`

	PortalProof *PortalWriteProof `json:"-"`
}
type ReviewParticipant struct {
	ID       string `json:"id"`
	Source   string `json:"source"`
	Identity string `json:"identity"`
	Name     string `json:"name"`
	CanClose bool   `json:"can_close"`
}
type ReviewAnswer struct {
	ID            string `json:"id"`
	ParticipantID string `json:"participant_id"`
	PointID       string `json:"point_id"`
	Result        string `json:"result"`
	Comment       string `json:"comment"`
	Name          string `json:"name"`
	UpdatedAt     string `json:"updated_at"`
}
type ReviewRun struct {
	ID             string              `json:"id"`
	FormID         string              `json:"form_id"`
	Label          string              `json:"label"`
	Title          string              `json:"title"`
	Kind           string              `json:"kind"`
	PreviousRun    string              `json:"previous_run"`
	Revision       string              `json:"revision"`
	Decision       string              `json:"decision"`
	Comment        string              `json:"comment"`
	ClosedAt       string              `json:"closed_at"`
	ClosedBy       string              `json:"closed_by"`
	ClosedName     string              `json:"closed_name"`
	ClosedSource   string              `json:"closed_source"`
	Participants   []ReviewParticipant `json:"participants"`
	Answers        []ReviewAnswer      `json:"answers"`
	AnsweredPoints int                 `json:"answered_points"`
}
type ReviewResponse struct {
	CorrelationID uint32      `json:"-"`
	Status        string      `json:"status"`
	FormID        string      `json:"form_id"`
	Revision      string      `json:"revision"`
	Form          ReviewForm  `json:"form"`
	Run           ReviewRun   `json:"run"`
	Runs          []ReviewRun `json:"runs"`
	Token         string      `json:"token"`
	InviteID      string      `json:"invite_id"`
	ParticipantID string      `json:"participant_id"`
	Cursor        string      `json:"cursor"`
	HasMore       bool        `json:"has_more"`
}

func reviewTextValid(s string, limit int, required bool) bool {
	return len(s) <= limit && utf8.ValidString(s) && !strings.ContainsRune(s, 0) && (!required || strings.TrimSpace(s) != "")
}
func ValidateReviewForm(f ReviewForm, released bool) error {
	if f.Version != 1 || !reviewTextValid(f.Title, 256, true) || !reviewTextValid(f.Build, 512, released) || !reviewTextValid(f.Environment, 2048, false) || len(f.Points) > MaxReviewPoints || released && len(f.Points) == 0 {
		return fmt.Errorf("review: invalid form")
	}
	if f.ReleasedAt != "" {
		if n, ok := chronicleDecimal(f.ReleasedAt); !ok || n == 0 || n > 1<<63-1 {
			return fmt.Errorf("review: invalid release timestamp")
		}
	}
	seen := make(map[string]bool, len(f.Points))
	for _, p := range f.Points {
		n, ok := chronicleDecimal(p.ID)
		if !ok || n == 0 || seen[p.ID] || !reviewTextValid(p.Section, 256, false) || !reviewTextValid(p.Question, 1024, true) || !reviewTextValid(p.Instruction, 2048, false) || !reviewTextValid(p.Expected, 2048, false) {
			return fmt.Errorf("review: invalid or duplicate point")
		}
		seen[p.ID] = true
	}
	return nil
}

// EncodeReviewRequest returns the complete frame; responses use a leading
// correlation ID, requests a trailing one, matching the Chronicle transport.
func EncodeReviewRequest(q ReviewRequest, correlation uint32) ([]byte, error) {
	switch q.Op {
	case "create", "update", "release", "copy", "get", "run_create", "run_list", "run_get", "participant_add", "invite", "revoke", "invitation_info", "guest_join", "answer", "close":
	default:
		return nil, fmt.Errorf("review: unknown operation")
	}
	if q.Op == "update" || q.Op == "release" || q.Op == "copy" || q.Op == "get" || q.Op == "run_create" {
		if n, ok := chronicleDecimal(q.FormID); !ok || n == 0 {
			return nil, fmt.Errorf("review: invalid form ID")
		}
	}
	if q.Op == "update" || q.Op == "release" || q.Op == "close" {
		if n, ok := chronicleDecimal(q.IfRevision); !ok || n == 0 || n > 1<<63-1 {
			return nil, fmt.Errorf("review: invalid revision")
		}
	}
	if q.Op == "run_get" || q.Op == "answer" || q.Op == "close" || q.Op == "participant_add" || q.Op == "invite" || q.Op == "revoke" {
		if n, ok := chronicleDecimal(q.RunID); !ok || n == 0 {
			return nil, fmt.Errorf("review: invalid run ID")
		}
	}
	if q.Op == "answer" {
		if n, ok := chronicleDecimal(q.PointID); !ok || n == 0 || (q.Result != "yes" && q.Result != "no" && q.Result != "unable") {
			return nil, fmt.Errorf("review: invalid answer")
		}
	}
	if q.Op == "close" && q.Decision != "accepted" && q.Decision != "conditional" && q.Decision != "rejected" && q.Decision != "completed" {
		return nil, fmt.Errorf("review: invalid decision")
	}
	for _, id := range []string{q.FormID, q.RunID, q.PreviousRun, q.PointID, q.InviteID, q.IfRevision, q.Cursor} {
		if id != "" {
			if _, ok := chronicleDecimal(id); !ok {
				return nil, fmt.Errorf("review: invalid decimal")
			}
		}
	}
	for _, value := range []string{q.Label, q.Identity, q.Name, q.Token, q.GuestID, q.ExpiresAt, q.Kind, q.Source} {
		if !reviewTextValid(value, 512, false) {
			return nil, fmt.Errorf("review: invalid text")
		}
	}
	if !reviewTextValid(q.Comment, 4096, false) || !reviewTextValid(q.Result, 16, false) || !reviewTextValid(q.Decision, 32, false) {
		return nil, fmt.Errorf("review: invalid text")
	}
	if q.Op == "create" || q.Op == "update" {
		if err := ValidateReviewForm(q.Form, false); err != nil {
			return nil, err
		}
		if q.Form.ReleasedAt != "" {
			return nil, fmt.Errorf("review: release requires a separate command")
		}
	}
	payload, err := json.Marshal(q)
	if err != nil {
		return nil, err
	}
	if len(payload) > MaxReviewFormBytes {
		return nil, fmt.Errorf("review: request too large")
	}
	frame := binary.BigEndian.AppendUint16(make([]byte, 0, len(payload)+6), C_Review)
	if q.PortalProof != nil {
		if q.Source != "portal" || q.Op != "answer" && q.Op != "close" {
			return nil, fmt.Errorf("review: portal proof is only valid on portal mutations")
		}
		frame, err = q.PortalProof.appendTo(append(frame, 0))
		if err != nil {
			return nil, err
		}
	}
	frame = append(frame, payload...)
	return binary.BigEndian.AppendUint32(frame, correlation), nil
}

// DecodeReviewResponse accepts a response body with its opcode removed.
func DecodeReviewResponse(body []byte) (*ReviewResponse, error) {
	if len(body) < 6 || len(body)+2 > MaxProtocolPayloadSize || !utf8.Valid(body[4:]) || len(bytes.TrimSpace(body[4:])) == 0 || bytes.TrimSpace(body[4:])[0] != '{' {
		return nil, fmt.Errorf("review: invalid response")
	}
	var r ReviewResponse
	if err := json.Unmarshal(body[4:], &r); err != nil {
		return nil, err
	}
	if r.Status == "" {
		return nil, fmt.Errorf("review: missing response status")
	}
	r.CorrelationID = binary.BigEndian.Uint32(body)
	// Form operations return a top-level identity; run/list/invite operations
	// may instead return a run or an empty list without a top-level form.
	if r.Status == "ok" && r.FormID != "" {
		id, ok := chronicleDecimal(r.FormID)
		revision, valid := chronicleDecimal(r.Revision)
		if !ok || id == 0 || !valid || revision == 0 || revision > 1<<63-1 {
			return nil, fmt.Errorf("review: invalid result identity")
		}
		if err := ValidateReviewForm(r.Form, r.Form.ReleasedAt != ""); err != nil {
			return nil, err
		}
	}
	if r.Status == "ok" {
		if r.FormID == "" && r.Form.Version != 0 {
			if err := ValidateReviewForm(r.Form, r.Form.ReleasedAt != ""); err != nil {
				return nil, err
			}
		}
		// invitation_info deliberately returns only the title, not a full form.
		titleOnly := r.Form.Version == 0 && reviewTextValid(r.Form.Title, 256, true) &&
			r.Form.Build == "" && r.Form.Environment == "" && r.Form.ReleasedAt == "" && len(r.Form.Points) == 0
		if r.FormID == "" && r.Run.ID == "" && r.Runs == nil && r.Token == "" && r.InviteID == "" && !titleOnly {
			return nil, fmt.Errorf("review: missing result")
		}
		for _, id := range []string{r.Cursor, r.ParticipantID, r.InviteID} {
			if id != "" {
				if n, ok := chronicleDecimal(id); !ok || n == 0 {
					return nil, fmt.Errorf("review: invalid result ID")
				}
			}
		}
		for _, run := range append(append([]ReviewRun{}, r.Runs...), r.Run) {
			if run.ID == "" {
				continue
			}
			for _, id := range []string{run.ID, run.FormID, run.Revision} {
				if n, ok := chronicleDecimal(id); !ok || n == 0 {
					return nil, fmt.Errorf("review: invalid run identity")
				}
			}
			if n, _ := chronicleDecimal(run.Revision); n > 1<<63-1 {
				return nil, fmt.Errorf("review: invalid run revision")
			}
			if run.PreviousRun != "" {
				if n, ok := chronicleDecimal(run.PreviousRun); !ok || n == 0 {
					return nil, fmt.Errorf("review: invalid previous run")
				}
			}
			for _, person := range run.Participants {
				if n, ok := chronicleDecimal(person.ID); !ok || n == 0 {
					return nil, fmt.Errorf("review: invalid participant ID")
				}
			}
			for _, answer := range run.Answers {
				for _, id := range []string{answer.ID, answer.ParticipantID, answer.PointID, answer.UpdatedAt} {
					if n, ok := chronicleDecimal(id); !ok || n == 0 {
						return nil, fmt.Errorf("review: invalid answer ID")
					}
				}
				if n, _ := chronicleDecimal(answer.UpdatedAt); n > 1<<63-1 {
					return nil, fmt.Errorf("review: invalid answer timestamp")
				}
			}
		}
	}
	return &r, nil
}
