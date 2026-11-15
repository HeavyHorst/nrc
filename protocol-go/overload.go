package protocol

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"math/rand/v2"
	"time"
)

const (
	DBConnectionOverloaded = "db_connection_overloaded"
	DBWorkerOverloaded     = "db_worker_overloaded"
	DBRetryWindow          = 2 * time.Second
)

// DatabaseRetryDelay returns the minimum delay for a pre-admission refusal.
// attempt is zero-based; callers add jitter and stop at DBRetryWindow. Never
// use this policy for a timeout or a lost connection with an unknown outcome.
func DatabaseRetryDelay(code string, attempt int) (time.Duration, bool) {
	if attempt < 0 || attempt >= 3 {
		return 0, false
	}
	var base time.Duration
	switch code {
	case DBConnectionOverloaded:
		base = 50 * time.Millisecond
	case DBWorkerOverloaded:
		base = 150 * time.Millisecond
	default:
		return 0, false
	}
	return base << attempt, true
}

// RetryDatabaseRequest retries only explicit matching overload responses, on
// the same connection. exchange must honor ctx and return the matching reply;
// it must not reconnect or retry transport errors itself. Exhaustion returns
// the last refusal unchanged so callers retain the server's error details.
func RetryDatabaseRequest(ctx context.Context, opcode uint16, correlationID uint32, exchange func(context.Context) (*Message, error)) (*Message, error) {
	deadline := time.Now().Add(DBRetryWindow)
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		response, err := exchange(ctx)
		if err != nil {
			return response, err
		}
		base, retry := DatabaseRetryDelay(DatabaseOverload(response, opcode, correlationID), attempt)
		if !retry {
			return response, nil
		}
		delay := base + time.Duration(rand.Int64N(int64(base/2)))
		if !time.Now().Add(delay).Before(deadline) {
			return response, nil
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
		if !time.Now().Before(deadline) {
			return response, nil
		}
	}
}

// DatabaseOverload recognizes correlated pre-admission refusals, including the
// legacy task read envelopes. The response body excludes the wire opcode.
func DatabaseOverload(response *Message, requestOpcode uint16, correlationID uint32) string {
	if response == nil || len(response.Data) > 1024 {
		return ""
	}
	if response.Opcode == S_DMError && requestOpcode >= C_StartDM && requestOpcode <= C_LeaveDM {
		r, err := DecodeDMError(response.Data)
		if err == nil && r.CorrelationID == correlationID {
			if _, ok := DatabaseRetryDelay(r.Message, 0); ok {
				return r.Message
			}
		}
		return ""
	}
	if response.Opcode == 168 && requestOpcode == 62 && len(response.Data) >= 4 {
		var page struct {
			Error string `json:"error"`
		}
		if binary.BigEndian.Uint32(response.Data) == correlationID && json.Unmarshal(response.Data[4:], &page) == nil {
			if _, ok := DatabaseRetryDelay(page.Error, 0); ok {
				return page.Error
			}
		}
		return ""
	}
	if response.Opcode == S_ErrorResponse {
		r, err := DecodeErrorResponse(response.Data)
		if err == nil && r.OriginOpcode == requestOpcode && r.CorrelationID == correlationID {
			if _, ok := DatabaseRetryDelay(r.ErrorMessage, 0); ok {
				return r.ErrorMessage
			}
		}
		return ""
	}
	// These read responses have a success byte after conv_id and end in
	// error_length + error + correlation_id. Successful payloads never retry.
	matching := (response.Opcode == S_TaskListResponse && requestOpcode >= C_CreateTask && requestOpcode <= C_GetTasks) ||
		(response.Opcode == S_TaskListPage && (requestOpcode == C_ListTasksPaged || requestOpcode == C_GetTasksByIDs)) ||
		(response.Opcode == S_TaskFull && requestOpcode == C_GetTask) ||
		(response.Opcode == S_TaskQueryPage && requestOpcode == C_QueryTasks) ||
		(response.Opcode == S_TaskSliceList && requestOpcode == C_ListTaskSlices) ||
		(response.Opcode == S_WorkspaceOverview && requestOpcode == C_GetWorkspaceOverview)
	b := response.Data
	if !matching || len(b) < 15 || b[8] != 0 || binary.BigEndian.Uint32(b[len(b)-4:]) != correlationID {
		return ""
	}
	for _, code := range []string{DBConnectionOverloaded, DBWorkerOverloaded} {
		start := len(b) - 4 - len(code)
		if start >= 11 && int(binary.BigEndian.Uint16(b[start-2:])) == len(code) && string(b[start:len(b)-4]) == code {
			return code
		}
	}
	return ""
}
